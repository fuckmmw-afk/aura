#import "AUCoverEffects.h"
#import "Core/AUCore.h"
#import "Core/AUTaurus.h"
#import "Core/AUYandex.h"
#import "UI/AUYandexFill.h"
#import "Features/AUPipeline.h"
#import "Core/AUTune.h"
#import "Features/AUScene3D.h"
#import "UI/AUSceneRenderer.h"
#import <Accelerate/Accelerate.h>
#import <CoreMotion/CoreMotion.h>
#import <QuartzCore/QuartzCore.h>
#import <dlfcn.h>
#import <objc/runtime.h>

static const CGFloat kCoverMinWidth = 200;
static const CGFloat kStepOut = 1.06;
static const CGFloat kSingleReach = 0.6;          // one layer: how far the picture slides at a full tilt (× strength × side)            // the objects' scale over the cover, from its foot (the cover only)

typedef NS_ENUM(NSInteger, AUSurfaceKind) {
    AUSurfaceCover,
    AUSurfaceFill,
};

// One place the scene is drawn: its background in a clipped stage, and its objects above.
@interface AUSurface : NSObject
@property (nonatomic) AUSurfaceKind kind;
@property (nonatomic, strong) CALayer *stage;                 // clipped to the cover or the fill
@property (nonatomic, strong) CALayer *background;
@property (nonatomic, strong, nullable) AUSceneRenderer *renderer;      // the whole scene in 3D (Metal), over `background`
@property (nonatomic, strong, nullable) NSArray<CALayer *> *softs;       // Fill: blurred copies, each faded in further down
@property (nonatomic, strong, nullable) NSArray<CAGradientLayer *> *softMasks;
@property (nonatomic, strong) CALayer *objects;               // the objects' host: unclipped over the cover, clipped and faded in Fill
@property (nonatomic, strong) CAGradientLayer *objectsMask;
@property (nonatomic, strong) NSMutableArray<CALayer *> *layers;
@property (nonatomic, weak) AUScene *content;
@property (nonatomic) CGRect pictureRect;                     // where the picture is drawn in the stage, zoomed
@property (nonatomic) BOOL attached;
@end

@implementation AUSurface
@end

@interface AUWeakCover : NSObject
@property (nonatomic, weak) UIView *view;
@end

@implementation AUWeakCover
@end

@interface AUCoverEffects : NSObject
+ (instancetype)shared;
- (void)tiltLaidOut:(UIView *)tilt;
- (void)fieldLaidOut:(UIView *)field;
- (void)holder:(UIView *)holder laidOutCover:(UIView *)cover;
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

void AUCoverEffectsCoverFound(UIView *holder, UIView *cover) {
    [[AUCoverEffects shared] holder:holder laidOutCover:cover];
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
                 @"hidden": off, @"sublayerTransform": off, @"mask": off, @"anchorPoint": off};
    });
    return none;
}

static CALayer *plainLayer(void) {
    CALayer *layer = [CALayer layer];
    layer.actions = noActions();
    layer.contentsGravity = kCAGravityResize;
    return layer;
}

// Fill as a full screen: the scene's stage runs past Taurus's field (0.625 of the screen) down to the screen's foot, the
// cover across the width (a touch bigger, 1.12) with the room LaMa painted below it, sharp down to 0.56 of the screen,
// a light blur coming in by 0.70, a softer one by 0.84, faded into the player's colour from 0.68 to 0.94.
// (The numbers are Core/AUTune's: blur1From/To/Size, blur2From/To/Size, fadeFrom/To, fillCrop.)
static void softRamp(int k, CGFloat *from, CGFloat *to) {
    *from = AUTune(k ? @"blur2From" : @"blur1From");
    *to = MAX(*from + 0.01, AUTune(k ? @"blur2To" : @"blur1To"));
}

// The small copy's side for a blur of `percent` of the width (two tent passes of 5 are about 1.2 % of 200 px).
static size_t softSide(int k) {
    double percent = AUTune(k ? @"blur2Size" : @"blur1Size");
    return percent <= 0.01 ? 0 : (size_t)MAX(16.0, MIN(800.0, 240.0 / percent));
}

static CAGradientLayer *ramp(CGFloat from, CGFloat to, BOOL rising) {
    NSMutableArray *locations = [NSMutableArray array], *colors = [NSMutableArray array];
    [locations addObject:@0];
    [colors addObject:(id)[UIColor colorWithWhite:1 alpha:rising ? 0 : 1].CGColor];
    for (int i = 0; i <= 16; i++) {
        CGFloat t = i / 16.0, smooth = t * t * t * (t * (t * 6 - 15) + 10);
        [locations addObject:@(from + (to - from) * t)];
        [colors addObject:(id)[UIColor colorWithWhite:1 alpha:rising ? smooth : 1 - smooth].CGColor];
    }
    [locations addObject:@1];
    [colors addObject:(id)[UIColor colorWithWhite:1 alpha:rising ? 1 : 0].CGColor];
    CAGradientLayer *layer = [CAGradientLayer layer];
    layer.actions = noActions();
    layer.colors = colors;
    layer.locations = locations;
    layer.startPoint = CGPointMake(0.5, 0);
    layer.endPoint = CGPointMake(0.5, 1);
    return layer;
}

// The scene as it rests (background, the room below it when `tall`, and the objects) blurred by a few percent of its
// side: a small copy convolved.
static CGImageRef blurredScene(AUScene *scene, size_t side, BOOL tall) {
    CGImageRef image = tall && scene.tall ? scene.tall.CGImage : scene.background.CGImage;
    if (!image) return NULL;
    size_t high = (size_t)lround(side * (tall ? scene.tallness : 1));
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef c = CGBitmapContextCreate(NULL, side, high, 8, 0, space, kCGImageAlphaNoneSkipLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(space);
    if (!c) return NULL;
    CGContextSetInterpolationQuality(c, kCGInterpolationHigh);
    CGContextDrawImage(c, CGRectMake(0, 0, side, high), image);
    for (AUSceneLayer *layer in scene.layers) CGContextDrawImage(c, CGRectMake(0, high - side, side, side), layer.image.CGImage);
    vImage_Buffer a = {CGBitmapContextGetData(c), high, side, CGBitmapContextGetBytesPerRow(c)};
    NSMutableData *scratch = [NSMutableData dataWithLength:a.rowBytes * high];
    vImage_Buffer b = {scratch.mutableBytes, high, side, a.rowBytes};
    vImageTentConvolve_ARGB8888(&a, &b, NULL, 0, 0, 5, 5, NULL, kvImageEdgeExtend);
    vImageTentConvolve_ARGB8888(&b, &a, NULL, 0, 0, 5, 5, NULL, kvImageEdgeExtend);
    CGImageRef made = CGBitmapContextCreateImage(c);
    CGContextRelease(c);
    return made;
}

static CALayer *ivarLayer(id object, const char *name) {
    Ivar ivar = class_getInstanceVariable(object_getClass(object), name);
    id value = ivar ? object_getIvar(object, ivar) : nil;
    return [value isKindOfClass:CALayer.class] ? value : nil;
}

// An artwork published for another track than the one playing is not shown.
// 1: the whole picture moves as one layer (no 3D, no objects), 0: the 3D scene.
static BOOL singleLayer(void) {
    return AUInteger(AUKeyMotionMode, 0) == 1;
}

static char kPlainSceneKey;

// The cover itself as a scene with nothing lifted out, made once per artwork.
static AUScene *plainSceneOf(AUArtwork *artwork) {
    if (!artwork.source) return nil;
    AUScene *scene = objc_getAssociatedObject(artwork, &kPlainSceneKey);
    if (scene) return scene;
    scene = [AUScene new];
    scene.background = artwork.source;
    scene.square = CGRectMake(0, 0, artwork.source.size.width * artwork.source.scale, artwork.source.size.height * artwork.source.scale);
    scene.layers = @[];
    objc_setAssociatedObject(artwork, &kPlainSceneKey, scene, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return scene;
}

static BOOL forCurrentTrack(AUArtwork *artwork) {
    NSString *playing = AUTaurusTrackURI();
    return !playing.length || !artwork.trackURI.length || [artwork.trackURI isEqualToString:playing];
}

@implementation AUCoverEffects {
    NSHashTable<UIView *> *_tilts;
    __weak UIView *_tilt, *_cover, *_field;
    __weak CALayer *_fillLayer;
    UIView *_plane;                  // over the cover, inside it, clipped to its corners
    UIView *_subjectHost;            // a zero-size view in the tilt view, so nothing takes it for the cover
    AUSurface *_coverSurface, *_fillSurface;
    CAGradientLayer *_fade;
    CGFloat _fadeFrom, _fadeTo;
    __weak AUArtwork *_shown;
    NSString *_shownKey;
    BOOL _shownMoving, _wantPlane;
    CADisplayLink *_link;
    CFTimeInterval _lastMove;
    CMMotionManager *_motion;
    NSOperationQueue *_motionQueue;
    BOOL _motionOn;
    double _refX, _refY;
    BOOL _refSet;
    CGPoint _tiltNow;
    BOOL _pickScheduled, _active;
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
    [center addObserver:self selector:@selector(trackChanged:) name:AUTrackDidChangeNotification object:nil];
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

static char kNamedCoverKey;

static UIView *namedCover(UIView *holder) {
    return ((AUWeakCover *)objc_getAssociatedObject(holder, &kNamedCoverKey)).view;
}

static UIView *coverIn(UIView *tilt) {
    UIView *named = namedCover(tilt);
    if (named) return named.superview == tilt ? named : nil;
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
    if (AUHostYandex()) return AUYandexFillField();
    UIView *(*field)(void) = (UIView * (*)(void)) dlsym(RTLD_DEFAULT, "SGRPlayerField");
    return field ? field() : nil;
}

// Taurus draws the same field behind playlists, albums, artists and its settings' preview: only the player's counts.
- (CALayer *)fillLayerShowing {
    UIView *field = taurusField();
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

- (void)holder:(UIView *)holder laidOutCover:(UIView *)cover {
    if (cover.bounds.size.width < kCoverMinWidth) return;
    if (namedCover(holder) != cover) {
        AUWeakCover *box = [AUWeakCover new];
        box.view = cover;
        objc_setAssociatedObject(holder, &kNamedCoverKey, box, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (holder == _tilt) [self schedulePick];
    }
    [_tilts addObject:holder];
    if (holder == _tilt) [self layoutCover];
    UIScrollView *list = listOf(holder);
    if ((list.isDragging || list.isDecelerating) && _wantPlane) [self startLink];
    [self schedulePick];
}

- (void)fieldLaidOut:(UIView *)field {
    if (field != taurusField()) return;
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
    surface.stage = plainLayer();
    surface.stage.masksToBounds = YES;
    surface.background = plainLayer();
    [surface.stage addSublayer:surface.background];
    surface.objects = plainLayer();
    surface.layers = [NSMutableArray array];
    if (kind == AUSurfaceFill) {
        // The objects fade later than Taurus's fill (0.76...0.985 of its height): they stay where the cover has melted.
        surface.objects.masksToBounds = YES;
        CAGradientLayer *mask = [CAGradientLayer layer];
        mask.actions = noActions();
        mask.colors = @[(id)UIColor.whiteColor.CGColor, (id)UIColor.whiteColor.CGColor, (id)[UIColor colorWithWhite:1 alpha:0].CGColor];
        mask.locations = @[@0, @(AUTune(@"fadeFrom") + 0.1), @1];
        surface.objects.mask = mask;
        surface.objectsMask = mask;
        NSMutableArray *softs = [NSMutableArray array], *masks = [NSMutableArray array];
        for (int i = 0; i < 2; i++) {
            CALayer *soft = plainLayer();
            CAGradientLayer *softMask = ramp(0, 1, YES);
            soft.mask = softMask;
            [surface.stage addSublayer:soft];
            [softs addObject:soft];
            [masks addObject:softMask];
        }
        surface.softs = softs;
        surface.softMasks = masks;
    }
    return surface;
}

- (void)pick {
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

#pragma mark - geometry

static CGFloat strengthNow(void) {
    return AUSceneMotion * AUNumber(AUKeyDepthStrength, 1.0);
}

// The picture (the cover's square) aspect-filled into `bounds`, zoomed just enough that the background's own move
// (`reach`: its largest factor) never shows its edge.
static CGRect pictureRectIn(CGRect bounds, CGSize picture, BOOL moving, double reach, BOOL threeD) {
    if (picture.width <= 0 || picture.height <= 0) return bounds;
    CGFloat scale = MAX(bounds.size.width / picture.width, bounds.size.height / picture.height);
    if (moving) scale *= threeD ? AUSceneZoom(AUNumber(AUKeyDepthStrength, 1.0)) : 1 + 2 * reach * strengthNow() + 0.006;
    CGSize size = CGSizeMake(picture.width * scale, picture.height * scale);
    return CGRectMake(CGRectGetMidX(bounds) - size.width / 2, CGRectGetMidY(bounds) - size.height / 2, size.width, size.height);
}

- (CGSize)pictureSizeFor:(AUSurface *)surface {
    AUScene *scene = surface.content;
    if (!scene) return CGSizeZero;
    return surface.kind == AUSurfaceCover ? scene.square.size : scene.background.size;
}

// Fill on Metal: the renderer blurs its finished frame; the ramps are the stage's shares of its height (stageHigh),
// turned into the picture's.
static void applyBlur(AUSurface *surface, CGFloat stageHigh) {
    if (!surface.renderer) return;
    if (surface.kind != AUSurfaceFill || stageHigh < 1) {
        [surface.renderer clearBlur];
        return;
    }
    CGFloat h = MAX(1, surface.pictureRect.size.height), y = surface.pictureRect.origin.y, H = stageHigh;
    CGFloat f1, t1, f2, t2;
    softRamp(0, &f1, &t1);
    softRamp(1, &f2, &t2);
    [surface.renderer setBlurRamp1:CGPointMake((f1 * H - y) / h, (t1 * H - y) / h) size1:AUTune(@"blur1Size") / 100
                             ramp2:CGPointMake((f2 * H - y) / h, (t2 * H - y) / h) size2:AUTune(@"blur2Size") / 100];
    // Over the cover: the painted room blurs upward from a touch inside the cover's top.
    double side = surface.pictureRect.size.width, coverTop = surface.renderer.frameTop * side, reach = AUTune(@"topBlurReach");
    if (coverTop > 1 && reach > 0.001) {
        [surface.renderer setTopBlurFrom:(coverTop + side * 0.03) / h to:(coverTop - side * reach) / h size:AUTune(@"blur2Size") / 100];
    }
}

- (void)placeSurface:(AUSurface *)surface stageBounds:(CGRect)bounds {
    double reach = singleLayer() ? kSingleReach : surface.content ? surface.content.plateReach : 0.3;
    if (surface.kind == AUSurfaceFill && (surface.renderer || singleLayer())) {
        // The cover across the stage's width, its middle at «Положение обложки» of the stage's height, the rooms LaMa
        // painted above and below it; zoomed round the cover's middle.
        CGFloat side0 = bounds.size.width * AUTune(@"fillCrop");
        CGFloat zoom = !_shownMoving ? 1 : surface.renderer ? AUSceneZoom(AUNumber(AUKeyDepthStrength, 1.0)) : 1 + 2 * kSingleReach * strengthNow() + 0.006;
        CGFloat side = side0 * zoom;
        CGFloat tall = surface.renderer ? surface.renderer.frameTall : 1;
        CGFloat above = surface.renderer ? surface.renderer.frameTop : 0;
        // Never lower than the stage's top would leave uncovered (a cover with no room painted above it).
        CGFloat middle = bounds.size.height * AUTune(@"fillCenter");
        if (above * side < middle - side / 2) middle = MAX(side0 / 2, above * side + side / 2);
        surface.pictureRect = CGRectMake((bounds.size.width - side) / 2, middle - side / 2 - above * side, side, side * tall);
    } else {
        surface.pictureRect = pictureRectIn((CGRect){CGPointZero, bounds.size}, [self pictureSizeFor:surface], _shownMoving, reach,
                                            surface.renderer != nil);
    }
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    surface.background.bounds = (CGRect){CGPointZero, surface.pictureRect.size};
    surface.background.position = CGPointMake(CGRectGetMidX(surface.pictureRect), CGRectGetMidY(surface.pictureRect));
    for (NSUInteger k = 0; k < surface.softs.count; k++) {
        CALayer *soft = surface.softs[k];
        soft.bounds = surface.background.bounds;
        soft.position = surface.background.position;
        surface.softMasks[k].frame = soft.bounds;
        // The ramp is the stage's: its share of the stage's height turned into the picture's.
        CGFloat h = MAX(1, surface.pictureRect.size.height), y = surface.pictureRect.origin.y, H = bounds.size.height;
        CGFloat rampFrom, rampTo;
        softRamp((int)k, &rampFrom, &rampTo);
        CGFloat from = (rampFrom * H - y) / h, to = (rampTo * H - y) / h;
        NSMutableArray *locations = [NSMutableArray array];
        NSArray *base = ramp(0, 1, YES).locations;
        for (NSUInteger i = 0; i < base.count; i++) {
            CGFloat t = i == 0 ? 0 : i == base.count - 1 ? 1 : from + (to - from) * [base[i] doubleValue];
            [locations addObject:@(MAX(0, MIN(1, t)))];
        }
        surface.softMasks[k].locations = locations;
    }
    if (surface.renderer) {
        surface.renderer.layer.frame = surface.background.bounds;
        [surface.renderer layoutForScale:UIScreen.mainScreen.scale];
        applyBlur(surface, bounds.size.height);
    }
    [CATransaction commit];
    [self moveSurfaces];
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
    [_plane.layer addSublayer:_coverSurface.stage];
    // Stepping out, the objects live over the cover, unclipped; else inside it, clipped to its corners.
    if (AUFlag(AUKeyPopOut)) [_subjectHost.layer addSublayer:_coverSurface.objects];
    else [_plane.layer addSublayer:_coverSurface.objects];
    [_cover addSubview:_plane];
    [_tilt addSubview:_subjectHost];
    // (Yandex rounds its cover by its holder's clipping: that is left alone unless the objects step out.)
    if (!AUHostYandex() || AUFlag(AUKeyPopOut)) _tilt.clipsToBounds = NO;
    _coverSurface.attached = YES;
    _coverSurface.content = nil;
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
    _coverSurface.stage.frame = _plane.bounds;
    [CATransaction commit];
    if (_subjectHost.superview == _tilt && _tilt.subviews.lastObject != _subjectHost) [_tilt bringSubviewToFront:_subjectHost];
    _subjectHost.frame = CGRectZero;
    [self placeSurface:_coverSurface stageBounds:_plane.bounds];
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
    if (!fill || !_field) return;
    // Lowest in `_fill`: under its blurred bands, inside its fading mask.
    [fill insertSublayer:_fillSurface.stage atIndex:0];
    if (fill.superlayer) [fill.superlayer insertSublayer:_fillSurface.objects above:fill];
    _fillSurface.stage.opacity = 0;
    _fillSurface.attached = YES;
    _fillSurface.content = nil;
    [self layoutFill];
    AULog(@"effects on Taurus's Fill background (%.0f x %.0f pt)", fill.bounds.size.width, fill.bounds.size.height);
    _shownKey = nil;
    [self apply:[AUPipeline shared].current animated:NO];
}

// While Aura's scene shows in Fill, Taurus's four blur bands (a still picture, they would not move with it) are
// hidden and its fade is a longer, gentler one; both go back as they were when the scene goes.
- (void)takeTaurusFill:(BOOL)take {
    UIView *field = _field;
    CALayer *fill = _fillLayer;
    if (!field || !fill) return;
    Ivar blursIvar = class_getInstanceVariable(object_getClass(field), "_fillBlurLayers");
    id blurs = blursIvar ? object_getIvar(field, blursIvar) : nil;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    if ([blurs isKindOfClass:NSArray.class]) {
        for (id blur in blurs) if ([blur isKindOfClass:CALayer.class]) ((CALayer *)blur).hidden = take;
    }
    CALayer *taurusMask = ivarLayer(field, "_fillMask");
    if (take) {
        CGFloat fadeFrom = AUTune(@"fadeFrom"), fadeTo = MAX(fadeFrom + 0.01, AUTune(@"fadeTo"));
        if (!_fade || _fadeFrom != fadeFrom || _fadeTo != fadeTo) {
            if (fill.mask == _fade) fill.mask = nil;
            _fade = ramp(fadeFrom, fadeTo, NO);
            _fadeFrom = fadeFrom;
            _fadeTo = fadeTo;
        }
        _fade.frame = [self fillStageBounds];
        if (fill.mask != _fade) fill.mask = _fade;
        // The stage runs on below the field Taurus gives its picture.
        fill.masksToBounds = NO;
    } else {
        if (fill.mask == _fade && taurusMask) fill.mask = taurusMask;
        fill.masksToBounds = YES;
    }
    [CATransaction commit];
}

- (void)detachFill {
    [self takeTaurusFill:NO];
    [_fillSurface.stage removeFromSuperlayer];
    [_fillSurface.objects removeFromSuperlayer];
    _fillSurface.attached = NO;
}

// Fill's stage: from the field's top to the screen's foot (Taurus's own picture stops at 0.625 of it).
- (CGRect)fillStageBounds {
    CALayer *fill = _fillLayer;
    UIView *field = _field;
    CGFloat window = field.window.bounds.size.height ?: UIScreen.mainScreen.bounds.size.height;
    CGFloat high = _fillSurface.renderer ? MAX(fill.bounds.size.height, window) : fill.bounds.size.height;
    return CGRectMake(0, 0, fill.bounds.size.width, high);
}

- (void)layoutFill {
    CALayer *fill = _fillLayer;
    if (!fill || !_fillSurface.attached) return;
    CGRect stage = [self fillStageBounds];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _fillSurface.stage.frame = stage;
    _fillSurface.objects.frame = fill.frame;
    _fillSurface.objectsMask.frame = (CGRect){CGPointZero, fill.bounds.size};
    if (_fade) _fade.frame = stage;
    [CATransaction commit];
    [self placeSurface:_fillSurface stageBounds:stage];
}

#pragma mark - moving

// Everything by its depth: the background bends by its smooth depth (Metal), every object moves whole by its own.
- (void)moveSurfaces {
    CGFloat strength = _shownMoving ? strengthNow() : 0;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    for (AUSurface *surface in [self attachedSurfaces]) {
        AUScene *scene = surface.content;
        CGRect picture = surface.pictureRect;
        CGFloat side = MIN(picture.size.width, picture.size.height);
        if (surface.renderer) {
            surface.background.affineTransform = CGAffineTransformIdentity;
            surface.renderer.tilt = _tiltNow;
            surface.renderer.strength = _shownMoving ? AUNumber(AUKeyDepthStrength, 1.0) : 0;
            if (_active && scene) [surface.renderer render];
        } else {
            // No GPU: the background slides whole, as the rule moves its typical (a little far) depth.
            CGFloat back = singleLayer() ? kSingleReach * strength * side
                         : scene ? [scene plateFactorOf:scene.plateCenter - 0.15] * strength * side : 0;
            surface.background.affineTransform = CGAffineTransformMakeTranslation(_tiltNow.x * back, _tiltNow.y * back);
        }
        for (CALayer *soft in surface.softs) soft.affineTransform = surface.background.affineTransform;
        CGRect objectsRect = picture;
        CGAffineTransform base = CGAffineTransformIdentity;
        if (surface.kind == AUSurfaceCover && _cover && surface.objects.superlayer == _plane.layer) {
            surface.objects.frame = _plane.bounds;
            surface.objects.opacity = 1;
        } else if (surface.kind == AUSurfaceCover && _cover) {
            // Over the cover, in the tilt view: a little bigger from its foot, taking the cover's paused shrink.
            CGRect inPlane = [_plane.layer convertRect:picture fromLayer:surface.stage];
            CGPoint center = [_tilt convertPoint:CGPointMake(CGRectGetMidX(inPlane), CGRectGetMidY(inPlane)) fromView:_plane];
            objectsRect = CGRectMake(center.x - inPlane.size.width / 2, center.y - inPlane.size.height / 2, inPlane.size.width, inPlane.size.height);
            // Stepping out of the frame (a little bigger, from the foot) only when asked: otherwise the objects lie
            // exactly on their place in the cover.
            CGFloat stepOut = AUFlag(AUKeyPopOut) ? kStepOut : 1;
            base = CGAffineTransformConcat(CGAffineTransformConcat(CGAffineTransformMakeScale(stepOut, stepOut),
                                                                   CGAffineTransformMakeTranslation(0, objectsRect.size.height / 2 * (1 - stepOut))),
                                           _cover.transform);
            surface.objects.opacity = (float)(_cover.alpha * _plane.alpha);
        } else if (surface.kind == AUSurfaceFill) {
            surface.objects.opacity = surface.stage.opacity * (_fillLayer ? _fillLayer.opacity : 1);
        }
        for (NSUInteger i = 0; i < surface.layers.count; i++) {
            CALayer *layer = surface.layers[i];
            AUSceneLayer *object = i < scene.layers.count ? scene.layers[i] : nil;
            CGFloat amount = object ? [scene weightOf:object] * strength * side : 0;
            layer.bounds = (CGRect){CGPointZero, objectsRect.size};
            layer.position = CGPointMake(CGRectGetMidX(objectsRect), CGRectGetMidY(objectsRect));
            layer.affineTransform = CGAffineTransformConcat(CGAffineTransformMakeTranslation(_tiltNow.x * amount, _tiltNow.y * amount), base);
        }
    }
    [CATransaction commit];
}

#pragma mark - what is shown

- (BOOL)wantsMotion { return AUEnabled(AUKeyDepth) && !AUThrottled(); }
- (BOOL)wantsObjects { return AUEnabled(AUKeyDepth) && !AUThrottled(); }

- (void)artworkChanged:(NSNotification *)note {
    [self apply:note.object animated:YES];
}

- (void)refresh {
    _shownKey = nil;
    if (_coverSurface.attached) {
        // The pop-out switch moves the objects between the cover and the tilt view.
        [self detachCover];
        [self attachCover];
    }
    for (AUSurface *surface in [self attachedSurfaces]) surface.content = nil;
    [self apply:[AUPipeline shared].current animated:YES];
}

// The track moved on: what showed belongs to the last one and goes at once, before Taurus has the new picture.
- (void)trackChanged:(NSNotification *)note {
    NSString *uri = note.userInfo[@"uri"];
    if ([_shown.trackURI isEqualToString:uri]) return;
    _shownKey = nil;
    _shownMoving = _wantPlane = NO;
    [self setShown:NO animated:NO];
    [self updateMotion];
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
        CALayer *stage = _fillSurface.stage;
        float target = shown ? 1 : 0;
        if (animated && stage.opacity != target) {
            CABasicAnimation *fade = [CABasicAnimation animationWithKeyPath:@"opacity"];
            fade.fromValue = @(stage.presentationLayer.opacity);
            fade.toValue = @(target);
            fade.duration = 0.22;
            [stage addAnimation:fade forKey:@"aura.fade"];
            [_fillSurface.objects addAnimation:[fade copy] forKey:@"aura.fade"];
        }
        stage.opacity = target;
        [self takeTaurusFill:shown];
    }
    [self moveSurfaces];
}

- (void)fill:(AUSurface *)surface with:(AUScene *)scene showObjects:(BOOL)objects {
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    BOOL cover = surface.kind == AUSurfaceCover;
    // A solid scene's own picture is `front` (its background has the bands behind the tears painted out).
    UIImage *own = scene.solid ? scene.front : nil;
    UIImage *background = cover ? [scene squareOf:own ?: scene.background] : own ? [scene squareOf:own] : scene.background;
    surface.background.contents = (__bridge id)(!cover && scene.tall && [AUSceneRenderer supported] ? own ?: scene.tall : background).CGImage;
    // The whole scene in 3D on Metal — unless the objects are to step out over the cover's frame (CA layers do that).
    BOOL threeD = [AUSceneRenderer supported] && background.CGImage && !(cover && AUFlag(AUKeyPopOut)) && !singleLayer();
    if (threeD) {
        if (!surface.renderer) {
            surface.renderer = [AUSceneRenderer new];
            surface.renderer.presentsWithTransaction = YES;
            [surface.background addSublayer:surface.renderer.layer];
        }
        [surface.renderer setScene:scene tall:!cover];
        surface.renderer.withObjects = objects;
        surface.renderer.layer.frame = surface.background.bounds;
        [surface.renderer layoutForScale:UIScreen.mainScreen.scale];
        applyBlur(surface, surface.stage.bounds.size.height);
    } else if (surface.renderer) {
        [surface.renderer.layer removeFromSuperlayer];
        surface.renderer = nil;
    }
    for (NSUInteger k = 0; k < surface.softs.count; k++) {
        // On Metal the renderer blurs its own finished frame (setBlurRamp1:…): no still copies to slide apart from it.
        size_t softPixels = threeD ? 0 : softSide((int)k);
        CGImageRef soft = softPixels ? blurredScene(scene, softPixels, NO) : NULL;
        surface.softs[k].hidden = !soft;
        surface.softs[k].contents = (__bridge id)soft;
        if (soft) CGImageRelease(soft);
    }
    for (CALayer *layer in surface.layers) [layer removeFromSuperlayer];
    [surface.layers removeAllObjects];
    if (objects && !threeD) {
        for (AUSceneLayer *object in scene.layers) {
            CALayer *layer = plainLayer();
            UIImage *image = cover ? [scene squareOf:object.image] : object.image;
            layer.contents = (__bridge id)image.CGImage;
            if (cover && AUFlag(AUKeyPopOut)) {
                layer.shadowColor = UIColor.blackColor.CGColor;
                layer.shadowOpacity = 0.35;
                layer.shadowRadius = 10;
                layer.shadowOffset = CGSizeMake(0, 6);
                // A shadow of the picture's own shape costs an offscreen pass a frame; rasterized it is drawn once and moved.
                layer.shouldRasterize = YES;
                layer.rasterizationScale = UIScreen.mainScreen.scale;
            }
            [surface.objects addSublayer:layer];
            [surface.layers addObject:layer];
        }
    }
    [CATransaction commit];
    surface.content = scene;
}

- (void)apply:(AUArtwork *)artwork animated:(BOOL)animated {
    NSArray<AUSurface *> *surfaces = [self attachedSurfaces];
    if (!surfaces.count) return;
    if (artwork != [AUPipeline shared].current) return;
    BOOL single = singleLayer();
    AUScene *scene = single ? plainSceneOf(artwork) : artwork.scene;
    BOOL objects = !single && [self wantsObjects] && scene.layers.count;
    // In 3D even a cover with no objects lifted moves: its background has its own relief.
    BOOL moving = [self wantsMotion] && (single || objects || [AUSceneRenderer supported]);
    BOOL wantPlane = scene && ([self wantsObjects] || artwork.upscaled) && forCurrentTrack(artwork);
    BOOL sameCover = [artwork.key isEqualToString:_shownKey];
    if (!sameCover) {
        _shownMoving = _wantPlane = NO;
        [self setShown:NO animated:NO];
    }
    _shown = artwork;
    _shownKey = artwork.key;
    if (!wantPlane) {
        _wantPlane = NO;
        [self setShown:NO animated:animated];
        [self updateMotion];
        return;
    }
    for (AUSurface *surface in surfaces) {
        if (surface.content != scene) [self fill:surface with:scene showObjects:objects];
    }
    BOOL first = !_wantPlane;
    _shownMoving = moving;
    _wantPlane = YES;
    if (_coverSurface.attached) [self placeSurface:_coverSurface stageBounds:_plane.bounds];
    if (_fillSurface.attached && _fillLayer) [self layoutFill];
    if (first) {
        double latency = (CACurrentMediaTime() - artwork.arrived) * 1000;
        AUStatRecord(@"shown", latency);
        static NSUInteger logged;
        if (logged++ < 60) {
            AULog(@"artwork …%@ shown %.0f ms after it came: %lu objects, %@, on %@",
                  [artwork.key substringFromIndex:artwork.key.length > 10 ? artwork.key.length - 10 : 0], latency,
                  (unsigned long)scene.layers.count, scene.inpainted ? @"painted in" : @"quick fill", _fillSurface.attached ? @"Fill" : @"the cover");
        }
    }
    [self setShown:YES animated:animated];
    [self updateMotion];
}

#pragma mark - motion and frames

- (BOOL)visible {
    return (_coverSurface.attached && showing(_tilt)) || (_fillSurface.attached && [self fillLayerShowing] == _fillLayer);
}

- (BOOL)needsMotion {
    return _active && _wantPlane && _shownMoving && !AUThrottled() && [self visible];
}

// While the scene can move, Core Motion runs on its own queue at 20 Hz to notice the phone moving; only then a
// display link runs, at up to 120 Hz, until the phone has been still for 0.8 s. The layers only move: Core
// Animation draws them, nothing is rendered per frame.
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
            // A phone held in the hand never stands still: only a real turn wakes the drawing.
            BOOL moved = !first && hypot(gx - lastX, gy - lastY) > AUTune(@"wake");
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
    if (_link || !_motionOn) return;
    _motion.deviceMotionUpdateInterval = 1.0 / 100;
    _link = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick:)];
    // The whole scene is drawn again each frame: 60 at most (the heat of 120 is not worth it), 30 when the phone is hot.
    float fps = (float)AUTune(@"appFps");
    if (NSProcessInfo.processInfo.thermalState >= NSProcessInfoThermalStateSerious) fps = MIN(fps, 30);
    if (@available(iOS 15.0, *)) _link.preferredFrameRateRange = CAFrameRateRangeMake(MIN(fps, 30), fps, fps);
    else _link.preferredFramesPerSecond = (NSInteger)fps;
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
        double dt = MIN(0.1, MAX(1.0 / 120, link.targetTimestamp - link.timestamp));
        double follow = 1 - exp(-dt / AUTune(@"follow"));
        _refX += (gx - _refX) * follow;
        _refY += (gy - _refY) * follow;
        double full = AUTune(@"tiltFull");
        CGFloat tx = (CGFloat)MAX(-1.0, MIN(1.0, (gx - _refX) / full)) * (AUTuneOn(@"invertX") ? -1 : 1);
        CGFloat ty = (CGFloat)MAX(-1.0, MIN(1.0, -(gy - _refY) / full)) * (AUTuneOn(@"invertY") ? -1 : 1);
        double smooth = 1 - exp(-dt / AUTune(@"smooth"));
        CGPoint next = CGPointMake(_tiltNow.x + (tx - _tiltNow.x) * smooth, _tiltNow.y + (ty - _tiltNow.y) * smooth);
        CGFloat moved = hypot(next.x - _tiltNow.x, next.y - _tiltNow.y);
        if (moved > 0.0015) _lastMove = now;
        if (moved > 0.0003) {
            _tiltNow = next;
            [self moveSurfaces];
            AUCountFrame();
            if (++_frames % 600 == 1) AULog(@"parallax running: tilt %.2f %.2f", _tiltNow.x, _tiltNow.y);
        }
    }
    if (now - _lastMove > 0.6) [self stopLink];
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
