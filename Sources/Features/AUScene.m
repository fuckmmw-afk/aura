#import "AUScene.h"
#import "AUImage.h"

static NSString *const kVersion = @"scene-v1";

@implementation AUSceneLayer
@end

@implementation AUScene {
    NSMapTable<UIImage *, UIImage *> *_squares;
}

- (double)weightOf:(AUSceneLayer *)layer {
    double span = MAX(0.05, 1 - _backgroundDepth);
    double relative = MIN(1, MAX(0, (layer.depth - _backgroundDepth) / span));
    return 0.5 + 0.5 * relative;
}

- (UIImage *)squareOf:(UIImage *)image {
    if (!image.CGImage) return nil;
    if (!_squares) _squares = [NSMapTable weakToStrongObjectsMapTable];
    UIImage *cached = [_squares objectForKey:image];
    if (cached) return cached;
    CGImageRef cut = CGImageCreateWithImageInRect(image.CGImage, _square);
    if (!cut) return nil;
    UIImage *square = [UIImage imageWithCGImage:cut];
    CGImageRelease(cut);
    [_squares setObject:square forKey:image];
    return square;
}

- (BOOL)writeTo:(NSString *)folder {
    NSFileManager *files = NSFileManager.defaultManager;
    [files createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:nil];
    if (![AUJPEGData(_background.CGImage, 0.9) writeToFile:[folder stringByAppendingPathComponent:@"scene-background.jpg"] atomically:YES]) return NO;
    NSMutableArray *depths = [NSMutableArray array];
    for (NSUInteger i = 0; i < _layers.count; i++) {
        NSString *path = [folder stringByAppendingPathComponent:[NSString stringWithFormat:@"scene-layer-%lu.png", (unsigned long)i]];
        if (![AUPNGData(_layers[i].image.CGImage) writeToFile:path atomically:YES]) return NO;
        [depths addObject:@(_layers[i].depth)];
    }
    NSDictionary *plist = @{@"version": kVersion, @"square": @[@(_square.origin.x), @(_square.origin.y), @(_square.size.width), @(_square.size.height)],
                            @"depths": depths, @"backgroundDepth": @(_backgroundDepth), @"inpainted": @(_inpainted)};
    return [plist writeToFile:[folder stringByAppendingPathComponent:@"scene.plist"] atomically:YES];
}

+ (instancetype)readFrom:(NSString *)folder {
    NSDictionary *plist = [NSDictionary dictionaryWithContentsOfFile:[folder stringByAppendingPathComponent:@"scene.plist"]];
    if (![plist[@"version"] isEqual:kVersion]) return nil;
    NSArray *square = plist[@"square"];
    NSArray *depths = plist[@"depths"];
    if (![square isKindOfClass:NSArray.class] || square.count != 4 || ![depths isKindOfClass:NSArray.class]) return nil;
    CGImageRef background = AUImageFromData([NSData dataWithContentsOfFile:[folder stringByAppendingPathComponent:@"scene-background.jpg"]]);
    if (!background) return nil;
    AUScene *scene = [AUScene new];
    scene.background = [UIImage imageWithCGImage:background];
    CGImageRelease(background);
    scene.square = CGRectMake([square[0] doubleValue], [square[1] doubleValue], [square[2] doubleValue], [square[3] doubleValue]);
    scene.backgroundDepth = [plist[@"backgroundDepth"] doubleValue];
    scene.inpainted = [plist[@"inpainted"] boolValue];
    NSMutableArray *layers = [NSMutableArray array];
    for (NSUInteger i = 0; i < depths.count; i++) {
        CGImageRef image = AUImageFromData([NSData dataWithContentsOfFile:[folder stringByAppendingPathComponent:[NSString stringWithFormat:@"scene-layer-%lu.png", (unsigned long)i]]]);
        if (!image) return nil;
        AUSceneLayer *layer = [AUSceneLayer new];
        layer.image = [UIImage imageWithCGImage:image];
        layer.depth = [depths[i] doubleValue];
        CGImageRelease(image);
        [layers addObject:layer];
    }
    scene.layers = layers;
    return scene;
}

@end
