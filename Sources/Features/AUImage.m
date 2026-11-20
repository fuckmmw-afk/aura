#import "AUImage.h"
#import <ImageIO/ImageIO.h>
#import <TargetConditionals.h>
#if TARGET_OS_IOS
#import <UIKit/UIKit.h>
#endif

static CGImageRef draw(CGImageRef image, size_t width, size_t height) {
    if (!image || !width || !height) return NULL;
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef context = CGBitmapContextCreate(NULL, width, height, 8, 0, space,
                                                 kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(space);
    if (!context) return NULL;
    CGContextSetInterpolationQuality(context, kCGInterpolationHigh);
    CGContextDrawImage(context, CGRectMake(0, 0, width, height), image);
    CGImageRef made = CGBitmapContextCreateImage(context);
    CGContextRelease(context);
    return made;
}

CGImageRef AUImageNormalized(CGImageRef image, size_t maxSide) {
    if (!image) return NULL;
    size_t w = CGImageGetWidth(image), h = CGImageGetHeight(image);
    if (!w || !h) return NULL;
    double scale = MIN(1.0, (double)maxSide / MAX(w, h));
    return draw(image, MAX(1, (size_t)llround(w * scale)), MAX(1, (size_t)llround(h * scale)));
}

CGImageRef AUImageResized(CGImageRef image, size_t width, size_t height) {
    return draw(image, width, height);
}

CGImageRef AUGrayImage(const uint8_t *bytes, size_t width, size_t height) {
    CFDataRef data = CFDataCreate(NULL, bytes, (CFIndex)(width * height));
    CGDataProviderRef provider = CGDataProviderCreateWithCFData(data);
    CFRelease(data);
    CGColorSpaceRef gray = CGColorSpaceCreateDeviceGray();
    CGImageRef image = CGImageCreate(width, height, 8, 8, width, gray, (CGBitmapInfo)kCGImageAlphaNone, provider, NULL, NO, kCGRenderingIntentDefault);
    CGColorSpaceRelease(gray);
    CGDataProviderRelease(provider);
    return image;
}

NSData *AUGrayBytes(CGImageRef image) {
    if (!image) return nil;
    size_t w = CGImageGetWidth(image), h = CGImageGetHeight(image);
    NSMutableData *bytes = [NSMutableData dataWithLength:w * h];
    CGColorSpaceRef gray = CGColorSpaceCreateDeviceGray();
    CGContextRef context = CGBitmapContextCreate(bytes.mutableBytes, w, h, 8, w, gray, (CGBitmapInfo)kCGImageAlphaNone);
    CGColorSpaceRelease(gray);
    if (!context) return nil;
    CGContextDrawImage(context, CGRectMake(0, 0, w, h), image);
    CGContextRelease(context);
    return bytes;
}

static NSData *encode(CGImageRef image, CFStringRef type, NSDictionary *options) {
    if (!image) return nil;
    NSMutableData *data = [NSMutableData data];
    CGImageDestinationRef destination = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)data, type, 1, NULL);
    if (!destination) return nil;
    CGImageDestinationAddImage(destination, image, (__bridge CFDictionaryRef)options);
    BOOL ok = CGImageDestinationFinalize(destination);
    CFRelease(destination);
    return ok ? data : nil;
}

NSData *AUPNGData(CGImageRef image) {
    return encode(image, CFSTR("public.png"), @{});
}

NSData *AUJPEGData(CGImageRef image, double quality) {
    return encode(image, CFSTR("public.jpeg"), @{(__bridge NSString *)kCGImageDestinationLossyCompressionQuality: @(quality)});
}

CGImageRef AUImageFromData(NSData *data) {
    if (!data.length) return NULL;
    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
    if (!source) return NULL;
    CGImageRef image = CGImageSourceCreateImageAtIndex(source, 0, (__bridge CFDictionaryRef)@{(__bridge NSString *)kCGImageSourceShouldCacheImmediately: @YES});
    CFRelease(source);
    return image;
}

static NSArray<NSNumber *> *starts(size_t length, size_t tile, size_t overlap) {
    if (length <= tile) return @[@0];
    size_t stride = tile - overlap;
    NSMutableArray *values = [NSMutableArray array];
    for (size_t x = 0;; x += stride) {
        if (x + tile >= length) {
            [values addObject:@(length - tile)];
            break;
        }
        [values addObject:@(x)];
    }
    return values;
}

NSArray<NSValue *> *AUTiles(size_t width, size_t height, size_t tile, size_t overlap) {
    NSMutableArray *tiles = [NSMutableArray array];
    for (NSNumber *y in starts(height, tile, overlap)) {
        for (NSNumber *x in starts(width, tile, overlap)) {
            CGRect rect = CGRectMake(x.doubleValue, y.doubleValue, MIN(tile, width), MIN(tile, height));
#if TARGET_OS_IOS
            [tiles addObject:[NSValue valueWithCGRect:rect]];
#else
            [tiles addObject:[NSValue valueWithBytes:&rect objCType:@encode(CGRect)]];
#endif
        }
    }
    return tiles;
}
