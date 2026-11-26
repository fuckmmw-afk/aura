// Yandex Music's yellow, white: every UIColor the app makes (by its components, by name from its asset catalogue, or
// as a dynamic colour for light and dark) passes here, and a strong yellow comes out white with its own alpha. Images,
// Lottie animations and SwiftUI's own colours (Color(red:green:blue:)) are not UIColors and keep theirs.
// Installed before the app's main(), so its palette is made through it; the switch takes effect at the next launch.
#import "AUYandexColors.h"
#import "AUCore.h"
#import <objc/runtime.h>

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


void AUYandexColorsInstall(void) {
    id value = [NSUserDefaults.standardUserDefaults objectForKey:AUKeyWhiteAccent];
    sOn = value ? [value boolValue] : YES;
    if (!sOn) return;
    Class cls = UIColor.class, meta = object_getClass(UIColor.class);

    typedef UIColor *(*RGBA)(id, SEL, CGFloat, CGFloat, CGFloat, CGFloat);
    {
        SEL sel = @selector(initWithRed:green:blue:alpha:);
        Method m = class_getInstanceMethod(cls, sel);
        __block RGBA orig = (RGBA)method_getImplementation(m);
        method_setImplementation(m, imp_implementationWithBlock(^UIColor *(id self, CGFloat r, CGFloat g, CGFloat b, CGFloat a) {
            if (yellowish(r, g, b)) r = g = b = 1;
            return orig(self, sel, r, g, b, a);
        }));
    }
    {
        SEL sel = @selector(colorWithRed:green:blue:alpha:);
        Method m = class_getInstanceMethod(meta, sel);
        __block RGBA orig = (RGBA)method_getImplementation(m);
        method_setImplementation(m, imp_implementationWithBlock(^UIColor *(id self, CGFloat r, CGFloat g, CGFloat b, CGFloat a) {
            if (yellowish(r, g, b)) r = g = b = 1;
            return orig(self, sel, r, g, b, a);
        }));
    }
    {
        SEL sel = @selector(initWithDisplayP3Red:green:blue:alpha:);
        Method m = class_getInstanceMethod(cls, sel);
        __block RGBA orig = (RGBA)method_getImplementation(m);
        method_setImplementation(m, imp_implementationWithBlock(^UIColor *(id self, CGFloat r, CGFloat g, CGFloat b, CGFloat a) {
            if (yellowish(r, g, b)) r = g = b = 1;
            return orig(self, sel, r, g, b, a);
        }));
    }
    {
        typedef UIColor *(*HSBA)(id, SEL, CGFloat, CGFloat, CGFloat, CGFloat);
        SEL sel = @selector(initWithHue:saturation:brightness:alpha:);
        Method m = class_getInstanceMethod(cls, sel);
        __block HSBA orig = (HSBA)method_getImplementation(m);
        method_setImplementation(m, imp_implementationWithBlock(^UIColor *(id self, CGFloat h, CGFloat s, CGFloat v, CGFloat a) {
            if (v >= 0.70 && s >= 0.45 && h * 360 >= 38 && h * 360 <= 64) {
                s = 0;
                v = 1;
            }
            return orig(self, sel, h, s, v, a);
        }));
    }
    {
        typedef UIColor *(*Dynamic)(id, SEL, UIColor * (^)(UITraitCollection *));
        SEL sel = @selector(initWithDynamicProvider:);
        Method m = class_getInstanceMethod(cls, sel);
        __block Dynamic orig = (Dynamic)method_getImplementation(m);
        method_setImplementation(m, imp_implementationWithBlock(^UIColor *(id self, UIColor * (^provider)(UITraitCollection *)) {
            UIColor * (^wrapped)(UITraitCollection *) = provider ? ^UIColor *(UITraitCollection *traits) {
                return whiteIfYellow(provider(traits));
            } : nil;
            return orig(self, sel, wrapped);
        }));
    }
    {
        typedef UIColor *(*Named)(id, SEL, NSString *, NSBundle *, UITraitCollection *);
        SEL sel = @selector(colorNamed:inBundle:compatibleWithTraitCollection:);
        Method m = class_getInstanceMethod(meta, sel);
        __block Named orig = (Named)method_getImplementation(m);
        method_setImplementation(m, imp_implementationWithBlock(^UIColor *(id self, NSString *name, NSBundle *bundle, UITraitCollection *traits) {
            UIColor *color = orig(self, sel, name, bundle, traits);
            if (!color) return color;
            // A catalogue colour may differ for light and dark: each look is checked as it is asked for.
            return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *asked) {
                return whiteIfYellow([color resolvedColorWithTraitCollection:asked]);
            }];
        }));
    }
    {
        SEL sel = @selector(systemYellowColor);
        Method m = class_getInstanceMethod(meta, sel);
        if (m) method_setImplementation(m, imp_implementationWithBlock(^UIColor *(id self) { return UIColor.whiteColor; }));
    }
}
