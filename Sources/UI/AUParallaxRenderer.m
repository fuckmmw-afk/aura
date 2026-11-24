#import "AUParallaxRenderer.h"
#import "Core/AUCore.h"
#import "Features/AUImage.h"
#import <Metal/Metal.h>

static NSString *const kShader = @"\
#include <metal_stdlib>\n\
using namespace metal;\n\
struct VOut { float4 position [[position]]; float2 uv; };\n\
vertex VOut au_vertex(uint vid [[vertex_id]]) {\n\
    const float2 corners[4] = { float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, 1) };\n\
    VOut out;\n\
    out.position = float4(corners[vid], 0, 1);\n\
    out.uv = float2((corners[vid].x + 1) * 0.5, 1 - (corners[vid].y + 1) * 0.5);\n\
    return out;\n\
}\n\
struct Uniforms { float2 tilt; float2 uvScale; float strength; float zoom; float hasDepth; float pad; };\n\
fragment half4 au_fragment(VOut in [[stage_in]], texture2d<half> color [[texture(0)]], texture2d<half> depth [[texture(1)]],\n\
                           constant Uniforms &u [[buffer(0)]]) {\n\
    constexpr sampler s(address::clamp_to_edge, filter::linear);\n\
    // The layer's point in the picture: aspect-filled, then zoomed in around the middle.\n\
    float2 uv = (in.uv - 0.5) * u.uvScale / u.zoom + 0.5;\n\
    if (u.hasDepth < 0.5) return half4(color.sample(s, uv).rgb, 1);\n\
    // Steep parallax: a point at depth d (1 near, 0 far) shows shifted by off * (d - 0.5), found by marching down\n\
    // through the map from the near plane, so each thing moves whole at its own depth and the near hides the far.\n\
    float2 off = u.tilt * u.strength;\n\
    const int steps = 16;\n\
    float layer = 1.0, stepSize = 1.0 / steps;\n\
    float2 p = uv - off * (layer - 0.5);\n\
    float d = float(depth.sample(s, p).r);\n\
    float prevLayer = layer, prevD = d;\n\
    for (int i = 0; i < steps && d < layer; i++) {\n\
        prevLayer = layer; prevD = d;\n\
        layer -= stepSize;\n\
        p = uv - off * (layer - 0.5);\n\
        d = float(depth.sample(s, p).r);\n\
    }\n\
    float before = prevD - prevLayer, after = d - layer;\n\
    float t = clamp(before / (before - after + 1e-5), 0.0, 1.0);\n\
    float hit = mix(prevLayer, layer, t);\n\
    float2 q = uv - off * (hit - 0.5);\n\
    // Where the march landed beside a depth step, what shows is room the near thing uncovered, and the colour there\n\
    // is a stretch of its edge. It is taken from a blurrier mip level, by how big the step and the shift are, so the\n\
    // uncovered room reads as soft background rather than a smear. At rest (no shift) all stays sharp.\n\
    float shift = length(off);\n\
    float2 dir = off / max(shift, 1e-5);\n\
    float2 texel = 1.0 / float2(depth.get_width(), depth.get_height());\n\
    float dA = float(depth.sample(s, q + dir * texel * 4.0).r);\n\
    float dB = float(depth.sample(s, q - dir * texel * 4.0).r);\n\
    float lod = clamp(abs(dA - dB) * shift * 140.0, 0.0, 4.5);\n\
    constexpr sampler mips(address::clamp_to_edge, filter::linear, mip_filter::linear);\n\
    return half4(color.sample(mips, q, level(lod)).rgb, 1);\n\
}\n";

typedef struct {
    float tilt[2];
    float uvScale[2];
    float strength;
    float zoom;
    float hasDepth;
    float pad;
} AUUniforms;

@implementation AUParallaxRenderer {
    id<MTLCommandQueue> _queue;
    id<MTLTexture> _color, _depth;
    CGSize _imageSize;
}

+ (id<MTLDevice>)device {
    static id<MTLDevice> device;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ device = MTLCreateSystemDefaultDevice(); });
    return device;
}

+ (BOOL)supported {
    return [self device] != nil;
}

+ (id<MTLRenderPipelineState>)pipeline {
    static id<MTLRenderPipelineState> pipeline;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        double started = AUNowMs();
        NSError *error = nil;
        id<MTLLibrary> library = [[self device] newLibraryWithSource:kShader options:nil error:&error];
        if (!library) {
            AULog(@"parallax shader: %@", error.localizedDescription);
            return;
        }
        MTLRenderPipelineDescriptor *descriptor = [MTLRenderPipelineDescriptor new];
        descriptor.vertexFunction = [library newFunctionWithName:@"au_vertex"];
        descriptor.fragmentFunction = [library newFunctionWithName:@"au_fragment"];
        descriptor.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
        pipeline = [[self device] newRenderPipelineStateWithDescriptor:descriptor error:&error];
        if (!pipeline) AULog(@"parallax pipeline: %@", error.localizedDescription);
        else AULog(@"parallax shader compiled in %.0f ms", AUNowMs() - started);
    });
    return pipeline;
}

- (instancetype)init {
    if (!(self = [super init])) return nil;
    id<MTLDevice> device = [AUParallaxRenderer device];
    _queue = [device newCommandQueue];
    _layer = [CAMetalLayer layer];
    _layer.device = device;
    _layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
    _layer.framebufferOnly = YES;
    _layer.opaque = YES;
    _layer.contentsGravity = kCAGravityResize;
    _layer.actions = @{@"bounds": NSNull.null, @"position": NSNull.null, @"frame": NSNull.null, @"contents": NSNull.null,
                       @"opacity": NSNull.null, @"transform": NSNull.null};
    _zoom = 1.06;
    _strength = 0.045;
    _maxPixels = 1200;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ [AUParallaxRenderer pipeline]; });
    return self;
}

- (BOOL)hasContent {
    return _color != nil;
}

// RGBA8 sRGB bytes straight into a texture: one format whatever the picture came as.
- (id<MTLTexture>)texture:(CGImageRef)image mipmapped:(BOOL)mipmapped {
    if (!image) return nil;
    CGImageRef normal = AUImageNormalized(image, 2048);
    if (!normal) return nil;
    size_t width = CGImageGetWidth(normal), height = CGImageGetHeight(normal);
    NSMutableData *bytes = [NSMutableData dataWithLength:width * height * 4];
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef context = CGBitmapContextCreate(bytes.mutableBytes, width, height, 8, width * 4, space,
                                                 kCGImageAlphaNoneSkipLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(space);
    CGContextDrawImage(context, CGRectMake(0, 0, width, height), normal);
    CGContextRelease(context);
    CGImageRelease(normal);
    MTLTextureDescriptor *descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                          width:width height:height mipmapped:mipmapped];
    descriptor.usage = MTLTextureUsageShaderRead;
    id<MTLTexture> texture = [[AUParallaxRenderer device] newTextureWithDescriptor:descriptor];
    [texture replaceRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0 withBytes:bytes.bytes bytesPerRow:width * 4];
    if (mipmapped && texture.mipmapLevelCount > 1) {
        // The blurrier levels the shader reaches for where a near thing uncovers the room behind it.
        id<MTLCommandBuffer> buffer = [_queue commandBuffer];
        id<MTLBlitCommandEncoder> blit = [buffer blitCommandEncoder];
        [blit generateMipmapsForTexture:texture];
        [blit endEncoding];
        [buffer commit];
        [buffer waitUntilCompleted];
    }
    return texture;
}

- (void)setColor:(CGImageRef)color depth:(CGImageRef)depth {
    _color = [self texture:color mipmapped:YES];
    _depth = [self texture:depth mipmapped:NO];
    _imageSize = color ? CGSizeMake(CGImageGetWidth(color), CGImageGetHeight(color)) : CGSizeZero;
}

- (void)layoutForScale:(CGFloat)scale {
    CGSize size = _layer.bounds.size;
    if (size.width < 1 || size.height < 1) return;
    CGFloat pixels = MIN(scale, _maxPixels / MAX(size.width, size.height));
    _layer.contentsScale = pixels;
    CGSize drawable = CGSizeMake(round(size.width * pixels), round(size.height * pixels));
    if (!CGSizeEqualToSize(_layer.drawableSize, drawable)) _layer.drawableSize = drawable;
}

- (AUUniforms)uniformsForWidth:(double)width height:(double)height {
    // Aspect fill: the share of the picture's width and height the layer shows.
    double imageAspect = _imageSize.height > 0 ? _imageSize.width / _imageSize.height : 1, layerAspect = height > 0 ? width / height : 1;
    float sx = (float)MIN(1.0, layerAspect / imageAspect), sy = (float)MIN(1.0, imageAspect / layerAspect);
    return (AUUniforms){{(float)_tilt.x, (float)_tilt.y}, {sx, sy}, (float)_strength, (float)_zoom, _depth ? 1.0f : 0.0f, 0};
}

- (void)encodeInto:(id<MTLTexture>)target buffer:(id<MTLCommandBuffer>)buffer {
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = target;
    pass.colorAttachments[0].loadAction = MTLLoadActionDontCare;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    AUUniforms uniforms = [self uniformsForWidth:target.width height:target.height];
    id<MTLRenderCommandEncoder> encoder = [buffer renderCommandEncoderWithDescriptor:pass];
    [encoder setRenderPipelineState:[AUParallaxRenderer pipeline]];
    [encoder setFragmentTexture:_color atIndex:0];
    [encoder setFragmentTexture:_depth ?: _color atIndex:1];
    [encoder setFragmentBytes:&uniforms length:sizeof(uniforms) atIndex:0];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
    [encoder endEncoding];
}

- (void)render {
    if (![AUParallaxRenderer pipeline] || !_color || _layer.drawableSize.width < 1) return;
    id<CAMetalDrawable> drawable = [_layer nextDrawable];
    if (!drawable) return;
    id<MTLCommandBuffer> buffer = [_queue commandBuffer];
    [self encodeInto:drawable.texture buffer:buffer];
    [buffer presentDrawable:drawable];
    [buffer commit];
    AUCountFrame();
}

- (CGImageRef)renderImageWidth:(size_t)width height:(size_t)height {
    if (![AUParallaxRenderer pipeline] || !_color) return NULL;
    MTLTextureDescriptor *descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                          width:width height:height mipmapped:NO];
    descriptor.usage = MTLTextureUsageRenderTarget;
    descriptor.storageMode = MTLStorageModeShared;
    id<MTLTexture> target = [[AUParallaxRenderer device] newTextureWithDescriptor:descriptor];
    id<MTLCommandBuffer> buffer = [_queue commandBuffer];
    [self encodeInto:target buffer:buffer];
    [buffer commit];
    [buffer waitUntilCompleted];
    NSMutableData *bytes = [NSMutableData dataWithLength:width * height * 4];
    [target getBytes:bytes.mutableBytes bytesPerRow:width * 4 fromRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0];
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef context = CGBitmapContextCreate(bytes.mutableBytes, width, height, 8, width * 4, space,
                                                 kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little);
    CGColorSpaceRelease(space);
    CGImageRef image = CGBitmapContextCreateImage(context);
    CGContextRelease(context);
    return image;
}

@end
