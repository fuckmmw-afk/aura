#import "AUPipeline.h"
#import "AUImage.h"
#import "AUVision.h"
#import "Core/AUCore.h"
#import "Core/AUModelManager.h"
#import "Core/AUTaurus.h"

NSNotificationName const AUArtworkDidChangeNotification = @"AUArtworkDidChangeNotification";

static const size_t kWorkSide = 1024;       // covers are read at most this big
static const size_t kUpscaleBelow = 600;    // a cover under this on its longer side is upscaled
static const uint64_t kCacheLimit = 150ull * 1024 * 1024;

@implementation AUArtwork
- (instancetype)initWithKey:(NSString *)key exact:(BOOL)exact {
    if (!(self = [super init])) return nil;
    _key = [key copy];
    _exact = exact;
    return self;
}
@end

@implementation AUPipeline {
    dispatch_queue_t _work;
    NSCache<NSString *, AUArtwork *> *_memory;
    NSUInteger _generation;     // the artwork being worked on; a stage of an older one stops
    UIImage *_pendingImage;
    NSString *_pendingKey, *_pendingURI;
    BOOL _pendingExact;
    BOOL _scheduled;
}

+ (instancetype)shared {
    static AUPipeline *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [AUPipeline new]; });
    return shared;
}

- (instancetype)init {
    if (!(self = [super init])) return nil;
    _work = dispatch_queue_create("aura.pipeline", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INITIATED, 0));
    _memory = [NSCache new];
    _memory.countLimit = 6;
    return self;
}

- (void)start {
    NSNotificationName name = AUTaurusArtworkNotification();
    if (!name) {
        AULog(@"pipeline: Taurus publishes no artwork notification; nothing to follow");
        return;
    }
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(artworkChanged:) name:name object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(settingsChanged) name:AUSettingsDidChangeNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(modelsChanged:) name:AUModelsDidChangeNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(settingsChanged) name:AUThrottleDidChangeNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(memoryWarning)
                                               name:UIApplicationDidReceiveMemoryWarningNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(trackChanged:) name:AUTrackDidChangeNotification object:nil];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_BACKGROUND, 0), ^{ [self pruneTo:kCacheLimit]; });
    [self artworkChanged:nil];
}

#pragma mark - following the player

- (void)artworkChanged:(NSNotification *)note {
    NSString *key = nil, *uri = nil;
    BOOL exact = NO;
    UIImage *image = AUTaurusArtwork(&uri, &key, &exact);
    if (!image.CGImage || !key.length) return;
    // A screen's copy of the same picture after the exact one adds nothing but, for the next song of the same
    // album, the track it now stands for.
    if ([key isEqualToString:_current.key] && (_current.exact || !exact)) {
        if (uri.length && ![uri isEqualToString:_current.trackURI]) {
            _current.trackURI = uri;
            [self post:_current];
        }
        return;
    }
    _pendingURI = uri;
    _pendingImage = image;
    _pendingKey = key;
    _pendingExact = exact;
    // A screen copy then the exact picture come close together: the exact one is waited for a moment.
    if (_scheduled) return;
    _scheduled = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(exact ? 0 : 0.08 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        self->_scheduled = NO;
        [self beginPending];
    });
}

// The next song of the same album: Taurus publishes nothing (its picture has not changed), so the artwork, with all
// that was made from it, is handed to the new track here — else it would wait for a picture that never comes.
- (void)trackChanged:(NSNotification *)note {
    NSString *uri = note.userInfo[@"uri"];
    AUArtwork *current = _current;
    if (!uri.length || !current || [current.trackURI isEqualToString:uri]) return;
    NSString *picture = AUTaurusTrackPictureKey();
    if (picture.length && [current.key isEqualToString:picture]) {
        current.trackURI = uri;
        AULog(@"track %@ shares the cover: its artwork carries over", [uri substringFromIndex:uri.length > 8 ? uri.length - 8 : 0]);
        [self post:current];
    }
}

- (void)beginPending {
    UIImage *image = _pendingImage;
    NSString *key = _pendingKey;
    BOOL exact = _pendingExact;
    _pendingImage = nil;
    if (!image) return;
    AUArtwork *artwork = [_memory objectForKey:key];
    if (!artwork || (exact && !artwork.exact)) artwork = [[AUArtwork alloc] initWithKey:key exact:exact];
    artwork.arrived = CACurrentMediaTime();
    artwork.trackURI = _pendingURI;
    _current = artwork;
    [self post:artwork];
    [self work:artwork image:image];
}

- (void)settingsChanged {
    AUArtwork *artwork = _current;
    if (!artwork) return;
    UIImage *image = AUTaurusArtwork(NULL, NULL, NULL);
    if (image.CGImage) [self work:artwork image:image];
    [self post:artwork];
}

// Only a model that has just become ready restarts the work; its progress and loads do not.
- (void)modelsChanged:(NSNotification *)note {
    static NSMutableDictionary<NSString *, NSNumber *> *states;
    if (!states) states = [NSMutableDictionary dictionary];
    NSString *modelID = note.object;
    if (![modelID isKindOfClass:NSString.class]) return;
    AUModelState state = [AUModelManager.shared stateOf:modelID];
    NSNumber *before = states[modelID];
    states[modelID] = @(state);
    if (state == AUModelReady && before && before.integerValue != AUModelReady) [self settingsChanged];
}

- (void)memoryWarning {
    [_memory removeAllObjects];
}

- (void)post:(AUArtwork *)artwork {
    if (artwork != _current) return;
    [NSNotificationCenter.defaultCenter postNotificationName:AUArtworkDidChangeNotification object:artwork];
}

// Hands a finished stage to the main queue, as the current artwork's if it still is.
- (void)deliver:(AUArtwork *)artwork generation:(NSUInteger)generation apply:(void (^)(void))apply {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (generation != self->_generation) return;
        apply();
        [self post:artwork];
    });
}

#pragma mark - the stages

- (void)work:(AUArtwork *)artwork image:(UIImage *)image {
    NSUInteger generation = ++_generation;
    BOOL wantTheme = AUEnabled(AUKeyTheme), wantDepth = AUEnabled(AUKeyDepth), wantScene = AUEnabled(AUKeyDepth);
    BOOL wantUpscale = AUEnabled(AUKeyUpscale), peopleOnly = AUFlag(AUKeyScenePeopleOnly), throttled = AUThrottled();
    BOOL lamaReady = [AUModelManager.shared stateOf:AUModelInpaint] == AUModelReady;
    if (throttled) AULog(@"pipeline: hot (%@): the palette only", AUThermalName());
    BOOL needPalette = wantTheme && !artwork.palette;
    BOOL needSource = !artwork.source || (wantUpscale && !throttled && !artwork.upscaleChecked) || (!wantUpscale && artwork.upscaled);
    BOOL needDepth = (wantDepth || wantScene) && !artwork.depth && !throttled;
    BOOL needScene = wantScene && !throttled
        && (!artwork.sceneChecked || artwork.scenePeopleOnly != peopleOnly || (artwork.scene && !artwork.scene.inpainted && lamaReady));
    if (wantScene && !lamaReady) [AUModelManager.shared ensure:AUModelInpaint];
    if (!needPalette && !needSource && !needDepth && !needScene) return;
    [self memoryStore:artwork];
    CGImageRef cgImage = CGImageRetain(image.CGImage);
    NSString *folder = [self folderFor:artwork];
    UIImage *knownDepth = artwork.depth;
    dispatch_async(_work, ^{
        @autoreleasepool {
            [self runStages:artwork image:cgImage folder:folder generation:generation palette:needPalette upscale:wantUpscale && !throttled
                      depth:needDepth knownDepth:knownDepth scene:needScene peopleOnly:peopleOnly];
        }
        CGImageRelease(cgImage);
    });
}

- (BOOL)stale:(NSUInteger)generation {
    __block BOOL stale;
    dispatch_sync(dispatch_get_main_queue(), ^{ stale = generation != self->_generation; });
    return stale;
}

- (void)runStages:(AUArtwork *)artwork image:(CGImageRef)original folder:(NSString *)folder generation:(NSUInteger)generation
          palette:(BOOL)needPalette upscale:(BOOL)wantUpscale depth:(BOOL)needDepth knownDepth:(UIImage *)knownDepth
            scene:(BOOL)needScene peopleOnly:(BOOL)peopleOnly {
    CFTimeInterval arrived = artwork.arrived;
    NSFileManager *files = NSFileManager.defaultManager;
    BOOL keep = artwork.exact;   // only the exact picture is stored under its key
    if (keep) [files createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:nil];
    CGImageRef cover = AUImageNormalized(original, kWorkSide);
    if (!cover) return;
    CGImageRef source = CGImageRetain(cover);
    do {
    // 1. The palette, from the cover as it came: the theme moves at once.
    if (needPalette) {
        NSString *path = [folder stringByAppendingPathComponent:@"palette.plist"];
        double started = AUNowMs();
        AUPalette *palette = keep ? [AUPalette paletteFromPlist:[NSDictionary dictionaryWithContentsOfFile:path]] : nil;
        BOOL cached = palette != nil;
        if (!palette) palette = [AUPalette paletteForImage:cover clusters:5];
        if (palette) {
            if (!cached) {
                AUStatRecord(@"palette", AUNowMs() - started);
                if (keep) [palette.plist writeToFile:path atomically:YES];
            }
            [self deliver:artwork generation:generation apply:^{ artwork.palette = palette; }];
        }
    }

    // 2. The source: a small cover upscaled, else the cover.
    BOOL upscaled = NO;
    size_t side = MAX(CGImageGetWidth(original), CGImageGetHeight(original));
    BOOL small = side < kUpscaleBelow;
    if (wantUpscale && small) {
        NSString *path = [folder stringByAppendingPathComponent:@"upscaled.jpg"];
        CGImageRef made = keep ? AUImageFromData([NSData dataWithContentsOfFile:path]) : NULL;
        if (!made) {
            if ([self stale:generation]) break;
            double started = AUNowMs();
            NSString *error = nil;
            made = AUUpscaled(cover, kWorkSide, &error);
            if (made) {
                AUStatRecord(@"upscale", AUNowMs() - started);
                AULog(@"upscale %zu px -> %zu px in %.0f ms", side, CGImageGetWidth(made), AUNowMs() - started);
                if (keep) [AUJPEGData(made, 0.92) writeToFile:path atomically:YES];
            } else {
                AULog(@"upscale skipped: %@", error);
            }
        }
        if (made) {
            CGImageRelease(source);
            source = made;
            upscaled = YES;
        }
    }
    {
        UIImage *sourceImage = [UIImage imageWithCGImage:source];
        BOOL wasUpscaled = upscaled, checked = wantUpscale;
        [self deliver:artwork generation:generation apply:^{
            artwork.source = sourceImage;
            artwork.upscaled = wasUpscaled;
            artwork.upscaleChecked = checked;
        }];
    }

    // 3. Depth.
    CGImageRef depth = knownDepth.CGImage ? CGImageRetain(knownDepth.CGImage) : NULL;
    if (needDepth && !depth) {
        NSString *path = [folder stringByAppendingPathComponent:@"depth.png"];
        depth = keep ? AUImageFromData([NSData dataWithContentsOfFile:path]) : NULL;
        if (!depth) {
            if ([self stale:generation]) break;
            double started = AUNowMs();
            NSString *error = nil;
            depth = AUDepthMap(source, &error);
            if (depth) {
                AUStatRecord(@"depth", AUNowMs() - started);
                if (keep) [AUPNGData(depth) writeToFile:path atomically:YES];
            } else {
                AULog(@"depth skipped: %@", error);
            }
        }
        if (depth) {
            UIImage *depthImage = [UIImage imageWithCGImage:depth];
            [self deliver:artwork generation:generation apply:^{ artwork.depth = depthImage; }];
        }
    }

    // 4. The scene: the objects lifted onto layers, the background painted in under them and around the cover.
    if (needScene) {
        NSString *sceneFolder = [folder stringByAppendingPathComponent:peopleOnly ? @"scene-people" : @"scene"];
        BOOL lamaReady = [AUModelManager.shared stateOf:AUModelInpaint] == AUModelReady;
        AUScene *scene = keep ? [AUScene readFrom:sceneFolder] : nil;
        if (scene && !scene.inpainted && lamaReady) scene = nil;   // made while the model was still coming
        if (!scene) {
            if ([self stale:generation]) {
                if (depth) CGImageRelease(depth);
                break;
            }
            double started = AUNowMs();
            NSString *log = nil;
            scene = AUSceneBuild(source, depth, peopleOnly, &log);
            AUStatRecord(@"scene", AUNowMs() - started);
            AULog(@"%@", log ?: @"scene: none");
            if (scene && keep) [scene writeTo:sceneFolder];
        }
        AUScene *made = scene;
        [self deliver:artwork generation:generation apply:^{
            artwork.scene = made;
            artwork.sceneChecked = YES;
            artwork.scenePeopleOnly = peopleOnly;
        }];
    }
    if (depth) CGImageRelease(depth);
    {
        double total = (CACurrentMediaTime() - arrived) * 1000;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation == self->_generation) AUStatRecord(@"ready", total);
        });
    }
    } while (0);
    CGImageRelease(source);
    CGImageRelease(cover);
}

#pragma mark - storage

- (NSString *)cacheRoot {
    NSString *caches = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
    return [[caches stringByAppendingPathComponent:@"Aura"] stringByAppendingPathComponent:@"Artwork"];
}

- (NSString *)folderFor:(AUArtwork *)artwork {
    return [[self cacheRoot] stringByAppendingPathComponent:AUSHA1(artwork.key)];
}

- (void)memoryStore:(AUArtwork *)artwork {
    if (artwork.exact) [_memory setObject:artwork forKey:artwork.key];
}

- (uint64_t)cacheBytes {
    uint64_t total = 0;
    NSDirectoryEnumerator *walk = [NSFileManager.defaultManager enumeratorAtURL:[NSURL fileURLWithPath:[self cacheRoot]]
                                                     includingPropertiesForKeys:@[NSURLFileSizeKey] options:0 errorHandler:nil];
    for (NSURL *url in walk) {
        NSNumber *size = nil;
        [url getResourceValue:&size forKey:NSURLFileSizeKey error:nil];
        total += size.unsignedLongLongValue;
    }
    return total;
}

// The least recently written covers go first until the cache fits.
- (void)pruneTo:(uint64_t)limit {
    NSFileManager *files = NSFileManager.defaultManager;
    NSArray<NSURL *> *folders = [files contentsOfDirectoryAtURL:[NSURL fileURLWithPath:[self cacheRoot]]
                                     includingPropertiesForKeys:@[NSURLContentModificationDateKey] options:0 error:nil];
    NSMutableArray *entries = [NSMutableArray array];
    uint64_t total = 0;
    for (NSURL *folder in folders) {
        uint64_t size = 0;
        for (NSURL *file in [files contentsOfDirectoryAtURL:folder includingPropertiesForKeys:@[NSURLFileSizeKey] options:0 error:nil]) {
            NSNumber *bytes = nil;
            [file getResourceValue:&bytes forKey:NSURLFileSizeKey error:nil];
            size += bytes.unsignedLongLongValue;
        }
        NSDate *date = nil;
        [folder getResourceValue:&date forKey:NSURLContentModificationDateKey error:nil];
        [entries addObject:@[date ?: NSDate.distantPast, @(size), folder]];
        total += size;
    }
    if (total <= limit) return;
    [entries sortUsingComparator:^NSComparisonResult(NSArray *a, NSArray *b) { return [a[0] compare:b[0]]; }];
    NSUInteger removed = 0;
    for (NSArray *entry in entries) {
        if (total <= limit * 0.8) break;
        [files removeItemAtURL:entry[2] error:nil];
        total -= [entry[1] unsignedLongLongValue];
        removed++;
    }
    AULog(@"cache pruned: %lu covers removed, %@ left", (unsigned long)removed, AUBytes(total));
}

- (void)clearCache {
    [_memory removeAllObjects];
    [NSFileManager.defaultManager removeItemAtPath:[self cacheRoot] error:nil];
    AUArtwork *current = _current;
    if (current) {
        _current = [[AUArtwork alloc] initWithKey:current.key exact:current.exact];
        [self settingsChanged];
    }
    AULog(@"cache cleared");
}

@end
