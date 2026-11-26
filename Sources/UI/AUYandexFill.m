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
    CGSize _composedFor;
    CGFloat _sideFor;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.userInteractionEnabled = NO;
    self.backgroundColor = UIColor.clearColor;
    _fill = [CALayer layer];
    _fill.actions = noActions();
    _fill.masksToBounds = YES;
    _fill.contentsGravity = kCAGravityResize;
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
// the cover across the width at the top, over a blurred copy of itself that fills the rest.
- (void)compose {
    UIImage *image = _shown;
    CGSize size = _fill.bounds.size;
    if (!image.CGImage || size.width < 1 || size.height < 1) return;
    _composedFor = size;
    CGFloat side = size.width * AUTune(@"fillCrop");
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    format.opaque = YES;
    format.scale = MIN(2, UIScreen.mainScreen.scale);
    CGImageRef soft = blurredCopy(image);
    UIImage *made = [[[UIGraphicsImageRenderer alloc] initWithSize:size format:format] imageWithActions:^(UIGraphicsImageRendererContext *context) {
        CGContextRef c = context.CGContext;
        if (soft) {
            // Aspect fill, the image flipped upright for CGContextDrawImage.
            CGFloat s = MAX(size.width, size.height);
            CGContextSaveGState(c);
            CGContextTranslateCTM(c, 0, size.height);
            CGContextScaleCTM(c, 1, -1);
            CGContextDrawImage(c, CGRectMake((size.width - s) / 2, (size.height - s) / 2, s, s), soft);
            CGContextRestoreGState(c);
        }
        [image drawInRect:CGRectMake((size.width - side) / 2, 0, side, side)];
    }];
    if (soft) CGImageRelease(soft);
    _fill.contents = (__bridge id)made.CGImage;
}

- (void)setPicture:(UIImage *)image {
    if (image == _shown) return;
    _shown = image;
    [self compose];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGSize size = self.bounds.size;
    CGFloat high = round(size.height * 0.625);
    CGFloat side = size.width * AUTune(@"fillCrop");
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _fill.frame = CGRectMake(0, 0, size.width, high);
    if (!CGSizeEqualToSize(_composedFor, _fill.bounds.size) || side != _sideFor) {
        _sideFor = side;
        [self compose];
    }
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

static void restoreCells(void) {
    for (UIView *view in sHidden) view.alpha = 1;
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
    // Under the carousel, over the artwork view's own background (its `backgroundContainer`, when it has one).
    Ivar ivar = class_getInstanceVariable(object_getClass(artworkView), "backgroundContainer");
    id background = ivar ? object_getIvar(artworkView, ivar) : nil;
    UIView *host = artworkView;
    if (fill.superview != host) {
        if ([background isKindOfClass:UIView.class] && [(UIView *)background superview] == artworkView) {
            [artworkView insertSubview:fill aboveSubview:background];
        } else {
            [artworkView insertSubview:fill atIndex:0];
        }
        AULog(@"yandex: Fill in %@ (%@), %@", NSStringFromClass(artworkView.class),
              background ? @"over its backgroundContainer" : @"at the bottom", artworkView.clipsToBounds ? @"clipped" : @"unclipped");
    }
    // The whole window, wherever the artwork view lies in it.
    CGRect window = artworkView.window.bounds;
    CGRect frame = [artworkView convertRect:window fromView:nil];
    if (!CGRectEqualToRect(fill.frame, frame)) fill.frame = frame;
    UIImage *image = AUYandexArtwork(NULL, NULL, NULL);
    if (image) [fill setPicture:image];
    // The carousel's covers give way (still there to be swiped).
    for (UICollectionViewCell *cell in carousel.visibleCells) {
        UIView *content = cell.contentView;
        if (content.alpha != 0) {
            content.alpha = 0;
            [sHidden addObject:content];
        }
    }
}
