#import "AUYandexFill.h"
#import "AUCoverEffects.h"
#import "Core/AUCore.h"
#import "Core/AUTune.h"
#import "Core/AUYandex.h"
#import <Accelerate/Accelerate.h>
#import <objc/runtime.h>

BOOL AUYandexFillOn(void) {
    return AUEnabled(AUKeyYandexFill);
}

static NSDictionary *noActions(void) {
    id off = NSNull.null;
    return @{@"bounds": off, @"position": off, @"frame": off, @"contents": off, @"opacity": off, @"hidden": off, @"mask": off};
}

// The cover small and blurred, for the room around and below the sharp one.
static CGImageRef blurredCopy(UIImage *image) {
    CGImageRef cg = image.CGImage;
    if (!cg) return NULL;
    const size_t side = 96;
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef c = CGBitmapContextCreate(NULL, side, side, 8, 0, space, (CGBitmapInfo)kCGImageAlphaNoneSkipLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(space);
    if (!c) return NULL;
    CGContextSetInterpolationQuality(c, kCGInterpolationMedium);
    CGContextDrawImage(c, CGRectMake(0, 0, side, side), cg);
    vImage_Buffer a = {CGBitmapContextGetData(c), side, side, CGBitmapContextGetBytesPerRow(c)};
    NSMutableData *scratch = [NSMutableData dataWithLength:a.rowBytes * side];
    vImage_Buffer b = {scratch.mutableBytes, side, side, a.rowBytes};
    for (int i = 0; i < 2; i++) {
        vImageTentConvolve_ARGB8888(&a, &b, NULL, 0, 0, 15, 15, NULL, kvImageEdgeExtend);
        vImageTentConvolve_ARGB8888(&b, &a, NULL, 0, 0, 15, 15, NULL, kvImageEdgeExtend);
    }
    CGImageRef made = CGBitmapContextCreateImage(c);
    CGContextRelease(c);
    return made;
}

@implementation AUYandexFillView {
    CAGradientLayer *_fade;
    __weak UIImage *_shown;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.userInteractionEnabled = NO;
    self.backgroundColor = UIColor.clearColor;
    _fill = [CALayer layer];
    _fill.actions = noActions();
    _fill.masksToBounds = YES;
    _fill.contentsGravity = kCAGravityResizeAspectFill;
    _fade = [CAGradientLayer layer];
    _fade.actions = noActions();
    _fill.mask = _fade;
    [self.layer addSublayer:_fill];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(artworkChanged) name:AUYandexArtworkDidChangeNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(setNeedsLayout) name:AUSettingsDidChangeNotification object:nil];
    return self;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)artworkChanged {
    UIImage *image = AUYandexArtwork(NULL, NULL, NULL);
    if (image) [self setPicture:image];
}

// The still picture as the fill's own contents (under every sublayer, as Taurus's is, so Aura's scene goes over it):
// the cover stretched over the field.
- (void)compose {
    _fill.contents = (__bridge id)_shown.CGImage;
}

- (void)setPicture:(UIImage *)image {
    if (image == _shown) return;
    _shown = image;
    [self compose];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGSize size = self.bounds.size;
    // Taurus's field: the top of the screen (0.62 by default), the picture faded out at its foot.
    CGFloat high = round(size.height * AUNumber(AUKeyYandexFillHeight, 0.62));
    _fill.frame = CGRectMake(0, 0, size.width, high);
    // The still picture's own fade (Aura's scene brings its own when it shows).
    CGFloat from = AUTune(@"fadeFrom"), to = MAX(from + 0.01, AUTune(@"fadeTo"));
    _fade.frame = _fill.bounds;
    _fade.colors = @[(id)UIColor.whiteColor.CGColor, (id)UIColor.whiteColor.CGColor, (id)[UIColor colorWithWhite:1 alpha:0].CGColor];
    _fade.locations = @[@0, @(MIN(from, 0.98)), @(MIN(to, 1.0))];
    [CATransaction commit];
    AUCoverEffectsFieldLaidOut(self);
}

@end

static __weak AUYandexFillView *sFill;
static NSHashTable<UIView *> *sHidden;

UIView *AUYandexFillField(void) {
    AUYandexFillView *fill = sFill;
    return fill.window && !fill.hidden ? fill : nil;
}

static char kEmptyMaskKey;

static void hideByMask(UIView *view) {
    CALayer *mask = objc_getAssociatedObject(view, &kEmptyMaskKey);
    if (!mask) {
        mask = [CALayer layer];
        objc_setAssociatedObject(view, &kEmptyMaskKey, mask, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (view.layer.mask != mask) {
        view.layer.mask = mask;
        [sHidden addObject:view];
    }
}

static void restoreCells(void) {
    for (UIView *view in sHidden) {
        if (view.layer.mask == objc_getAssociatedObject(view, &kEmptyMaskKey)) view.layer.mask = nil;
    }
    [sHidden removeAllObjects];
}

void AUYandexFillUpdate(UIView *artworkView, UICollectionView *carousel) {
    static char kFillKey;
    AUYandexFillView *fill = objc_getAssociatedObject(artworkView, &kFillKey);
    if (!sHidden) sHidden = [NSHashTable weakObjectsHashTable];
    if (!AUYandexFillOn() || !artworkView.window) {
        if (fill) {
            [fill removeFromSuperview];
            objc_setAssociatedObject(artworkView, &kFillKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            restoreCells();
            AUCoverEffectsFieldLaidOut(fill);
        }
        return;
    }
    if (!fill) {
        fill = [[AUYandexFillView alloc] initWithFrame:CGRectZero];
        objc_setAssociatedObject(artworkView, &kFillKey, fill, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    sFill = fill;
    // The fill hangs off the artwork view's lifetime, wherever it is put.
    // The player's background: in the player's own view, under the list the player scrolls in (the artwork view lies
    // in a SwiftUI card inside it, which cuts anything drawn from there). Else over the artwork view's background.
    UIViewController *player = AUYandexPlayerController();
    UIView *list = AUYandexPlayerLayerOf(artworkView);
    UIView *root = player.viewIfLoaded;
    if (root && list) {
        if (fill.superview != root || [root.subviews indexOfObject:fill] > [root.subviews indexOfObject:list]) {
            [root insertSubview:fill belowSubview:list];
            AULog(@"yandex: Fill in the player's view, under %@", NSStringFromClass(list.class));
        }
        if (!CGRectEqualToRect(fill.frame, root.bounds)) fill.frame = root.bounds;
    } else {
        Ivar ivar = class_getInstanceVariable(object_getClass(artworkView), "backgroundContainer");
        id background = ivar ? object_getIvar(artworkView, ivar) : nil;
        if (fill.superview != artworkView) {
            if ([background isKindOfClass:UIView.class] && [(UIView *)background superview] == artworkView) {
                [artworkView insertSubview:fill aboveSubview:background];
            } else {
                [artworkView insertSubview:fill atIndex:0];
            }
            AULog(@"yandex: Fill in the artwork view (no player view yet)");
        }
        CGRect frame = [artworkView convertRect:artworkView.window.bounds fromView:nil];
        if (!CGRectEqualToRect(fill.frame, frame)) fill.frame = frame;
    }
    UIImage *image = AUYandexArtwork(NULL, NULL, NULL);
    if (image) [fill setPicture:image];
    // The carousel's covers and the artwork view's own background and gradient give way: each drawn through an empty
    // mask (the app animates their alpha itself, on pause and on a new track; it leaves masks alone). Still there to be
    // swiped and tapped: a mask changes nothing of that.
    NSMutableArray<UIView *> *parts = [NSMutableArray array];
    if (carousel) [parts addObject:carousel];
    for (NSString *name in @[@"backgroundContainer", @"gradientOverlayView"]) {
        Ivar part = class_getInstanceVariable(object_getClass(artworkView), name.UTF8String);
        id view = part ? object_getIvar(artworkView, part) : nil;
        if ([view isKindOfClass:UIView.class]) [parts addObject:view];
    }
    for (UIView *view in parts) hideByMask(view);
    Ivar gradient = class_getInstanceVariable(object_getClass(artworkView), "gradientLayer");
    id gradientLayer = gradient ? object_getIvar(artworkView, gradient) : nil;
    if ([gradientLayer isKindOfClass:CALayer.class]) ((CALayer *)gradientLayer).hidden = YES;
}
