#import "AUCoverEffects.h"
#import "AUParallaxView.h"
#import "Core/AUCore.h"
#import "Features/AUPipeline.h"
#import <CoreMotion/CoreMotion.h>
#import <QuartzCore/QuartzCore.h>

static const CGFloat kCoverMinWidth = 200;
static const CGFloat kStepOut = 1.07;            // the subject's scale over the cover, from its foot
static const CGFloat kMaxTilt = 0.32;            // gravity change (≈ radians) for a full shift
static const CFTimeInterval kSubjectWait = 0.35; // how long a cover with a subject still to come waits for it

@interface AUCoverEffects : NSObject
+ (instancetype)shared;
- (void)tiltLaidOut:(UIView *)tilt;
@property (nonatomic, weak, readonly) UIView *playerRoot;
@end

void AUCoverEffectsStart(void) {
    [AUCoverEffects shared];
}

void AUCoverEffectsTiltLaidOut(UIView *tilt) {
    [[AUCoverEffects shared] tiltLaidOut:tilt];
}

UIView *AUCoverEffectsPlayerRoot(void) {
    return [AUCoverEffects shared].playerRoot;
}

@implementation AUCoverEffects {
    NSHashTable<UIView *> *_tilts;
    __weak UIView *_tilt, *_cover;
    UIView *_plane;                  // over the cover, inside it, clipped to its corners
    AUParallaxView *_parallax;
    UIView *_subjectHost;            // a zero-size view in the tilt view, so nothing takes it for the cover
    UIView *_subject;                // the subject's picture as layer contents: no UIImageView for Taurus to repaint
    AUArtwork *_shown;
    NSString *_shownKey;
    BOOL _shownHasSubject, _shownHasDepth, _wantPlane;
    CADisplayLink *_link;            // only while the phone moves or the covers scroll
    CFTimeInterval _lastMove;
    CMMotionManager *_motion;
    NSOperationQueue *_motionQueue;
    BOOL _motionOn;
    double _refX, _refY;             // the gravity the hand rests at, followed slowly
    BOOL _refSet;
    CGPoint _tiltNow;                // smoothed, -1...1
    BOOL _pickScheduled, _active, _waitScheduled;
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
    return self;
}

#pragma mark - which cover

static BOOL inCoverCell(UIView *tilt) {
    static Class cell;
    if (!cell) cell = NSClassFromString(@"_TtC28NowPlaying_ContentLayersImpl16CoverArtCellImpl");
    for (UIView *v = tilt.superview; v; v = v.superview) {
        if (cell && [v isKindOfClass:cell]) return YES;
    }
    return NO;
}

// The child of the tilt view the size of the tilt view (Taurus's shadow plate is a sibling of its own class).
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

- (void)tiltLaidOut:(UIView *)tilt {
    if (tilt.bounds.size.width < kCoverMinWidth || !inCoverCell(tilt)) return;
    [_tilts addObject:tilt];
    if (tilt == _tilt) [self layoutViews];
    UIScrollView *list = listOf(tilt);
    if ((list.isDragging || list.isDecelerating) && _wantPlane) [self startLink];
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

// The player's own screen: the nearest view over the cover that a view controller owns and fills the window.
- (UIView *)playerRoot {
    for (UIView *v = _tilt; v && v != v.window; v = v.superview) {
        CGSize window = v.window.bounds.size;
        if ([v.nextResponder isKindOfClass:UIViewController.class] && v.bounds.size.width >= window.width - 1
            && v.bounds.size.height >= window.height * 0.8) {
            return v;
        }
    }
    return nil;
}

- (void)pick {
    UIView *tilt = [self showingTilt];
    if (tilt == _tilt && (!tilt || _cover == coverIn(tilt))) {
        [self updateMotion];
        return;
    }
    _tilt = tilt;
    _cover = tilt ? coverIn(tilt) : nil;
    [_plane removeFromSuperview];
    [_subjectHost removeFromSuperview];
    if (_tilt && _cover) {
        [self ensureViews];
        [_cover addSubview:_plane];
        [_tilt addSubview:_subjectHost];
        _tilt.clipsToBounds = NO;
        [self layoutViews];
        _shownKey = nil;
        [self apply:[AUPipeline shared].current animated:NO];
    }
    [self updateMotion];
}

#pragma mark - views

- (void)ensureViews {
    if (_plane) return;
    _plane = [UIView new];
    _plane.userInteractionEnabled = NO;
    _plane.clipsToBounds = YES;
    _plane.alpha = 0;
    if ([AUParallaxView supported]) {
        _parallax = [[AUParallaxView alloc] initWithFrame:CGRectZero];
        _parallax.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [_plane addSubview:_parallax];
    }
    _subjectHost = [[UIView alloc] initWithFrame:CGRectZero];
    _subjectHost.userInteractionEnabled = NO;
    _subjectHost.clipsToBounds = NO;
    _subject = [UIView new];
    _subject.userInteractionEnabled = NO;
    _subject.alpha = 0;
    CALayer *layer = _subject.layer;
    layer.contentsGravity = kCAGravityResize;
    layer.shadowColor = UIColor.blackColor.CGColor;
    layer.shadowOpacity = 0.45;
    layer.shadowRadius = 14;
    layer.shadowOffset = CGSizeMake(0, 8);
    // A shadow of the picture's own shape costs an offscreen pass a frame; rasterized it is drawn once and moved.
    layer.shouldRasterize = YES;
    layer.rasterizationScale = UIScreen.mainScreen.scale;
    [_subjectHost addSubview:_subject];
}

- (void)layoutViews {
    UIView *cover = _cover;
    if (!cover || !_plane) return;
    if (_plane.superview != cover) [cover addSubview:_plane];
    if (cover.subviews.lastObject != _plane) [cover bringSubviewToFront:_plane];
    _plane.frame = cover.bounds;
    _plane.layer.cornerRadius = MAX(cover.layer.cornerRadius, [self imageCornerRadius]);
    _plane.layer.cornerCurve = kCACornerCurveContinuous;
    _parallax.frame = _plane.bounds;
    if (_subjectHost.superview == _tilt && _tilt.subviews.lastObject != _subjectHost) [_tilt bringSubviewToFront:_subjectHost];
    _subjectHost.frame = CGRectZero;
    [self placeSubject];
}

// Taurus rounds the image inside the cover (the Encore image view clips), not always the cover itself.
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

// The subject stands at the cover's foot, a little bigger than the cover and nearer than anything on it: it moves
// most with the tilt, takes the cover's paused shrink, and fades with it (Taurus hides the cover under a clip).
- (void)placeSubject {
    UIView *cover = _cover;
    if (!cover || !_subjectHost.superview) return;
    CGSize size = cover.bounds.size;
    CGFloat shift = 0.03 * 0.6 * AUNumber(AUKeyDepthStrength, 1.0);
    CGPoint offset = CGPointMake(_tiltNow.x * shift * size.width, _tiltNow.y * shift * size.height);
    _subject.bounds = (CGRect){CGPointZero, size};
    _subject.center = cover.center;   // the host sits at the tilt view's origin: the same coordinates
    CGAffineTransform own = CGAffineTransformConcat(CGAffineTransformMakeScale(kStepOut, kStepOut),
                                                    CGAffineTransformMakeTranslation(offset.x, offset.y + size.height / 2 * (1 - kStepOut)));
    _subject.transform = CGAffineTransformConcat(own, cover.transform);
    _subject.layer.opacity = (float)cover.alpha;
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

- (void)apply:(AUArtwork *)artwork animated:(BOOL)animated {
    if (!_plane) return;
    if (artwork != [AUPipeline shared].current) return;
    BOOL depth = [self wantsDepth] && artwork.depth;
    BOOL subject = [self wantsSubject] && artwork.cutout && artwork.background;
    BOOL upscaled = artwork.upscaled && AUEnabled(AUKeyUpscale);
    BOOL wantPlane = (depth || subject || upscaled) && artwork.source && _parallax;
    BOOL sameCover = [artwork.key isEqualToString:_shownKey];
    if (!sameCover) {
        // A new track: what showed goes at once; Spotify's own cover underneath shows until the new effects land.
        [_plane.layer removeAllAnimations];
        _plane.alpha = 0;
        _subject.alpha = 0;
        _shownHasDepth = _shownHasSubject = NO;
        _shown = nil;
    }
    // A subject still being looked for is waited for a moment, so the cover does not jump from sharp to blurred.
    BOOL subjectPending = [self wantsSubject] && !artwork.cutout && !artwork.noSubject;
    CFTimeInterval waited = CACurrentMediaTime() - artwork.arrived;
    if (wantPlane && subjectPending && waited < kSubjectWait && !_shownHasDepth) {
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
    BOOL changed = artwork != _shown || depth != _shownHasDepth || subject != _shownHasSubject;
    if (wantPlane && changed) {
        [_parallax setColor:subject ? artwork.background : artwork.source depth:depth ? artwork.depth : nil];
        _subject.layer.contents = subject ? (__bridge id)artwork.cutout.CGImage : nil;
        _shownHasDepth = depth;
        _shownHasSubject = subject;
        CGFloat strength = AUNumber(AUKeyDepthStrength, 1.0);
        _parallax.strength = 0.03 * strength;
        _parallax.zoom = depth ? 1.04 + 0.02 * strength : 1.0;
        _parallax.tilt = _tiltNow;
        [_parallax render];
        if (_plane.alpha < 1) {
            double latency = waited * 1000;
            static NSUInteger logged;
            if (logged++ < 40) {
                AULog(@"cover %@ shown %.0f ms after it came: depth %d, subject %d, upscaled %d",
                      [artwork.key substringFromIndex:artwork.key.length > 12 ? artwork.key.length - 12 : 0], latency, depth, subject, upscaled);
            }
            AUStatRecord(@"shown", latency);
        }
    }
    _shown = artwork;
    _shownKey = artwork.key;
    _wantPlane = wantPlane;
    void (^show)(void) = ^{
        self->_plane.alpha = wantPlane ? 1 : 0;
        self->_subject.alpha = wantPlane && subject ? 1 : 0;
    };
    if (animated) [UIView animateWithDuration:0.22 delay:0 options:UIViewAnimationOptionBeginFromCurrentState animations:show completion:nil];
    else show();
    [self updateMotion];
}

- (void)memoryWarning {
    if (!showing(_tilt)) {
        [_parallax setColor:nil depth:nil];
        _subject.layer.contents = nil;
        _shown = nil;
        _shownKey = nil;
        _wantPlane = NO;
        _plane.alpha = 0;
    }
}

#pragma mark - motion and frames

- (BOOL)needsMotion {
    return _active && _tilt && showing(_tilt) && _wantPlane && (_shownHasDepth || _shownHasSubject) && !AUThrottled();
}

// While the cover can move, Core Motion runs on its own queue at 20 Hz to notice the phone moving; only then a
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
            BOOL moved = !first && hypot(gx - lastX, gy - lastY) > 0.006;
            first = NO;
            lastX = gx;
            lastY = gy;
            if (moved) dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf startLink]; });
        }];
        [self startLink];
    } else if (!run && _motionOn) {
        _motionOn = NO;
        [_motion stopDeviceMotionUpdates];
        [self stopLink];
    }
}

- (void)startLink {
    _lastMove = CACurrentMediaTime();
    if (_link) return;
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
    if (!_cover || !showing(_tilt)) {
        [self stopLink];
        [self updateMotion];
        return;
    }
    CFTimeInterval now = CACurrentMediaTime();
    // A cover being swiped to the next track: the effects step aside until it settles.
    UIScrollView *list = listOf(_tilt);
    BOOL scrolling = list.isDragging || list.isDecelerating;
    if (scrolling) _lastMove = now;
    CGFloat planeAlpha = scrolling || !_wantPlane ? 0 : 1;
    if (_plane.alpha != planeAlpha) {
        [UIView animateWithDuration:0.15 delay:0 options:UIViewAnimationOptionBeginFromCurrentState animations:^{
            self->_plane.alpha = planeAlpha;
            self->_subject.alpha = self->_shownHasSubject ? planeAlpha : 0;
        } completion:nil];
    }
    CMDeviceMotion *motion = _motion.deviceMotion;
    if (motion && (_shownHasDepth || _shownHasSubject)) {
        double gx = motion.gravity.x, gy = motion.gravity.y;
        if (!_refSet) {
            _refX = gx;
            _refY = gy;
            _refSet = YES;
        }
        // The rest position follows the hand over a couple of seconds: any way the phone is held is the middle.
        double dt = MIN(0.1, MAX(1.0 / 120, link.targetTimestamp - link.timestamp));
        double follow = 1 - exp(-dt / 2.0);
        _refX += (gx - _refX) * follow;
        _refY += (gy - _refY) * follow;
        CGFloat tx = (CGFloat)MAX(-1.0, MIN(1.0, (gx - _refX) / kMaxTilt));
        CGFloat ty = (CGFloat)MAX(-1.0, MIN(1.0, -(gy - _refY) / kMaxTilt));
        double smooth = 1 - exp(-dt / 0.06);
        CGPoint next = CGPointMake(_tiltNow.x + (tx - _tiltNow.x) * smooth, _tiltNow.y + (ty - _tiltNow.y) * smooth);
        CGFloat moved = hypot(next.x - _tiltNow.x, next.y - _tiltNow.y);
        if (moved > 0.0015) _lastMove = now;
        if (moved > 0.0004) {
            _tiltNow = next;
            [CATransaction begin];
            [CATransaction setDisableActions:YES];
            [self placeSubject];
            [CATransaction commit];
            if (_shownHasDepth) {
                _parallax.tilt = _tiltNow;
                [_parallax render];
            }
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
