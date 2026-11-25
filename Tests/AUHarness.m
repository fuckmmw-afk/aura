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
#import "Features/AUScene3D.h"
#import "UI/AUSceneRenderer.h"
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

// The app's look, on the CPU as the shader draws it (AUScene3D): the square aspect-filled into `size`, zoomed for
// the swing, the background and every object by its own relief, seen by the camera at `tilt`.
static CGImageRef sceneFrame(AUScene *scene, CGPoint tilt, CGSize size) {
    size_t w = (size_t)size.width, h = (size_t)size.height;
    double drawn = MAX(size.width, size.height) * AUSceneZoom(1);
    CGRect square = CGRectMake((size.width - drawn) / 2, (size.height - drawn) / 2, drawn, drawn);
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGBitmapInfo info = kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big;
    size_t side = CGImageGetWidth(scene.background.CGImage);
    CGContextRef back = CGBitmapContextCreate(NULL, side, side, 8, 0, space, info);
    CGContextRef c = CGBitmapContextCreate(NULL, w, h, 8, 0, space, info);
    CGContextDrawImage(back, CGRectMake(0, 0, side, side), scene.background.CGImage);
    AUCamera camera = AUSceneCamera(scene, tilt, 1);
    AUSceneSource source = {CGBitmapContextGetData(back), CGBitmapContextGetBytesPerRow(back), side, side,
                            CGRectMake(0, 0, side, side), NO, 0, YES, CGRectNull};
    AUSceneDraw3D(CGBitmapContextGetData(c), CGBitmapContextGetBytesPerRow(c), w, h, square, scene, camera, source);
    CGContextRelease(back);
    for (AUSceneLayer *layer in scene.layers) {
        CGContextRef o = CGBitmapContextCreate(NULL, side, side, 8, 0, space, info);
        CGContextDrawImage(o, CGRectMake(0, 0, side, side), layer.image.CGImage);
        AUSceneSource object = {CGBitmapContextGetData(o), CGBitmapContextGetBytesPerRow(o), side, side,
                                CGRectMake(0, 0, side, side), YES, layer.depth, NO,
                                AUSceneAlphaBox(CGBitmapContextGetData(o), CGBitmapContextGetBytesPerRow(o), side), layer.relief};
        AUSceneDraw3D(CGBitmapContextGetData(c), CGBitmapContextGetBytesPerRow(c), w, h, square, scene, camera, object);
        CGContextRelease(o);
    }
    CGColorSpaceRelease(space);
    CGImageRef out = CGBitmapContextCreateImage(c);
    CGContextRelease(c);
    return out;
}

// Fill as the app lays it out: the screen (402 x 874 pt), the cover across its width x1.12 from the top and the room
// painted below it, everything seen by the camera (no blur or fade: those are Core Animation's in the app).
static CGImageRef fillFrame(AUScene *scene, CGPoint tilt, CGSize size) {
    if (!scene.tall) return NULL;
    size_t w = (size_t)size.width, h = (size_t)size.height;
    double side0 = size.width * 1.12, drawn = side0 * AUSceneZoom(1);
    CGRect square = CGRectMake((size.width - drawn) / 2, (side0 - drawn) / 2, drawn, drawn);
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGBitmapInfo info = kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big;
    size_t side = CGImageGetWidth(scene.tall.CGImage), high = CGImageGetHeight(scene.tall.CGImage);
    CGContextRef back = CGBitmapContextCreate(NULL, side, high, 8, 0, space, info);
    CGContextRef c = CGBitmapContextCreate(NULL, w, h, 8, 0, space, info);
    CGContextDrawImage(back, CGRectMake(0, 0, side, high), scene.tall.CGImage);
    AUCamera camera = AUSceneCamera(scene, tilt, 1);
    AUSceneSource source = {CGBitmapContextGetData(back), CGBitmapContextGetBytesPerRow(back), side, high,
                            CGRectMake(0, 0, side, side), NO, 0, NO, CGRectNull};
    AUSceneDraw3D(CGBitmapContextGetData(c), CGBitmapContextGetBytesPerRow(c), w, h, square, scene, camera, source);
    CGContextRelease(back);
    for (AUSceneLayer *layer in scene.layers) {
        CGContextRef o = CGBitmapContextCreate(NULL, side, side, 8, 0, space, info);
        CGContextDrawImage(o, CGRectMake(0, 0, side, side), layer.image.CGImage);
        AUSceneSource object = {CGBitmapContextGetData(o), CGBitmapContextGetBytesPerRow(o), side, side,
                                CGRectMake(0, 0, side, side), YES, layer.depth, NO,
                                AUSceneAlphaBox(CGBitmapContextGetData(o), CGBitmapContextGetBytesPerRow(o), side), layer.relief};
        AUSceneDraw3D(CGBitmapContextGetData(c), CGBitmapContextGetBytesPerRow(c), w, h, square, scene, camera, object);
        CGContextRelease(o);
    }
    CGColorSpaceRelease(space);
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
        BOOL ready = waitForModel(AUModelDepth) & waitForModel(AUModelUpscale) & waitForModel(AUModelInpaint)
            & waitForModel(AUModelSamEncoder) & waitForModel(AUModelSamPrompt) & waitForModel(AUModelSamDecoder);
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
            save(scene.tall.CGImage, [name stringByAppendingString:@"-2-tall.png"]);
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
                    // The app's own shader: the same scene on Metal, to see it compiles and agrees with the CPU copy.
                    if ([AUSceneRenderer supported]) {
                        AUSceneRenderer *renderer = [AUSceneRenderer new];
                        [renderer setScene:scene tall:NO];
                        renderer.zoom = AUSceneZoom(1);
                        renderer.tilt = tilt;
                        CGImageRef gpu = nil;
                        for (int wait = 0; wait < 50 && !(gpu = [renderer renderImageWidth:600 height:600]); wait++) {
                            [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
                        }
                        save(gpu, [NSString stringWithFormat:@"%@-4-cover-gpu-%d.png", name, i]);
                        if (gpu) CGImageRelease(gpu);
                    } else if (i == 0) {
                        printf("  no Metal device\n");
                    }
                    CGImageRef fill = fillFrame(scene, tilt, CGSizeMake(402, 874));
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
