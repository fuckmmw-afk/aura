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

// The cover with the subject's room filled from what is around it and softened, by normalized convolution at 256 px:
// blur(cover x keep) / blur(keep), keep being 0 on the subject (grown a little) and 1 elsewhere. Scaled back up to
// the cover's size, which the blur makes smooth.
static CGImageRef inpaintedBackground(CGImageRef cover, CGImageRef mask) {
    enum { kSide = 256 };
    const size_t n = kSide * kSide;
    uint8_t *rgba = calloc(n * 4, 1), *m8 = calloc(n, 1), *grown = calloc(n, 1);
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef c = CGBitmapContextCreate(rgba, kSide, kSide, 8, kSide * 4, space, kCGImageAlphaNoneSkipLast | kCGBitmapByteOrder32Big);
    CGContextSetInterpolationQuality(c, kCGInterpolationHigh);
    CGContextDrawImage(c, CGRectMake(0, 0, kSide, kSide), cover);
    CGContextRelease(c);
    CGColorSpaceRef gray = CGColorSpaceCreateDeviceGray();
    CGContextRef g = CGBitmapContextCreate(m8, kSide, kSide, 8, kSide, gray, (CGBitmapInfo)kCGImageAlphaNone);
    CGContextDrawImage(g, CGRectMake(0, 0, kSide, kSide), mask);
    CGContextRelease(g);
    CGColorSpaceRelease(gray);
    vImage_Buffer m8b = {m8, kSide, kSide, kSide}, grownb = {grown, kSide, kSide, kSide};
    vImageMax_Planar8(&m8b, &grownb, NULL, 0, 0, 9, 9, kvImageEdgeExtend);
    float *keep = malloc(n * sizeof(float)), *channel = malloc(n * sizeof(float)), *num = malloc(n * sizeof(float));
    float *den = malloc(n * sizeof(float)), *tmp = malloc(n * sizeof(float));
    for (size_t i = 0; i < n; i++) keep[i] = 1.0f - grown[i] / 255.0f;
    // A gaussian of sigma ~6% of the side, as one separable kernel.
    enum { kRadius = 30 };
    float kernel[2 * kRadius + 1], sum = 0, sigma = kSide * 0.06f;
    for (int i = -kRadius; i <= kRadius; i++) sum += kernel[i + kRadius] = expf(-(float)(i * i) / (2 * sigma * sigma));
    for (int i = 0; i <= 2 * kRadius; i++) kernel[i] /= sum;
    vImage_Buffer keepb = {keep, kSide, kSide, kSide * sizeof(float)}, denb = {den, kSide, kSide, kSide * sizeof(float)};
    vImage_Buffer tmpb = {tmp, kSide, kSide, kSide * sizeof(float)}, numb = {num, kSide, kSide, kSide * sizeof(float)};
    vImageSepConvolve_PlanarF(&keepb, &denb, NULL, 0, 0, kernel, 2 * kRadius + 1, kernel, 2 * kRadius + 1, 0, 0, kvImageEdgeExtend);
    uint8_t *out = calloc(n * 4, 1);
    for (int ch = 0; ch < 3; ch++) {
        double mean = 0;
        for (size_t i = 0; i < n; i++) {
            channel[i] = rgba[i * 4 + ch] / 255.0f;
            mean += channel[i];
            tmp[i] = channel[i] * keep[i];
        }
        mean /= n;
        vImageSepConvolve_PlanarF(&tmpb, &numb, NULL, 0, 0, kernel, 2 * kRadius + 1, kernel, 2 * kRadius + 1, 0, 0, kvImageEdgeExtend);
        for (size_t i = 0; i < n; i++) {
            // Where the subject took everything around, the cover's own mean stands in; slightly dimmed throughout,
            // so the subject reads in front of it.
            float value = (num[i] + (float)mean * 1e-3f) / (den[i] + 1e-3f);
            out[i * 4 + ch] = (uint8_t)lroundf(fminf(1, fmaxf(0, value * 0.9f)) * 255);
        }
    }
    for (size_t i = 0; i < n; i++) out[i * 4 + 3] = 255;
    CGContextRef o = CGBitmapContextCreate(out, kSide, kSide, 8, kSide * 4, space, kCGImageAlphaNoneSkipLast | kCGBitmapByteOrder32Big);
    CGImageRef small = CGBitmapContextCreateImage(o);
    CGContextRelease(o);
    CGColorSpaceRelease(space);
    free(rgba); free(m8); free(grown); free(keep); free(channel); free(num); free(den); free(tmp); free(out);
    CGImageRef full = AUImageResized(small, CGImageGetWidth(cover), CGImageGetHeight(cover));
    CGImageRelease(small);
    return full;
}

void AUCutoutResultRelease(AUCutoutResult *result) {
    if (result->cutout) CGImageRelease(result->cutout);
    if (result->background) CGImageRelease(result->background);
    result->cutout = result->background = NULL;
}

static uint8_t sg_curve[256];

// One instance's mask as 8-bit, at the image's size, or NULL. `mw`/`mh` set by the first, later ones must match.
static uint8_t *instanceMask(VNInstanceMaskObservation *observation, NSUInteger index, VNImageRequestHandler *handler,
                             size_t *mw, size_t *mh) API_AVAILABLE(ios(17.0)) {
    NSError *e = nil;
    CVPixelBufferRef mask = [observation generateScaledMaskForImageForInstances:[NSIndexSet indexSetWithIndex:index]
                                                             fromRequestHandler:handler error:&e];
    if (!mask) return NULL;
    size_t w = CVPixelBufferGetWidth(mask), h = CVPixelBufferGetHeight(mask);
    uint8_t *bytes = NULL;
    if ((!*mw || (w == *mw && h == *mh)) && CVPixelBufferGetPixelFormatType(mask) == kCVPixelFormatType_OneComponent32Float) {
        *mw = w;
        *mh = h;
        bytes = malloc(w * h);
        CVPixelBufferLockBaseAddress(mask, kCVPixelBufferLock_ReadOnly);
        vImage_Buffer src = {CVPixelBufferGetBaseAddress(mask), h, w, CVPixelBufferGetBytesPerRow(mask)};
        vImage_Buffer dst = {bytes, h, w, w};
        if (vImageConvert_PlanarFtoPlanar8(&src, &dst, 1, 0, 0) != kvImageNoError) {
            free(bytes);
            bytes = NULL;
        }
        CVPixelBufferUnlockBaseAddress(mask, kCVPixelBufferLock_ReadOnly);
    }
    CVPixelBufferRelease(mask);
    return bytes;
}

AUCutoutResult AUCutoutSubject(CGImageRef image, BOOL objects, NSString **error) {
    AUCutoutResult result = {NULL, NULL, CGRectZero, 0};
    if (@available(iOS 17.0, *)) {
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            for (int i = 0; i < 256; i++) {
                float x = fminf(1, fmaxf(0, (i / 255.0f - 0.25f) / 0.35f));
                sg_curve[i] = (uint8_t)lroundf(x * x * (3 - 2 * x) * 255);
            }
        });
        Class personClass = NSClassFromString(@"VNGeneratePersonInstanceMaskRequest");
        Class foregroundClass = NSClassFromString(@"VNGenerateForegroundInstanceMaskRequest");
        if (!foregroundClass || (!objects && !personClass)) {
            if (error) *error = @"no instance mask request";
            return result;
        }
        // People, and the foreground subjects (as the Photos app lifts them) in the same pass. Vision is unsure of
        // drawn people (a cover's illustration): it can find a character's legs as a person and the rest only
        // faintly. A foreground subject that the faint person mask covers by a quarter is taken whole as a person.
        VNImageRequestHandler *handler = [[VNImageRequestHandler alloc] initWithCGImage:image options:@{}];
        VNImageBasedRequest *foreground = [foregroundClass new];
        VNImageBasedRequest *person = objects ? nil : [personClass new];
        NSError *e = nil;
        if (![handler performRequests:person ? @[person, foreground] : @[foreground] error:&e]) {
            if (error) *error = e.localizedDescription ?: @"Vision failed";
            return result;
        }
        size_t mw = 0, mh = 0;
        uint8_t *alpha = NULL, *soft = NULL;
        NSUInteger kept = 0;
        // People: each against its own peak, then the smoothstep; `soft` keeps the raw union for the overlap test.
        VNInstanceMaskObservation *people = (VNInstanceMaskObservation *)person.results.firstObject;
        if ([people respondsToSelector:@selector(allInstances)]) {
            NSIndexSet *instances = people.allInstances;
            NSUInteger seen = 0;
            for (NSUInteger index = instances.firstIndex; index != NSNotFound && seen < 8; index = [instances indexGreaterThanIndex:index], seen++) {
                uint8_t *one = instanceMask(people, index, handler, &mw, &mh);
                if (!one) continue;
                if (!alpha) {
                    alpha = calloc(mw * mh, 1);
                    soft = calloc(mw * mh, 1);
                }
                uint8_t peak = 0;
                for (size_t i = 0; i < mw * mh; i++) {
                    if (one[i] > peak) peak = one[i];
                    if (one[i] > soft[i]) soft[i] = one[i];
                }
                if (peak >= 38) {
                    float scale = 255.0f / peak;
                    for (size_t i = 0; i < mw * mh; i++) {
                        uint8_t v = sg_curve[(uint8_t)fminf(255, one[i] * scale)];
                        if (v > alpha[i]) alpha[i] = v;
                    }
                    kept++;
                }
                free(one);
            }
        }
        VNInstanceMaskObservation *subjects = (VNInstanceMaskObservation *)foreground.results.firstObject;
        if ([subjects respondsToSelector:@selector(allInstances)] && (objects || soft)) {
            NSIndexSet *instances = subjects.allInstances;
            NSUInteger seen = 0;
            for (NSUInteger index = instances.firstIndex; index != NSNotFound && seen < 8; index = [instances indexGreaterThanIndex:index], seen++) {
                uint8_t *one = instanceMask(subjects, index, handler, &mw, &mh);
                if (!one) continue;
                if (!alpha) alpha = calloc(mw * mh, 1);
                double area = 0, overlap = 0;
                for (size_t i = 0; i < mw * mh; i++) {
                    area += one[i];
                    if (soft) overlap += one[i] * (soft[i] / 255.0);
                }
                if (objects || (area > 0 && overlap / area > 0.25)) {
                    for (size_t i = 0; i < mw * mh; i++) {
                        uint8_t v = sg_curve[one[i]];
                        if (v > alpha[i]) alpha[i] = v;
                    }
                    kept++;
                }
                free(one);
            }
        }
        free(soft);
        if (!alpha || !kept) {
            free(alpha);
            if (error) *error = objects ? @"no subject" : @"no person";
            return result;
        }
        size_t width = CGImageGetWidth(image), height = CGImageGetHeight(image);
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

        // The background: the cover with the subject's room filled from around it, then blurred, so no ghost of the
        // subject shows behind it as it moves.
        result.background = inpaintedBackground(image, maskImage);
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
