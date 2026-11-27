#import "AUScene.h"
#import "AUImage.h"
#import "Core/AUTune.h"

static NSString *const kVersion = @"scene-v7";

@implementation AUSceneLayer
- (instancetype)init {
    if ((self = [super init])) _relief = 1;
    return self;
}
@end

const double AUSceneMotion = 0.08;
static const double kPlateLimit = 0.6, kObjectLeast = 0.3;

@implementation AUScene {
    NSMapTable<UIImage *, UIImage *> *_squares;
    NSData *_plateBytes;
    size_t _plateSide, _plateHigh;
    double _plateReach;
    BOOL _plateRead;
    double _plateLow;
    NSData *_rawBytes;
    size_t _rawSide;
    BOOL _rawRead;
    NSData *_frontBytes;
    size_t _frontSide, _frontHigh;
    BOOL _frontRead;
}

- (BOOL)solid { return _front.CGImage && _frontDepth.CGImage; }

- (void)setFrontDepth:(UIImage *)frontDepth {
    _frontDepth = frontDepth;
    _frontRead = NO;
    _frontBytes = nil;
}

- (void)readFront {
    if (_frontRead) return;
    _frontRead = YES;
    CGImageRef image = _frontDepth.CGImage;
    if (!image) return;
    size_t side = CGImageGetWidth(image), high = CGImageGetHeight(image);
    if (side < 2 || high < 2 || side > 1024 || high > 2048) return;
    NSMutableData *bytes = [NSMutableData dataWithLength:side * high];
    CGColorSpaceRef gray = CGColorSpaceCreateDeviceGray();
    CGContextRef c = CGBitmapContextCreate(bytes.mutableBytes, side, high, 8, side, gray, (CGBitmapInfo)kCGImageAlphaNone);
    CGColorSpaceRelease(gray);
    if (!c) return;
    // Nearest: the snapped edges must stay steps, not ramps.
    CGContextSetInterpolationQuality(c, kCGInterpolationNone);
    CGContextDrawImage(c, CGRectMake(0, 0, side, high), image);
    CGContextRelease(c);
    _frontBytes = bytes;
    _frontSide = side;
    _frontHigh = high;
}

- (NSData *)frontBytes { [self readFront]; return _frontBytes; }
- (size_t)frontSide { [self readFront]; return _frontSide; }
- (size_t)frontHigh { [self readFront]; return _frontHigh; }

- (double)plateCenter { return _backgroundDepth; }
- (BOOL)complete { return _inpainted && _segmented; }

- (instancetype)init {
    if ((self = [super init])) {
        _styleSwing = _styleDeep = _styleRelief = 1;
        _tearJump = 0.07;
    }
    return self;
}
- (double)tallness { return _tall && _tallness >= 1 ? _tallness : 1; }
- (double)tallTop { return _tall ? MAX(0.0, _tallTop) : 0; }
- (double)plateLimit { return kPlateLimit; }

- (double)plateFactorOf:(double)depth {
    return MAX(-kPlateLimit, MIN(kPlateLimit, (depth - _backgroundDepth) * 2));
}

- (double)weightOf:(AUSceneLayer *)layer {
    return MAX(kObjectLeast, MIN(1.0, (layer.depth - _backgroundDepth) * 2));
}

- (void)setPlateDepth:(UIImage *)plateDepth {
    _plateDepth = plateDepth;
    _plateRead = NO;
    _plateBytes = nil;
}

static NSData *grayBytes(CGImageRef image, size_t *outSide) {
    if (!image) return nil;
    size_t side = MAX(CGImageGetWidth(image), CGImageGetHeight(image));
    if (side < 2 || side > 1024) return nil;
    NSMutableData *bytes = [NSMutableData dataWithLength:side * side];
    CGColorSpaceRef gray = CGColorSpaceCreateDeviceGray();
    CGContextRef c = CGBitmapContextCreate(bytes.mutableBytes, side, side, 8, side, gray, (CGBitmapInfo)kCGImageAlphaNone);
    CGColorSpaceRelease(gray);
    if (!c) return nil;
    CGContextSetInterpolationQuality(c, kCGInterpolationHigh);
    CGContextDrawImage(c, CGRectMake(0, 0, side, side), image);
    CGContextRelease(c);
    *outSide = side;
    return bytes;
}

- (void)setRawDepth:(UIImage *)rawDepth {
    _rawDepth = rawDepth;
    _rawRead = NO;
    _rawBytes = nil;
}

- (NSData *)rawBytes {
    if (!_rawRead) {
        _rawRead = YES;
        _rawBytes = grayBytes(_rawDepth.CGImage, &_rawSide);
    }
    return _rawBytes;
}

- (size_t)rawSide { [self rawBytes]; return _rawSide; }
- (double)plateLow { [self readPlate]; return _plateLow; }

- (void)readPlate {
    if (_plateRead) return;
    _plateRead = YES;
    _plateReach = 0.3;
    _plateLow = MAX(0.0, _backgroundDepth - 0.2);
    CGImageRef image = _plateDepth.CGImage;
    if (!image) return;
    size_t side = CGImageGetWidth(image), high = CGImageGetHeight(image);
    if (side < 2 || high < 2 || side > 1024 || high > 2048) return;
    NSMutableData *bytes = [NSMutableData dataWithLength:side * high];
    CGColorSpaceRef gray = CGColorSpaceCreateDeviceGray();
    CGContextRef c = CGBitmapContextCreate(bytes.mutableBytes, side, high, 8, side, gray, (CGBitmapInfo)kCGImageAlphaNone);
    CGColorSpaceRelease(gray);
    if (!c) return;
    CGContextSetInterpolationQuality(c, kCGInterpolationHigh);
    CGContextDrawImage(c, CGRectMake(0, 0, side, high), image);
    CGContextRelease(c);
    const uint8_t *p = bytes.bytes;
    double reach = 0;
    size_t histogram[256] = {0};
    // The far end over the cover's own square (the room below is the floor carried on).
    size_t square = MIN(high, side), skip = (size_t)lround(self.tallTop * side);
    if (skip + square > high) skip = 0;
    p += skip * side;
    for (size_t i = 0; i < side * square; i++) {
        reach = MAX(reach, fabs([self plateFactorOf:p[i] / 255.0]));
        histogram[p[i]]++;
    }
    size_t seen = 0;
    for (int v = 0; v < 256; v++) {
        seen += histogram[v];
        if (seen >= side * square / 20) {
            _plateLow = v / 255.0;
            break;
        }
    }
    _plateBytes = bytes;
    _plateSide = side;
    _plateHigh = high;
    _plateReach = reach;
}

- (NSData *)plateBytes { [self readPlate]; return _plateBytes; }
- (size_t)plateSide { [self readPlate]; return _plateSide; }
- (size_t)plateHigh { [self readPlate]; return _plateHigh; }
- (double)plateReach { [self readPlate]; return _plateReach; }

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
    NSMutableArray *depths = [NSMutableArray array], *reliefs = [NSMutableArray array];
    for (NSUInteger i = 0; i < _layers.count; i++) {
        NSString *path = [folder stringByAppendingPathComponent:[NSString stringWithFormat:@"scene-layer-%lu.png", (unsigned long)i]];
        if (![AUPNGData(_layers[i].image.CGImage) writeToFile:path atomically:YES]) return NO;
        [depths addObject:@(_layers[i].depth)];
        [reliefs addObject:@(_layers[i].relief)];
    }
    if (_plateDepth.CGImage && ![AUPNGData(_plateDepth.CGImage) writeToFile:[folder stringByAppendingPathComponent:@"scene-depth.png"] atomically:YES]) return NO;
    if (_tall.CGImage && ![AUJPEGData(_tall.CGImage, 0.9) writeToFile:[folder stringByAppendingPathComponent:@"scene-tall.jpg"] atomically:YES]) return NO;
    if (_rawDepth.CGImage && ![AUPNGData(_rawDepth.CGImage) writeToFile:[folder stringByAppendingPathComponent:@"scene-raw.png"] atomically:YES]) return NO;
    if (_front.CGImage && ![AUJPEGData(_front.CGImage, 0.92) writeToFile:[folder stringByAppendingPathComponent:@"scene-front.jpg"] atomically:YES]) return NO;
    if (_frontDepth.CGImage && ![AUPNGData(_frontDepth.CGImage) writeToFile:[folder stringByAppendingPathComponent:@"scene-front-depth.png"] atomically:YES]) return NO;
    NSDictionary *plist = @{@"version": kVersion, @"square": @[@(_square.origin.x), @(_square.origin.y), @(_square.size.width), @(_square.size.height)],
                            @"depths": depths, @"backgroundDepth": @(_backgroundDepth), @"inpainted": @(_inpainted), @"segmented": @(_segmented), @"tallness": @(_tallness), @"tune": _tune ?: @"", @"reliefs": reliefs,
                            @"style": @[@(_styleSwing), @(_styleDeep), @(_styleRelief)], @"styleName": _styleName ?: @"",
                            @"nearDepth": @(_nearDepth), @"tearJump": @(_tearJump), @"tallTop": @(_tallTop)};
    return [plist writeToFile:[folder stringByAppendingPathComponent:@"scene.plist"] atomically:YES];
}

+ (instancetype)readFrom:(NSString *)folder {
    NSDictionary *plist = [NSDictionary dictionaryWithContentsOfFile:[folder stringByAppendingPathComponent:@"scene.plist"]];
    if (![plist[@"version"] isEqual:kVersion]) return nil;
    // Made with other numbers for the objects or the painting: made again.
    if (![plist[@"tune"] isEqual:AUTuneSignature(AUTuneScene)]) return nil;
    NSArray *square = plist[@"square"];
    NSArray *depths = plist[@"depths"];
    if (![square isKindOfClass:NSArray.class] || square.count != 4 || ![depths isKindOfClass:NSArray.class]) return nil;
    CGImageRef background = AUImageFromData([NSData dataWithContentsOfFile:[folder stringByAppendingPathComponent:@"scene-background.jpg"]]);
    if (!background) return nil;
    AUScene *scene = [AUScene new];
    scene.background = [UIImage imageWithCGImage:background];
    CGImageRelease(background);
    CGImageRef raw = AUImageFromData([NSData dataWithContentsOfFile:[folder stringByAppendingPathComponent:@"scene-raw.png"]]);
    if (raw) {
        scene.rawDepth = [UIImage imageWithCGImage:raw];
        CGImageRelease(raw);
    }
    CGImageRef plate = AUImageFromData([NSData dataWithContentsOfFile:[folder stringByAppendingPathComponent:@"scene-depth.png"]]);
    if (plate) {
        scene.plateDepth = [UIImage imageWithCGImage:plate];
        CGImageRelease(plate);
    }
    scene.square = CGRectMake([square[0] doubleValue], [square[1] doubleValue], [square[2] doubleValue], [square[3] doubleValue]);
    scene.backgroundDepth = [plist[@"backgroundDepth"] doubleValue];
    scene.inpainted = [plist[@"inpainted"] boolValue];
    scene.segmented = [plist[@"segmented"] boolValue];
    NSArray *style = plist[@"style"];
    if ([style isKindOfClass:NSArray.class] && style.count == 3) {
        scene.styleSwing = [style[0] doubleValue];
        scene.styleDeep = [style[1] doubleValue];
        scene.styleRelief = [style[2] doubleValue];
    }
    scene.styleName = plist[@"styleName"];
    scene.nearDepth = [plist[@"nearDepth"] doubleValue];
    if ([plist[@"tearJump"] doubleValue] > 0) scene.tearJump = [plist[@"tearJump"] doubleValue];
    CGImageRef front = AUImageFromData([NSData dataWithContentsOfFile:[folder stringByAppendingPathComponent:@"scene-front.jpg"]]);
    CGImageRef frontDepth = AUImageFromData([NSData dataWithContentsOfFile:[folder stringByAppendingPathComponent:@"scene-front-depth.png"]]);
    if (front && frontDepth) {
        scene.front = [UIImage imageWithCGImage:front];
        scene.frontDepth = [UIImage imageWithCGImage:frontDepth];
    }
    if (front) CGImageRelease(front);
    if (frontDepth) CGImageRelease(frontDepth);
    CGImageRef tall = AUImageFromData([NSData dataWithContentsOfFile:[folder stringByAppendingPathComponent:@"scene-tall.jpg"]]);
    if (tall) {
        scene.tall = [UIImage imageWithCGImage:tall];
        scene.tallness = [plist[@"tallness"] doubleValue] ?: CGImageGetHeight(tall) / (double)CGImageGetWidth(tall);
        scene.tallTop = [plist[@"tallTop"] doubleValue];
        CGImageRelease(tall);
    }
    NSMutableArray *layers = [NSMutableArray array];
    for (NSUInteger i = 0; i < depths.count; i++) {
        CGImageRef image = AUImageFromData([NSData dataWithContentsOfFile:[folder stringByAppendingPathComponent:[NSString stringWithFormat:@"scene-layer-%lu.png", (unsigned long)i]]]);
        if (!image) return nil;
        AUSceneLayer *layer = [AUSceneLayer new];
        layer.image = [UIImage imageWithCGImage:image];
        layer.depth = [depths[i] doubleValue];
        NSArray *reliefs = plist[@"reliefs"];
        if ([reliefs isKindOfClass:NSArray.class] && i < reliefs.count) layer.relief = [reliefs[i] doubleValue];
        CGImageRelease(image);
        [layers addObject:layer];
    }
    scene.layers = layers;
    return scene;
}

@end
