#import "AULockScreen.h"
#import "Core/AUCore.h"
#import "Features/AUImage.h"
#import "Core/AUTune.h"
#import "Features/AUScene3D.h"
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

// (The numbers are Core/AUTune's: fps, loop, lockBoost, orbitX/Y, lockBlur, lockBlurFrom/To, lockShade, lockBitrate.)
static int32_t clipFPS(void) { return (int32_t)lround(AUTune(@"fps")); }

#pragma mark - the clip, on the CPU
//
// The clip is made when the lock screen asks for it, and Spotify is then in the background, where iOS lets no app
// use the GPU. It needs none: the scene's layers are scaled to the frame once, and each frame is the background bent
// by its depth (AUSceneWarp, all cores) and the objects drawn at their offsets as the camera circles, plus a shade at
// the foot for the lock screen's controls.

typedef struct {
    CGContextRef base;            // the background (square + the room around it), the frame's size and a margin all round
    CGImageRef background;        // the same, as a picture, for the still clip
    size_t margin;
    CGContextRef objects[16];     // each object, premultiplied, the square's size
    CGRect boxes[16];             // where each lies, picture units
    double medians[16];
    int count;
    CGImageRef shade;
    CGSize size;
    CGRect square;                // the square in the frame, pixels, rows top down (zoomed)
    double side;
    double strength;
    BOOL moving;
} AUClipLayers;

// The lock screen's flight: a wide orbit and half again the app's swing — nobody tilts a locked phone to see it.

static CGPoint tiltAt(double phase) {
    return CGPointMake(AUTune(@"orbitX") * sin(2 * M_PI * phase), AUTune(@"orbitY") * cos(2 * M_PI * phase));
}

static CGContextRef bgraContext(size_t width, size_t height, void *data, size_t rowBytes) {
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef context = CGBitmapContextCreate(data, width, height, 8, rowBytes, space, kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    CGColorSpaceRelease(space);
    return context;
}

static CGImageRef scaled(CGImageRef image, CGSize size) {
    CGContextRef c = bgraContext((size_t)ceil(size.width), (size_t)ceil(size.height), NULL, 0);
    if (!c) return NULL;
    CGContextSetInterpolationQuality(c, kCGInterpolationHigh);
    CGContextDrawImage(c, CGRectMake(0, 0, ceil(size.width), ceil(size.height)), image);
    CGImageRef made = CGBitmapContextCreateImage(c);
    CGContextRelease(c);
    return made;
}

// A copy of `image` blurred by about `radius` pixels (a small copy convolved, drawn back up), the same size.
static CGImageRef softened(CGImageRef image, double radius) {
    size_t w = CGImageGetWidth(image), h = CGImageGetHeight(image);
    double shrink = MAX(1.0, radius / 3);
    size_t sw = MAX((size_t)4, (size_t)round(w / shrink)), sh = MAX((size_t)4, (size_t)round(h / shrink));
    CGContextRef small = bgraContext(sw, sh, NULL, 0);
    CGContextSetInterpolationQuality(small, kCGInterpolationHigh);
    CGContextDrawImage(small, CGRectMake(0, 0, sw, sh), image);
    vImage_Buffer a = {CGBitmapContextGetData(small), sh, sw, CGBitmapContextGetBytesPerRow(small)};
    NSMutableData *scratch = [NSMutableData dataWithLength:a.rowBytes * sh];
    vImage_Buffer b = {scratch.mutableBytes, sh, sw, a.rowBytes};
    vImageTentConvolve_ARGB8888(&a, &b, NULL, 0, 0, 7, 7, NULL, kvImageEdgeExtend);
    vImageTentConvolve_ARGB8888(&b, &a, NULL, 0, 0, 7, 7, NULL, kvImageEdgeExtend);
    CGImageRef tiny = CGBitmapContextCreateImage(small);
    CGContextRelease(small);
    CGImageRef made = scaled(tiny, CGSizeMake(w, h));
    CGImageRelease(tiny);
    return made;
}

// The room above and below the square, as Apple fills it: the cover's own top and bottom rows carried out to the
// frame's edges, then a blur that comes on by degrees — starting well inside the cover, barely there at its edge,
// growing over a third of the screen — in three steps blended row by row, so there is no line where it starts.
// `square` is the picture (with the room painted below it, when there is one); the blur comes in from `from` to `to`
// (rows) below, and over the same run above when the picture does not reach the top.
static void extendCover(CGContextRef base, CGRect square, double side, double from, double to) {
    uint8_t *p = CGBitmapContextGetData(base);
    size_t row = CGBitmapContextGetBytesPerRow(base), w = CGBitmapContextGetWidth(base), h = CGBitmapContextGetHeight(base);
    long top = MAX(0L, MIN((long)h - 1, lround(CGRectGetMinY(square))));
    long bottom = MAX(top + 1, MIN((long)h, lround(CGRectGetMaxY(square))));
    long fromTop = MIN(top + 2, (long)h - 1), fromBottom = MAX(bottom - 3, 0L);
    for (long y = 0; y < top; y++) memcpy(p + y * row, p + fromTop * row, row);
    for (long y = bottom; y < (long)h; y++) memcpy(p + y * row, p + fromBottom * row, row);
    CGImageRef full = CGBitmapContextCreateImage(base);
    double blur = AUTune(@"lockBlur");
    const double radii[3] = {0.006 * blur, 0.016 * blur, 0.035 * blur};
    // Each step's share against the distance's progress (0 = well inside the cover, 1 = far out).
    static const double ranges[3][2] = {{0.0, 0.30}, {0.18, 0.60}, {0.45, 1.0}};
    CGContextRef levels[3];
    for (int k = 0; k < 3; k++) {
        CGImageRef image = softened(full, side * radii[k]);
        levels[k] = bgraContext(w, h, NULL, 0);
        CGContextDrawImage(levels[k], CGRectMake(0, 0, w, h), image);
        CGImageRelease(image);
    }
    CGImageRelease(full);
    uint8_t **levelData = malloc(sizeof(uint8_t *) * 3);
    size_t *levelRows = malloc(sizeof(size_t) * 3);
    for (int k = 0; k < 3; k++) {
        levelData[k] = CGBitmapContextGetData(levels[k]);
        levelRows[k] = CGBitmapContextGetBytesPerRow(levels[k]);
    }
    double inside = side * 0.16, outside = side * 0.50;
    double belowFrom = from, belowTo = MAX(from + 1, to);
    dispatch_apply(h, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^(size_t y) {
        long yy = (long)y;
        double progress;
        if (yy >= (top + bottom) / 2) {
            progress = MAX(0.0, MIN(1.0, (yy - belowFrom) / (belowTo - belowFrom)));
        } else {
            double distance = yy < top ? top - yy : -(double)(yy - top);
            progress = top > 0 ? MAX(0.0, MIN(1.0, (distance + inside) / (outside + inside))) : 0;
        }
        uint8_t *o = p + y * row;
        for (int k = 0; k < 3; k++) {
            double t = MAX(0.0, MIN(1.0, (progress - ranges[k][0]) / (ranges[k][1] - ranges[k][0])));
            t = t * t * t * (t * (t * 6 - 15) + 10);
            if (t <= 0) continue;
            uint32_t wt = (uint32_t)lround(t * 256);
            const uint8_t *l = levelData[k] + y * levelRows[k];
            for (size_t i = 0; i < w * 4; i++) o[i] = (uint8_t)((o[i] * (256 - wt) + l[i] * wt) >> 8);
        }
    });
    for (int k = 0; k < 3; k++) CGContextRelease(levels[k]);
    free(levelData);
    free(levelRows);
}

static AUClipLayers makeLayers(AUScene *scene, CGSize size, BOOL moving) {
    AUClipLayers l;
    memset(&l, 0, sizeof(l));
    l.size = size;
    l.moving = moving;
    // The square across the frame's width (zoomed for the camera's swing), a little above the middle, its own rows
    // carried out above and below.
    l.strength = AUTune(@"lockBoost") * AUNumber(AUKeyDepthStrength, 1.0);
    double zoom = l.moving ? AUSceneZoom(l.strength) : 1.0;
    double side = size.width * zoom;
    l.side = side;
    // With the room painted below the cover, the cover sits at the top and the picture runs down the whole frame;
    // without it, a little above the middle with its own rows carried out.
    double tallness = scene.tall ? scene.tallness : 1;
    double top = scene.tall ? (size.width - side) / 2 : (size.height - side) * 0.42;
    l.square = CGRectMake((size.width - side) / 2, top, side, side);
    size_t margin = l.moving ? (size_t)ceil(side * 0.2) : 0;
    l.margin = margin;
    CGSize baseSize = CGSizeMake(size.width + 2 * margin, size.height + 2 * margin);
    CGContextRef base = bgraContext((size_t)baseSize.width, (size_t)baseSize.height, NULL, 0);
    // Core Graphics counts from the bottom.
    double pictureHigh = side * tallness;
    CGRect inBase = CGRectMake(l.square.origin.x + margin, baseSize.height - (top + margin) - pictureHigh, side, pictureHigh);
    CGContextSetInterpolationQuality(base, kCGInterpolationHigh);
    CGContextDrawImage(base, inBase, (scene.tall ?: scene.background).CGImage);
    CGRect pictureTopDown = CGRectMake(inBase.origin.x, top + margin, side, pictureHigh);
    // The blur only at the foot: from 0.74 of the frame (the picture's own foot when it is shorter) to the bottom.
    double footFrom = scene.tall ? margin + size.height * AUTune(@"lockBlurFrom") : margin + top + side - side * 0.16;
    double footTo = scene.tall ? margin + size.height * AUTune(@"lockBlurTo") : margin + top + side + side * 0.5;
    footFrom = MIN(footFrom, margin + top + pictureHigh - side * 0.1);
    extendCover(base, pictureTopDown, side, footFrom, MAX(footFrom + side * 0.15, footTo));
    l.background = CGBitmapContextCreateImage(base);
    l.base = base;
    for (AUSceneLayer *object in scene.layers) {
        if (l.count >= 16) break;
        CGContextRef c = bgraContext((size_t)side, (size_t)side, NULL, 0);
        if (!c) continue;
        CGContextSetInterpolationQuality(c, kCGInterpolationHigh);
        CGContextDrawImage(c, CGRectMake(0, 0, (size_t)side, (size_t)side), object.image.CGImage);
        l.objects[l.count] = c;
        l.boxes[l.count] = AUSceneAlphaBox(CGBitmapContextGetData(c), CGBitmapContextGetBytesPerRow(c), (size_t)side);
        l.medians[l.count] = object.depth;
        l.count++;
    }
    CGContextRef shade = bgraContext((size_t)size.width, (size_t)size.height, NULL, 0);
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGFloat components[8] = {0, 0, 0, AUTune(@"lockShade"), 0, 0, 0, 0};
    CGFloat locations[2] = {0, 1};
    CGGradientRef gradient = CGGradientCreateWithColorComponents(space, components, locations, 2);
    CGContextDrawLinearGradient(shade, gradient, CGPointMake(0, 0), CGPointMake(0, size.height * AUTune(@"lockShadeHeight")), 0);
    CGGradientRelease(gradient);
    CGColorSpaceRelease(space);
    l.shade = CGBitmapContextCreateImage(shade);
    CGContextRelease(shade);
    return l;
}

static void freeLayers(AUClipLayers *l) {
    if (l->background) CGImageRelease(l->background);
    if (l->base) CGContextRelease(l->base);
    for (int i = 0; i < l->count; i++) if (l->objects[i]) CGContextRelease(l->objects[i]);
    if (l->shade) CGImageRelease(l->shade);
    memset(l, 0, sizeof(*l));
}

// The camera circles the window: the background (with its room) and every object, each by its own relief, drawn as
// the camera sees them (AUScene3D on all cores), then the shade at the foot for the lock screen's controls.
static void drawFrame(CGContextRef context, AUClipLayers *l, AUScene *scene, double phase) {
    uint8_t *frame = CGBitmapContextGetData(context);
    size_t w = CGBitmapContextGetWidth(context), h = CGBitmapContextGetHeight(context), row = CGBitmapContextGetBytesPerRow(context);
    if (l->moving && frame && w == (size_t)l->size.width && h == (size_t)l->size.height) {
        AUCamera camera = AUSceneCamera(scene, tiltAt(phase), l->strength);
        CGRect inBase = CGRectOffset(l->square, l->margin, l->margin);
        AUSceneSource back = {CGBitmapContextGetData(l->base), CGBitmapContextGetBytesPerRow(l->base),
                              CGBitmapContextGetWidth(l->base), CGBitmapContextGetHeight(l->base), inBase, NO, 0, NO, CGRectNull};
        AUSceneDraw3D(frame, row, w, h, l->square, scene, camera, back);
        for (int i = 0; i < l->count; i++) {
            if (CGRectIsEmpty(l->boxes[i])) continue;
            CGContextRef o = l->objects[i];
            AUSceneSource object = {CGBitmapContextGetData(o), CGBitmapContextGetBytesPerRow(o), CGBitmapContextGetWidth(o),
                                    CGBitmapContextGetHeight(o), CGRectMake(0, 0, CGBitmapContextGetWidth(o), CGBitmapContextGetHeight(o)),
                                    YES, l->medians[i], NO, l->boxes[i]};
            AUSceneDraw3D(frame, row, w, h, l->square, scene, camera, object);
        }
    } else {
        CGContextSetBlendMode(context, kCGBlendModeCopy);
        CGContextDrawImage(context, CGRectMake(-(double)l->margin, -(double)l->margin, CGImageGetWidth(l->background), CGImageGetHeight(l->background)), l->background);
        CGContextSetBlendMode(context, kCGBlendModeNormal);
        CGRect picture = CGRectMake(l->square.origin.x, l->size.height - CGRectGetMaxY(l->square), l->side, l->side);
        for (int i = 0; i < l->count; i++) {
            CGImageRef image = CGBitmapContextCreateImage(l->objects[i]);
            CGContextDrawImage(context, picture, image);
            CGImageRelease(image);
        }
    }
    CGContextSetBlendMode(context, kCGBlendModeNormal);
    CGContextDrawImage(context, CGRectMake(0, 0, l->size.width, l->size.height), l->shade);
}

CGImageRef AULockClipFrame(AUScene *scene, CGSize size, double phase, BOOL moving) {
    if (!scene.background || size.width < 1 || size.height < 1) return NULL;
    AUClipLayers l = makeLayers(scene, size, moving);
    CGContextRef context = bgraContext((size_t)size.width, (size_t)size.height, NULL, 0);
    drawFrame(context, &l, scene, phase);
    CGImageRef frame = CGBitmapContextCreateImage(context);
    CGContextRelease(context);
    freeLayers(&l);
    return frame;
}

BOOL AULockClipWrite(NSURL *file, AUScene *scene, CGSize size, BOOL moving) {
    if (!scene.background || size.width < 16 || size.height < 16) return NO;
    double started = AUNowMs();
    NSURL *partial = [file URLByAppendingPathExtension:@"partial.mp4"];
    [NSFileManager.defaultManager removeItemAtURL:partial error:nil];
    AVAssetWriter *writer = [AVAssetWriter assetWriterWithURL:partial fileType:AVFileTypeMPEG4 error:nil];
    int32_t width = (int32_t)size.width, height = (int32_t)size.height;
    AVAssetWriterInput *video = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:@{
        AVVideoCodecKey: AVVideoCodecTypeH264,
        AVVideoWidthKey: @(width),
        AVVideoHeightKey: @(height),
        AVVideoCompressionPropertiesKey: @{AVVideoAverageBitRateKey: @(moving ? AUTune(@"lockBitrate") * 1e6 : 1500000), AVVideoMaxKeyFrameIntervalKey: @(clipFPS())},
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
    AUClipLayers l = makeLayers(scene, size, moving);
    int32_t fps = clipFPS();
    int32_t frames = l.moving ? (int32_t)lround(AUTune(@"loop") * fps) : fps;
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
                drawFrame(context, &l, scene, (double)index / frames);
                CGContextRelease(context);
            }
            CVPixelBufferUnlockBaseAddress(buffer, 0);
            ok = context && [adaptor appendPixelBuffer:buffer withPresentationTime:CMTimeMake(index, fps)];
            CVPixelBufferRelease(buffer);
        }
    }
    BOOL wasMoving = l.moving;
    freeLayers(&l);
    if (!ok) {
        AULog(@"lock screen: clip not written: %@", writer.error.localizedDescription ?: @"?");
        [writer cancelWriting];
        [NSFileManager.defaultManager removeItemAtURL:partial error:nil];
        return NO;
    }
    [video markAsFinished];
    [writer endSessionAtSourceTime:CMTimeMake(frames, fps)];
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
    AULog(@"lock screen: %@ clip %dx%d in %.0f ms, %@", wasMoving ? @"3D" : @"still", width, height, AUNowMs() - started, AUBytes(attributes.fileSize));
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
@property (nonatomic, strong) AUScene *scene;
@property (nonatomic) BOOL moving;
@property (nonatomic, copy) NSString *signature;
@end

@implementation AULockMaterial
@end

static BOOL settled(AUArtwork *artwork, BOOL moving) {
    BOOL wantScene = AUEnabled(AUKeyDepth);
    return artwork.source && (!wantScene || artwork.sceneChecked);
}

// The cover alone as a scene (no objects), for a cover without one.
static AUScene *plainScene(UIImage *source) {
    AUScene *scene = [AUScene new];
    scene.background = source;
    scene.square = CGRectMake(0, 0, source.size.width * source.scale, source.size.height * source.scale);
    scene.layers = @[];
    return scene;
}

static AULockMaterial *materialOf(AUArtwork *artwork, BOOL moving) {
    if (!artwork.source) return nil;
    AULockMaterial *material = [AULockMaterial new];
    material.scene = artwork.scene ?: plainScene(artwork.source);
    material.moving = moving;
    material.signature = [NSString stringWithFormat:@"%@|%d|%lu|%d|%d|v10|%@", artwork.key, material.moving, (unsigned long)material.scene.layers.count,
                          material.scene.inpainted, artwork.upscaled, AUTuneSignature(AUTuneLock)];
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
            CGImageRef first = AULockClipFrame(material.scene, size, 0, material.moving);
            if (first) {
                poster = [UIImage imageWithCGImage:first];
                CGImageRelease(first);
            }
            NSString *name = [NSString stringWithFormat:@"%@-%.0fx%.0f.mp4", AUSHA1(material.signature), size.width, size.height];
            file = [clipFolder() URLByAppendingPathComponent:name];
        };
        NSString *artworkID = [NSString stringWithFormat:@"aura-%@-%ld-v8", AUSHA1(uri), (long)mode];
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
                        ready = AULockClipWrite(file, material.scene, size, material.moving);
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
                AULockClipWrite(file, material.scene, size, material.moving);
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
