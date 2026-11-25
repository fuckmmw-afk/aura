#import "AUSam.h"
#import "Core/AUCore.h"
#import "Core/AUModelManager.h"
#import "Core/AUTune.h"
#import "Features/AUImage.h"
#import <Accelerate/Accelerate.h>
#import <CoreML/CoreML.h>

enum { kLow = 256 };

typedef struct {
    float score;
    size_t area;
    uint8_t *mask;      // kLow x kLow, 0/255 at logit > 0
    float *logits;      // kLow x kLow
    int x0, y0, x1, y1;
} AUCandidate;

static MLMultiArray *array(NSArray<NSNumber *> *shape, MLMultiArrayDataType type) {
    return [[MLMultiArray alloc] initWithShape:shape dataType:type error:nil];
}

static float valueAt(MLMultiArray *a, NSInteger index) {
    if (a.dataType == MLMultiArrayDataTypeFloat32) return ((const float *)a.dataPointer)[index];
    if (a.dataType == MLMultiArrayDataTypeDouble) return (float)((const double *)a.dataPointer)[index];
    if (@available(iOS 16.0, macCatalyst 16.0, *)) {
        if (a.dataType == MLMultiArrayDataTypeFloat16) return (float)((const __fp16 *)a.dataPointer)[index];
    }
    return [a[index] floatValue];
}

// The element at [0, k, y, x] of a 4-D array, by its strides.
static inline NSInteger offset4(MLMultiArray *a, int k, int y, int x) {
    NSArray<NSNumber *> *st = a.strides;
    return k * st[1].integerValue + y * st[2].integerValue + x * st[3].integerValue;
}

static size_t median(const uint8_t *depth, const uint8_t *mask, size_t n, BOOL inside, size_t *count) {
    size_t histogram[256] = {0}, total = 0;
    for (size_t i = 0; i < n; i++) {
        if ((mask[i] >= 128) != inside) continue;
        histogram[depth[i]]++;
        total++;
    }
    *count = total;
    size_t seen = 0;
    for (int v = 0; v < 256; v++) {
        seen += histogram[v];
        if (seen * 2 >= total) return (size_t)v;
    }
    return 0;
}

NSArray<NSData *> *AUSamObjects(CGImageRef square, size_t side, const uint8_t *depth, const uint8_t *taken, NSUInteger limit,
                                NSString **log) {
    AUModelManager *models = AUModelManager.shared;
    MLModel *encoder = [models modelFor:AUModelSamEncoder], *prompt = [models modelFor:AUModelSamPrompt],
            *decoder = [models modelFor:AUModelSamDecoder];
    if (!encoder || !prompt || !decoder) {
        for (NSString *model in @[AUModelSamEncoder, AUModelSamPrompt, AUModelSamDecoder]) [models ensure:model];
        if (log) *log = @"SAM not ready";
        return nil;
    }
    double started = AUNowMs();
    NSError *error = nil;
    MLImageConstraint *constraint = encoder.modelDescription.inputDescriptionsByName[@"image"].imageConstraint;
    MLFeatureValue *image = [MLFeatureValue featureValueWithCGImage:square constraint:constraint options:nil error:&error];
    id<MLFeatureProvider> encoded = image ? [encoder predictionFromFeatures:[[MLDictionaryFeatureProvider alloc]
        initWithDictionary:@{@"image": image} error:nil] error:&error] : nil;
    if (!encoded) {
        if (log) *log = [NSString stringWithFormat:@"SAM encoder: %@", error.localizedDescription ?: @"?"];
        return nil;
    }
    double encodedMs = AUNowMs() - started;
    MLFeatureValue *embedding = [encoded featureValueForName:@"image_embedding"], *s0 = [encoded featureValueForName:@"feats_s0"],
                   *s1 = [encoded featureValueForName:@"feats_s1"];
    double inputSide = constraint.pixelsWide ?: 1024;
    // The numbers are Core/AUTune's.
    const int kGrid = (int)lround(AUTune(@"samGrid"));
    const float minScore = (float)AUTune(@"samScore");
    const double stability = AUTune(@"samStability"), minArea = AUTune(@"samMinArea"), maxArea = AUTune(@"samMaxArea");
    const double contrast = AUTune(@"samContrast");
    AUCandidate *candidates = calloc(kGrid * kGrid * 3, sizeof(AUCandidate));
    int found = 0;
    for (int gy = 0; gy < kGrid; gy++) {
        for (int gx = 0; gx < kGrid; gx++) {
            @autoreleasepool {
                MLMultiArray *points = array(@[@1, @1, @2], MLMultiArrayDataTypeFloat32), *labels = array(@[@1, @1], MLMultiArrayDataTypeInt32);
                ((float *)points.dataPointer)[0] = (float)((gx + 0.5) / kGrid * inputSide);
                ((float *)points.dataPointer)[1] = (float)((gy + 0.5) / kGrid * inputSide);
                ((int32_t *)labels.dataPointer)[0] = 1;
                id<MLFeatureProvider> prompted = [prompt predictionFromFeatures:[[MLDictionaryFeatureProvider alloc] initWithDictionary:@{
                    @"points": points, @"labels": labels} error:nil] error:&error];
                if (!prompted) continue;
                id<MLFeatureProvider> decoded = [decoder predictionFromFeatures:[[MLDictionaryFeatureProvider alloc] initWithDictionary:@{
                    @"image_embedding": embedding, @"sparse_embedding": [prompted featureValueForName:@"sparse_embeddings"],
                    @"dense_embedding": [prompted featureValueForName:@"dense_embeddings"], @"feats_s0": s0, @"feats_s1": s1} error:nil]
                                                                        error:&error];
                if (!decoded) continue;
                MLMultiArray *masks = [decoded featureValueForName:@"low_res_masks"].multiArrayValue;
                MLMultiArray *scores = [decoded featureValueForName:@"scores"].multiArrayValue;
                if (masks.count < 3 * kLow * kLow || scores.count < 3) continue;
                for (int k = 0; k < 3; k++) {
                    float score = valueAt(scores, k * scores.strides.lastObject.integerValue);
                    if (score < minScore) continue;
                    float *logits = malloc(sizeof(float) * kLow * kLow);
                    uint8_t *mask = calloc(kLow * kLow, 1);
                    size_t area = 0, loose = 0, strict = 0;
                    int x0 = kLow, y0 = kLow, x1 = -1, y1 = -1;
                    NSInteger sk = offset4(masks, k, 0, 0), sy = offset4(masks, 0, 1, 0), sx = offset4(masks, 0, 0, 1);
                    for (int i = 0; i < kLow * kLow; i++) {
                        float v = valueAt(masks, sk + (i / kLow) * sy + (i % kLow) * sx);
                        logits[i] = v;
                        if (v > -1) loose++;
                        if (v > 1) strict++;
                        if (v <= 0) continue;
                        mask[i] = 255;
                        area++;
                        int x = i % kLow, y = i / kLow;
                        x0 = MIN(x0, x); x1 = MAX(x1, x); y0 = MIN(y0, y); y1 = MAX(y1, y);
                    }
                    // Stable (the edge does not wander with the threshold), and an object's size, not the whole picture.
                    double share = area / (double)(kLow * kLow);
                    int borders = (x0 <= 1) + (y0 <= 1) + (x1 >= kLow - 2) + (y1 >= kLow - 2);
                    if (!loose || strict / (double)loose < stability || share < minArea || share > maxArea || borders >= 3) {
                        free(logits);
                        free(mask);
                        continue;
                    }
                    candidates[found++] = (AUCandidate){score, area, mask, logits, x0, y0, x1, y1};
                }
            }
        }
    }
    double decodedMs = AUNowMs() - started - encodedMs;
    // Best first; one that mostly repeats a kept one (another point on the same sheep) goes.
    qsort_b(candidates, found, sizeof(AUCandidate), ^int(const void *a, const void *b) {
        float sa = ((const AUCandidate *)a)->score, sb = ((const AUCandidate *)b)->score;
        return sa < sb ? 1 : sa > sb ? -1 : 0;
    });
    uint8_t *claimed = calloc(kLow * kLow, 1);
    // What other objects already hold, at the low size.
    if (taken) {
        CGImageRef full = AUGrayImage(taken, side, side);
        CGColorSpaceRef gray = CGColorSpaceCreateDeviceGray();
        CGContextRef c = CGBitmapContextCreate(claimed, kLow, kLow, 8, kLow, gray, (CGBitmapInfo)kCGImageAlphaNone);
        CGColorSpaceRelease(gray);
        CGContextSetInterpolationQuality(c, kCGInterpolationHigh);
        CGContextDrawImage(c, CGRectMake(0, 0, kLow, kLow), full);
        CGContextRelease(c);
        if (full) CGImageRelease(full);
        for (int i = 0; i < kLow * kLow; i++) claimed[i] = claimed[i] >= 128 ? 255 : 0;
    }
    uint8_t *depthLow = NULL;
    if (depth) {
        depthLow = malloc(kLow * kLow);
        CGImageRef full = AUGrayImage(depth, side, side);
        CGColorSpaceRef gray = CGColorSpaceCreateDeviceGray();
        CGContextRef c = CGBitmapContextCreate(depthLow, kLow, kLow, 8, kLow, gray, (CGBitmapInfo)kCGImageAlphaNone);
        CGColorSpaceRelease(gray);
        CGContextSetInterpolationQuality(c, kCGInterpolationHigh);
        CGContextDrawImage(c, CGRectMake(0, 0, kLow, kLow), full);
        CGContextRelease(c);
        if (full) CGImageRelease(full);
    }
    NSMutableArray<NSData *> *result = [NSMutableArray array];
    NSMutableArray<NSString *> *kept = [NSMutableArray array];
    uint8_t *ring = malloc(kLow * kLow), *own = malloc(kLow * kLow);
    for (int c = 0; c < found && result.count < limit; c++) {
        AUCandidate *candidate = &candidates[c];
        size_t free_ = 0;
        for (int i = 0; i < kLow * kLow; i++) {
            own[i] = candidate->mask[i] && !claimed[i] ? 255 : 0;
            free_ += own[i] != 0;
        }
        if (free_ < candidate->area * 0.6 || free_ < kLow * kLow * minArea) continue;
        // In front of its surroundings: its median depth over that of a ring around it.
        if (depthLow) {
            vImage_Buffer ob = {own, kLow, kLow, kLow}, rb = {ring, kLow, kLow, kLow};
            vImageMax_Planar8(&ob, &rb, NULL, 0, 0, 13, 13, kvImageEdgeExtend);
            for (int i = 0; i < kLow * kLow; i++) ring[i] = ring[i] && !own[i] ? 255 : 0;
            size_t inCount = 0, ringCount = 0;
            size_t inside = median(depthLow, own, kLow * kLow, YES, &inCount);
            size_t around = median(depthLow, ring, kLow * kLow, YES, &ringCount);
            if (ringCount && (double)inside - (double)around < contrast * 255) continue;
            [kept addObject:[NSString stringWithFormat:@"%.0f%%/%.2f", 100.0 * free_ / (kLow * kLow), ((double)inside - around) / 255]];
        }
        for (int i = 0; i < kLow * kLow; i++) if (own[i]) claimed[i] = 255;
        // The soft edge from the logits (sigmoid-ish over -2...2), only where this object is kept, at full size.
        uint8_t *soft = malloc(kLow * kLow);
        for (int i = 0; i < kLow * kLow; i++) {
            double t = MAX(0.0, MIN(1.0, (candidate->logits[i] + 2) / 4));
            BOOL near = own[i] || (candidate->mask[i] == 0 && !claimed[i]);
            soft[i] = near ? (uint8_t)lround(255 * t * t * (3 - 2 * t)) : 0;
            if (candidate->mask[i] && !own[i]) soft[i] = 0;
        }
        CGImageRef small = AUGrayImage(soft, kLow, kLow);
        free(soft);
        NSMutableData *big = [NSMutableData dataWithLength:side * side];
        CGColorSpaceRef gray = CGColorSpaceCreateDeviceGray();
        CGContextRef bc = CGBitmapContextCreate(big.mutableBytes, side, side, 8, side, gray, (CGBitmapInfo)kCGImageAlphaNone);
        CGColorSpaceRelease(gray);
        CGContextSetInterpolationQuality(bc, kCGInterpolationHigh);
        CGContextDrawImage(bc, CGRectMake(0, 0, side, side), small);
        CGContextRelease(bc);
        if (small) CGImageRelease(small);
        [result addObject:big];
    }
    free(ring);
    free(own);
    free(claimed);
    free(depthLow);
    for (int c = 0; c < found; c++) {
        free(candidates[c].mask);
        free(candidates[c].logits);
    }
    free(candidates);
    if (log) {
        *log = [NSString stringWithFormat:@"SAM: %d candidates, %lu objects [%@], encoder %.0f ms, %d points %.0f ms",
                found, (unsigned long)result.count, [kept componentsJoinedByString:@" "], encodedMs, kGrid * kGrid, decodedMs];
    }
    return result;
}
