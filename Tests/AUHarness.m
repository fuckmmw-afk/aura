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

// The cover view's look: the scene's square, the objects over it moved by the tilt (no step-out, no shadow).
static CGImageRef squareFrame(AUScene *scene, CGPoint tilt, size_t side) {
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef c = CGBitmapContextCreate(NULL, side, side, 8, 0, space, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(space);
    double zoom = 1 + 2.2 * 0.25 * 0.04, drawn = side * zoom, off = (side - drawn) / 2, s = 0.04 * drawn;
    CGImageRef back = [scene squareOf:scene.background].CGImage;
    CGContextDrawImage(c, CGRectMake(off - tilt.x * 0.25 * s, off + tilt.y * 0.25 * s, drawn, drawn), back);
    for (AUSceneLayer *layer in scene.layers) {
        double w = [scene weightOf:layer] * s;
        CGContextDrawImage(c, CGRectMake(off + tilt.x * w, off - tilt.y * w, drawn, drawn), [scene squareOf:layer.image].CGImage);
    }
    CGImageRef out = CGBitmapContextCreateImage(c);
    CGContextRelease(c);
    return out;
}

// Fill's look: the square aspect-filled into 402 x 546 as Taurus fills it, the objects over it by the tilt.
static CGImageRef fillFrame(AUScene *scene, CGPoint tilt, CGSize size) {
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef c = CGBitmapContextCreate(NULL, (size_t)size.width, (size_t)size.height, 8, 0, space, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(space);
    double zoom = 1 + 2.2 * 0.25 * 0.04, drawn = MAX(size.width, size.height) * zoom, s = 0.04 * drawn;
    double ox = (size.width - drawn) / 2, oy = (size.height - drawn) / 2;
    CGContextDrawImage(c, CGRectMake(ox - tilt.x * 0.25 * s, oy + tilt.y * 0.25 * s, drawn, drawn), scene.background.CGImage);
    for (AUSceneLayer *layer in scene.layers) {
        double w = [scene weightOf:layer] * s;
        CGContextDrawImage(c, CGRectMake(ox + tilt.x * w, oy - tilt.y * w, drawn, drawn), layer.image.CGImage);
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
            for (NSUInteger i = 0; i < scene.layers.count; i++) {
                save(scene.layers[i].image.CGImage, [NSString stringWithFormat:@"%@-3-layer%lu.png", name, (unsigned long)i]);
            }
            if (scene) {
                for (int i = 0; i < 2; i++) {
                    CGPoint tilt = i ? CGPointMake(1, 0.6) : CGPointMake(-1, -0.3);
                    CGImageRef lock = AULockClipFrame(scene, CGSizeMake(896, 1200), i ? 0.125 : 0.625, YES);
                    save(lock, [NSString stringWithFormat:@"%@-8-lock-%d.png", name, i]);
                    if (lock) CGImageRelease(lock);
                    CGImageRef square = squareFrame(scene, tilt, 600);
                    save(square, [NSString stringWithFormat:@"%@-4-cover-%d.png", name, i]);
                    if (square) CGImageRelease(square);
                    CGImageRef fill = fillFrame(scene, tilt, CGSizeMake(402, 546));
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
