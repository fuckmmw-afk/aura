#import "AUVision.h"
#import "AUImage.h"
#import "Core/AUCompat.h"
#import "Core/AUCore.h"
#import "Core/AUModelManager.h"
#import <Accelerate/Accelerate.h>
#import <CoreImage/CoreImage.h>
#import <CoreML/CoreML.h>
#import <Vision/Vision.h>

static CIContext *ciContext(void) {
    static CIContext *context;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        context = [CIContext contextWithOptions:@{kCIContextCacheIntermediates: @NO, kCIContextUseSoftwareRenderer: @NO}];
    });
    return context;
}

// A Core Image result as plain 8-bit sRGB: Core Image's own default can be a float format a texture loader reads wrong.
static CGImageRef rgba8(CIImage *image, CGRect rect) {
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGImageRef made = [ciContext() createCGImage:[image imageByCroppingToRect:rect] fromRect:rect format:kCIFormatRGBA8 colorSpace:space];
    CGColorSpaceRelease(space);
    return made;
}

static MLFeatureValue *imageFeature(MLModel *model, NSString *name, CGImageRef image, NSString **error) {
    MLFeatureDescription *description = model.modelDescription.inputDescriptionsByName[name];
    MLImageConstraint *constraint = description.imageConstraint;
    if (!constraint) {
        if (error) *error = [NSString stringWithFormat:@"the model has no image input %@", name];
        return nil;
    }
    NSError *e = nil;
    MLFeatureValue *value = [MLFeatureValue featureValueWithCGImage:image constraint:constraint
                                                            options:@{MLFeatureValueImageOptionCropAndScale: @(VNImageCropAndScaleOptionScaleFill)}
                                                              error:&e];
    if (!value && error) *error = e.localizedDescription;
    return value;
}

#pragma mark - depth

CGImageRef AUDepthMap(CGImageRef image, NSString **error) {
    MLModel *model = [AUModelManager.shared modelFor:AUModelDepth];
    if (!model) {
        if (error) *error = @"model not ready";
        return NULL;
    }
    MLFeatureValue *input = imageFeature(model, @"image", image, error);
    if (!input) return NULL;
    NSError *e = nil;
    MLDictionaryFeatureProvider *features = [[MLDictionaryFeatureProvider alloc] initWithDictionary:@{@"image": input} error:&e];
    id<MLFeatureProvider> output = features ? [model predictionFromFeatures:features error:&e] : nil;
    CVPixelBufferRef buffer = [output featureValueForName:@"depth"].imageBufferValue;
    if (!buffer) {
        if (error) *error = e.localizedDescription ?: @"no depth output";
        return NULL;
    }
    size_t width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer), n = width * height;
    OSType format = CVPixelBufferGetPixelFormatType(buffer);
    float *values = malloc(n * sizeof(float));
    CVPixelBufferLockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly);
    uint8_t *base = CVPixelBufferGetBaseAddress(buffer);
    size_t rowBytes = CVPixelBufferGetBytesPerRow(buffer);
    BOOL read = YES;
    for (size_t y = 0; y < height && read; y++) {
        void *row = base + y * rowBytes;
        if (format == kCVPixelFormatType_OneComponent16Half) {
            vImage_Buffer src = {row, 1, width, width * 2}, dst = {values + y * width, 1, width, width * 4};
            vImageConvert_Planar16FtoPlanarF(&src, &dst, 0);
        } else if (format == kCVPixelFormatType_OneComponent32Float) {
            memcpy(values + y * width, row, width * 4);
        } else if (format == kCVPixelFormatType_OneComponent8) {
            vDSP_vfltu8(row, 1, values + y * width, 1, width);
        } else {
            read = NO;
        }
    }
    CVPixelBufferUnlockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly);
    if (!read) {
        free(values);
        if (error) *error = [NSString stringWithFormat:@"depth comes as %c%c%c%c", (char)(format >> 24), (char)(format >> 16), (char)(format >> 8), (char)format];
        return NULL;
    }
    // The 1st and 99th percentiles from a 512 bin histogram: one stray pixel should not flatten the rest.
    float lo, hi;
    vDSP_minv(values, 1, &lo, n);
    vDSP_maxv(values, 1, &hi, n);
    if (!(hi > lo)) hi = lo + 1;
    enum { kBins = 512 };
    size_t histogram[kBins] = {0};
    float binScale = (kBins - 1) / (hi - lo);
    for (size_t i = 0; i < n; i++) histogram[(int)((values[i] - lo) * binScale)]++;
    size_t acc = 0, loBin = 0, hiBin = kBins - 1;
    for (int b = 0; b < kBins; b++) {
        acc += histogram[b];
        if (acc < n / 100) loBin = b;
        if (acc <= n - n / 100) hiBin = b;
    }
    float pLo = lo + loBin / binScale, pHi = lo + (hiBin + 1) / binScale;
    if (!(pHi > pLo)) pHi = pLo + 1e-3f;
    float scale = 255.0f / (pHi - pLo), offset = -pLo * scale, zero = 0, top = 255;
    vDSP_vsmsa(values, 1, &scale, &offset, values, 1, n);
    vDSP_vclip(values, 1, &zero, &top, values, 1, n);
    uint8_t *bytes = malloc(n), *soft = malloc(n);
    vDSP_vfixu8(values, 1, bytes, 1, n);
    free(values);
    vImage_Buffer src = {bytes, height, width, width}, dst = {soft, height, width, width};
    vImageTentConvolve_Planar8(&src, &dst, NULL, 0, 0, 7, 7, 0, kvImageEdgeExtend);
    CGImageRef map = AUGrayImage(soft, width, height);
    free(bytes);
    free(soft);
    return map;
}

#pragma mark - cutout

void AUCutoutResultRelease(AUCutoutResult *result) {
    if (result->cutout) CGImageRelease(result->cutout);
    if (result->background) CGImageRelease(result->background);
    result->cutout = result->background = NULL;
}

AUCutoutResult AUCutoutSubject(CGImageRef image, BOOL objects, NSString **error) {
    AUCutoutResult result = {NULL, NULL, CGRectZero, 0};
    if (@available(iOS 17.0, *)) {
        Class requestClass = NSClassFromString(objects ? @"VNGenerateForegroundInstanceMaskRequest" : @"VNGeneratePersonInstanceMaskRequest");
        if (!requestClass) {
            if (error) *error = @"no instance mask request";
            return result;
        }
        VNImageRequestHandler *handler = [[VNImageRequestHandler alloc] initWithCGImage:image options:@{}];
        VNImageBasedRequest *request = [requestClass new];
        NSError *e = nil;
        if (![handler performRequests:@[request] error:&e]) {
            if (error) *error = e.localizedDescription ?: @"Vision failed";
            return result;
        }
        VNInstanceMaskObservation *observation = (VNInstanceMaskObservation *)request.results.firstObject;
        if (![observation respondsToSelector:@selector(allInstances)] || !observation.allInstances.count) {
            if (error) *error = @"no subject";
            return result;
        }
        CVPixelBufferRef mask = [observation generateScaledMaskForImageForInstances:observation.allInstances fromRequestHandler:handler error:&e];
        if (!mask) {
            if (error) *error = e.localizedDescription ?: @"no mask";
            return result;
        }
        size_t width = CGImageGetWidth(image), height = CGImageGetHeight(image);
        size_t mw = CVPixelBufferGetWidth(mask), mh = CVPixelBufferGetHeight(mask);
        uint8_t *alpha = malloc(mw * mh);
        CVPixelBufferLockBaseAddress(mask, kCVPixelBufferLock_ReadOnly);
        vImage_Buffer src = {CVPixelBufferGetBaseAddress(mask), mh, mw, CVPixelBufferGetBytesPerRow(mask)};
        vImage_Buffer dst = {alpha, mh, mw, mw};
        BOOL converted = CVPixelBufferGetPixelFormatType(mask) == kCVPixelFormatType_OneComponent32Float
            && vImageConvert_PlanarFtoPlanar8(&src, &dst, 1, 0, 0) == kvImageNoError;
        CVPixelBufferUnlockBaseAddress(mask, kCVPixelBufferLock_ReadOnly);
        CVPixelBufferRelease(mask);
        if (!converted) {
            free(alpha);
            if (error) *error = @"mask format";
            return result;
        }
        // Coverage and the subject's box, rows top first.
        size_t minX = mw, minY = mh, maxX = 0, maxY = 0;
        double sum = 0;
        for (size_t y = 0; y < mh; y++) {
            for (size_t x = 0; x < mw; x++) {
                uint8_t a = alpha[y * mw + x];
                sum += a;
                if (a > 127) {
                    if (x < minX) minX = x;
                    if (x > maxX) maxX = x;
                    if (y < minY) minY = y;
                    if (y > maxY) maxY = y;
                }
            }
        }
        double coverage = sum / 255.0 / (mw * mh);
        if (coverage < 0.03 || coverage > 0.85 || maxX <= minX || maxY <= minY) {
            free(alpha);
            if (error) *error = [NSString stringWithFormat:@"subject covers %.0f%%", coverage * 100];
            return result;
        }
        CGImageRef maskImage = AUGrayImage(alpha, mw, mh);
        free(alpha);
        CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        CGContextRef context = CGBitmapContextCreate(NULL, width, height, 8, 0, space, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
        CGColorSpaceRelease(space);
        CGRect all = CGRectMake(0, 0, width, height);
        CGContextClipToMask(context, all, maskImage);
        CGContextDrawImage(context, all, image);
        result.cutout = CGBitmapContextCreateImage(context);
        CGContextRelease(context);

        // The background: the cover blurred (its edges clamped so the blur does not darken them) and dimmed where
        // the subject stood, so the subject's own ghost does not show behind it as it moves.
        CIImage *cover = [CIImage imageWithCGImage:image];
        double radius = MAX(width, height) * 0.035;
        CIImage *blurred = [[cover imageByClampingToExtent] imageByApplyingGaussianBlurWithSigma:radius];
        CIImage *maskCI = [[[CIImage imageWithCGImage:maskImage] imageByClampingToExtent] imageByApplyingGaussianBlurWithSigma:radius * 0.6];
        CIImage *dim = [blurred imageByApplyingFilter:@"CIColorControls" withInputParameters:@{@"inputBrightness": @(-0.08), @"inputSaturation": @1.05}];
        CIImage *mixed = [dim imageByApplyingFilter:@"CIBlendWithMask" withInputParameters:@{@"inputBackgroundImage": blurred, @"inputMaskImage": maskCI}];
        result.background = rgba8(mixed, cover.extent);
        CGImageRelease(maskImage);
        result.bounds = CGRectMake((double)minX / mw, (double)minY / mh, (double)(maxX - minX + 1) / mw, (double)(maxY - minY + 1) / mh);
        result.coverage = coverage;
        return result;
    }
    if (error) *error = @"needs iOS 17";
    return result;
}

#pragma mark - upscale

CGImageRef AUUpscaled(CGImageRef image, size_t maxSide, NSString **error) {
    MLModel *model = [AUModelManager.shared modelFor:AUModelUpscale];
    if (!model) {
        if (error) *error = @"model not ready";
        return NULL;
    }
    MLImageConstraint *constraint = model.modelDescription.inputDescriptionsByName[@"image"].imageConstraint;
    size_t tile = constraint.pixelsWide;
    if (!tile || constraint.pixelsHigh != (NSInteger)tile) {
        if (error) *error = @"the model's tile is not square";
        return NULL;
    }
    const size_t scale = 4, overlap = 8;
    // Smaller than a tile: drawn up to one first, so the tile is the whole cover.
    size_t width = CGImageGetWidth(image), height = CGImageGetHeight(image);
    CGImageRef source = width < tile || height < tile ? AUImageResized(image, MAX(width, tile), MAX(height, tile)) : CGImageRetain(image);
    width = CGImageGetWidth(source);
    height = CGImageGetHeight(source);
    NSArray<NSValue *> *tiles = AUTiles(width, height, tile, overlap);
    NSMutableArray<id<MLFeatureProvider>> *inputs = [NSMutableArray array];
    for (NSValue *value in tiles) {
        CGImageRef part = CGImageCreateWithImageInRect(source, value.CGRectValue);
        MLFeatureValue *feature = part ? imageFeature(model, @"image", part, error) : nil;
        if (part) CGImageRelease(part);
        MLDictionaryFeatureProvider *provider = feature ? [[MLDictionaryFeatureProvider alloc] initWithDictionary:@{@"image": feature} error:nil] : nil;
        if (!provider) {
            CGImageRelease(source);
            return NULL;
        }
        [inputs addObject:provider];
    }
    NSError *e = nil;
    id<MLBatchProvider> outputs = [model predictionsFromBatch:[[MLArrayBatchProvider alloc] initWithFeatureProviderArray:inputs] error:&e];
    if (!outputs || outputs.count != (NSInteger)tiles.count) {
        CGImageRelease(source);
        if (error) *error = e.localizedDescription ?: @"batch failed";
        return NULL;
    }
    size_t outWidth = width * scale, outHeight = height * scale;
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef canvas = CGBitmapContextCreate(NULL, outWidth, outHeight, 8, 0, space, kCGImageAlphaNoneSkipLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(space);
    for (NSUInteger i = 0; i < tiles.count; i++) {
        CVPixelBufferRef buffer = [[outputs featuresAtIndex:i] featureValueForName:@"upscaled"].imageBufferValue;
        if (!buffer) continue;
        CGRect rect = tiles[i].CGRectValue;
        // Where this tile's pixels are kept: up to the middle of each overlap with a neighbour, to the edge otherwise.
        CGFloat left = rect.origin.x == 0 ? 0 : overlap / 2, top = rect.origin.y == 0 ? 0 : overlap / 2;
        CGFloat right = CGRectGetMaxX(rect) >= width ? 0 : overlap / 2, bottom = CGRectGetMaxY(rect) >= height ? 0 : overlap / 2;
        CIImage *output = [CIImage imageWithCVPixelBuffer:buffer];
        CGImageRef made = rgba8(output, output.extent);
        if (!made) continue;
        // Core Graphics counts from the bottom: a tile at y from the top lands at outHeight - (y + h) * scale.
        CGRect target = CGRectMake(rect.origin.x * scale, outHeight - CGRectGetMaxY(rect) * scale, rect.size.width * scale, rect.size.height * scale);
        CGRect keep = CGRectMake(target.origin.x + left * scale, target.origin.y + bottom * scale,
                                 target.size.width - (left + right) * scale, target.size.height - (top + bottom) * scale);
        CGContextSaveGState(canvas);
        CGContextClipToRect(canvas, keep);
        CGContextDrawImage(canvas, target, made);
        CGContextRestoreGState(canvas);
        CGImageRelease(made);
    }
    CGImageRef full = CGBitmapContextCreateImage(canvas);
    CGContextRelease(canvas);
    CGImageRelease(source);
    if (!full) return NULL;
    CGImageRef sized = AUImageNormalized(full, maxSide);
    CGImageRelease(full);
    return sized;
}
