// The scene as a real 3D place seen through the cover's frame. Every point of the picture gets a distance from its
// depth: the window plane (z = 0) lies a little behind the nearest object, so the nearest things come a touch out of
// it and everything else goes far back into the screen, as into a hole. The picture is laid out at those distances so
// that at rest it looks exactly as the cover; tilting the phone swings a perspective camera round the window's middle.
// Each object keeps its own relief (the model's depth inside it, a little exaggerated), so it is a body, not a card.
//
// Units: the picture's side is 1, its middle is (0, 0), y runs down. The same arithmetic runs in the Metal shader
// (AUSceneRenderer) and here on the CPU (lock-screen clips, the Mac harness).
#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
#import "Features/AUScene.h"

NS_ASSUME_NONNULL_BEGIN

typedef struct {
    double angleX, angleY;      // the camera's swing, radians (from the tilt)
    double pivot;               // the depth that lies on the window plane
    double scale;               // z per unit of depth
    double focal;               // the camera's distance from the window
    double relief;              // an object's own depth around its median, exaggerated by this
    double reliefBack, reliefFront;   // ... and kept within -reliefBack...reliefFront of it first
    double zFar, zNear;         // z is kept within -zFar...zNear
    double zOut;                // the lock clip's room around the square: a flat wall at this distance
} AUCamera;

// strength: 1 = the app's look at the slider's x1; the lock clip passes more.
AUCamera AUSceneCamera(AUScene *scene, CGPoint tilt, double strength);
// How much the picture is zoomed into its frame so the swing never shows an edge.
double AUSceneZoom(double strength);
double AUCameraZ(AUCamera c, double depth);
double AUCameraObjectZ(AUCamera c, double depth, double median, double relief);
// A picture point (at distance z) to where it is seen.
CGPoint AUCameraProject(AUCamera c, CGPoint p, double z);

typedef struct {
    const uint8_t *pixels;      // 4 bytes a pixel, premultiplied, rows top down
    size_t row, width, height;
    CGRect square;              // the picture's square in these pixels
    BOOL object;
    double median;              // an object's depth
    BOOL mirror;                // past the square: the picture mirrored (as the app's sampler), else these pixels (a flat wall)
    CGRect box;                 // an object's extent, picture units; CGRectNull for everywhere
    double relief;              // an object's own relief share (AUSceneLayer.relief)
} AUSceneSource;

// Draws `source` as seen by the camera into `frame` (w x h, the picture's square at `square` there), each pixel found
// by walking back from the screen to the picture point that lands on it. The background replaces, an object is laid
// over (premultiplied).
void AUSceneDraw3D(uint8_t *frame, size_t frameRow, size_t w, size_t h, CGRect square, AUScene *scene, AUCamera camera,
                   AUSceneSource source);
// The solid surface (AUScene.front, premultiplied 4-byte pixels, width x height: the square and the room below it)
// over `frame`, by its depth (depthSide x depthHigh, the same picture): spread between neighbours, torn where their
// depths differ by more than `tear` (0...1); the nearest wins. `square` is the cover's square in the frame; the
// picture has `top` (a share of its width) of room above the cover.
void AUSceneSplat3D(uint8_t *frame, size_t frameRow, size_t w, size_t h, CGRect square, AUCamera camera,
                    const uint8_t *pixels, size_t row, size_t width, size_t height,
                    const uint8_t *depth, size_t depthSide, size_t depthHigh, double tear, double top);
// The extent of what is not transparent in a side x side RGBA picture, picture units.
CGRect AUSceneAlphaBox(const uint8_t *pixels, size_t row, size_t side);

NS_ASSUME_NONNULL_END
