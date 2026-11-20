#import "AUCoverEffects.h"
#import "AUParallaxRenderer.h"
#import "Core/AUCore.h"
#import "Features/AUPipeline.h"
#import <CoreMotion/CoreMotion.h>
#import <QuartzCore/QuartzCore.h>
#import <dlfcn.h>
#import <objc/runtime.h>

static const CGFloat kCoverMinWidth = 200;
static const CGFloat kStepOut = 1.07;            // the subject's scale over the cover, from its foot
static const CGFloat kMaxTilt = 0.22;            // gravity change (≈ radians) for a full shift
static const CFTimeInterval kSubjectWait = 0.35; // how long a cover with a subject still to come waits for it

typedef NS_ENUM(NSInteger, AUSurfaceKind) {
    AUSurfaceCover,
    AUSurfaceFill,
};

// One place the effects are drawn: its renderer's layer and the subject's layer.
@interface AUSurface : NSObject
@property (nonatomic) AUSurfaceKind kind;
@property (nonatomic, strong) AUParallaxRenderer *renderer;
@property (nonatomic, strong) CALayer *subject;
@property (nonatomic, strong) CAGradientLayer *subjectMask;   // Fill only
@property (nonatomic, weak) id contentArtwork;                  // the artwork its textures hold
@property (nonatomic) BOOL contentDepth, contentSubject;
@property (nonatomic) BOOL attached;
@end

@implementation AUSurface
@end

@interface AUCoverEffects : NSObject
+ (instancetype)shared;
- (void)tiltLaidOut:(UIView *)tilt;
- (void)fieldLaidOut:(UIView *)field;
@property (nonatomic, weak, readonly) UIView *playerRoot;
@end

void AUCoverEffectsStart(void) {
    [AUCoverEffects shared];
}

void AUCoverEffectsTiltLaidOut(UIView *tilt) {
    [[AUCoverEffects shared] tiltLaidOut:tilt];
}

void AUCoverEffectsFieldLaidOut(UIView *field) {
    [[AUCoverEffects shared] fieldLaidOut:field];
}

UIView *AUCoverEffectsPlayerRoot(void) {
    return [AUCoverEffects shared].playerRoot;
}

static NSDictionary *noActions(void) {
    static NSDictionary *none;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        id off = NSNull.null;
        none = @{@"bounds": off, @"position": off, @"frame": off, @"contents": off, @"opacity": off, @"transform": off,
                 @"hidden": off, @"sublayerTransform": off, @"mask": off};
    });
    return none;
}

static CALayer *ivarLayer(id object, const char *name) {
    Ivar ivar = class_getInstanceVariable(object_getClass(object), name);
    id value = ivar ? object_getIvar(object, ivar) : nil;
    return [value isKindOfClass:CALayer.class] ? value : nil;
}

@implementation AUCoverEffects {
    NSHashTable<UIView *> *_tilts;
    __weak UIView *_tilt, *_cover, *_field;
    __weak CALayer *_fillLayer;
    UIView *_plane;                  // over the cover, inside it, clipped to its corners
    UIView *_subjectHost;            // a zero-size view in the tilt view, so nothing takes it for the cover
    AUSurface *_coverSurface, *_fillSurface;
    __weak AUArtwork *_shown;
    NSString *_shownKey;
    BOOL _shownDepth, _shownSubject, _wantPlane;
    CADisplayLink *_link;            // only while the phone moves or the covers scroll
    CFTimeInterval _lastMove;
    CMMotionManager *_motion;
    NSOperationQueue *_motionQueue;
    BOOL _motionOn;
    double _refX, _refY;
    BOOL _refSet;
    CGPoint _tiltNow;                // smoothed, -1...1
    BOOL _pickScheduled, _active, _waitScheduled;
    NSUInteger _frames;
}

+ (instancetype)shared {
    static AUCoverEffects *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [AUCoverEffects new]; });
    return shared;
}

- (instancetype)init {
    if (!(self = [super init])) return nil;
    _tilts = [NSHashTable weakObjectsHashTable];
    _motion = [CMMotionManager new];
    _motionQueue = [NSOperationQueue new];
    _motionQueue.maxConcurrentOperationCount = 1;
    _motionQueue.qualityOfService = NSQualityOfServiceUserInteractive;
    _active = UIApplication.sharedApplication.applicationState == UIApplicationStateActive;
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    [center addObserver:self selector:@selector(artworkChanged:) name:AUArtworkDidChangeNotification object:nil];
    [center addObserver:self selector:@selector(refresh) name:AUSettingsDidChangeNotification object:nil];
    [center addObserver:self selector:@selector(refresh) name:AUThrottleDidChangeNotification object:nil];
    [center addObserver:self selector:@selector(becameActive) name:UIApplicationDidBecomeActiveNotification object:nil];
    [center addObserver:self selector:@selector(resignedActive) name:UIApplicationWillResignActiveNotification object:nil];
    [center addObserver:self selector:@selector(memoryWarning) name:UIApplicationDidReceiveMemoryWarningNotification object:nil];
    if (![AUParallaxRenderer supported]) AULog(@"cover effects: no Metal device");
    return self;
}

#pragma mark - where the artwork is

static BOOL inCoverCell(UIView *tilt) {
    static Class cell;
    if (!cell) cell = NSClassFromString(@"_TtC28NowPlaying_ContentLayersImpl16CoverArtCellImpl");
    for (UIView *v = tilt.superview; v; v = v.superview) {
        if (cell && [v isKindOfClass:cell]) return YES;
    }
    return NO;
}

static UIView *coverIn(UIView *tilt) {
    for (UIView *sub in tilt.subviews) {
        NSString *name = NSStringFromClass(sub.class);
        if ([name hasPrefix:@"SGR"] || [name hasPrefix:@"AU"]) continue;
        if (CGSizeEqualToSize(sub.bounds.size, tilt.bounds.size)) return sub;
    }
    return nil;
}

static BOOL showing(UIView *view) {
    if (!view.window) return NO;
    for (UIView *v = view; v; v = v.superview) {
        if (v.hidden || v.alpha < 0.01) return NO;
    }
    return YES;
}

static UIScrollView *listOf(UIView *tilt) {
    for (UIView *v = tilt.superview; v; v = v.superview) {
        if ([v isKindOfClass:UIScrollView.class]) return (UIScrollView *)v;
    }
    return nil;
}

static UIView *taurusField(void) {
    UIView *(*field)(void) = (UIView * (*)(void)) dlsym(RTLD_DEFAULT, "SGRPlayerField");
    return field ? field() : nil;
}

// Taurus's Fill background, when it is the one showing: the field's `_fill` layer, not hidden.
- (CALayer *)fillLayerShowing {
    UIView *field = _field ?: taurusField();
    if (!field || !showing(field)) return nil;
    CALayer *fill = ivarLayer(field, "_fill");
    if (!fill || fill.hidden || fill.bounds.size.width < 1) return nil;
    _field = field;
    return fill;
}

- (void)tiltLaidOut:(UIView *)tilt {
    if (tilt.bounds.size.width < kCoverMinWidth || !inCoverCell(tilt)) return;
    [_tilts addObject:tilt];
    if (tilt == _tilt) [self layoutCover];
    UIScrollView *list = listOf(tilt);
    if ((list.isDragging || list.isDecelerating) && _wantPlane) [self startLink];
    [self schedulePick];
}

- (void)fieldLaidOut:(UIView *)field {
    _field = field;
    [self layoutFill];
    [self schedulePick];
}

- (void)schedulePick {
    if (_pickScheduled) return;
    _pickScheduled = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        self->_pickScheduled = NO;
        [self pick];
    });
}

- (UIView *)showingTilt {
    UIView *best = nil;
    CGFloat bestDistance = CGFLOAT_MAX;
    for (UIView *tilt in _tilts) {
        if (!showing(tilt)) continue;
        CGPoint center = [tilt convertPoint:CGPointMake(CGRectGetMidX(tilt.bounds), CGRectGetMidY(tilt.bounds)) toView:nil];
        CGFloat distance = fabs(center.x - CGRectGetMidX(tilt.window.bounds));
        if (distance < bestDistance) {
            bestDistance = distance;
            best = tilt;
        }
    }
    return best;
}

- (UIView *)playerRoot {
    UIView *start = _tilt ?: _field;
    for (UIView *v = start; v && v != v.window; v = v.superview) {
        CGSize window = v.window.bounds.size;
        if ([v.nextResponder isKindOfClass:UIViewController.class] && v.bounds.size.width >= window.width - 1
            && v.bounds.size.height >= window.height * 0.8) {
            return v;
        }
    }
    return nil;
}

- (AUSurface *)makeSurface:(AUSurfaceKind)kind {
    AUSurface *surface = [AUSurface new];
    surface.kind = kind;
    surface.renderer = [AUParallaxRenderer new];
    surface.renderer.layer.actions = noActions();
    CALayer *subject = [CALayer layer];
    subject.actions = noActions();
    subject.contentsGravity = kind == AUSurfaceFill ? kCAGravityResizeAspectFill : kCAGravityResize;
    subject.opacity = 0;
    if (kind == AUSurfaceCover) {
        subject.shadowColor = UIColor.blackColor.CGColor;
        subject.shadowOpacity = 0.45;
        subject.shadowRadius = 14;
        subject.shadowOffset = CGSizeMake(0, 8);
        // A shadow of the picture's own shape costs an offscreen pass a frame; rasterized it is drawn once and moved.
        subject.shouldRasterize = YES;
        subject.rasterizationScale = UIScreen.mainScreen.scale;
    } else {
        subject.masksToBounds = YES;
        // The subject fades later than Taurus's fill (0.76...0.985 of its height): it stays where the cover has melted.
        CAGradientLayer *mask = [CAGradientLayer layer];
        mask.actions = noActions();
        mask.colors = @[(id)UIColor.whiteColor.CGColor, (id)UIColor.whiteColor.CGColor, (id)[UIColor colorWithWhite:1 alpha:0].CGColor];
        mask.locations = @[@0, @0.86, @1];
        subject.mask = mask;
        surface.subjectMask = mask;
    }
    surface.subject = subject;
    return surface;
}

- (void)pick {
    if (![AUParallaxRenderer supported]) return;
    // Fill first: in Fill Taurus has no square cover on screen.
    CALayer *fill = [self fillLayerShowing];
    if (fill != _fillLayer || (fill && !_fillSurface.attached)) {
        [self detachFill];
        _fillLayer = fill;
        if (fill) [self attachFill];
    }
    UIView *tilt = fill ? nil : [self showingTilt];
    UIView *cover = tilt ? coverIn(tilt) : nil;
    if (tilt != _tilt || cover != _cover) {
        [self detachCover];
        _tilt = tilt;
        _cover = cover;
        if (tilt && cover) [self attachCover];
    }
    [self updateMotion];
}

#pragma mark - the cover

- (void)attachCover {
    if (!_coverSurface) _coverSurface = [self makeSurface:AUSurfaceCover];
    if (!_plane) {
        _plane = [UIView new];
        _plane.userInteractionEnabled = NO;
        _plane.clipsToBounds = YES;
        _plane.alpha = 0;
        _subjectHost = [[UIView alloc] initWithFrame:CGRectZero];
        _subjectHost.userInteractionEnabled = NO;
    }
    [_plane.layer addSublayer:_coverSurface.renderer.layer];
    [_subjectHost.layer addSublayer:_coverSurface.subject];
    [_cover addSubview:_plane];
    [_tilt addSubview:_subjectHost];
    _tilt.clipsToBounds = NO;
    _coverSurface.attached = YES;
    _coverSurface.contentArtwork = nil;
    [self layoutCover];
    AULog(@"effects on the cover (%.0f pt)", _cover.bounds.size.width);
    _shownKey = nil;
    [self apply:[AUPipeline shared].current animated:NO];
}

- (void)detachCover {
    [_plane removeFromSuperview];
    [_subjectHost removeFromSuperview];
    _coverSurface.attached = NO;
}

- (void)layoutCover {
    UIView *cover = _cover;
    if (!cover || !_plane || !_coverSurface.attached) return;
    if (cover.subviews.lastObject != _plane) [cover bringSubviewToFront:_plane];
    _plane.frame = cover.bounds;
    _plane.layer.cornerRadius = MAX(cover.layer.cornerRadius, [self imageCornerRadius]);
    _plane.layer.cornerCurve = kCACornerCurveContinuous;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _coverSurface.renderer.layer.frame = _plane.bounds;
    [_coverSurface.renderer layoutForScale:UIScreen.mainScreen.scale];
    [CATransaction commit];
    if (_subjectHost.superview == _tilt && _tilt.subviews.lastObject != _subjectHost) [_tilt bringSubviewToFront:_subjectHost];
    _subjectHost.frame = CGRectZero;
    [self placeSubjects];
}

- (CGFloat)imageCornerRadius {
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:_cover];
    for (NSUInteger seen = 0; queue.count && seen < 40; seen++) {
        UIView *v = queue.firstObject;
        [queue removeObjectAtIndex:0];
        if (v != _cover && v.layer.cornerRadius > 0 && v.bounds.size.width > _cover.bounds.size.width * 0.8) return v.layer.cornerRadius;
        for (UIView *sub in v.subviews) {
            if (sub != _plane) [queue addObject:sub];
        }
    }
    return 0;
}

#pragma mark - Fill

- (void)attachFill {
    if (!_fillSurface) _fillSurface = [self makeSurface:AUSurfaceFill];
    CALayer *fill = _fillLayer;
    UIView *field = _field;
    if (!fill || !field) return;
    // Lowest in `_fill`: under its blurred bands, inside its fading mask.
    [fill insertSublayer:_fillSurface.renderer.layer atIndex:0];
    if (fill.superlayer) [fill.superlayer insertSublayer:_fillSurface.subject above:fill];
    _fillSurface.renderer.layer.opacity = 0;
    _fillSurface.attached = YES;
    _fillSurface.contentArtwork = nil;
    [self layoutFill];
    AULog(@"effects on Taurus's Fill background (%.0f x %.0f pt)", fill.bounds.size.width, fill.bounds.size.height);
    _shownKey = nil;
    [self apply:[AUPipeline shared].current animated:NO];
}

- (void)detachFill {
    [_fillSurface.renderer.layer removeFromSuperlayer];
    [_fillSurface.subject removeFromSuperlayer];
    _fillSurface.attached = NO;
}

- (void)layoutFill {
    CALayer *fill = _fillLayer;
    if (!fill || !_fillSurface.attached) return;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _fillSurface.renderer.layer.frame = fill.bounds;
    // The whole screen at 3x would be two million pixels a frame; at 2x it is under one and still sharp under the fade.
    [_fillSurface.renderer layoutForScale:2];
    _fillSurface.subjectMask.frame = (CGRect){CGPointZero, fill.bounds.size};
    [CATransaction commit];
    [self placeSubjects];
}

#pragma mark - the subject's place

- (void)placeSubjects {
    CGFloat strength = AUNumber(AUKeyDepthStrength, 1.0);
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    UIView *cover = _cover;
    if (cover && _coverSurface.attached) {
        // At the cover's foot, a little bigger than the cover and nearer than anything on it: it moves most with
        // the tilt, takes the cover's paused shrink and fades with it.
        CGSize size = cover.bounds.size;
        CGFloat shift = 0.045 * 0.55 * strength;
        CGPoint offset = CGPointMake(_tiltNow.x * shift * size.width, _tiltNow.y * shift * size.height);
        CALayer *subject = _coverSurface.subject;
        subject.bounds = (CGRect){CGPointZero, size};
        subject.position = cover.center;
        CGAffineTransform own = CGAffineTransformConcat(CGAffineTransformMakeScale(kStepOut, kStepOut),
                                                        CGAffineTransformMakeTranslation(offset.x, offset.y + size.height / 2 * (1 - kStepOut)));
        subject.affineTransform = CGAffineTransformConcat(own, cover.transform);
        subject.opacity = (_shownSubject && _plane.alpha > 0.01) ? (float)(cover.alpha * _plane.alpha) : 0;
    }
    CALayer *fill = _fillLayer;
    if (fill && _fillSurface.attached) {
        CALayer *subject = _fillSurface.subject;
        CGSize size = fill.bounds.size;
        CGFloat shift = 0.045 * 0.55 * strength * MAX(size.width, size.height);
        subject.frame = fill.frame;
        subject.affineTransform = CGAffineTransformMakeTranslation(_tiltNow.x * shift, _tiltNow.y * shift);
        subject.opacity = (_shownSubject && _fillSurface.renderer.layer.opacity > 0.01) ? fill.opacity : 0;
    }
    [CATransaction commit];
}

#pragma mark - what is shown

- (BOOL)wantsDepth { return AUEnabled(AUKeyDepth) && !AUThrottled(); }
- (BOOL)wantsSubject { return AUEnabled(AUKeyCutout) && !AUThrottled(); }

- (void)artworkChanged:(NSNotification *)note {
    [self apply:note.object animated:YES];
}

- (void)refresh {
    _shownKey = nil;
    [self apply:[AUPipeline shared].current animated:YES];
}

- (NSArray<AUSurface *> *)attachedSurfaces {
    NSMutableArray *surfaces = [NSMutableArray array];
    if (_coverSurface.attached) [surfaces addObject:_coverSurface];
    if (_fillSurface.attached) [surfaces addObject:_fillSurface];
    return surfaces;
}

- (void)setShown:(BOOL)shown animated:(BOOL)animated {
    if (_plane) {
        void (^fade)(void) = ^{ self->_plane.alpha = shown ? 1 : 0; };
        if (animated) [UIView animateWithDuration:0.22 delay:0 options:UIViewAnimationOptionBeginFromCurrentState animations:fade completion:nil];
        else fade();
    }
    if (_fillSurface.attached) {
        CALayer *layer = _fillSurface.renderer.layer;
        float target = shown ? 1 : 0;
        if (animated && layer.opacity != target) {
            CABasicAnimation *fade = [CABasicAnimation animationWithKeyPath:@"opacity"];
            fade.fromValue = @(layer.presentationLayer.opacity);
            fade.toValue = @(target);
            fade.duration = 0.22;
            [layer addAnimation:fade forKey:@"aura.fade"];
            CABasicAnimation *subjectFade = [fade copy];
            [_fillSurface.subject addAnimation:subjectFade forKey:@"aura.fade"];
        }
        layer.opacity = target;
    }
    [self placeSubjects];
}

- (void)apply:(AUArtwork *)artwork animated:(BOOL)animated {
    NSArray<AUSurface *> *surfaces = [self attachedSurfaces];
    if (!surfaces.count) return;
    if (artwork != [AUPipeline shared].current) return;
    BOOL depth = [self wantsDepth] && artwork.depth;
    BOOL subject = [self wantsSubject] && artwork.cutout && artwork.background;
    BOOL upscaled = artwork.upscaled && AUEnabled(AUKeyUpscale);
    BOOL wantPlane = (depth || subject || upscaled) && artwork.source;
    BOOL sameCover = [artwork.key isEqualToString:_shownKey];
    if (!sameCover) {
        // A new track: what showed goes at once; Spotify's own cover underneath shows until the new effects land.
        _shownDepth = _shownSubject = NO;
        _wantPlane = NO;
        [self setShown:NO animated:NO];
    }
    // A subject still being looked for is waited for a moment, so the picture does not jump from sharp to blurred.
    BOOL subjectPending = [self wantsSubject] && !artwork.cutout && !artwork.noSubject;
    CFTimeInterval waited = CACurrentMediaTime() - artwork.arrived;
    if (wantPlane && subjectPending && waited < kSubjectWait && !_shownDepth) {
        if (!_waitScheduled) {
            _waitScheduled = YES;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((kSubjectWait - waited) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                self->_waitScheduled = NO;
                [self apply:[AUPipeline shared].current animated:YES];
            });
        }
        _shownKey = artwork.key;
        return;
    }
    CGFloat strength = AUNumber(AUKeyDepthStrength, 1.0);
    for (AUSurface *surface in surfaces) {
        if (!wantPlane) continue;
        if (surface.contentArtwork != artwork || surface.contentDepth != depth || surface.contentSubject != subject) {
            UIImage *color = subject ? artwork.background : artwork.source;
            UIImage *depthMap = subject ? (artwork.softDepth ?: artwork.depth) : artwork.depth;
            [surface.renderer setColor:color.CGImage depth:depth ? depthMap.CGImage : NULL];
            surface.subject.contents = subject ? (__bridge id)artwork.cutout.CGImage : nil;
            surface.contentArtwork = artwork;
            surface.contentDepth = depth;
            surface.contentSubject = subject;
        }
        surface.renderer.strength = depth ? 0.045 * strength : 0;
        surface.renderer.zoom = depth ? 1.03 + 0.03 * strength : 1.0;
        surface.renderer.tilt = _tiltNow;
        [surface.renderer render];
    }
    if (wantPlane && (!_wantPlane || depth != _shownDepth || subject != _shownSubject)) {
        double latency = waited * 1000;
        static NSUInteger logged;
        if (logged++ < 60) {
            AULog(@"artwork …%@ shown %.0f ms after it came: depth %d, subject %d, upscaled %d, on %@",
                  [artwork.key substringFromIndex:artwork.key.length > 10 ? artwork.key.length - 10 : 0], latency, depth, subject,
                  upscaled, _fillSurface.attached ? @"Fill" : @"the cover");
        }
        if (!_wantPlane) AUStatRecord(@"shown", latency);
    }
    if (!wantPlane && artwork.source) {
        static NSUInteger quiet;
        if (quiet++ < 20) AULog(@"artwork shown plain: depth %@, subject %@", artwork.depth ? @"ready" : @"none yet",
                                artwork.cutout ? @"ready" : (artwork.noSubject ? @"none on it" : @"none yet"));
    }
    _shown = artwork;
    _shownKey = artwork.key;
    _shownDepth = depth;
    _shownSubject = subject;
    _wantPlane = wantPlane;
    [self setShown:wantPlane animated:animated];
    [self updateMotion];
}

- (void)memoryWarning {
    if (_link) return;
    for (AUSurface *surface in @[_coverSurface ?: (id)NSNull.null, _fillSurface ?: (id)NSNull.null]) {
        if (![surface isKindOfClass:AUSurface.class] || surface.attached) continue;
        [surface.renderer setColor:NULL depth:NULL];
        surface.subject.contents = nil;
        surface.contentArtwork = nil;
    }
}

#pragma mark - motion and frames

- (BOOL)visible {
    return (_coverSurface.attached && showing(_tilt)) || (_fillSurface.attached && [self fillLayerShowing] == _fillLayer);
}

- (BOOL)needsMotion {
    return _active && _wantPlane && (_shownDepth || _shownSubject) && !AUThrottled() && [self visible];
}

// While the artwork can move, Core Motion runs on its own queue at 20 Hz to notice the phone moving; only then a
// display link runs, at up to 120 Hz, until the phone has been still for 0.8 s. A link capped low would drag
// Spotify's own 120 Hz animations down with it, so there is none at rest.
- (void)updateMotion {
    BOOL run = [self needsMotion];
    if (run && !_motionOn && _motion.deviceMotionAvailable) {
        _motionOn = YES;
        _refSet = NO;
        _motion.deviceMotionUpdateInterval = 1.0 / 20;
        __weak AUCoverEffects *weakSelf = self;
        __block double lastX = 0, lastY = 0;
        __block BOOL first = YES;
        [_motion startDeviceMotionUpdatesToQueue:_motionQueue withHandler:^(CMDeviceMotion *motion, NSError *error) {
            if (!motion) return;
            double gx = motion.gravity.x, gy = motion.gravity.y;
            BOOL moved = !first && hypot(gx - lastX, gy - lastY) > 0.004;
            first = NO;
            lastX = gx;
            lastY = gy;
            if (moved) dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf startLink]; });
        }];
        AULog(@"motion on (%@)", _fillSurface.attached ? @"Fill" : @"cover");
        [self startLink];
    } else if (!run && _motionOn) {
        _motionOn = NO;
        [_motion stopDeviceMotionUpdates];
        [self stopLink];
    }
}

- (void)startLink {
    _lastMove = CACurrentMediaTime();
    if (_link || !_motionOn) return;
    _motion.deviceMotionUpdateInterval = 1.0 / 100;
    _link = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick:)];
    if (@available(iOS 15.0, *)) _link.preferredFrameRateRange = CAFrameRateRangeMake(80, 120, 120);
    else _link.preferredFramesPerSecond = 120;
    [_link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
}

- (void)stopLink {
    [_link invalidate];
    _link = nil;
    if (_motionOn) _motion.deviceMotionUpdateInterval = 1.0 / 20;
}

- (void)tick:(CADisplayLink *)link {
    if (![self visible]) {
        [self stopLink];
        [self schedulePick];
        return;
    }
    CFTimeInterval now = CACurrentMediaTime();
    // A cover being swiped to the next track: the effects step aside until it settles.
    if (_coverSurface.attached) {
        UIScrollView *list = listOf(_tilt);
        BOOL scrolling = list.isDragging || list.isDecelerating;
        if (scrolling) _lastMove = now;
        CGFloat alpha = scrolling || !_wantPlane ? 0 : 1;
        if (_plane.alpha != alpha) {
            [UIView animateWithDuration:0.15 delay:0 options:UIViewAnimationOptionBeginFromCurrentState
                             animations:^{ self->_plane.alpha = alpha; } completion:nil];
        }
    }
    CMDeviceMotion *motion = _motion.deviceMotion;
    if (motion) {
        double gx = motion.gravity.x, gy = motion.gravity.y;
        if (!_refSet) {
            _refX = gx;
            _refY = gy;
            _refSet = YES;
        }
        // The rest position follows the hand over a few seconds: any way the phone is held is the middle.
        double dt = MIN(0.1, MAX(1.0 / 120, link.targetTimestamp - link.timestamp));
        double follow = 1 - exp(-dt / 3.0);
        _refX += (gx - _refX) * follow;
        _refY += (gy - _refY) * follow;
        CGFloat tx = (CGFloat)MAX(-1.0, MIN(1.0, (gx - _refX) / kMaxTilt));
        CGFloat ty = (CGFloat)MAX(-1.0, MIN(1.0, -(gy - _refY) / kMaxTilt));
        double smooth = 1 - exp(-dt / 0.05);
        CGPoint next = CGPointMake(_tiltNow.x + (tx - _tiltNow.x) * smooth, _tiltNow.y + (ty - _tiltNow.y) * smooth);
        CGFloat moved = hypot(next.x - _tiltNow.x, next.y - _tiltNow.y);
        if (moved > 0.0015) _lastMove = now;
        if (moved > 0.0003) {
            _tiltNow = next;
            [self placeSubjects];
            if (_shownDepth) {
                for (AUSurface *surface in [self attachedSurfaces]) {
                    surface.renderer.tilt = _tiltNow;
                    [surface.renderer render];
                }
            }
            if (++_frames % 600 == 1) AULog(@"parallax running: tilt %.2f %.2f", _tiltNow.x, _tiltNow.y);
        }
    }
    if (now - _lastMove > 0.8) [self stopLink];
}

- (void)becameActive {
    _active = YES;
    [self updateMotion];
}

- (void)resignedActive {
    _active = NO;
    [self updateMotion];
}

@end
