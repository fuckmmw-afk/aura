// Yandex Music's yellow, white: every UIColor the app makes (by its components, by name from its asset catalogue, or
// as a dynamic colour for light and dark) passes here, and a strong yellow comes out white with its own alpha. Images,
// Lottie animations and SwiftUI's own colours (Color(red:green:blue:)) are not UIColors and keep theirs.
// Installed before the app's main(), so its palette is made through it; the switch takes effect at the next launch.
#import "AUYandexColors.h"
#import "AUCore.h"
#import <objc/runtime.h>
#import <QuartzCore/QuartzCore.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import "Vendor/fishhook.h"

static BOOL yellowish(CGFloat r, CGFloat g, CGFloat b) {
    CGFloat max = MAX(r, MAX(g, b)), min = MIN(r, MIN(g, b));
    if (max < 0.70) return NO;
    CGFloat saturation = max > 0 ? (max - min) / max : 0;
    if (saturation < 0.45) return NO;
    // Hue in degrees; yellow is red and green both high, blue low.
    CGFloat delta = max - min, hue;
    if (max == r) hue = 60 * fmod((g - b) / delta, 6);
    else if (max == g) hue = 60 * ((b - r) / delta + 2);
    else hue = 60 * ((r - g) / delta + 4);
    if (hue < 0) hue += 360;
    return hue >= 38 && hue <= 64;
}

static UIColor *whiteIfYellow(UIColor *color) {
    CGFloat r, g, b, a;
    if (![color getRed:&r green:&g blue:&b alpha:&a]) return color;
    if (!yellowish(r, g, b)) return color;
    return [UIColor colorWithWhite:1 alpha:a];
}

static BOOL sOn;


// `block` in place of `sel` in `cls`, only when `cls` has its own: UIColor's inits run on its placeholder subclass.
static IMP swapOwn(Class cls, SEL sel, id (^make)(IMP orig)) {
    if (!cls) return NULL;
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    IMP orig = NULL;
    for (unsigned int i = 0; i < count; i++) {
        if (method_getName(methods[i]) == sel) {
            orig = method_getImplementation(methods[i]);
            method_setImplementation(methods[i], imp_implementationWithBlock(make(orig)));
            break;
        }
    }
    free(methods);
    return orig;
}

typedef UIColor *(*RGBA)(id, SEL, CGFloat, CGFloat, CGFloat, CGFloat);

static id rgbaBlock(SEL sel, IMP imp) {
    RGBA orig = (RGBA)imp;
    return ^UIColor *(id self, CGFloat r, CGFloat g, CGFloat b, CGFloat a) {
        if (yellowish(r, g, b)) r = g = b = 1;
        return orig(self, sel, r, g, b, a);
    };
}

static id hsbaBlock(SEL sel, IMP imp) {
    RGBA orig = (RGBA)imp;
    return ^UIColor *(id self, CGFloat h, CGFloat s, CGFloat v, CGFloat a) {
        if (v >= 0.70 && s >= 0.45 && h * 360 >= 38 && h * 360 <= 64) {
            s = 0;
            v = 1;
        }
        return orig(self, sel, h, s, v, a);
    };
}

static id dynamicBlock(SEL sel, IMP imp) {
    UIColor *(*orig)(id, SEL, id) = (UIColor * (*)(id, SEL, id))imp;
    return ^UIColor *(id self, UIColor * (^provider)(UITraitCollection *)) {
        UIColor * (^wrapped)(UITraitCollection *) = provider ? ^UIColor *(UITraitCollection *traits) {
            return whiteIfYellow(provider(traits));
        } : nil;
        return orig(self, sel, wrapped);
    };
}

#pragma mark - CGColor

// Colours made straight as CGColors (DivKit's layouts, Lottie, the app's own layers) in the app's own images.
static CGColorRef (*origCreate)(CGColorSpaceRef, const CGFloat *);
static CGColorRef (*origSRGB)(CGFloat, CGFloat, CGFloat, CGFloat);
static CGColorRef (*origGeneric)(CGFloat, CGFloat, CGFloat, CGFloat);

static CGColorRef whiteCreate(CGColorSpaceRef space, const CGFloat *components) {
    if (space && components && CGColorSpaceGetModel(space) == kCGColorSpaceModelRGB && CGColorSpaceGetNumberOfComponents(space) == 3
        && yellowish(components[0], components[1], components[2])) {
        CGFloat white[4] = {1, 1, 1, components[3]};
        return origCreate(space, white);
    }
    return origCreate(space, components);
}

static CGColorRef whiteSRGB(CGFloat r, CGFloat g, CGFloat b, CGFloat a) {
    if (yellowish(r, g, b)) r = g = b = 1;
    return origSRGB(r, g, b, a);
}

static CGColorRef whiteGeneric(CGFloat r, CGFloat g, CGFloat b, CGFloat a) {
    if (yellowish(r, g, b)) r = g = b = 1;
    return origGeneric(r, g, b, a);
}

// A yellow CGColor as white with its alpha (+1), or NULL when it is not yellow.
static CGColorRef whiteFor(CGColorRef color) {
    if (!color) return NULL;
    CGColorSpaceRef space = CGColorGetColorSpace(color);
    if (!space || CGColorSpaceGetModel(space) != kCGColorSpaceModelRGB || CGColorGetNumberOfComponents(color) < 4) return NULL;
    const CGFloat *c = CGColorGetComponents(color);
    if (!yellowish(c[0], c[1], c[2])) return NULL;
    CGFloat white[4] = {1, 1, 1, c[3]};
    return origCreate ? origCreate(space, white) : CGColorCreate(space, white);
}

typedef void (*SetColor)(id, SEL, CGColorRef);

static void swapLayerColor(Class cls, SEL sel) {
    swapOwn(cls, sel, ^id(IMP imp) {
        SetColor orig = (SetColor)imp;
        return ^(id self, CGColorRef color) {
            CGColorRef white = whiteFor(color);
            orig(self, sel, white ?: color);
            if (white) CGColorRelease(white);
        };
    });
}

static struct rebinding sColorRebindings[3];

static void addedImage(const struct mach_header *header, intptr_t slide) {
    Dl_info info;
    if (!dladdr(header, &info) || !info.dli_fname || !strstr(info.dli_fname, ".app/")) return;
    struct rebinding copy[3];
    memcpy(copy, sColorRebindings, sizeof(copy));
    for (int i = 0; i < 3; i++) copy[i].replaced = NULL;
    rebind_symbols_image((void *)header, slide, copy, 3);
}

void AUYandexColorsInstall(void) {
    id value = [NSUserDefaults.standardUserDefaults objectForKey:AUKeyWhiteAccent];
    sOn = value ? [value boolValue] : YES;
    if (!sOn) return;
    Class meta = object_getClass(UIColor.class);
    NSArray<Class> *classes = @[UIColor.class, NSClassFromString(@"UIPlaceholderColor") ?: UIColor.class];
    for (Class cls in [NSSet setWithArray:classes]) {
        SEL rgba = @selector(initWithRed:green:blue:alpha:), p3 = @selector(initWithDisplayP3Red:green:blue:alpha:);
        SEL hsba = @selector(initWithHue:saturation:brightness:alpha:), dynamic = @selector(initWithDynamicProvider:);
        swapOwn(cls, rgba, ^id(IMP orig) { return rgbaBlock(rgba, orig); });
        swapOwn(cls, p3, ^id(IMP orig) { return rgbaBlock(p3, orig); });
        swapOwn(cls, hsba, ^id(IMP orig) { return hsbaBlock(hsba, orig); });
        swapOwn(cls, dynamic, ^id(IMP orig) { return dynamicBlock(dynamic, orig); });
    }
    SEL classRGBA = @selector(colorWithRed:green:blue:alpha:);
    swapOwn(meta, classRGBA, ^id(IMP orig) { return rgbaBlock(classRGBA, orig); });
    SEL named = @selector(colorNamed:inBundle:compatibleWithTraitCollection:);
    swapOwn(meta, named, ^id(IMP imp) {
        UIColor *(*orig)(id, SEL, NSString *, NSBundle *, UITraitCollection *) = (UIColor * (*)(id, SEL, NSString *, NSBundle *, UITraitCollection *))imp;
        return ^UIColor *(id self, NSString *name, NSBundle *bundle, UITraitCollection *traits) {
            UIColor *color = orig(self, named, name, bundle, traits);
            if (!color) return color;
            // A catalogue colour may differ for light and dark: each look is checked as it is asked for.
            return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *asked) {
                return whiteIfYellow([color resolvedColorWithTraitCollection:asked]);
            }];
        };
    });
    SEL yellow = @selector(systemYellowColor);
    swapOwn(meta, yellow, ^id(IMP orig) { return ^UIColor *(id self) { return UIColor.whiteColor; }; });

    // What SwiftUI and Core Animation draw with, whoever made the colour: layers' fills, backgrounds and borders.
    swapLayerColor(CALayer.class, @selector(setBackgroundColor:));
    swapLayerColor(CALayer.class, @selector(setBorderColor:));
    swapLayerColor(CAShapeLayer.class, @selector(setFillColor:));
    swapLayerColor(CAShapeLayer.class, @selector(setStrokeColor:));

    origCreate = CGColorCreate;
    origSRGB = CGColorCreateSRGB;
    origGeneric = CGColorCreateGenericRGB;
    struct rebinding rebindings[3] = {
        {"CGColorCreate", (void *)whiteCreate, NULL},
        {"CGColorCreateSRGB", (void *)whiteSRGB, NULL},
        {"CGColorCreateGenericRGB", (void *)whiteGeneric, NULL},
    };
    memcpy(sColorRebindings, rebindings, sizeof(rebindings));
    _dyld_register_func_for_add_image(addedImage);
}
