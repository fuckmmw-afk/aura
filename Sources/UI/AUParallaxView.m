#import "AUParallaxView.h"
#import "Core/AUCore.h"

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
struct Uniforms { float2 tilt; float strength; float zoom; float hasDepth; };\n\
fragment half4 au_fragment(VOut in [[stage_in]], texture2d<half> color [[texture(0)]], texture2d<half> depth [[texture(1)]],\n\
                           constant Uniforms &u [[buffer(0)]]) {\n\
    constexpr sampler s(address::clamp_to_edge, filter::linear);\n\
    float2 uv = (in.uv - 0.5) / u.zoom + 0.5;\n\
    if (u.hasDepth < 0.5) return half4(color.sample(s, uv).rgb, 1);\n\
    // A point at depth d (1 near, 0 far) shows shifted by off * (d - 0.5): the near moves with the tilt, the far against.\n\
    float2 off = u.tilt * u.strength;\n\
    const int steps = 18;\n\
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
    half3 rgb = color.sample(s, uv - off * (hit - 0.5)).rgb;\n\
    // A soft sheen that slides with the tilt, so the card reads as a surface.\n\
    float band = (in.uv.x + in.uv.y) * 0.5 - 0.5 - (u.tilt.x - u.tilt.y) * 0.35;\n\
    float sheen = exp(-band * band * 40.0) * 0.07 * length(u.tilt);\n\
    return half4(rgb + half(sheen), 1);\n\
}\n";

typedef struct {
    float tilt[2];
    float strength;
    float zoom;
    float hasDepth;
} AUUniforms;

@implementation AUParallaxView {
    id<MTLCommandQueue> _queue;
    id<MTLRenderPipelineState> _pipeline;
    id<MTLTexture> _color, _depth;
    MTKTextureLoader *_loader;
}

+ (id<MTLDevice>)sharedDevice {
    static id<MTLDevice> device;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ device = MTLCreateSystemDefaultDevice(); });
    return device;
}

+ (BOOL)supported {
    return [self sharedDevice] != nil;
}

// Compiled once, off the main queue the first time a cover asks.
+ (id<MTLRenderPipelineState>)sharedPipeline {
    static id<MTLRenderPipelineState> pipeline;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        double started = AUNowMs();
        NSError *error = nil;
        id<MTLLibrary> library = [[self sharedDevice] newLibraryWithSource:kShader options:nil error:&error];
        if (!library) {
            AULog(@"parallax shader: %@", error.localizedDescription);
            return;
        }
        MTLRenderPipelineDescriptor *descriptor = [MTLRenderPipelineDescriptor new];
        descriptor.vertexFunction = [library newFunctionWithName:@"au_vertex"];
        descriptor.fragmentFunction = [library newFunctionWithName:@"au_fragment"];
        descriptor.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
        pipeline = [[self sharedDevice] newRenderPipelineStateWithDescriptor:descriptor error:&error];
        if (!pipeline) AULog(@"parallax pipeline: %@", error.localizedDescription);
        else AULog(@"parallax shader compiled in %.0f ms", AUNowMs() - started);
    });
    return pipeline;
}

+ (void)warmUp {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ [self sharedPipeline]; });
}

- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame device:[AUParallaxView sharedDevice]])) return nil;
    self.colorPixelFormat = MTLPixelFormatBGRA8Unorm;
    self.framebufferOnly = YES;
    self.paused = YES;
    self.enableSetNeedsDisplay = NO;
    self.autoResizeDrawable = YES;
    self.opaque = YES;
    self.userInteractionEnabled = NO;
    self.clearColor = MTLClearColorMake(0, 0, 0, 1);
    self.backgroundColor = UIColor.blackColor;
    _queue = [self.device newCommandQueue];
    _loader = [[MTKTextureLoader alloc] initWithDevice:self.device];
    _zoom = 1.06;
    _strength = 0.03;
    [AUParallaxView warmUp];
    return self;
}

- (BOOL)hasContent {
    return _color != nil;
}

- (id<MTLTexture>)texture:(UIImage *)image {
    if (!image.CGImage) return nil;
    NSError *error = nil;
    // The bytes go through untouched (no sRGB decode): the drawable is plain BGRA8 too.
    id<MTLTexture> texture = [_loader newTextureWithCGImage:image.CGImage options:@{
        MTKTextureLoaderOptionSRGB: @NO,
        MTKTextureLoaderOptionTextureUsage: @(MTLTextureUsageShaderRead),
        MTKTextureLoaderOptionTextureStorageMode: @(MTLStorageModePrivate),
    } error:&error];
    if (!texture) AULog(@"parallax texture: %@", error.localizedDescription);
    return texture;
}

- (void)setColor:(UIImage *)color depth:(UIImage *)depth {
    _color = color ? [self texture:color] : nil;
    _depth = depth ? [self texture:depth] : nil;
}

- (void)render {
    id<MTLRenderPipelineState> pipeline = [AUParallaxView sharedPipeline];
    if (!pipeline || !_color || self.bounds.size.width < 1) return;
    MTLRenderPassDescriptor *pass = self.currentRenderPassDescriptor;
    id<CAMetalDrawable> drawable = self.currentDrawable;
    if (!pass || !drawable) return;
    AUUniforms uniforms = {{(float)_tilt.x, (float)_tilt.y}, (float)_strength, (float)_zoom, _depth ? 1.0f : 0.0f};
    id<MTLCommandBuffer> buffer = [_queue commandBuffer];
    id<MTLRenderCommandEncoder> encoder = [buffer renderCommandEncoderWithDescriptor:pass];
    [encoder setRenderPipelineState:pipeline];
    [encoder setFragmentTexture:_color atIndex:0];
    [encoder setFragmentTexture:_depth ?: _color atIndex:1];
    [encoder setFragmentBytes:&uniforms length:sizeof(uniforms) atIndex:0];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
    [encoder endEncoding];
    [buffer presentDrawable:drawable];
    [buffer commit];
    AUCountFrame();
}

@end
