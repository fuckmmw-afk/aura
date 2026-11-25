// The Mac harness: Aura's own pipeline code (Mac Catalyst build of Sources/Core, Features and the renderer) run on
// real covers, writing what each stage made as PNGs, so the effects can be looked at without a phone.
//     aura-harness <out dir> <cover.jpg>...
#import <UIKit/UIKit.h>
#import "Core/AUCore.h"
#import "Core/AUModelManager.h"
#import "Features/AUImage.h"
#import "Features/AUPalette.h"
#import "Features/AUVision.h"
#import "Features/AUScene.h"
#import "UI/AULockScreen.h"
#import "UI/AUParallaxRenderer.h"
#import <AVFoundation/AVFoundation.h>

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

// The app's look, on the CPU as the shader draws it: the canvas aspect-filled into `size`, zoomed for the moves, the
// background bent by its depth (AUSceneWarp, the lock clip's warp) and every object moved whole by its own depth.
static CGImageRef sceneFrame(AUScene *scene, CGPoint tilt, CGSize size) {
    size_t w = (size_t)size.width, h = (size_t)size.height;
    double reach = scene.plateReach, zoom = 1 + 2 * reach * AUSceneMotion + 0.006;
    double drawn = MAX(size.width, size.height) * zoom, motion = AUSceneMotion * drawn;
    double ox = (size.width - drawn) / 2, oy = (size.height - drawn) / 2;
    size_t margin = (size_t)ceil(reach * motion) + 2;
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGBitmapInfo info = kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big;
    CGContextRef base = CGBitmapContextCreate(NULL, w + 2 * margin, h + 2 * margin, 8, 0, space, info);
    CGContextRef c = CGBitmapContextCreate(NULL, w, h, 8, 0, space, info);
    CGColorSpaceRelease(space);
    CGContextSetInterpolationQuality(base, kCGInterpolationHigh);
    CGContextDrawImage(base, CGRectMake(ox + margin, oy + margin, drawn, drawn), scene.background.CGImage);
    float *factors = AUScenePlateFactors(scene, w, h, CGRectMake(ox, oy, drawn, drawn), 0);
    AUSceneWarp(CGBitmapContextGetData(c), CGBitmapContextGetBytesPerRow(c), w, h, CGBitmapContextGetData(base),
                CGBitmapContextGetBytesPerRow(base), margin, factors, CGPointMake(tilt.x * motion, tilt.y * motion));
    free(factors);
    CGContextRelease(base);
    for (AUSceneLayer *layer in scene.layers) {
        double m = [scene weightOf:layer] * motion;
        CGContextDrawImage(c, CGRectMake(ox + tilt.x * m, oy - tilt.y * m, drawn, drawn), layer.image.CGImage);
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
        BOOL ready = waitForModel(AUModelDepth) & waitForModel(AUModelUpscale) & waitForModel(AUModelInpaint);
        if (!ready) failures++;
        for (int a = 2; a < argc; a++) {
            NSString *path = @(argv[a]), *name = path.lastPathComponent.stringByDeletingPathExtension;
            printf("== %s\n", name.UTF8String);
            CGImageRef original = AUImageFromData([NSData dataWithContentsOfFile:path]);
            CGImageRef cover = AUImageNormalized(original, 1024);
            NSString *error = nil;
            double t = AUNowMs();
            CGImageRef depth = AUDepthMap(cover, &error);
            printf("  depth %.0f ms %s\n", AUNowMs() - t, depth ? "" : error.UTF8String);
            save(depth, [name stringByAppendingString:@"-1-depth.png"]);
            NSString *log = nil;
            t = AUNowMs();
            AUScene *scene = AUSceneBuild(cover, depth, NO, &log);
            double sceneMs = AUNowMs() - t;
            printf("  %s (%.0f ms in all)\n", log.UTF8String ?: "no scene", sceneMs);
            if (!scene || !scene.inpainted) failures++;
            save(scene.background.CGImage, [name stringByAppendingString:@"-2-background.png"]);
            save(scene.plateDepth.CGImage, [name stringByAppendingString:@"-2-plate-depth.png"]);
            for (NSUInteger i = 0; i < scene.layers.count; i++) {
                save(scene.layers[i].image.CGImage, [NSString stringWithFormat:@"%@-3-layer%lu.png", name, (unsigned long)i]);
            }
            if (scene) {
                for (int i = 0; i < 2; i++) {
                    CGPoint tilt = i ? CGPointMake(1, 0.6) : CGPointMake(-1, -0.3);
                    CGImageRef lock = AULockClipFrame(scene, CGSizeMake(896, 1200), i ? 0.125 : 0.625, YES);
                    save(lock, [NSString stringWithFormat:@"%@-8-lock-%d.png", name, i]);
                    if (lock) CGImageRelease(lock);
                    CGImageRef square = sceneFrame(scene, tilt, CGSizeMake(600, 600));
                    save(square, [NSString stringWithFormat:@"%@-4-cover-%d.png", name, i]);
                    if (square) CGImageRelease(square);
                    // The app's own shader (the background alone), to see it compiles and bends as the CPU copy does.
                    if ([AUParallaxRenderer supported]) {
                        AUParallaxRenderer *renderer = [AUParallaxRenderer new];
                        [renderer setColor:scene.background.CGImage depth:scene.plateDepth.CGImage];
                        renderer.center = scene.plateCenter;
                        renderer.limit = scene.plateLimit;
                        renderer.reach = AUSceneMotion;
                        renderer.zoom = 1 + 2 * scene.plateReach * AUSceneMotion + 0.006;
                        renderer.tilt = tilt;
                        CGImageRef gpu = [renderer renderImageWidth:600 height:600];
                        save(gpu, [NSString stringWithFormat:@"%@-4-cover-gpu-background-%d.png", name, i]);
                        if (gpu) CGImageRelease(gpu);
                    } else if (i == 0) {
                        printf("  no Metal device\n");
                    }
                    CGImageRef fill = sceneFrame(scene, tilt, CGSizeMake(402, 546));
                    save(fill, [NSString stringWithFormat:@"%@-5-fill-%d.png", name, i]);
                    if (fill) CGImageRelease(fill);
                }
                NSURL *clip = [NSURL fileURLWithPath:[outDir stringByAppendingPathComponent:[name stringByAppendingString:@"-9-lock.mp4"]]];
                t = AUNowMs();
                BOOL written = AULockClipWrite(clip, scene, CGSizeMake(896, 1200), YES);
                AVURLAsset *asset = [AVURLAsset assetWithURL:clip];
                AVAssetTrack *track = [asset tracksWithMediaType:AVMediaTypeVideo].firstObject;
                printf("  lock clip %s in %.0f ms: %.2f s, %.0fx%.0f\n", written ? "written" : "NOT written", AUNowMs() - t,
                       CMTimeGetSeconds(asset.duration), track.naturalSize.width, track.naturalSize.height);
                if (!written) failures++;
            }
            CGImageRef small = AUImageResized(cover, 300, 300);
            t = AUNowMs();
            CGImageRef up = AUUpscaled(small, 1024, &error);
            printf("  upscale 300 -> %zu px %.0f ms %s\n", up ? CGImageGetWidth(up) : 0, AUNowMs() - t, up ? "" : error.UTF8String);
            if (up) CGImageRelease(up);
            CGImageRelease(small);
            if (depth) CGImageRelease(depth);
            CGImageRelease(cover);
            CGImageRelease(original);
        }
        printf(failures ? "harness: %d failure(s)\n" : "harness ok\n", failures);
        return failures ? 1 : 0;
    }
}
