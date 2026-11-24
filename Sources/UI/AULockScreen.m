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
static const double kStrength = 0.05, kBackgroundShare = 0.25;

#pragma mark - the clip, on the CPU
//
// The clip is made when the lock screen asks for it, and Spotify is then in the background, where iOS lets no app
// use the GPU. It needs none: the scene's layers are scaled to the frame once, and each frame is the background and
// the objects drawn at their offsets as the camera circles, plus a shade at the foot for the lock screen's controls.

typedef struct {
    CGImageRef background;        // drawn at the picture's size
    CGImageRef objects[8];
    double weights[8];
    int count;
    CGImageRef shade;
    CGSize size;
    CGRect picture;               // where the canvas is drawn in the frame (origin bottom left), zoomed
    double side;
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

static CGImageRef scaled(CGImageRef image, CGSize size) {
    CGContextRef c = bgraContext((size_t)ceil(size.width), (size_t)ceil(size.height), NULL, 0);
    if (!c) return NULL;
    CGContextSetInterpolationQuality(c, kCGInterpolationHigh);
    CGContextDrawImage(c, CGRectMake(0, 0, ceil(size.width), ceil(size.height)), image);
    CGImageRef made = CGBitmapContextCreateImage(c);
    CGContextRelease(c);
    return made;
}

static AUClipLayers makeLayers(AUScene *scene, CGSize size, BOOL moving) {
    AUClipLayers l;
    memset(&l, 0, sizeof(l));
    l.size = size;
    l.moving = moving && scene.layers.count;
    CGSize canvas = scene.background.size;
    double scale = MAX(size.width / canvas.width, size.height / canvas.height);
    if (l.moving) scale *= 1 + 2.2 * kBackgroundShare * kStrength;
    CGSize drawn = CGSizeMake(canvas.width * scale, canvas.height * scale);
    l.picture = CGRectMake((size.width - drawn.width) / 2, (size.height - drawn.height) / 2, drawn.width, drawn.height);
    l.side = MIN(drawn.width, drawn.height);
    l.background = scaled(scene.background.CGImage, drawn);
    for (AUSceneLayer *object in scene.layers) {
        if (l.count >= 8) break;
        l.objects[l.count] = scaled(object.image.CGImage, drawn);
        l.weights[l.count] = [scene weightOf:object];
        l.count++;
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
    if (l->background) CGImageRelease(l->background);
    for (int i = 0; i < l->count; i++) if (l->objects[i]) CGImageRelease(l->objects[i]);
    if (l->shade) CGImageRelease(l->shade);
    memset(l, 0, sizeof(*l));
}

// Down the screen is +y in the app; Core Graphics counts from the bottom, so the tilt's y is turned over.
static void drawFrame(CGContextRef context, AUClipLayers *l, double phase) {
    CGPoint tilt = l->moving ? tiltAt(phase) : CGPointZero;
    CGContextSetInterpolationQuality(context, kCGInterpolationLow);
    CGContextSetBlendMode(context, kCGBlendModeCopy);
    double back = -kBackgroundShare * kStrength * l->side;
    CGContextDrawImage(context, CGRectOffset(l->picture, tilt.x * back, -tilt.y * back), l->background);
    CGContextSetBlendMode(context, kCGBlendModeNormal);
    for (int i = 0; i < l->count; i++) {
        double amount = l->weights[i] * kStrength * l->side;
        CGContextDrawImage(context, CGRectOffset(l->picture, tilt.x * amount, -tilt.y * amount), l->objects[i]);
    }
    CGContextDrawImage(context, CGRectMake(0, 0, l->size.width, l->size.height), l->shade);
}

CGImageRef AULockClipFrame(AUScene *scene, CGSize size, double phase, BOOL moving) {
    if (!scene.background || size.width < 1 || size.height < 1) return NULL;
    AUClipLayers l = makeLayers(scene, size, moving);
    CGContextRef context = bgraContext((size_t)size.width, (size_t)size.height, NULL, 0);
    drawFrame(context, &l, phase);
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
    AUClipLayers l = makeLayers(scene, size, moving);
    int32_t frames = l.moving ? kLoopSeconds * kFPS : kFPS;
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
                drawFrame(context, &l, (double)index / frames);
                CGContextRelease(context);
            }
            CVPixelBufferUnlockBaseAddress(buffer, 0);
            ok = context && [adaptor appendPixelBuffer:buffer withPresentationTime:CMTimeMake(index, kFPS)];
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
    BOOL wantScene = AUEnabled(AUKeyDepth) || AUEnabled(AUKeyCutout);
    return artwork.source && (!wantScene || artwork.sceneChecked);
}

// The cover alone as a scene (no objects, the cover filled over the 3:4 canvas), for a cover without one.
static AUScene *plainScene(UIImage *source) {
    CGSize canvas = CGSizeMake(source.size.width, round(source.size.width * 4 / 3));
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    format.scale = 1;
    format.opaque = YES;
    UIImage *background = [[[UIGraphicsImageRenderer alloc] initWithSize:canvas format:format] imageWithActions:^(UIGraphicsImageRendererContext *c) {
        CGFloat scale = MAX(canvas.width / source.size.width, canvas.height / source.size.height);
        CGSize drawn = CGSizeMake(source.size.width * scale, source.size.height * scale);
        [source drawInRect:CGRectMake((canvas.width - drawn.width) / 2, (canvas.height - drawn.height) / 2, drawn.width, drawn.height)];
    }];
    AUScene *scene = [AUScene new];
    scene.background = background;
    scene.square = CGRectMake(0, (canvas.height - canvas.width) / 2, canvas.width, canvas.width);
    scene.layers = @[];
    return scene;
}

static AULockMaterial *materialOf(AUArtwork *artwork, BOOL moving) {
    if (!artwork.source) return nil;
    AULockMaterial *material = [AULockMaterial new];
    material.scene = artwork.scene ?: plainScene(artwork.source);
    material.moving = moving && material.scene.layers.count;
    material.signature = [NSString stringWithFormat:@"%@|%d|%lu|%d|%d|v6", artwork.key, material.moving, (unsigned long)material.scene.layers.count,
                          material.scene.inpainted, artwork.upscaled];
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
        NSString *artworkID = [NSString stringWithFormat:@"aura-%@-%ld-v6", AUSHA1(uri), (long)mode];
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
