#import "AUDepthLayers.h"

const double AUDepthLayerDepths[3] = {0.25, 0.55, 0.85};
const double AUSubjectDepth = 1.05;

static float smooth(float x, float a, float b) {
    float t = fminf(1, fmaxf(0, (x - a) / (b - a)));
    return t * t * (3 - 2 * t);
}

AUDepthLayers AUDepthLayersMake(CGImageRef color, CGImageRef depth) {
    AUDepthLayers layers = {NULL, NULL, NULL};
    if (!color) return layers;
    size_t w = CGImageGetWidth(color), h = CGImageGetHeight(color);
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef base = CGBitmapContextCreate(NULL, w, h, 8, 0, space, kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    CGContextDrawImage(base, CGRectMake(0, 0, w, h), color);
    layers.far = CGBitmapContextCreateImage(base);
    if (depth) {
        uint8_t *d = calloc(w * h, 1);
        CGColorSpaceRef gray = CGColorSpaceCreateDeviceGray();
        CGContextRef dc = CGBitmapContextCreate(d, w, h, 8, w, gray, (CGBitmapInfo)kCGImageAlphaNone);
        CGColorSpaceRelease(gray);
        CGContextSetInterpolationQuality(dc, kCGInterpolationHigh);
        CGContextDrawImage(dc, CGRectMake(0, 0, w, h), depth);
        CGContextRelease(dc);
        const uint8_t *src = CGBitmapContextGetData(base);
        size_t srcRow = CGBitmapContextGetBytesPerRow(base);
        float bands[2][2] = {{0.33f, 0.5f}, {0.62f, 0.78f}};
        for (int k = 0; k < 2; k++) {
            CGContextRef layer = CGBitmapContextCreate(NULL, w, h, 8, 0, space, kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
            uint8_t *dst = CGBitmapContextGetData(layer);
            size_t dstRow = CGBitmapContextGetBytesPerRow(layer);
            for (size_t y = 0; y < h; y++) {
                const uint8_t *s = src + y * srcRow;
                uint8_t *o = dst + y * dstRow;
                for (size_t x = 0; x < w; x++) {
                    float a = smooth(d[y * w + x] / 255.0f, bands[k][0], bands[k][1]);
                    o[x * 4 + 0] = (uint8_t)(s[x * 4 + 0] * a);
                    o[x * 4 + 1] = (uint8_t)(s[x * 4 + 1] * a);
                    o[x * 4 + 2] = (uint8_t)(s[x * 4 + 2] * a);
                    o[x * 4 + 3] = (uint8_t)(255 * a);
                }
            }
            CGImageRef made = CGBitmapContextCreateImage(layer);
            if (k == 0) layers.middle = made;
            else layers.near = made;
            CGContextRelease(layer);
        }
        free(d);
    }
    CGContextRelease(base);
    CGColorSpaceRelease(space);
    return layers;
}

void AUDepthLayersRelease(AUDepthLayers *layers) {
    if (layers->far) CGImageRelease(layers->far);
    if (layers->middle) CGImageRelease(layers->middle);
    if (layers->near) CGImageRelease(layers->near);
    layers->far = layers->middle = layers->near = NULL;
}
