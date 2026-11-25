#import "AUScene.h"
#import "AUImage.h"

static NSString *const kVersion = @"scene-v3";

@implementation AUSceneLayer
@end

const double AUSceneMotion = 0.08;
static const double kPlateLimit = 0.6, kObjectLeast = 0.3;

@implementation AUScene {
    NSMapTable<UIImage *, UIImage *> *_squares;
    NSData *_plateBytes;
    size_t _plateSide;
    double _plateReach;
    BOOL _plateRead;
    double _plateLow;
    NSData *_rawBytes;
    size_t _rawSide;
    BOOL _rawRead;
    UIImage *_plateSquare;
}

- (double)plateCenter { return _backgroundDepth; }
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
    _plateSquare = nil;
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
    size_t side = MAX(CGImageGetWidth(image), CGImageGetHeight(image));
    if (side < 2 || side > 1024) return;
    NSMutableData *bytes = [NSMutableData dataWithLength:side * side];
    CGColorSpaceRef gray = CGColorSpaceCreateDeviceGray();
    CGContextRef c = CGBitmapContextCreate(bytes.mutableBytes, side, side, 8, side, gray, (CGBitmapInfo)kCGImageAlphaNone);
    CGColorSpaceRelease(gray);
    if (!c) return;
    CGContextSetInterpolationQuality(c, kCGInterpolationHigh);
    CGContextDrawImage(c, CGRectMake(0, 0, side, side), image);
    CGContextRelease(c);
    const uint8_t *p = bytes.bytes;
    double reach = 0;
    size_t histogram[256] = {0};
    for (size_t i = 0; i < side * side; i++) {
        reach = MAX(reach, fabs([self plateFactorOf:p[i] / 255.0]));
        histogram[p[i]]++;
    }
    size_t seen = 0;
    for (int v = 0; v < 256; v++) {
        seen += histogram[v];
        if (seen >= side * side / 20) {
            _plateLow = v / 255.0;
            break;
        }
    }
    _plateBytes = bytes;
    _plateSide = side;
    _plateReach = reach;
}

- (NSData *)plateBytes { [self readPlate]; return _plateBytes; }
- (size_t)plateSide { [self readPlate]; return _plateSide; }
- (double)plateReach { [self readPlate]; return _plateReach; }

- (UIImage *)plateSquare {
    if (_plateSquare || !_plateDepth.CGImage) return _plateSquare;
    CGSize canvas = _background.size;
    if (canvas.width < 1 || canvas.height < 1) return nil;
    CGImageRef plate = _plateDepth.CGImage;
    double sx = CGImageGetWidth(plate) / canvas.width, sy = CGImageGetHeight(plate) / canvas.height;
    CGRect cut = CGRectIntegral(CGRectMake(_square.origin.x * sx, _square.origin.y * sy, _square.size.width * sx, _square.size.height * sy));
    CGImageRef square = CGImageCreateWithImageInRect(plate, cut);
    if (!square) return _plateDepth;
    _plateSquare = [UIImage imageWithCGImage:square];
    CGImageRelease(square);
    return _plateSquare;
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

static inline double bilinear8(const uint8_t *p, size_t side, double x, double y) {
    x = MAX(0.0, MIN(side - 1.0, x));
    y = MAX(0.0, MIN(side - 1.0, y));
    size_t x0 = (size_t)x, y0 = (size_t)y, x1 = MIN(x0 + 1, side - 1), y1 = MIN(y0 + 1, side - 1);
    double fx = x - x0, fy = y - y0;
    double top = p[y0 * side + x0] * (1 - fx) + p[y0 * side + x1] * fx;
    double bottom = p[y1 * side + x0] * (1 - fx) + p[y1 * side + x1] * fx;
    return (top * (1 - fy) + bottom * fy) / 255.0;
}

float *_Nullable AUScenePlateFactors(AUScene *scene, size_t w, size_t h, CGRect canvas, double falloff) {
    float *factors = malloc(w * h * sizeof(float));
    if (!factors) return NULL;
    NSData *plate = scene.plateBytes;
    const uint8_t *p = plate.bytes;
    size_t side = scene.plateSide;
    double still = [scene plateFactorOf:scene.plateCenter - 0.15];
    double minX = CGRectGetMinX(canvas), maxX = CGRectGetMaxX(canvas), minY = CGRectGetMinY(canvas), maxY = CGRectGetMaxY(canvas);
    dispatch_apply(h, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^(size_t y) {
        double py = y + 0.5;
        double v = (py - minY) / canvas.size.height;
        double dy = MAX(0.0, MAX(minY - py, py - maxY));
        for (size_t x = 0; x < w; x++) {
            double px = x + 0.5;
            double u = (px - minX) / canvas.size.width;
            double f = p ? [scene plateFactorOf:bilinear8(p, side, u * side - 0.5, v * side - 0.5)] : still;
            double dx = MAX(0.0, MAX(minX - px, px - maxX));
            double t = falloff > 0 ? MAX(0.0, 1 - hypot(dx, dy) / falloff) : (dx > 0 || dy > 0 ? 0 : 1);
            factors[y * w + x] = (float)(f * t * t * (3 - 2 * t));
        }
    });
    return factors;
}

void AUSceneWarp(uint8_t *frame, size_t frameRow, size_t w, size_t h, const uint8_t *source, size_t sourceRow,
                 size_t margin, const float *factors, CGPoint shift) {
    const size_t sw = w + 2 * margin, sh = h + 2 * margin;
    const float sx = (float)shift.x, sy = (float)shift.y;
    dispatch_apply(h, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^(size_t y) {
        uint8_t *out = frame + y * frameRow;
        const float *f = factors + y * w;
        for (size_t x = 0; x < w; x++) {
            float fx = (float)(x + margin) - sx * f[x], fy = (float)(y + margin) - sy * f[x];
            fx = fminf(fmaxf(fx, 0), (float)(sw - 1.001));
            fy = fminf(fmaxf(fy, 0), (float)(sh - 1.001));
            size_t x0 = (size_t)fx, y0 = (size_t)fy;
            uint32_t ax = (uint32_t)((fx - x0) * 256), ay = (uint32_t)((fy - y0) * 256);
            const uint8_t *a = source + y0 * sourceRow + x0 * 4, *b = a + sourceRow;
            for (int c = 0; c < 4; c++) {
                uint32_t top = a[c] * (256 - ax) + a[c + 4] * ax, bottom = b[c] * (256 - ax) + b[c + 4] * ax;
                out[x * 4 + c] = (uint8_t)((top * (256 - ay) + bottom * ay + 32768) >> 16);
            }
        }
    });
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
    if (_plateDepth.CGImage && ![AUPNGData(_plateDepth.CGImage) writeToFile:[folder stringByAppendingPathComponent:@"scene-depth.png"] atomically:YES]) return NO;
    if (_rawDepth.CGImage && ![AUPNGData(_rawDepth.CGImage) writeToFile:[folder stringByAppendingPathComponent:@"scene-raw.png"] atomically:YES]) return NO;
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
