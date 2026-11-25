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
struct Uniforms { float2 tilt; float2 uvScale; float2 reach; float zoom; float hasDepth; float center; float limit; };\n\
fragment half4 au_fragment(VOut in [[stage_in]], texture2d<half> color [[texture(0)]], texture2d<half> depth [[texture(1)]],\n\
                           constant Uniforms &u [[buffer(0)]]) {\n\
    constexpr sampler s(address::clamp_to_edge, filter::linear);\n\
    // The layer's point in the picture: aspect-filled, then zoomed in around the middle.\n\
    float2 uv = (in.uv - 0.5) * u.uvScale / u.zoom + 0.5;\n\
    // The background with its objects lifted out and painted in: its depth is smooth (no object edges left), so it\n\
    // bends gently by it — the floor and the walls recede, the far side moves against the tilt — and tears nowhere.\n\
    float d = u.hasDepth > 0.5 ? float(depth.sample(s, uv).r) : u.center - 0.15;\n\
    float f = clamp((d - u.center) * 2, -u.limit, u.limit);\n\
    return half4(color.sample(s, uv - u.tilt * u.reach * f).rgb, 1);\n\
}\n";

typedef struct {
    float tilt[2];
    float uvScale[2];
    float reach[2];
    float zoom;
    float hasDepth;
    float center;
    float limit;
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
    _layer.maximumDrawableCount = 3;
    _layer.opaque = YES;
    _layer.contentsGravity = kCAGravityResize;
    _layer.actions = @{@"bounds": NSNull.null, @"position": NSNull.null, @"frame": NSNull.null, @"contents": NSNull.null,
                       @"opacity": NSNull.null, @"transform": NSNull.null};
    _zoom = 1;
    _reach = 0.08;
    _center = 0.5;
    _limit = 0.7;
    _maxPixels = 2048;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ [AUParallaxRenderer pipeline]; });
    return self;
}

- (void)setPresentsWithTransaction:(BOOL)presents {
    _presentsWithTransaction = presents;
    _layer.presentsWithTransaction = presents;
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
    // Until it is drawn again, the last picture must not show over the new one.
    _layer.hidden = YES;
    _color = [self texture:color mipmapped:NO];
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
    // The reach is a share of the picture's shorter side, in each axis's own texture units.
    double shortSide = MIN(_imageSize.width, _imageSize.height);
    float rx = _imageSize.width > 0 ? (float)(_reach * shortSide / _imageSize.width) : 0;
    float ry = _imageSize.height > 0 ? (float)(_reach * shortSide / _imageSize.height) : 0;
    return (AUUniforms){{(float)_tilt.x, (float)_tilt.y}, {sx, sy}, {rx, ry}, (float)_zoom, _depth ? 1.0f : 0.0f,
                        (float)_center, (float)_limit};
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
    if (_presentsWithTransaction) {
        [buffer commit];
        [buffer waitUntilScheduled];
        [drawable present];
    } else {
        [buffer presentDrawable:drawable];
        [buffer commit];
    }
    _layer.hidden = NO;
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
