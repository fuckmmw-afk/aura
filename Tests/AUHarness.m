// The Mac harness: Aura's own pipeline code (Mac Catalyst build of Sources/Core, Features and the renderer) run on
// real covers, writing what each stage made as PNGs, so the effects can be looked at without a phone.
//     aura-harness <out dir> <cover.jpg>...
#import <UIKit/UIKit.h>
#import "Core/AUCore.h"
#import "Core/AUModelManager.h"
#import "Features/AUImage.h"
#import "Features/AUPalette.h"
#import "Features/AUVision.h"
#import "UI/AUParallaxRenderer.h"

static NSString *outDir;

static void save(CGImageRef image, NSString *name) {
    if (!image) {
        printf("  (no %s)\n", name.UTF8String);
        return;
    }
    [AUPNGData(image) writeToFile:[outDir stringByAppendingPathComponent:name] atomically:YES];
}

static BOOL waitForModel(NSString *modelID) {
    [AUModelManager.shared ensure:modelID];
    for (int i = 0; i < 600; i++) {
        AUModelState state = [AUModelManager.shared stateOf:modelID];
        if (state == AUModelReady) return YES;
        if (state == AUModelFailed) {
            printf("model %s failed: %s\n", modelID.UTF8String, [AUModelManager.shared lastErrorOf:modelID].UTF8String);
            return NO;
        }
        [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.2]];
    }
    return NO;
}

// What the cover mode shows: the renderer's picture with the subject over it, scaled 1.07 from its foot and moved.
static CGImageRef composite(CGImageRef base, CGImageRef subject, CGPoint tilt, size_t side) {
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    size_t canvas = side + side / 5;
    CGContextRef c = CGBitmapContextCreate(NULL, canvas, canvas, 8, 0, space, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(space);
    CGContextSetRGBFillColor(c, 0.04, 0.04, 0.06, 1);
    CGContextFillRect(c, CGRectMake(0, 0, canvas, canvas));
    CGFloat margin = (canvas - side) / 2.0;
    CGContextDrawImage(c, CGRectMake(margin, margin, side, side), base);
    if (subject) {
        CGFloat scale = 1.07, shift = 0.045 * 0.55 * side;
        CGFloat w = side * scale;
        CGRect r = CGRectMake(margin + (side - w) / 2 + tilt.x * shift, margin - tilt.y * shift, w, w);
        CGContextSetShadowWithColor(c, CGSizeMake(0, -8), 14, [UIColor colorWithWhite:0 alpha:0.45].CGColor);
        CGContextDrawImage(c, r, subject);
    }
    CGImageRef out = CGBitmapContextCreateImage(c);
    CGContextRelease(c);
    return out;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 3) {
            printf("usage: aura-harness <out dir> <cover>...\n");
            return 2;
        }
        outDir = @(argv[1]);
        [NSFileManager.defaultManager createDirectoryAtPath:outDir withIntermediateDirectories:YES attributes:nil error:nil];
        int failures = 0;
        BOOL depthModel = waitForModel(AUModelDepth), upscaleModel = waitForModel(AUModelUpscale);
        if (!depthModel || !upscaleModel) failures++;
        for (int a = 2; a < argc; a++) {
            NSString *path = @(argv[a]), *name = path.lastPathComponent.stringByDeletingPathExtension;
            printf("== %s\n", name.UTF8String);
            CGImageRef original = AUImageFromData([NSData dataWithContentsOfFile:path]);
            CGImageRef cover = AUImageNormalized(original, 1024);
            double t = AUNowMs();
            AUPalette *palette = [AUPalette paletteForImage:cover clusters:5];
            AURGB c = palette.accent;
            printf("  palette %.1f ms, accent #%02X%02X%02X, gray %d\n", AUNowMs() - t, (int)(c.r * 255), (int)(c.g * 255), (int)(c.b * 255), palette.gray);
            NSString *error = nil;
            t = AUNowMs();
            CGImageRef depth = AUDepthMap(cover, &error);
            printf("  depth %.1f ms %s\n", AUNowMs() - t, depth ? "" : error.UTF8String);
            if (!depth) failures++;
            save(depth, [name stringByAppendingString:@"-1-depth.png"]);
            t = AUNowMs();
            AUCutoutResult cut = AUCutoutSubject(cover, NO, &error);
            printf("  cutout %.1f ms, coverage %.0f%% %s\n", AUNowMs() - t, cut.coverage * 100, cut.cutout ? "" : error.UTF8String);
            save(cut.cutout, [name stringByAppendingString:@"-2-cutout.png"]);
            save(cut.background, [name stringByAppendingString:@"-3-background.png"]);
            if (cut.background) {
                // The background must keep the cover's colors: its mean brightness near the cover's, not white.
                AUPalette *bg = [AUPalette paletteForImage:cut.background clusters:3];
                AURGB d = bg.dominant;
                float lb = 0.2126f * d.r + 0.7152f * d.g + 0.0722f * d.b, lc = 0.2126f * palette.dominant.r + 0.7152f * palette.dominant.g + 0.0722f * palette.dominant.b;
                printf("  background dominant luminance %.2f vs cover %.2f\n", lb, lc);
                if (fabsf(lb - lc) > 0.25f) {
                    printf("  FAIL: the background lost the cover's colors\n");
                    failures++;
                }
            }
            AUParallaxRenderer *renderer = [AUParallaxRenderer new];
            [renderer setColor:cut.background ?: cover depth:depth];
            renderer.zoom = 1.06;
            renderer.strength = 0.045;
            CGPoint tilts[3] = {{-1, 0}, {0, 0}, {1, 0.6}};
            for (int i = 0; i < 3; i++) {
                renderer.tilt = tilts[i];
                CGImageRef frame = [renderer renderImageWidth:600 height:600];
                CGImageRef shot = frame ? composite(frame, cut.cutout, tilts[i], 600) : NULL;
                save(shot, [NSString stringWithFormat:@"%@-4-cover-tilt%d.png", name, i]);
                if (frame) CGImageRelease(frame);
                if (shot) CGImageRelease(shot);
                // Fill: the same picture aspect-filled into the top of a 402 x 874 screen (62.5%: 402 x 546).
                CGImageRef fill = [renderer renderImageWidth:402 height:546];
                save(fill, [NSString stringWithFormat:@"%@-5-fill-tilt%d.png", name, i]);
                if (fill) CGImageRelease(fill);
            }
            t = AUNowMs();
            [renderer setColor:cover depth:depth];
            renderer.tilt = CGPointMake(1, 0);
            for (int i = 0; i < 20; i++) {
                CGImageRef frame = [renderer renderImageWidth:1062 height:1062];
                if (frame) CGImageRelease(frame);
            }
            printf("  render 1062 px: %.1f ms a frame (incl. readback)\n", (AUNowMs() - t) / 20);
            CGImageRef small = AUImageResized(cover, 300, 300);
            t = AUNowMs();
            CGImageRef up = AUUpscaled(small, 1024, &error);
            printf("  upscale 300 -> %zu px %.1f ms %s\n", up ? CGImageGetWidth(up) : 0, AUNowMs() - t, up ? "" : error.UTF8String);
            if (!up) failures++;
            save(small, [name stringByAppendingString:@"-6-small300.png"]);
            save(up, [name stringByAppendingString:@"-7-upscaled.png"]);
            AUCutoutResultRelease(&cut);
            if (depth) CGImageRelease(depth);
            if (up) CGImageRelease(up);
            CGImageRelease(small);
            CGImageRelease(cover);
            CGImageRelease(original);
        }
        printf(failures ? "harness: %d failure(s)\n" : "harness ok\n", failures);
        return failures ? 1 : 0;
    }
}
