#import "AULockScreen.h"
#import "Core/AUCore.h"
#import "Features/AUImage.h"
#import <AVFoundation/AVFoundation.h>
#import <TargetConditionals.h>
#import <dlfcn.h>
#import <objc/message.h>
#if !TARGET_OS_MACCATALYST
#import <MediaPlayer/MediaPlayer.h>
#import "Core/AUTaurus.h"
#import "Features/AUPipeline.h"
#endif

static const int32_t kFPS = 30, kLoopSeconds = 6;
static const double kStrength = 0.04, kZoom = 1.07;

#pragma mark - the clip, on the CPU
//
// The clip is made when the lock screen asks for it, and Spotify is then in the background, where iOS lets no app
// use the GPU (a Metal frame comes out black). So it is drawn with Core Graphics: the cover cut by its depth map into
// three layers (far, middle, near, soft-edged), each shifted by its depth as the camera circles, the subject in
// front with its shadow baked in, and a shade at the foot for the lock screen's controls.

typedef struct {
    CGImageRef layers[3];       // far (opaque), middle, near; each the canvas's size
    double depths[3];
    CGImageRef subject;         // with its shadow, the canvas's size, or NULL
    CGImageRef shade;
    CGSize size, canvas;        // the frame, and the frame with a margin for the shifts all round
    double side;                // the cover's side as drawn
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

// The cover aspect-filled and zoomed into the canvas, as the frame's middle.
static CGRect coverRect(AUClipLayers *l) {
    return CGRectMake((l->canvas.width - l->side) / 2, (l->canvas.height - l->side) / 2, l->side, l->side);
}

static float smooth(float x, float a, float b) {
    float t = fminf(1, fmaxf(0, (x - a) / (b - a)));
    return t * t * (3 - 2 * t);
}

static AUClipLayers makeLayers(AULockClipInput input, CGSize size, BOOL moving) {
    AUClipLayers l = {{NULL, NULL, NULL}, {0.25, 0.55, 0.85}, NULL, NULL, size, size, 0};
    BOOL layered = moving && input.depth;
    double zoom = layered ? kZoom : 1.0;
    l.side = MAX(size.width, size.height) * zoom;
    double margin = layered ? ceil(kStrength * l.side * 0.6) : 0;
    l.canvas = CGSizeMake(size.width + 2 * margin, size.height + 2 * margin);
    size_t cw = (size_t)l.canvas.width, ch = (size_t)l.canvas.height;
    CGRect rect = coverRect(&l);
    CGContextRef far = bgraContext(cw, ch, NULL, 0);
    CGContextSetInterpolationQuality(far, kCGInterpolationHigh);
    CGContextDrawImage(far, rect, input.color);
    l.layers[0] = CGBitmapContextCreateImage(far);
    if (layered) {
        // The depth map at the canvas's size, and the middle and near layers cut from the cover by it.
        NSMutableData *depth = [NSMutableData dataWithLength:cw * ch];
        CGColorSpaceRef gray = CGColorSpaceCreateDeviceGray();
        CGContextRef d = CGBitmapContextCreate(depth.mutableBytes, cw, ch, 8, cw, gray, (CGBitmapInfo)kCGImageAlphaNone);
        CGColorSpaceRelease(gray);
        CGContextSetInterpolationQuality(d, kCGInterpolationHigh);
        CGContextDrawImage(d, rect, input.depth);
        CGContextRelease(d);
        const uint8_t *dp = depth.bytes;
        const uint8_t *src = CGBitmapContextGetData(far);
        size_t srcRow = CGBitmapContextGetBytesPerRow(far);
        float bands[2][2] = {{0.33f, 0.5f}, {0.62f, 0.78f}};
        for (int k = 0; k < 2; k++) {
            CGContextRef layer = bgraContext(cw, ch, NULL, 0);
            uint8_t *dst = CGBitmapContextGetData(layer);
            size_t dstRow = CGBitmapContextGetBytesPerRow(layer);
            // Core Graphics' rows run from the top in memory, as the depth context's do.
            for (size_t y = 0; y < ch; y++) {
                const uint8_t *s = src + y * srcRow;
                uint8_t *o = dst + y * dstRow;
                for (size_t x = 0; x < cw; x++) {
                    float a = smooth(dp[y * cw + x] / 255.0f, bands[k][0], bands[k][1]);
                    o[x * 4 + 0] = (uint8_t)(s[x * 4 + 0] * a);
                    o[x * 4 + 1] = (uint8_t)(s[x * 4 + 1] * a);
                    o[x * 4 + 2] = (uint8_t)(s[x * 4 + 2] * a);
                    o[x * 4 + 3] = (uint8_t)(255 * a);
                }
            }
            l.layers[k + 1] = CGBitmapContextCreateImage(layer);
            CGContextRelease(layer);
        }
    }
    CGContextRelease(far);
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
    for (int k = 0; k < 3; k++) if (l->layers[k]) CGImageRelease(l->layers[k]);
    if (l->subject) CGImageRelease(l->subject);
    if (l->shade) CGImageRelease(l->shade);
}

static void drawFrame(CGContextRef context, AUClipLayers *l, double phase, BOOL moving) {
    CGPoint tilt = moving ? tiltAt(phase) : CGPointZero;
    double margin = (l->canvas.width - l->size.width) / 2;
    CGContextSetInterpolationQuality(context, kCGInterpolationLow);
    CGContextSetBlendMode(context, kCGBlendModeCopy);
    for (int k = 0; k < 3; k++) {
        if (!l->layers[k]) continue;
        double amount = kStrength * l->side * (l->depths[k] - 0.5);
        // Down the screen is up in Core Graphics: the tilt's y is turned over.
        CGRect at = CGRectMake(-margin + tilt.x * amount, -margin - tilt.y * amount, l->canvas.width, l->canvas.height);
        CGContextDrawImage(context, at, l->layers[k]);
        if (k == 0) CGContextSetBlendMode(context, kCGBlendModeNormal);
    }
    if (l->subject) {
        double amount = kStrength * l->side * 0.55 * (moving && l->layers[1] ? 1 : 0);
        CGContextDrawImage(context, CGRectMake(-margin + tilt.x * amount, -margin - tilt.y * amount, l->canvas.width, l->canvas.height), l->subject);
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
    BOOL wantDepth = moving && AUEnabled(AUKeyDepth), wantSubject = AUEnabled(AUKeyCutout);
    return artwork.source && (!wantDepth || artwork.depth) && (!wantSubject || artwork.cutout || artwork.noSubject);
}

static AULockMaterial *materialOf(AUArtwork *artwork, BOOL moving) {
    if (!artwork.source) return nil;
    AULockMaterial *material = [AULockMaterial new];
    BOOL subject = AUEnabled(AUKeyCutout) && artwork.cutout && artwork.background;
    BOOL depth = moving && AUEnabled(AUKeyDepth) && artwork.depth;
    material.color = subject ? artwork.background : artwork.source;
    material.depth = depth ? (subject ? (artwork.softDepth ?: artwork.depth) : artwork.depth) : nil;
    material.subject = subject ? artwork.cutout : nil;
    material.moving = depth;
    material.signature = [NSString stringWithFormat:@"%@|%d%d|%d|v2", artwork.key, depth, subject, artwork.upscaled];
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
        NSString *artworkID = [NSString stringWithFormat:@"aura-%@-%ld-v2", AUSHA1(uri), (long)mode];
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
