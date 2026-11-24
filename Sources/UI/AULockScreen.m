#import "AULockScreen.h"
#import "Core/AUCore.h"
#import "Features/AUImage.h"
#import "Features/AUDepthLayers.h"
#import <AVFoundation/AVFoundation.h>
#import <Accelerate/Accelerate.h>
#import <TargetConditionals.h>
#import <dlfcn.h>
#import <objc/message.h>
#if !TARGET_OS_MACCATALYST
#import <MediaPlayer/MediaPlayer.h>
#import "Core/AUTaurus.h"
#import "Features/AUPipeline.h"
#endif

static const int32_t kFPS = 24, kLoopSeconds = 6;
static const double kStrength = 0.04;

#pragma mark - the clip, on the CPU
//
// The clip is made when the lock screen asks for it, and Spotify is then in the background, where iOS lets no app
// use the GPU (a Metal frame comes out black). So it is drawn on the CPU, as the app's Metal one is: the cover bent
// by its softened depth map as the camera circles (each pixel moved by its depth, sampled bilinearly, the rows
// split over the cores), the subject in front with its shadow baked in, and a shade at the foot for the controls.

typedef struct {
    uint8_t *source;            // the picture, BGRA premultiplied, the canvas's size (the frame with a margin)
    size_t sourceRow;
    uint8_t *depth;             // the depth map at the canvas's size, near bright
    uint8_t *blurred;           // the picture softened, for the room a near thing uncovers (as the app's mip levels)
    CGImageRef subject;         // with its shadow, the canvas's size, or NULL
    CGImageRef shade;
    CGSize size, canvas;
    double side, margin;
    BOOL moving;
} AUClipLayers;

static CGPoint tiltAt(double phase) {
    return CGPointMake(0.65 * sin(2 * M_PI * phase), 0.4 * cos(2 * M_PI * phase));
}

static CGContextRef bgraContext(size_t width, size_t height, void *data, size_t rowBytes) {
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef context = CGBitmapContextCreate(data, width, height, 8, rowBytes, space, kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    CGColorSpaceRelease(space);
    return context;
}

static AUClipLayers makeLayers(AULockClipInput input, CGSize size, BOOL moving) {
    AUClipLayers l;
    memset(&l, 0, sizeof(l));
    l.size = size;
    l.moving = moving && input.depth;
    double zoom = l.moving ? 1 + 1.1 * kStrength : 1.0;
    l.side = MAX(size.width, size.height) * zoom;
    l.margin = l.moving ? ceil(kStrength * l.side * 0.55) + 2 : 0;
    l.canvas = CGSizeMake(size.width + 2 * l.margin, size.height + 2 * l.margin);
    size_t cw = (size_t)l.canvas.width, ch = (size_t)l.canvas.height;
    CGRect rect = CGRectMake((l.canvas.width - l.side) / 2, (l.canvas.height - l.side) / 2, l.side, l.side);
    l.sourceRow = cw * 4;
    l.source = calloc(l.sourceRow * ch, 1);
    CGContextRef source = bgraContext(cw, ch, l.source, l.sourceRow);
    CGContextSetInterpolationQuality(source, kCGInterpolationHigh);
    CGContextDrawImage(source, rect, input.color);
    CGContextRelease(source);
    if (l.moving) {
        uint8_t *depth = calloc(cw * ch, 1);
        CGColorSpaceRef gray = CGColorSpaceCreateDeviceGray();
        CGContextRef d = CGBitmapContextCreate(depth, cw, ch, 8, cw, gray, (CGBitmapInfo)kCGImageAlphaNone);
        CGColorSpaceRelease(gray);
        CGContextSetInterpolationQuality(d, kCGInterpolationHigh);
        CGContextDrawImage(d, rect, input.depth);
        CGContextRelease(d);
        l.depth = depth;
        l.blurred = malloc(l.sourceRow * ch);
        uint8_t *scratch = malloc(l.sourceRow * ch);
        uint32_t k = (uint32_t)(l.side / 90) | 1;
        vImage_Buffer a = {l.source, ch, cw, l.sourceRow}, b = {scratch, ch, cw, l.sourceRow}, c = {l.blurred, ch, cw, l.sourceRow};
        vImageBoxConvolve_ARGB8888(&a, &b, NULL, 0, 0, k, k, NULL, kvImageEdgeExtend);
        vImageBoxConvolve_ARGB8888(&b, &c, NULL, 0, 0, k, k, NULL, kvImageEdgeExtend);
        free(scratch);
    }
    if (input.subject) {
        CGContextRef s = bgraContext(cw, ch, NULL, 0);
        CGContextSetInterpolationQuality(s, kCGInterpolationHigh);
        CGColorRef shadow = CGColorCreateSRGB(0, 0, 0, 0.5);
        CGContextSetShadowWithColor(s, CGSizeMake(0, -10), 22, shadow);
        CGColorRelease(shadow);
        CGContextDrawImage(s, rect, input.subject);
        l.subject = CGBitmapContextCreateImage(s);
        CGContextRelease(s);
    }
    CGContextRef shade = bgraContext((size_t)size.width, (size_t)size.height, NULL, 0);
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGFloat components[8] = {0, 0, 0, 0.45, 0, 0, 0, 0};
    CGFloat locations[2] = {0, 1};
    CGGradientRef gradient = CGGradientCreateWithColorComponents(space, components, locations, 2);
    CGContextDrawLinearGradient(shade, gradient, CGPointMake(0, 0), CGPointMake(0, size.height * 0.32), 0);
    CGGradientRelease(gradient);
    CGColorSpaceRelease(space);
    l.shade = CGBitmapContextCreateImage(shade);
    CGContextRelease(shade);
    return l;
}

static void freeLayers(AUClipLayers *l) {
    free(l->source);
    free(l->depth);
    free(l->blurred);
    if (l->subject) CGImageRelease(l->subject);
    if (l->shade) CGImageRelease(l->shade);
    memset(l, 0, sizeof(*l));
}

// Steep parallax into `pixels` (BGRA, rows from the top, `rowBytes` apart), as the app's shader does it: for each
// pixel the depth map is marched from the near plane down until the surface is met, so each thing moves whole at its
// depth and the near hides the far; the colour there is sampled bilinearly. Down the screen is +y as in the app.
static void warp(AUClipLayers *l, uint8_t *pixels, size_t rowBytes, CGPoint tilt) {
    size_t w = (size_t)l->size.width, h = (size_t)l->size.height, cw = (size_t)l->canvas.width, ch = (size_t)l->canvas.height;
    float m = (float)l->margin;
    const uint8_t *src = l->source, *depth = l->depth, *soft = l->blurred;
    size_t srcRow = l->sourceRow;
    float ox = (float)(tilt.x * kStrength * l->side), oy = (float)(tilt.y * kStrength * l->side);
    float shift = hypotf(ox, oy), dx = shift > 0 ? ox / shift : 0, dy = shift > 0 ? oy / shift : 0;
    size_t chunk = 16;
    dispatch_apply((h + chunk - 1) / chunk, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^(size_t c) {
        size_t y0 = c * chunk, y1 = MIN(h, y0 + chunk);
        for (size_t y = y0; y < y1; y++) {
            uint32_t *out = (uint32_t *)(pixels + y * rowBytes);
            for (size_t x = 0; x < w; x++) {
                float px = x + m, py = y + m;
                #define DEPTH_AT(layer) ({ \
                    float qx = px - ox * ((layer) - 0.5f), qy = py - oy * ((layer) - 0.5f); \
                    long ix = lroundf(qx), iy = lroundf(qy); \
                    if (ix < 0) ix = 0; if (iy < 0) iy = 0; if (ix >= (long)cw) ix = cw - 1; if (iy >= (long)ch) iy = ch - 1; \
                    depth[iy * cw + ix] / 255.0f; })
                const int steps = 12;
                float layer = 1, step = 1.0f / steps, d = DEPTH_AT(layer), prevLayer = layer, prevD = d;
                for (int i = 0; i < steps && d < layer; i++) {
                    prevLayer = layer;
                    prevD = d;
                    layer -= step;
                    d = DEPTH_AT(layer);
                }
                #undef DEPTH_AT
                float before = prevD - prevLayer, after = d - layer;
                float t = before / (before - after + 1e-5f);
                t = t < 0 ? 0 : (t > 1 ? 1 : t);
                float hit = prevLayer + (layer - prevLayer) * t;
                float sx = px - ox * (hit - 0.5f), sy = py - oy * (hit - 0.5f);
                if (sx < 0) sx = 0;
                if (sy < 0) sy = 0;
                if (sx > cw - 1.001f) sx = cw - 1.001f;
                if (sy > ch - 1.001f) sy = ch - 1.001f;
                size_t ix = (size_t)sx, iy = (size_t)sy;
                // Beside a depth step the colour is uncovered room: it is mixed toward the softened picture by how big
                // the step and the shift are, as the shader picks a blurrier mip level.
                long ax = lroundf(sx + dx * 4), ay = lroundf(sy + dy * 4), bx = lroundf(sx - dx * 4), by = lroundf(sy - dy * 4);
                ax = ax < 0 ? 0 : (ax >= (long)cw ? (long)cw - 1 : ax); bx = bx < 0 ? 0 : (bx >= (long)cw ? (long)cw - 1 : bx);
                ay = ay < 0 ? 0 : (ay >= (long)ch ? (long)ch - 1 : ay); by = by < 0 ? 0 : (by >= (long)ch ? (long)ch - 1 : by);
                float edge = fabsf((float)depth[ay * cw + ax] - (float)depth[by * cw + bx]) / 255.0f;
                float mixSoft = fminf(1.0f, edge * shift / 10.0f);
                uint32_t ms = (uint32_t)(mixSoft * 256);
                uint32_t fx = (uint32_t)((sx - ix) * 256), fy = (uint32_t)((sy - iy) * 256);
                size_t at = iy * srcRow + ix * 4;
                const uint8_t *p00 = src + at, *p10 = p00 + 4, *p01 = p00 + srcRow, *p11 = p01 + 4;
                const uint8_t *q00 = soft + at, *q10 = q00 + 4, *q01 = q00 + srcRow, *q11 = q01 + 4;
                uint32_t result = 0;
                for (int k = 0; k < 4; k++) {
                    uint32_t top = p00[k] * (256 - fx) + p10[k] * fx, bottom = p01[k] * (256 - fx) + p11[k] * fx;
                    uint32_t sharp = (top * (256 - fy) + bottom * fy) >> 16;
                    uint32_t softTop = q00[k] * (256 - fx) + q10[k] * fx, softBottom = q01[k] * (256 - fx) + q11[k] * fx;
                    uint32_t blurred = (softTop * (256 - fy) + softBottom * fy) >> 16;
                    result |= ((sharp * (256 - ms) + blurred * ms) >> 8) << (k * 8);
                }
                out[x] = result;
            }
        }
    });
}

static void drawFrame(CGContextRef context, AUClipLayers *l, double phase, BOOL moving) {
    CGPoint tilt = moving && l->moving ? tiltAt(phase) : CGPointZero;
    size_t w = (size_t)l->size.width, h = (size_t)l->size.height;
    uint8_t *pixels = CGBitmapContextGetData(context);
    if (l->moving && pixels) {
        warp(l, pixels, CGBitmapContextGetBytesPerRow(context), tilt);
    } else {
        // Still: the picture straight from the canvas's middle.
        size_t m = (size_t)l->margin, row = CGBitmapContextGetBytesPerRow(context);
        for (size_t y = 0; y < h && pixels; y++) memcpy(pixels + y * row, l->source + (y + m) * l->sourceRow + m * 4, w * 4);
    }
    if (l->subject) {
        double amount = l->moving ? kStrength * l->side * (AUSubjectDepth - 0.5) : 0;
        CGContextSetInterpolationQuality(context, kCGInterpolationLow);
        CGContextDrawImage(context, CGRectMake(-l->margin + tilt.x * amount, -l->margin - tilt.y * amount, l->canvas.width, l->canvas.height), l->subject);
    }
    CGContextDrawImage(context, CGRectMake(0, 0, l->size.width, l->size.height), l->shade);
}

CGImageRef AULockClipFrame(AULockClipInput input, CGSize size, double phase, BOOL moving) {
    if (!input.color || size.width < 1 || size.height < 1) return NULL;
    AUClipLayers l = makeLayers(input, size, moving);
    CGContextRef context = bgraContext((size_t)size.width, (size_t)size.height, NULL, 0);
    drawFrame(context, &l, phase, moving);
    CGImageRef frame = CGBitmapContextCreateImage(context);
    CGContextRelease(context);
    freeLayers(&l);
    return frame;
}

BOOL AULockClipWrite(NSURL *file, AULockClipInput input, CGSize size, BOOL moving) {
    if (!input.color || size.width < 16 || size.height < 16) return NO;
    double started = AUNowMs();
    NSURL *partial = [file URLByAppendingPathExtension:@"partial.mp4"];
    [NSFileManager.defaultManager removeItemAtURL:partial error:nil];
    AVAssetWriter *writer = [AVAssetWriter assetWriterWithURL:partial fileType:AVFileTypeMPEG4 error:nil];
    int32_t width = (int32_t)size.width, height = (int32_t)size.height;
    AVAssetWriterInput *video = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:@{
        AVVideoCodecKey: AVVideoCodecTypeH264,
        AVVideoWidthKey: @(width),
        AVVideoHeightKey: @(height),
        AVVideoCompressionPropertiesKey: @{AVVideoAverageBitRateKey: @(moving ? 3500000 : 1500000), AVVideoMaxKeyFrameIntervalKey: @(kFPS)},
    }];
    video.expectsMediaDataInRealTime = NO;
    AVAssetWriterInputPixelBufferAdaptor *adaptor = [AVAssetWriterInputPixelBufferAdaptor
        assetWriterInputPixelBufferAdaptorWithAssetWriterInput:video sourcePixelBufferAttributes:@{
            (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
            (id)kCVPixelBufferWidthKey: @(width),
            (id)kCVPixelBufferHeightKey: @(height),
        }];
    if (!writer || ![writer canAddInput:video]) return NO;
    [writer addInput:video];
    if (![writer startWriting]) {
        AULog(@"lock screen: the writer would not start: %@", writer.error.localizedDescription);
        return NO;
    }
    [writer startSessionAtSourceTime:kCMTimeZero];
    AUClipLayers l = makeLayers(input, size, moving);
    double prepared = AUNowMs();
    int32_t frames = moving ? kLoopSeconds * kFPS : kFPS;
    BOOL ok = YES;
    for (int32_t index = 0; index < frames && ok; index++) {
        @autoreleasepool {
            while (!video.readyForMoreMediaData && writer.status == AVAssetWriterStatusWriting) [NSThread sleepForTimeInterval:0.002];
            CVPixelBufferRef buffer = NULL;
            ok = writer.status == AVAssetWriterStatusWriting && adaptor.pixelBufferPool
                && CVPixelBufferPoolCreatePixelBuffer(NULL, adaptor.pixelBufferPool, &buffer) == kCVReturnSuccess;
            if (!ok) break;
            CVPixelBufferLockBaseAddress(buffer, 0);
            CGContextRef context = bgraContext((size_t)width, (size_t)height, CVPixelBufferGetBaseAddress(buffer), CVPixelBufferGetBytesPerRow(buffer));
            if (context) {
                drawFrame(context, &l, (double)index / frames, moving);
                CGContextRelease(context);
            }
            CVPixelBufferUnlockBaseAddress(buffer, 0);
            ok = context && [adaptor appendPixelBuffer:buffer withPresentationTime:CMTimeMake(index, kFPS)];
            CVPixelBufferRelease(buffer);
        }
    }
    freeLayers(&l);
    if (!ok) {
        AULog(@"lock screen: clip not written: %@", writer.error.localizedDescription ?: @"?");
        [writer cancelWriting];
        [NSFileManager.defaultManager removeItemAtURL:partial error:nil];
        return NO;
    }
    [video markAsFinished];
    [writer endSessionAtSourceTime:CMTimeMake(frames, kFPS)];
    dispatch_semaphore_t written = dispatch_semaphore_create(0);
    [writer finishWritingWithCompletionHandler:^{ dispatch_semaphore_signal(written); }];
    dispatch_semaphore_wait(written, DISPATCH_TIME_FOREVER);
    if (writer.status != AVAssetWriterStatusCompleted) {
        AULog(@"lock screen: clip not finished: %@", writer.error.localizedDescription ?: @"?");
        [NSFileManager.defaultManager removeItemAtURL:partial error:nil];
        return NO;
    }
    [NSFileManager.defaultManager removeItemAtURL:file error:nil];
    BOOL moved = [NSFileManager.defaultManager moveItemAtURL:partial toURL:file error:nil];
    NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:file.path error:nil];
    AULog(@"lock screen: %@ clip %dx%d in %.0f ms (layers %.0f ms), %@", moving ? @"3D" : @"still", width, height,
          AUNowMs() - started, prepared - started, AUBytes(attributes.fileSize));
    return moved;
}

#if !TARGET_OS_MACCATALYST

#pragma mark - offering it to the lock screen

#if __IPHONE_OS_VERSION_MAX_ALLOWED < 260000
@interface MPMediaItemAnimatedArtwork : NSObject
- (instancetype)initWithArtworkID:(NSString *)artworkID
       previewImageRequestHandler:(void (^)(CGSize size, void (^completion)(UIImage *_Nullable image)))previewImageRequestHandler
  videoAssetFileURLRequestHandler:(void (^)(CGSize size, void (^completion)(NSURL *_Nullable url)))videoAssetFileURLRequestHandler;
@end
#endif

static NSString *keyNamed(const char *name) {
    void *slot = dlsym(RTLD_DEFAULT, name);
    return slot ? (__bridge NSString *)(*(void **)slot) : nil;
}

static NSArray<NSString *> *supportedKeys(void) {
    Class center = MPNowPlayingInfoCenter.class;
    SEL selector = NSSelectorFromString(@"supportedAnimatedArtworkKeys");
    if (![center respondsToSelector:selector]) return nil;
    id keys = ((id (*)(id, SEL))objc_msgSend)(center, selector);
    return [keys isKindOfClass:NSArray.class] ? keys : nil;
}

static dispatch_queue_t clipQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ queue = dispatch_queue_create("aura.lockscreen", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INITIATED, 0)); });
    return queue;
}

static NSURL *clipFolder(void) {
    NSURL *caches = [NSFileManager.defaultManager URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask].firstObject;
    NSURL *folder = [[caches URLByAppendingPathComponent:@"Aura" isDirectory:YES] URLByAppendingPathComponent:@"Lock" isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:folder withIntermediateDirectories:YES attributes:nil error:nil];
    return folder;
}

static void pruneClips(void) {
    NSArray<NSURL *> *files = [NSFileManager.defaultManager contentsOfDirectoryAtURL:clipFolder()
                                                          includingPropertiesForKeys:@[NSURLContentModificationDateKey] options:0 error:nil];
    if (files.count <= 16) return;
    files = [files sortedArrayUsingComparator:^NSComparisonResult(NSURL *a, NSURL *b) {
        NSDate *da = nil, *db = nil;
        [a getResourceValue:&da forKey:NSURLContentModificationDateKey error:nil];
        [b getResourceValue:&db forKey:NSURLContentModificationDateKey error:nil];
        return [db compare:da];
    }];
    for (NSUInteger i = 16; i < files.count; i++) [NSFileManager.defaultManager removeItemAtURL:files[i] error:nil];
}

static CGSize clipSize(void) {
    CGFloat (*pixels)(void) = (CGFloat (*)(void))dlsym(RTLD_DEFAULT, "SGMotionPixels");
    CGFloat width = pixels ? pixels() : UIScreen.mainScreen.nativeBounds.size.width * 0.75;
    width = MAX(floor(width / 16) * 16, 256);
    return CGSizeMake(width, round(width * 4 / 3 / 16) * 16);
}

static UIImage *filled(UIImage *image, CGSize size) {
    if (!image || size.width < 1 || size.height < 1) return image;
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    format.scale = 1;
    format.opaque = YES;
    CGFloat scale = MAX(size.width / image.size.width, size.height / image.size.height);
    CGSize drawn = CGSizeMake(image.size.width * scale, image.size.height * scale);
    return [[[UIGraphicsImageRenderer alloc] initWithSize:size format:format] imageWithActions:^(UIGraphicsImageRendererContext *context) {
        [image drawInRect:CGRectMake((size.width - drawn.width) / 2, (size.height - drawn.height) / 2, drawn.width, drawn.height)];
    }];
}

// What the clip of a track is made from, read on the main queue from the pipeline's artwork for that very track.
@interface AULockMaterial : NSObject
@property (nonatomic, strong) UIImage *color, *depth, *subject;
@property (nonatomic) BOOL moving;
@property (nonatomic, copy) NSString *signature;
@end

@implementation AULockMaterial
@end

static BOOL settled(AUArtwork *artwork, BOOL moving) {
    BOOL wantDepth = moving && AUEnabled(AUKeyDepth), wantSubject = AUFlag(AUKeyPopOut);
    return artwork.source && (!wantDepth || artwork.depth) && (!wantSubject || artwork.cutout || artwork.noSubject);
}

static AULockMaterial *materialOf(AUArtwork *artwork, BOOL moving) {
    if (!artwork.source) return nil;
    AULockMaterial *material = [AULockMaterial new];
    BOOL subject = AUFlag(AUKeyPopOut) && artwork.cutout && artwork.background;
    BOOL depth = moving && AUEnabled(AUKeyDepth) && artwork.depth;
    material.color = subject ? artwork.background : artwork.source;
    material.depth = depth ? (subject ? (artwork.softDepth ?: artwork.depth) : artwork.depth) : nil;
    material.subject = subject ? artwork.cutout : nil;
    material.moving = depth;
    material.signature = [NSString stringWithFormat:@"%@|%d%d|%d|v7", artwork.key, depth, subject, artwork.upscaled];
    return material;
}

// Waits on the clip queue (never the main one) for the pipeline's artwork of `uri`: settled, or what there is
// once `patience` runs out. nil when that track's artwork never came.
static AULockMaterial *waitForMaterial(NSString *uri, BOOL moving, double patience) {
    double deadline = CACurrentMediaTime() + patience;
    while (YES) {
        __block AULockMaterial *material = nil;
        __block BOOL done = NO, other = NO;
        dispatch_sync(dispatch_get_main_queue(), ^{
            AUArtwork *artwork = [AUPipeline shared].current;
            BOOL ours = artwork && (!uri.length || [artwork.trackURI isEqualToString:uri]);
            NSString *playing = AUTaurusTrackURI();
            other = uri.length && playing.length && ![playing isEqualToString:uri];
            if (ours && (settled(artwork, moving) || CACurrentMediaTime() > deadline)) {
                material = materialOf(artwork, moving);
                done = material != nil;
            }
        });
        if (done) return material;
        if (other || CACurrentMediaTime() > deadline + 4) return nil;
        [NSThread sleepForTimeInterval:0.05];
    }
}

@interface AULockScreen : NSObject
@end

@implementation AULockScreen {
    NSString *_offeredFor;   // track URI and mode of the last offer
}

+ (instancetype)shared {
    static AULockScreen *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [AULockScreen new]; });
    return shared;
}

- (instancetype)init {
    if (!(self = [super init])) return nil;
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(trackChanged) name:AUTrackDidChangeNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(settingsChanged) name:AUSettingsDidChangeNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(trackChanged) name:AUArtworkDidChangeNotification object:nil];
    dispatch_async(dispatch_get_main_queue(), ^{ [self trackChanged]; });
    return self;
}

- (void)settingsChanged {
    _offeredFor = nil;
    [self trackChanged];
}

// Offered the moment the track changes, before its cover is ready, so the lock screen goes full-screen at once
// rather than showing the square cover first: the picture and the video are made when it asks, from that track's
// own artwork, waited for.
- (void)trackChanged {
    NSInteger mode = AUInteger(AUKeyLockScreen, 0);
    NSString *uri = AUTaurusTrackURI();
    NSString *title = AUTaurusTrackTitle();
    if (!uri.length || !title.length) return;
    NSString *offer = [NSString stringWithFormat:@"%@|%ld", uri, (long)mode];
    if ([offer isEqualToString:_offeredFor]) return;
    _offeredFor = offer;
    void (*setExtras)(NSString *, NSDictionary *, NSString *) = (void (*)(NSString *, NSDictionary *, NSString *))dlsym(RTLD_DEFAULT, "SGNowPlayingSetExtras");
    if (!setExtras) {
        AULog(@"lock screen: Taurus's now playing extras are missing");
        return;
    }
    if (mode == 2) {
        setExtras(@"motion", nil, nil);
        return;
    }
    if (@available(iOS 26.0, *)) {
        NSString *key = keyNamed("MPNowPlayingInfoProperty3x4AnimatedArtwork");
        Class artworkClass = NSClassFromString(@"MPMediaItemAnimatedArtwork");
        if (!key || !artworkClass || ![supportedKeys() containsObject:key]) {
            static BOOL told;
            if (!told) AULog(@"lock screen: this iOS takes no 3:4 animated artwork (%@)", [supportedKeys() componentsJoinedByString:@", "]);
            told = YES;
            return;
        }
        BOOL moving = mode == 0;
        CGSize size = clipSize();
        // One offer per track: what it holds is fixed once it is first asked for, and shared by both requests.
        __block AULockMaterial *material = nil;
        __block NSURL *file = nil;
        __block UIImage *poster = nil;
        void (^prepare)(void) = ^{
            if (material) return;
            material = waitForMaterial(uri, moving, 2.5);
            if (!material) {
                AULog(@"lock screen: no artwork for %@ in time", uri);
                return;
            }
            AULockClipInput input = {material.color.CGImage, material.depth.CGImage, material.subject.CGImage};
            CGImageRef first = AULockClipFrame(input, size, 0, material.moving);
            if (first) {
                poster = [UIImage imageWithCGImage:first];
                CGImageRelease(first);
            }
            NSString *name = [NSString stringWithFormat:@"%@-%.0fx%.0f.mp4", AUSHA1(material.signature), size.width, size.height];
            file = [clipFolder() URLByAppendingPathComponent:name];
        };
        NSString *artworkID = [NSString stringWithFormat:@"aura-%@-%ld-v7", AUSHA1(uri), (long)mode];
        MPMediaItemAnimatedArtwork *artwork = [[artworkClass alloc] initWithArtworkID:artworkID
            previewImageRequestHandler:^(CGSize wanted, void (^completion)(UIImage *)) {
                dispatch_async(clipQueue(), ^{
                    prepare();
                    completion(poster ? filled(poster, wanted) : nil);
                });
            }
            videoAssetFileURLRequestHandler:^(CGSize wanted, void (^completion)(NSURL *)) {
                dispatch_async(clipQueue(), ^{
                    prepare();
                    if (!file) {
                        completion(nil);
                        return;
                    }
                    BOOL ready = [NSFileManager.defaultManager fileExistsAtPath:file.path];
                    if (!ready) {
                        AULockClipInput input = {material.color.CGImage, material.depth.CGImage, material.subject.CGImage};
                        ready = AULockClipWrite(file, input, size, material.moving);
                        pruneClips();
                    }
                    AULog(@"lock screen: video for %@ %@", [uri substringFromIndex:uri.length > 8 ? uri.length - 8 : 0], ready ? @"handed over" : @"failed");
                    completion(ready ? file : nil);
                });
            }];
        // Made at once in the background, so it is usually ready before the phone is locked; a request that comes
        // first waits for it on the same queue.
        NSString *uriNow = uri;
        dispatch_async(clipQueue(), ^{
            prepare();
            if (file && ![NSFileManager.defaultManager fileExistsAtPath:file.path]) {
                AULockClipInput input = {material.color.CGImage, material.depth.CGImage, material.subject.CGImage};
                AULockClipWrite(file, input, size, material.moving);
                pruneClips();
                AULog(@"lock screen: clip for %@ made ahead", [uriNow substringFromIndex:uriNow.length > 8 ? uriNow.length - 8 : 0]);
            }
        });
        setExtras(@"motion", @{key: artwork}, title);
        AULog(@"lock screen: %@ offered for \"%@\"", moving ? @"3D flight" : @"stretched cover", title);
    }
}

@end

void AULockScreenStart(void) {
    [AULockScreen shared];
}

#else
void AULockScreenStart(void) {}
#endif
