#import "AULockScreen.h"
#import "AUParallaxRenderer.h"
#import "Core/AUCore.h"
#import <AVFoundation/AVFoundation.h>
#import <TargetConditionals.h>
#import <dlfcn.h>
#import <objc/message.h>
#if !TARGET_OS_MACCATALYST
#import <MediaPlayer/MediaPlayer.h>
#import "Features/AUPipeline.h"
#endif

static const int32_t kFPS = 30, kLoopSeconds = 6;
static const double kStrength = 0.04, kZoom = 1.07;

#pragma mark - the clip

// The flight's path: an ellipse, wider than tall, once round the loop, so the last frame meets the first.
static CGPoint tiltAt(double phase) {
    return CGPointMake(0.65 * sin(2 * M_PI * phase), 0.4 * cos(2 * M_PI * phase));
}

static AUParallaxRenderer *rendererFor(AULockClipInput input, BOOL moving) {
    AUParallaxRenderer *renderer = [AUParallaxRenderer new];
    [renderer setColor:input.color depth:moving ? input.depth : NULL];
    renderer.zoom = moving && input.depth ? kZoom : 1.0;
    renderer.strength = moving && input.depth ? kStrength : 0;
    return renderer;
}

// Draws the frame into `context` (width x height, origin bottom left): the renderer's picture, the subject over it
// where the picture puts it, and a shade at the foot so the lock screen's controls read.
static void drawFrame(CGContextRef context, AUParallaxRenderer *renderer, AULockClipInput input, CGSize size, double phase, BOOL moving) {
    CGPoint tilt = moving ? tiltAt(phase) : CGPointZero;
    renderer.tilt = tilt;
    CGImageRef picture = [renderer renderImageWidth:(size_t)size.width height:(size_t)size.height];
    CGRect all = CGRectMake(0, 0, size.width, size.height);
    if (picture) {
        CGContextDrawImage(context, all, picture);
        CGImageRelease(picture);
    }
    if (input.subject) {
        // The cover is aspect-filled and zoomed as the renderer does it; the subject is the nearest thing on it.
        double zoom = renderer.zoom;
        double side = MAX(size.width, size.height) * zoom * MAX(1.0, (double)CGImageGetWidth(input.subject) / CGImageGetHeight(input.subject));
        double shift = kStrength * 0.55 * side * (moving && input.depth ? 1 : 0);
        CGRect rect = CGRectMake((size.width - side) / 2 + tilt.x * shift, (size.height - side) / 2 - tilt.y * shift, side, side);
        CGContextSaveGState(context);
        CGContextSetShadowWithColor(context, CGSizeMake(0, -10), 22, [[UIColor colorWithWhite:0 alpha:0.5] CGColor]);
        CGContextDrawImage(context, rect, input.subject);
        CGContextRestoreGState(context);
    }
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGFloat components[8] = {0, 0, 0, 0.45, 0, 0, 0, 0};
    CGFloat locations[2] = {0, 1};
    CGGradientRef shade = CGGradientCreateWithColorComponents(space, components, locations, 2);
    CGContextDrawLinearGradient(context, shade, CGPointMake(0, 0), CGPointMake(0, size.height * 0.32), 0);
    CGGradientRelease(shade);
    CGColorSpaceRelease(space);
}

CGImageRef AULockClipFrame(AULockClipInput input, CGSize size, double phase, BOOL moving) {
    if (!input.color || size.width < 1 || size.height < 1) return NULL;
    AUParallaxRenderer *renderer = rendererFor(input, moving);
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef context = CGBitmapContextCreate(NULL, (size_t)size.width, (size_t)size.height, 8, 0, space,
                                                 kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    CGColorSpaceRelease(space);
    if (!context) return NULL;
    drawFrame(context, renderer, input, size, phase, moving);
    CGImageRef frame = CGBitmapContextCreateImage(context);
    CGContextRelease(context);
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
    if (![writer startWriting]) return NO;
    [writer startSessionAtSourceTime:kCMTimeZero];
    AUParallaxRenderer *renderer = rendererFor(input, moving);
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
            CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
            CGContextRef context = CGBitmapContextCreate(CVPixelBufferGetBaseAddress(buffer), (size_t)width, (size_t)height, 8,
                                                         CVPixelBufferGetBytesPerRow(buffer), space,
                                                         kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
            CGColorSpaceRelease(space);
            if (context) {
                // A still clip draws its one frame once and repeats the buffer's copy.
                drawFrame(context, renderer, input, size, (double)index / frames, moving);
                CGContextRelease(context);
            }
            CVPixelBufferUnlockBaseAddress(buffer, 0);
            ok = context && [adaptor appendPixelBuffer:buffer withPresentationTime:CMTimeMake(index, kFPS)];
            CVPixelBufferRelease(buffer);
        }
    }
    if (!ok) {
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
        [NSFileManager.defaultManager removeItemAtURL:partial error:nil];
        return NO;
    }
    [NSFileManager.defaultManager removeItemAtURL:file error:nil];
    BOOL moved = [NSFileManager.defaultManager moveItemAtURL:partial toURL:file error:nil];
    NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:file.path error:nil];
    AULog(@"lock screen: %@ clip %dx%d written in %.0f ms, %@", moving ? @"3D" : @"still", width, height, AUNowMs() - started,
          AUBytes(attributes.fileSize));
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
    dispatch_once(&once, ^{ queue = dispatch_queue_create("aura.lockscreen", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0)); });
    return queue;
}

static NSURL *clipFolder(void) {
    NSURL *caches = [NSFileManager.defaultManager URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask].firstObject;
    NSURL *folder = [[caches URLByAppendingPathComponent:@"Aura" isDirectory:YES] URLByAppendingPathComponent:@"Lock" isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:folder withIntermediateDirectories:YES attributes:nil error:nil];
    return folder;
}

// The newest dozen clips are kept; a cover played again gets its clip back at once.
static void pruneClips(void) {
    NSArray<NSURL *> *files = [NSFileManager.defaultManager contentsOfDirectoryAtURL:clipFolder()
                                                          includingPropertiesForKeys:@[NSURLContentModificationDateKey] options:0 error:nil];
    if (files.count <= 12) return;
    files = [files sortedArrayUsingComparator:^NSComparisonResult(NSURL *a, NSURL *b) {
        NSDate *da = nil, *db = nil;
        [a getResourceValue:&da forKey:NSURLContentModificationDateKey error:nil];
        [b getResourceValue:&db forKey:NSURLContentModificationDateKey error:nil];
        return [db compare:da];
    }];
    for (NSUInteger i = 12; i < files.count; i++) [NSFileManager.defaultManager removeItemAtURL:files[i] error:nil];
}

static CGSize clipSize(void) {
    CGFloat (*pixels)(void) = (CGFloat (*)(void))dlsym(RTLD_DEFAULT, "SGMotionPixels");
    CGFloat width = pixels ? pixels() : UIScreen.mainScreen.nativeBounds.size.width * 0.75;
    width = MAX(floor(width / 16) * 16, 256);
    return CGSizeMake(width, round(width * 4 / 3 / 16) * 16);
}

static NSString *currentTitle(void) {
    SEL stateSelector = NSSelectorFromString(@"track");
    id (*state)(void) = (id (*)(void))dlsym(RTLD_DEFAULT, "SGPlayerState");
    id player = state ? state() : nil;
    id track = [player respondsToSelector:stateSelector] ? [player valueForKey:@"track"] : nil;
    NSString *title = [track respondsToSelector:NSSelectorFromString(@"trackTitle")] ? [track valueForKey:@"trackTitle"] : nil;
    NSString *shown = MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo[MPMediaItemPropertyTitle];
    BOOL (*match)(id, id) = (BOOL (*)(id, id))dlsym(RTLD_DEFAULT, "SGNowPlayingTitlesMatch");
    if ([shown isKindOfClass:NSString.class] && title && match && match(shown, title)) return shown;
    return title ?: ([shown isKindOfClass:NSString.class] ? shown : nil);
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

@interface AULockScreen : NSObject
@end

@implementation AULockScreen {
    NSString *_offered;   // the signature of what was offered last
    NSUInteger _walk;
}

+ (instancetype)shared {
    static AULockScreen *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [AULockScreen new]; });
    return shared;
}

- (instancetype)init {
    if (!(self = [super init])) return nil;
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(artworkChanged:) name:AUArtworkDidChangeNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(settingsChanged) name:AUSettingsDidChangeNotification object:nil];
    return self;
}

- (void)settingsChanged {
    _offered = nil;
    [self consider:[AUPipeline shared].current];
}

- (void)artworkChanged:(NSNotification *)note {
    [self consider:note.object];
}

// Offered once the cover's effects have settled (or 2 s after it came, with what there is), and again only if what
// would be drawn changed.
- (void)consider:(AUArtwork *)artwork {
    NSInteger mode = AUInteger(AUKeyLockScreen, 0);
    if (!artwork.source || mode == 2) {
        if (mode == 2 && _offered) {
            _offered = nil;
            [self offer:nil];
        }
        return;
    }
    BOOL moving = mode == 0;
    BOOL wantDepth = moving && AUEnabled(AUKeyDepth), wantSubject = AUEnabled(AUKeyCutout);
    BOOL settled = (!wantDepth || artwork.depth) && (!wantSubject || artwork.cutout || artwork.noSubject);
    NSUInteger walk = ++_walk;
    if (!settled) {
        __weak AUArtwork *weakArtwork = artwork;
        CFTimeInterval left = MAX(0, 2.0 - (CACurrentMediaTime() - artwork.arrived));
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(left * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            AUArtwork *later = weakArtwork;
            if (walk == self->_walk && later == [AUPipeline shared].current) [self offerArtwork:later moving:moving];
        });
        return;
    }
    [self offerArtwork:artwork moving:moving];
}

- (void)offerArtwork:(AUArtwork *)artwork moving:(BOOL)moving {
    BOOL subject = AUEnabled(AUKeyCutout) && artwork.cutout && artwork.background;
    BOOL depth = moving && AUEnabled(AUKeyDepth) && artwork.depth;
    NSString *signature = [NSString stringWithFormat:@"%@|%d%d%d|%d", artwork.key, moving, depth, subject, artwork.upscaled];
    if ([signature isEqualToString:_offered]) return;
    _offered = signature;
    UIImage *color = subject ? artwork.background : artwork.source;
    UIImage *depthMap = depth ? (subject ? (artwork.softDepth ?: artwork.depth) : artwork.depth) : nil;
    UIImage *cutout = subject ? artwork.cutout : nil;
    [self offer:@{@"signature": signature, @"color": color, @"depth": depthMap ?: NSNull.null, @"subject": cutout ?: NSNull.null,
                  @"moving": @(depth)}];
}

- (void)offer:(NSDictionary *)clip {
    void (*setExtras)(NSString *, NSDictionary *, NSString *) = (void (*)(NSString *, NSDictionary *, NSString *))dlsym(RTLD_DEFAULT, "SGNowPlayingSetExtras");
    if (!setExtras) {
        AULog(@"lock screen: Taurus's now playing extras are missing");
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
        NSString *title = currentTitle();
        if (!clip) {
            setExtras(@"motion", nil, nil);
            return;
        }
        if (!title.length) return;
        UIImage *color = clip[@"color"];
        UIImage *depth = clip[@"depth"] == NSNull.null ? nil : clip[@"depth"];
        UIImage *subject = clip[@"subject"] == NSNull.null ? nil : clip[@"subject"];
        BOOL moving = [clip[@"moving"] boolValue];
        CGSize size = clipSize();
        NSString *name = [NSString stringWithFormat:@"%@-%.0fx%.0f-v1.mp4", AUSHA1(clip[@"signature"]), size.width, size.height];
        NSURL *file = [clipFolder() URLByAppendingPathComponent:name];
        // Made now, in the background, so it is ready when the screen locks; the lock screen's ask waits for it.
        __block UIImage *poster = nil;
        __block BOOL ready = [NSFileManager.defaultManager fileExistsAtPath:file.path];
        UIImage *keepColor = color, *keepDepth = depth, *keepSubject = subject;
        dispatch_async(clipQueue(), ^{
            AULockClipInput held = {keepColor.CGImage, keepDepth.CGImage, keepSubject.CGImage};
            CGImageRef first = AULockClipFrame(held, size, 0, moving);
            if (first) {
                poster = [UIImage imageWithCGImage:first];
                CGImageRelease(first);
            }
            if (!ready) ready = AULockClipWrite(file, held, size, moving);
            pruneClips();
        });
        MPMediaItemAnimatedArtwork *artwork = [[artworkClass alloc] initWithArtworkID:name
            previewImageRequestHandler:^(CGSize wanted, void (^completion)(UIImage *)) {
                dispatch_async(clipQueue(), ^{ completion(filled(poster, wanted)); });
            }
            videoAssetFileURLRequestHandler:^(CGSize wanted, void (^completion)(NSURL *)) {
                dispatch_async(clipQueue(), ^{ completion(ready ? file : nil); });
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
