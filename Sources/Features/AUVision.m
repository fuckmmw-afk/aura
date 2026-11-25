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

static CGImageRef softened(CGImageRef depth, size_t divisor, int passes) {
    NSData *bytes = AUGrayBytes(depth);
    if (!bytes) return NULL;
    size_t w = CGImageGetWidth(depth), h = CGImageGetHeight(depth);
    NSMutableData *a = [bytes mutableCopy], *b = [NSMutableData dataWithLength:w * h];
    vImage_Buffer src = {a.mutableBytes, h, w, w}, dst = {b.mutableBytes, h, w, w};
    uint32_t side = (uint32_t)(MAX(w, h) / divisor) | 1;
    for (int pass = 0; pass < passes; pass++) {
        vImageTentConvolve_Planar8(&src, &dst, NULL, 0, 0, side, side, 0, kvImageEdgeExtend);
        vImageTentConvolve_Planar8(&dst, &src, NULL, 0, 0, side, side, 0, kvImageEdgeExtend);
    }
    return AUGrayImage(a.bytes, w, h);
}

CGImageRef AUSoftenedDepth(CGImageRef depth) {
    return softened(depth, 10, 2);
}

CGImageRef AUEasedDepth(CGImageRef depth) {
    return softened(depth, 24, 1);
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
    if (!mask) {
        static NSUInteger told;
        if (told++ < 10) AULog(@"vision: no mask for instance %lu: %@", (unsigned long)index, e.localizedDescription ?: @"?");
        return NULL;
    }
    size_t w = CVPixelBufferGetWidth(mask), h = CVPixelBufferGetHeight(mask);
    uint8_t *bytes = NULL;
    OSType format = CVPixelBufferGetPixelFormatType(mask);
    if ((!*mw || (w == *mw && h == *mh)) && format == kCVPixelFormatType_OneComponent8) {
        *mw = w;
        *mh = h;
        bytes = malloc(w * h);
        CVPixelBufferLockBaseAddress(mask, kCVPixelBufferLock_ReadOnly);
        const uint8_t *base = CVPixelBufferGetBaseAddress(mask);
        size_t row = CVPixelBufferGetBytesPerRow(mask);
        for (size_t y = 0; y < h; y++) memcpy(bytes + y * w, base + y * row, w);
        CVPixelBufferUnlockBaseAddress(mask, kCVPixelBufferLock_ReadOnly);
    } else if ((!*mw || (w == *mw && h == *mh)) && format == kCVPixelFormatType_OneComponent32Float) {
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
    if (!bytes) {
        static NSUInteger told;
        if (told++ < 10) AULog(@"vision: instance mask %zux%zu format %.4s not taken (want %zux%zu)", w, h, (const char *)&(OSType){CFSwapInt32HostToBig(format)}, *mw, *mh);
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
        NSMutableArray<NSData *> *personMasks = [NSMutableArray array];   // each person's solid mask
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
                AULog(@"cutout: person %lu peak %.2f", (unsigned long)index, peak / 255.0);
                if (peak >= 38) {
                    float scale = 255.0f / peak;
                    NSMutableData *solid = [NSMutableData dataWithLength:mw * mh];
                    uint8_t *solidBytes = solid.mutableBytes;
                    for (size_t i = 0; i < mw * mh; i++) {
                        uint8_t v = sg_curve[(uint8_t)fminf(255, one[i] * scale)];
                        solidBytes[i] = v;
                        if (v > alpha[i]) alpha[i] = v;
                    }
                    [personMasks addObject:solid];
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
                // Taken when most of some person lies inside it: a drawn character found as a person only by its
                // legs is still whole in the foreground subject that holds those legs.
                double area = 0, best = 0;
                for (size_t i = 0; i < mw * mh; i++) area += one[i];
                for (NSData *solid in personMasks) {
                    const uint8_t *p = solid.bytes;
                    double inside = 0, total = 0;
                    for (size_t i = 0; i < mw * mh; i++) {
                        total += p[i];
                        inside += MIN(p[i], one[i]);
                    }
                    if (total > 0) best = MAX(best, inside / total);
                }
                AULog(@"cutout: subject %lu covers %.1f%%, holds %.0f%% of a person", (unsigned long)index, area / 255.0 / (mw * mh) * 100, best * 100);
                if (objects || best > 0.5) {
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

#pragma mark - the scene

static double areaOf(const uint8_t *mask, size_t n) {
    double sum = 0;
    for (size_t i = 0; i < n; i++) sum += mask[i];
    return sum / 255.0 / n;
}

// The objects, each a solid 8-bit mask the image's size, largest first, at most five.
static NSArray<NSData *> *objectMasks(CGImageRef image, BOOL peopleOnly, size_t *outW, size_t *outH) API_AVAILABLE(ios(17.0)) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        for (int i = 0; i < 256; i++) {
            float x = fminf(1, fmaxf(0, (i / 255.0f - 0.25f) / 0.35f));
            sg_curve[i] = (uint8_t)lroundf(x * x * (3 - 2 * x) * 255);
        }
    });
    Class personClass = NSClassFromString(@"VNGeneratePersonInstanceMaskRequest");
    Class foregroundClass = NSClassFromString(@"VNGenerateForegroundInstanceMaskRequest");
    if (!foregroundClass) return @[];
    VNImageRequestHandler *handler = [[VNImageRequestHandler alloc] initWithCGImage:image options:@{}];
    VNImageBasedRequest *foreground = [foregroundClass new];
    VNImageBasedRequest *person = personClass ? [personClass new] : nil;
    NSError *e = nil;
    if (![handler performRequests:person ? @[person, foreground] : @[foreground] error:&e]) return @[];
    size_t mw = 0, mh = 0;
    NSMutableArray<NSData *> *people = [NSMutableArray array], *subjects = [NSMutableArray array];
    VNInstanceMaskObservation *peopleObservation = (VNInstanceMaskObservation *)person.results.firstObject;
    if ([peopleObservation respondsToSelector:@selector(allInstances)]) {
        NSIndexSet *instances = peopleObservation.allInstances;
        NSUInteger seen = 0;
        for (NSUInteger index = instances.firstIndex; index != NSNotFound && seen < 8; index = [instances indexGreaterThanIndex:index], seen++) {
            uint8_t *one = instanceMask(peopleObservation, index, handler, &mw, &mh);
            if (!one) continue;
            uint8_t peak = 0;
            for (size_t i = 0; i < mw * mh; i++) if (one[i] > peak) peak = one[i];
            if (peak >= 38) {
                float scale = 255.0f / peak;
                for (size_t i = 0; i < mw * mh; i++) one[i] = sg_curve[(uint8_t)fminf(255, one[i] * scale)];
                [people addObject:[NSData dataWithBytesNoCopy:one length:mw * mh freeWhenDone:YES]];
            } else {
                free(one);
            }
        }
    }
    VNInstanceMaskObservation *subjectObservation = (VNInstanceMaskObservation *)foreground.results.firstObject;
    if ([subjectObservation respondsToSelector:@selector(allInstances)]) {
        NSIndexSet *instances = subjectObservation.allInstances;
        NSUInteger seen = 0;
        for (NSUInteger index = instances.firstIndex; index != NSNotFound && seen < 8; index = [instances indexGreaterThanIndex:index], seen++) {
            uint8_t *one = instanceMask(subjectObservation, index, handler, &mw, &mh);
            if (!one) continue;
            for (size_t i = 0; i < mw * mh; i++) one[i] = sg_curve[one[i]];
            [subjects addObject:[NSData dataWithBytesNoCopy:one length:mw * mh freeWhenDone:YES]];
        }
    }
    static NSUInteger told;
    if (told++ < 40) {
        AULog(@"vision: %lu subjects, %lu people (person request %@, %lu results)", (unsigned long)subjects.count,
              (unsigned long)people.count, person ? @"ran" : @"missing", (unsigned long)person.results.count);
    }
    *outW = mw;
    *outH = mh;
    if (!mw) return @[];
    size_t n = mw * mh;
    // How much of `inner` lies inside `outer`.
    double (^inside)(NSData *, NSData *) = ^double(NSData *inner, NSData *outer) {
        const uint8_t *a = inner.bytes, *b = outer.bytes;
        double total = 0, in = 0;
        for (size_t i = 0; i < n; i++) {
            total += a[i];
            in += MIN(a[i], b[i]);
        }
        return total > 0 ? in / total : 0;
    };
    NSMutableArray<NSData *> *taken = [NSMutableArray array];
    for (NSData *subject in subjects) {
        NSMutableArray<NSData *> *held = [NSMutableArray array];
        for (NSData *p in people) if (inside(p, subject) > 0.5) [held addObject:p];
        if (peopleOnly && !held.count) continue;
        if (held.count < 2) {
            [taken addObject:subject];
            continue;
        }
        // Vision's subject often holds a whole group: each person moves on its own, and what is left of the subject
        // (a bath, a table, things in hands set down) is one more object, its slivers along the people opened away.
        for (NSData *p in held) if (![taken containsObject:p]) [taken addObject:p];
        if (peopleOnly) continue;
        NSMutableData *rest = [NSMutableData dataWithLength:n], *opened = [NSMutableData dataWithLength:n];
        uint8_t *r = rest.mutableBytes;
        const uint8_t *s = subject.bytes;
        for (size_t i = 0; i < n; i++) {
            uint8_t most = 0;
            for (NSData *p in held) most = MAX(most, ((const uint8_t *)p.bytes)[i]);
            r[i] = most < 96 ? s[i] : 0;
        }
        uint32_t open = (uint32_t)(mw / 60) | 1;
        vImage_Buffer rb = {r, mh, mw, mw}, ob = {opened.mutableBytes, mh, mw, mw};
        vImageMin_Planar8(&rb, &ob, NULL, 0, 0, open, open, kvImageEdgeExtend);
        vImageMax_Planar8(&ob, &rb, NULL, 0, 0, open, open, kvImageEdgeExtend);
        // The opening squared off the subject's soft edge: the subject's own edge back where it is kept.
        for (size_t i = 0; i < n; i++) r[i] = MIN(r[i], s[i]);
        [taken addObject:rest];
    }
    // A person no subject took (Vision's two requests do not always agree) is a layer of its own.
    for (NSData *p in people) {
        BOOL covered = NO;
        for (NSData *t in taken) covered |= inside(p, t) > 0.5;
        if (!covered) [taken addObject:p];
    }
    NSMutableArray *kept = [NSMutableArray array];
    for (NSData *mask in taken) {
        double area = areaOf(mask.bytes, n);
        if (area >= 0.01 && area <= 0.8) [kept addObject:@[@(area), mask]];
    }
    [kept sortUsingComparator:^NSComparisonResult(NSArray *a, NSArray *b) { return [b[0] compare:a[0]]; }];
    NSMutableArray<NSData *> *result = [NSMutableArray array];
    for (NSArray *entry in kept) {
        if (result.count < 6) [result addObject:entry[1]];
    }
    return result;
}

// The depth map at w x h, 8-bit.
static NSData *depthBytes(CGImageRef depth, size_t w, size_t h) {
    if (!depth) return nil;
    NSMutableData *bytes = [NSMutableData dataWithLength:w * h];
    CGColorSpaceRef gray = CGColorSpaceCreateDeviceGray();
    CGContextRef c = CGBitmapContextCreate(bytes.mutableBytes, w, h, 8, w, gray, (CGBitmapInfo)kCGImageAlphaNone);
    CGColorSpaceRelease(gray);
    CGContextSetInterpolationQuality(c, kCGInterpolationHigh);
    CGContextDrawImage(c, CGRectMake(0, 0, w, h), depth);
    CGContextRelease(c);
    return bytes;
}

// The median depth where `mask` (or, with `outside`, where none of it) is set.
static double medianDepth(const uint8_t *depth, const uint8_t *mask, size_t n, BOOL outside) {
    size_t histogram[256] = {0}, count = 0;
    for (size_t i = 0; i < n; i++) {
        BOOL in = mask[i] >= 128;
        if (in == outside) continue;
        histogram[depth[i]]++;
        count++;
    }
    if (!count) return 0.5;
    size_t acc = 0;
    for (int v = 0; v < 256; v++) {
        acc += histogram[v];
        if (acc * 2 >= count) return v / 255.0;
    }
    return 0.5;
}

// The near part of the depth map, when it stands out (Otsu's threshold, opened, 5...70% of the cover, clearly nearer).
static NSData *depthSplit(const uint8_t *depth, size_t w, size_t h) {
    size_t n = w * h, histogram[256] = {0};
    for (size_t i = 0; i < n; i++) histogram[depth[i]]++;
    double total = 0;
    for (int v = 0; v < 256; v++) total += v * (double)histogram[v];
    double sumB = 0, best = -1;
    size_t wB = 0;
    int threshold = 128;
    for (int t = 0; t < 256; t++) {
        wB += histogram[t];
        if (!wB || wB == n) continue;
        sumB += t * (double)histogram[t];
        double mB = sumB / wB, mF = (total - sumB) / (n - wB);
        double between = (double)wB * (n - wB) * (mB - mF) * (mB - mF);
        if (between > best) {
            best = between;
            threshold = t;
        }
    }
    NSMutableData *mask = [NSMutableData dataWithLength:n], *opened = [NSMutableData dataWithLength:n];
    uint8_t *m = mask.mutableBytes;
    double near = 0, far = 0;
    size_t nearCount = 0;
    for (size_t i = 0; i < n; i++) {
        BOOL isNear = depth[i] > threshold;
        m[i] = isNear ? 255 : 0;
        if (isNear) {
            near += depth[i];
            nearCount++;
        } else {
            far += depth[i];
        }
    }
    double share = (double)nearCount / n;
    if (share < 0.05 || share > 0.7 || nearCount == n) return nil;
    if ((near / nearCount - far / (n - nearCount)) / 255.0 < 0.18) return nil;
    uint32_t k = (uint32_t)(MAX(w, h) / 80) | 1;
    vImage_Buffer a = {m, h, w, w}, b = {opened.mutableBytes, h, w, w};
    vImageMin_Planar8(&a, &b, NULL, 0, 0, k, k, kvImageEdgeExtend);
    vImageMax_Planar8(&b, &a, NULL, 0, 0, k, k, kvImageEdgeExtend);
    vImageTentConvolve_Planar8(&a, &b, NULL, 0, 0, 5, 5, 0, kvImageEdgeExtend);
    return opened;
}

// Draws `image` into a top-left-origin rect of a w x h context (Core Graphics counts from the bottom).
static CGRect flipped(CGRect topLeft, size_t height) {
    return CGRectMake(topLeft.origin.x, height - CGRectGetMaxY(topLeft), topLeft.size.width, topLeft.size.height);
}

// Big-LaMa over a 384 x 512 copy of the canvas: the cover in its square, the bands and the objects' room as holes.
static CGImageRef lamaFill(MLModel *model, CGImageRef cover, const uint8_t *holes, size_t mw, size_t mh, CGRect squareIn512, NSString **error) {
    MLImageConstraint *imageC = model.modelDescription.inputDescriptionsByName[@"image"].imageConstraint;
    MLImageConstraint *maskC = model.modelDescription.inputDescriptionsByName[@"mask"].imageConstraint;
    size_t W = imageC.pixelsWide, H = imageC.pixelsHigh;
    if (!W || !H || !maskC) {
        if (error) *error = @"the inpainting model's inputs are not images";
        return NULL;
    }
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef ic = CGBitmapContextCreate(NULL, W, H, 8, 0, space, kCGImageAlphaNoneSkipLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(space);
    CGContextSetInterpolationQuality(ic, kCGInterpolationHigh);
    CGContextDrawImage(ic, flipped(squareIn512, H), cover);
    CGImageRef input = CGBitmapContextCreateImage(ic);
    CGContextRelease(ic);
    NSMutableData *maskBytes = [NSMutableData dataWithLength:W * H];
    uint8_t *mb = maskBytes.mutableBytes;
    size_t top = (size_t)squareIn512.origin.y, bottom = (size_t)CGRectGetMaxY(squareIn512);
    for (size_t y = 0; y < H; y++) {
        if (y < top || y >= bottom) memset(mb + y * W, 255, W);
    }
    CGImageRef holesImage = AUGrayImage(holes, mw, mh);
    CGColorSpaceRef gray = CGColorSpaceCreateDeviceGray();
    CGContextRef mc = CGBitmapContextCreate(mb, W, H, 8, W, gray, (CGBitmapInfo)kCGImageAlphaNone);
    CGColorSpaceRelease(gray);
    CGContextDrawImage(mc, flipped(squareIn512, H), holesImage);
    CGContextRelease(mc);
    CGImageRelease(holesImage);
    CGImageRef maskImage = AUGrayImage(mb, W, H);
    NSError *e = nil;
    MLFeatureValue *imageValue = [MLFeatureValue featureValueWithCGImage:input constraint:imageC options:nil error:&e];
    MLFeatureValue *maskValue = maskImage ? [MLFeatureValue featureValueWithCGImage:maskImage constraint:maskC options:nil error:&e] : nil;
    CGImageRelease(input);
    if (maskImage) CGImageRelease(maskImage);
    if (!imageValue || !maskValue) {
        if (error) *error = e.localizedDescription ?: @"inputs";
        return NULL;
    }
    MLDictionaryFeatureProvider *features = [[MLDictionaryFeatureProvider alloc] initWithDictionary:@{@"image": imageValue, @"mask": maskValue} error:&e];
    id<MLFeatureProvider> output = features ? [model predictionFromFeatures:features error:&e] : nil;
    CVPixelBufferRef buffer = [output featureValueForName:@"filled"].imageBufferValue;
    if (!buffer) {
        if (error) *error = e.localizedDescription ?: @"no output";
        return NULL;
    }
    CIImage *filled = [CIImage imageWithCVPixelBuffer:buffer];
    return rgba8(filled, filled.extent);
}

// An object that is really two things at clearly different depths (two people one behind the other, a person and the
// bath before them — Vision often gives such a group as one): its depth inside the mask has two humps with a valley
// between. Split at the valley (Otsu), softly over a few hundredths of depth, so each part moves by its own depth;
// a single body whose depth only ramps (lying down, reaching out) has no valley and stays whole.
static NSArray<NSData *> *depthParts(NSData *mask, const uint8_t *depth, size_t n) {
    enum { kBins = 32 };
    const uint8_t *m = mask.bytes;
    double hist[kBins] = {0}, total = 0;
    for (size_t i = 0; i < n; i++) {
        if (m[i] < 128) continue;
        hist[depth[i] * kBins / 256] += 1;
        total += 1;
    }
    if (total < n * 0.02) return @[mask];
    double sum = 0;
    for (int b = 0; b < kBins; b++) sum += b * hist[b];
    double wFar = 0, sumFar = 0, best = -1;
    int cut = -1;
    for (int b = 0; b < kBins - 1; b++) {
        wFar += hist[b];
        sumFar += b * hist[b];
        double wNear = total - wFar;
        if (wFar < total * 0.15 || wNear < total * 0.15) continue;
        double mFar = sumFar / wFar, mNear = (sum - sumFar) / wNear;
        double between = wFar * wNear * (mNear - mFar) * (mNear - mFar);
        if (between > best) {
            best = between;
            cut = b;
        }
    }
    if (cut < 0) return @[mask];
    double far = 0, near = 0, peakFar = 0, peakNear = 0, wf = 0, wn = 0;
    for (int b = 0; b < kBins; b++) {
        if (b <= cut) { far += b * hist[b]; wf += hist[b]; peakFar = MAX(peakFar, hist[b]); }
        else { near += b * hist[b]; wn += hist[b]; peakNear = MAX(peakNear, hist[b]); }
    }
    double gap = (near / wn - far / wf) / kBins;
    double valley = (hist[cut] + hist[cut + 1] + (cut > 0 ? hist[cut - 1] : hist[cut])) / 3;
    if (gap < 0.15 || valley > 0.3 * MIN(peakFar, peakNear)) return @[mask];
    double threshold = (cut + 1.0) / kBins * 255;
    // The near part, hard, then closed and opened (a 25th of the side): no islands of one part left in the other —
    // a cheek whose depth dips is not handed to the person behind — and the seam softened a little.
    size_t side = (size_t)lround(sqrt((double)n));
    NSMutableData *a = [NSMutableData dataWithLength:n], *b = [NSMutableData dataWithLength:n];
    uint8_t *pa = a.mutableBytes;
    for (size_t i = 0; i < n; i++) pa[i] = m[i] >= 128 && depth[i] >= threshold ? 255 : 0;
    vImage_Buffer ab = {pa, side, side, side}, bb = {b.mutableBytes, side, side, side};
    uint32_t k = (uint32_t)(side / 25) | 1;
    vImageMax_Planar8(&ab, &bb, NULL, 0, 0, k, k, kvImageEdgeExtend);
    vImageMin_Planar8(&bb, &ab, NULL, 0, 0, k, k, kvImageEdgeExtend);
    vImageMin_Planar8(&ab, &bb, NULL, 0, 0, k, k, kvImageEdgeExtend);
    vImageMax_Planar8(&bb, &ab, NULL, 0, 0, k, k, kvImageEdgeExtend);
    // And the far part opened the same way: a thin arm reaching over the nearer one goes with it, no sliver left.
    for (size_t i = 0; i < n; i++) pa[i] = m[i] >= 128 && pa[i] < 128 ? 255 : 0;
    vImageMin_Planar8(&ab, &bb, NULL, 0, 0, k, k, kvImageEdgeExtend);
    vImageMax_Planar8(&bb, &ab, NULL, 0, 0, k, k, kvImageEdgeExtend);
    for (size_t i = 0; i < n; i++) pa[i] = pa[i] >= 128 ? 0 : 255;
    uint32_t soft = (uint32_t)(side / 160) | 1;
    vImageTentConvolve_Planar8(&ab, &bb, NULL, 0, 0, soft, soft, 0, kvImageEdgeExtend);
    const uint8_t *t = b.bytes;
    NSMutableData *farMask = [NSMutableData dataWithLength:n], *nearMask = [NSMutableData dataWithLength:n];
    uint8_t *f = farMask.mutableBytes, *ne = nearMask.mutableBytes;
    double nearArea = 0, farArea = 0;
    for (size_t i = 0; i < n; i++) {
        ne[i] = (uint8_t)((m[i] * t[i] + 127) / 255);
        f[i] = (uint8_t)(m[i] - ne[i]);
        nearArea += ne[i] >= 128;
        farArea += f[i] >= 128;
    }
    if (nearArea < total * 0.12 || farArea < total * 0.12) return @[mask];
    wf = farArea;
    wn = nearArea;
    AULog(@"scene: an object split by depth at %.2f (parts %.0f%% / %.0f%%, %.2f apart)", threshold / 255, 100 * wf / total, 100 * wn / total, gap);
    return @[farMask, nearMask];
}

// The background's depth: where the objects were, the depth around them carried in (normalized convolution at 128
// px), then softened, so the plate bends smoothly and has no object edge left to tear along.
static CGImageRef plateDepthOf(const uint8_t *depth, const uint8_t *holes, size_t side) {
    enum { kSmall = 128 };
    const size_t n = kSmall * kSmall;
    uint8_t *d = calloc(n, 1), *h = calloc(n, 1), *num = calloc(n, 1), *den = calloc(n, 1), *a = calloc(n, 1), *b = calloc(n, 1);
    CGColorSpaceRef gray = CGColorSpaceCreateDeviceGray();
    CGImageRef depthImage = AUGrayImage(depth, side, side), holesImage = AUGrayImage(holes, side, side);
    CGContextRef dc = CGBitmapContextCreate(d, kSmall, kSmall, 8, kSmall, gray, (CGBitmapInfo)kCGImageAlphaNone);
    CGContextSetInterpolationQuality(dc, kCGInterpolationHigh);
    CGContextDrawImage(dc, CGRectMake(0, 0, kSmall, kSmall), depthImage);
    CGContextRelease(dc);
    CGContextRef hc = CGBitmapContextCreate(h, kSmall, kSmall, 8, kSmall, gray, (CGBitmapInfo)kCGImageAlphaNone);
    CGContextDrawImage(hc, CGRectMake(0, 0, kSmall, kSmall), holesImage);
    CGContextRelease(hc);
    CGColorSpaceRelease(gray);
    CGImageRelease(depthImage);
    CGImageRelease(holesImage);
    for (size_t i = 0; i < n; i++) {
        uint8_t keep = 255 - h[i];
        num[i] = (uint8_t)((d[i] * keep + 127) / 255);
        den[i] = keep;
    }
    vImage_Buffer nb = {num, kSmall, kSmall, kSmall}, db = {den, kSmall, kSmall, kSmall}, ab = {a, kSmall, kSmall, kSmall}, bb = {b, kSmall, kSmall, kSmall};
    for (int pass = 0; pass < 2; pass++) {
        vImageTentConvolve_Planar8(&nb, &ab, NULL, 0, 0, 31, 31, 0, kvImageEdgeExtend);
        vImageTentConvolve_Planar8(&ab, &nb, NULL, 0, 0, 31, 31, 0, kvImageEdgeExtend);
        vImageTentConvolve_Planar8(&db, &bb, NULL, 0, 0, 31, 31, 0, kvImageEdgeExtend);
        vImageTentConvolve_Planar8(&bb, &db, NULL, 0, 0, 31, 31, 0, kvImageEdgeExtend);
    }
    for (size_t i = 0; i < n; i++) {
        double filled = den[i] > 2 ? MIN(255.0, 255.0 * num[i] / den[i]) : d[i];
        double keep = (255 - h[i]) / 255.0;
        a[i] = (uint8_t)lround(d[i] * keep + filled * (1 - keep));
    }
    // Softened well (a fifth of the side): a thing nobody lifted out bends with its surroundings, not on its own.
    vImageTentConvolve_Planar8(&ab, &bb, NULL, 0, 0, 25, 25, 0, kvImageEdgeExtend);
    CGImageRef small = AUGrayImage(b, kSmall, kSmall);
    free(d); free(h); free(num); free(den); free(a); free(b);
    return small;
}

AUScene *AUSceneBuild(CGImageRef cover, CGImageRef depth, BOOL peopleOnly, NSString **log) {
    if (!cover) return nil;
    double started = AUNowMs();
    // The cover as a square at most 1024 px.
    size_t side = MIN((size_t)1024, MIN(CGImageGetWidth(cover), CGImageGetHeight(cover)));
    CGImageRef square = AUImageResized(cover, side, side);
    if (!square) return nil;
    size_t mw = 0, mh = 0;
    NSArray<NSData *> *masks = @[];
    if (@available(iOS 17.0, *)) masks = objectMasks(square, peopleOnly, &mw, &mh);
    if (mw != side || mh != side) {
        masks = @[];
        mw = mh = side;
    }
    size_t n = side * side;
    NSData *depthMap = depthBytes(depth, side, side);
    if (!masks.count && depthMap) {
        NSData *split = depthSplit(depthMap.bytes, side, side);
        if (split) masks = @[split];
    }
    if (depthMap && masks.count) {
        NSMutableArray<NSData *> *parts = [NSMutableArray array];
        for (NSData *mask in masks) {
            if (masks.count + parts.count >= 8) [parts addObject:mask];
            else [parts addObjectsFromArray:depthParts(mask, depthMap.bytes, n)];
        }
        masks = parts;
    }
    // The objects' room, grown a little so no fringe of theirs is left in the background.
    NSMutableData *unionMask = [NSMutableData dataWithLength:n], *grown = [NSMutableData dataWithLength:n];
    uint8_t *u = unionMask.mutableBytes;
    for (NSData *mask in masks) {
        const uint8_t *m = mask.bytes;
        for (size_t i = 0; i < n; i++) if (m[i] > u[i]) u[i] = m[i];
    }
    uint32_t grow = (uint32_t)(side / 32) | 1;
    vImage_Buffer ub = {u, side, side, side}, gb = {grown.mutableBytes, side, side, side};
    vImageMax_Planar8(&ub, &gb, NULL, 0, 0, grow, grow, kvImageEdgeExtend);
    uint8_t *g = grown.mutableBytes;
    for (size_t i = 0; i < n; i++) g[i] = g[i] >= 64 ? 255 : 0;

    // The canvas is the cover itself, square: nothing is added around it, so it frames as Taurus frames the cover.
    size_t cw = side, ch = side;
    CGRect squareRect = CGRectMake(0, 0, side, side);
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef canvas = CGBitmapContextCreate(NULL, cw, ch, 8, 0, space, kCGImageAlphaNoneSkipLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(space);
    CGContextSetInterpolationQuality(canvas, kCGInterpolationHigh);
    BOOL inpainted = NO;
    NSString *why = nil;
    MLModel *lama = [AUModelManager.shared modelFor:AUModelInpaint];
    if (lama) {
        double t = AUNowMs();
        MLImageConstraint *size = lama.modelDescription.inputDescriptionsByName[@"image"].imageConstraint;
        CGRect squareIn = CGRectMake(0, 0, size.pixelsWide, size.pixelsHigh);
        CGImageRef painted = lamaFill(lama, square, g, side, side, squareIn, &why);
        if (painted) {
            CGContextDrawImage(canvas, CGRectMake(0, 0, cw, ch), painted);
            CGImageRelease(painted);
            inpainted = YES;
            AUStatRecord(@"inpaint", AUNowMs() - t);
        }
    } else {
        why = @"model not ready";
    }
    if (!inpainted) {
        // The quick fallback: the cover stretched over the canvas and blurred, and the objects' room filled from around it.
        CGContextDrawImage(canvas, CGRectMake(0, 0, cw, ch), square);
        CGImageRef holesImage = AUGrayImage(g, side, side);
        CGImageRef filled = masks.count ? inpaintedBackground(square, holesImage) : NULL;
        CGImageRelease(holesImage);
        if (filled) {
            CGContextDrawImage(canvas, flipped(squareRect, ch), filled);
            CGImageRelease(filled);
        }
    }
    // The cover's own pixels wherever no object was, the seam to the painted room feathered.
    NSMutableData *keep = [NSMutableData dataWithLength:n];
    uint8_t *k = keep.mutableBytes;
    for (size_t i = 0; i < n; i++) k[i] = 255 - g[i];
    NSMutableData *soft = [NSMutableData dataWithLength:n];
    vImage_Buffer kb = {k, side, side, side}, sb = {soft.mutableBytes, side, side, side};
    uint32_t feather = (uint32_t)(side / 120) | 1;
    vImageTentConvolve_Planar8(&kb, &sb, NULL, 0, 0, feather, feather, 0, kvImageEdgeExtend);
    CGImageRef keepImage = AUGrayImage(soft.bytes, side, side);
    CGContextSaveGState(canvas);
    CGContextClipToMask(canvas, flipped(squareRect, ch), keepImage);
    CGContextDrawImage(canvas, flipped(squareRect, ch), square);
    CGContextRestoreGState(canvas);
    CGImageRelease(keepImage);
    CGImageRef background = CGBitmapContextCreateImage(canvas);
    CGContextRelease(canvas);

    // The objects, each on a canvas-sized layer, edges feathered a pixel, far to near.
    NSMutableArray<AUSceneLayer *> *layers = [NSMutableArray array];
    double backgroundDepth = depthMap ? medianDepth(depthMap.bytes, g, n, YES) : 0.3;
    NSMutableArray<NSArray *> *ordered = [NSMutableArray array];
    for (NSData *mask in masks) [ordered addObject:@[@(depthMap ? medianDepth(depthMap.bytes, mask.bytes, n, NO) : 0.8), mask]];
    [ordered sortUsingComparator:^NSComparisonResult(NSArray *a, NSArray *b) { return [a[0] compare:b[0]]; }];
    // Where two objects part, the painted room behind them shows in the seam (a band of the cover there would be a
    // ghost copy of the nearer one).
    CGColorSpaceRef rgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    for (NSUInteger index = 0; index < ordered.count; index++) {
        NSData *mask = ordered[index][1];
        // A soft edge, pulled in a pixel or two so no rim of the background rides along with the object.
        NSMutableData *eroded = [NSMutableData dataWithLength:n], *edge = [NSMutableData dataWithLength:n];
        vImage_Buffer mb = {(void *)mask.bytes, side, side, side}, rb = {eroded.mutableBytes, side, side, side}, eb = {edge.mutableBytes, side, side, side};
        uint32_t pull = (uint32_t)(side / 320) | 1, soften = (uint32_t)(side / 110) | 1;
        vImageMin_Planar8(&mb, &rb, NULL, 0, 0, pull, pull, kvImageEdgeExtend);
        vImageTentConvolve_Planar8(&rb, &eb, NULL, 0, 0, soften, soften, 0, kvImageEdgeExtend);
        CGImageRef maskImage = AUGrayImage(edge.bytes, side, side);
        CGContextRef layer = CGBitmapContextCreate(NULL, cw, ch, 8, 0, rgb, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
        CGContextSetInterpolationQuality(layer, kCGInterpolationHigh);
        CGContextClipToMask(layer, flipped(squareRect, ch), maskImage);
        CGContextDrawImage(layer, flipped(squareRect, ch), square);
        CGImageRelease(maskImage);
        CGImageRef made = CGBitmapContextCreateImage(layer);
        CGContextRelease(layer);
        AUSceneLayer *sceneLayer = [AUSceneLayer new];
        sceneLayer.image = [UIImage imageWithCGImage:made];
        CGImageRelease(made);
        sceneLayer.depth = [ordered[index][0] doubleValue];
        [layers addObject:sceneLayer];
    }
    CGColorSpaceRelease(rgb);
    [layers sortUsingComparator:^NSComparisonResult(AUSceneLayer *a, AUSceneLayer *b) { return [@(a.depth) compare:@(b.depth)]; }];
    AUScene *scene = [AUScene new];
    if (depthMap) {
        CGImageRef full = AUGrayImage(depthMap.bytes, side, side);
        CGImageRef raw = full ? AUImageResized(full, 256, 256) : NULL;
        if (raw) {
            scene.rawDepth = [UIImage imageWithCGImage:raw];
            CGImageRelease(raw);
        }
        if (full) CGImageRelease(full);
        CGImageRef plate = plateDepthOf(depthMap.bytes, g, side);
        if (plate) {
            scene.plateDepth = [UIImage imageWithCGImage:plate];
            CGImageRelease(plate);
        }
    }
    scene.background = [UIImage imageWithCGImage:background];
    CGImageRelease(background);
    CGImageRelease(square);
    scene.square = squareRect;
    scene.layers = layers;
    scene.backgroundDepth = backgroundDepth;
    scene.inpainted = inpainted;
    NSMutableArray *depths = [NSMutableArray array];
    for (AUSceneLayer *layer in layers) [depths addObject:[NSString stringWithFormat:@"%.2f", layer.depth]];
    NSString *summary = [NSString stringWithFormat:@"scene %zu px: %lu objects (depth %@ over %.2f), background %@ in %.0f ms",
                         side, (unsigned long)layers.count, [depths componentsJoinedByString:@" "], backgroundDepth,
                         inpainted ? @"painted by LaMa" : [@"blur fill: " stringByAppendingString:why ?: @"?"], AUNowMs() - started];
    if (log) *log = summary;
    return scene;
}
