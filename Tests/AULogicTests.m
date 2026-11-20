// Mac logic tests: the palette's k-means, the upscale tiling, the manifest checks and the picture keys.
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import "Features/AUPalette.h"
#import "Features/AUImage.h"

#import "Core/AUManifest.h"

static int failures = 0;
#define CHECK(cond, ...) do { if (!(cond)) { failures++; printf("FAIL %s:%d: ", __FILE__, __LINE__); printf(__VA_ARGS__); printf("\n"); } } while (0)

static CGImageRef blocks(int w, int h, void (^paint)(CGContextRef)) {
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef c = CGBitmapContextCreate(NULL, w, h, 8, 0, space, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(space);
    paint(c);
    CGImageRef image = CGBitmapContextCreateImage(c);
    CGContextRelease(c);
    return image;
}

static void testPalette(void) {
    // 70% dark navy, 25% gray, 5% vivid orange: the accent must be the orange, the dominant the navy.
    CGImageRef image = blocks(200, 200, ^(CGContextRef c) {
        CGContextSetRGBFillColor(c, 0.05, 0.07, 0.25, 1);
        CGContextFillRect(c, CGRectMake(0, 0, 200, 140));
        CGContextSetRGBFillColor(c, 0.5, 0.5, 0.5, 1);
        CGContextFillRect(c, CGRectMake(0, 140, 200, 50));
        CGContextSetRGBFillColor(c, 1.0, 0.45, 0.05, 1);
        CGContextFillRect(c, CGRectMake(0, 190, 200, 10));
    });
    AUPalette *p = [AUPalette paletteForImage:image clusters:5];
    CGImageRelease(image);
    CHECK(p != nil, "no palette");
    CHECK(fabsf(p.dominant.b - 0.25f) < 0.03f && p.dominant.r < 0.1f, "dominant %.2f %.2f %.2f", p.dominant.r, p.dominant.g, p.dominant.b);
    CHECK(p.accent.r > 0.9f && p.accent.b < 0.15f, "accent %.2f %.2f %.2f", p.accent.r, p.accent.g, p.accent.b);
    CHECK(!p.gray, "colorful cover read as gray");
    CHECK(fabs(p.weights.firstObject.doubleValue - 0.70) < 0.03, "dominant weight %.3f", p.weights.firstObject.doubleValue);
    AUPalette *again = [AUPalette paletteFromPlist:p.plist];
    CHECK(again && fabsf(again.accent.r - p.accent.r) < 1e-5f, "plist round trip");

    CGImageRef gray = blocks(64, 64, ^(CGContextRef c) {
        CGContextSetRGBFillColor(c, 0.2, 0.2, 0.2, 1);
        CGContextFillRect(c, CGRectMake(0, 0, 64, 32));
        CGContextSetRGBFillColor(c, 0.85, 0.85, 0.85, 1);
        CGContextFillRect(c, CGRectMake(0, 32, 64, 32));
    });
    AUPalette *g = [AUPalette paletteForImage:gray clusters:5];
    CGImageRelease(gray);
    CHECK(g.gray, "black and white cover not gray");

    float h, s, v;
    AURGBToHSV((AURGB){1, 0.5f, 0}, &h, &s, &v);
    AURGB back = AUHSVToRGB(h, s, v);
    CHECK(fabsf(back.r - 1) < 1e-4f && fabsf(back.g - 0.5f) < 1e-4f && back.b < 1e-4f, "hsv round trip");
}

static CGRect rectAt(NSArray<NSValue *> *tiles, NSUInteger i) {
    CGRect r;
    [tiles[i] getValue:&r size:sizeof(r)];
    return r;
}

static void testTiles(void) {
    NSArray *one = AUTiles(128, 128, 128, 8);
    CHECK(one.count == 1, "128 is one tile, got %lu", (unsigned long)one.count);
    NSArray *t = AUTiles(300, 300, 128, 8);
    CHECK(t.count == 9, "300 px is 3x3 tiles, got %lu", (unsigned long)t.count);
    CGRect last = rectAt(t, t.count - 1);
    CHECK(CGRectGetMaxX(last) == 300 && CGRectGetMaxY(last) == 300, "last tile flush with the edge");
    // Every pixel covered, each neighbour overlapping by at least 8.
    for (size_t w = 129; w < 700; w += 37) {
        NSArray *tiles = AUTiles(w, 200, 128, 8);
        for (size_t x = 0; x < w; x++) {
            BOOL covered = NO;
            for (NSUInteger i = 0; i < tiles.count; i++) {
                CGRect r = rectAt(tiles, i);
                if (x >= r.origin.x && x < CGRectGetMaxX(r)) covered = YES;
            }
            CHECK(covered, "x %zu of %zu not covered", x, w);
        }
        double previousEnd = -1;
        for (NSUInteger i = 0; i < tiles.count; i++) {
            CGRect r = rectAt(tiles, i);
            if (r.origin.y != 0) continue;
            if (previousEnd >= 0) CHECK(previousEnd - r.origin.x >= 8, "overlap %.0f at w %zu", previousEnd - r.origin.x, w);
            previousEnd = CGRectGetMaxX(r);
        }
    }
    NSArray *narrow = AUTiles(90, 300, 128, 8);
    CHECK(rectAt(narrow, 0).size.width == 90, "a narrow picture's tile is its width");
}

static void testManifest(void) {
    NSString *good = @"{\"id\":\"depth-v2s-p8\",\"version\":1,\"package\":\"D.mlpackage\",\"files\":["
        "{\"path\":\"D.mlpackage/Manifest.json\",\"size\":617,\"sha256\":\"0000000000000000000000000000000000000000000000000000000000000000\"},"
        "{\"path\":\"D.mlpackage/Data/w.bin\",\"size\":1000,\"sha256\":\"1111111111111111111111111111111111111111111111111111111111111111\"}]}";
    NSString *error = nil;
    AUManifest *m = [AUManifest manifestWithData:[good dataUsingEncoding:NSUTF8StringEncoding] error:&error];
    CHECK(m && m.files.count == 2 && m.size == 1617 && m.version == 1, "good manifest: %s", error.UTF8String);
    NSArray *bad = @[
        @"{\"id\":\"x\",\"version\":1,\"package\":\"D.mlpackage\",\"files\":[{\"path\":\"D.mlpackage/../../evil\",\"size\":1,\"sha256\":\"0000000000000000000000000000000000000000000000000000000000000000\"}]}",
        @"{\"id\":\"x\",\"version\":1,\"package\":\"D.mlpackage\",\"files\":[{\"path\":\"/etc/passwd\",\"size\":1,\"sha256\":\"0000000000000000000000000000000000000000000000000000000000000000\"}]}",
        @"{\"id\":\"x\",\"version\":1,\"package\":\"D.mlpackage\",\"files\":[{\"path\":\"Other/file\",\"size\":1,\"sha256\":\"0000000000000000000000000000000000000000000000000000000000000000\"}]}",
        @"{\"id\":\"x\",\"version\":1,\"package\":\"D.mlpackage\",\"files\":[{\"path\":\"D.mlpackage/a\",\"size\":1,\"sha256\":\"short\"}]}",
        @"{\"id\":\"x\",\"version\":1,\"package\":\"D.zip\",\"files\":[]}",
        @"[1,2,3]",
    ];
    for (NSString *json in bad) {
        CHECK([AUManifest manifestWithData:[json dataUsingEncoding:NSUTF8StringEncoding] error:nil] == nil, "accepted bad manifest %s", json.UTF8String);
    }
}

static void testKeys(void) {
    BOOL exact = NO;
    CHECK([AUPictureKeyFromIdentity(@"spotify:image:ab67616d#exact", &exact) isEqualToString:@"spotify:image:ab67616d"] && exact, "exact key");
    CHECK([AUPictureKeyFromIdentity(@"spotify:image:ab67616d#12", &exact) isEqualToString:@"spotify:image:ab67616d"] && !exact, "serial key");
    CHECK([AUPictureKeyFromIdentity(@"custom:spotify:track:1:cover.jpg", &exact) isEqualToString:@"custom:spotify:track:1:cover.jpg"] && !exact, "no suffix");
}

int main(void) {
    @autoreleasepool {
        testPalette();
        testTiles();
        testManifest();
        testKeys();
    }
    if (failures) {
        printf("%d check(s) failed\n", failures);
        return 1;
    }
    printf("all logic tests passed\n");
    return 0;
}
