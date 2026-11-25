#import "AUScene3D.h"
#import "Core/AUTune.h"

// The numbers (Core/AUTune): swing (degrees at a full tilt, x1), focal, deep (how far behind the window the background's
// far end lies), window (where between the background and the nearest object the window plane is), relief.

AUCamera AUSceneCamera(AUScene *scene, CGPoint tilt, double strength) {
    AUCamera c;
    double background = scene.backgroundDepth, front = background + 0.3;
    if (scene.layers.count) {
        front = 0;
        for (AUSceneLayer *layer in scene.layers) front = MAX(front, layer.depth);
    }
    front = MIN(0.98, MAX(front, background + 0.1));
    double low = MIN(scene.plateLow, background);
    c.pivot = background + AUTune(@"window") * (front - background);
    // The cover's own style (AUScene.style*) scales the swing, the depth and the relief, unless switched off.
    BOOL adapt = AUTuneOn(@"adaptive");
    double styleSwing = adapt ? scene.styleSwing : 1, styleDeep = adapt ? scene.styleDeep : 1, styleRelief = adapt ? scene.styleRelief : 1;
    c.scale = MIN(1.6, AUTune(@"deep") * styleDeep / MAX(0.15, c.pivot - low));
    c.focal = AUTune(@"focal");
    c.relief = AUTune(@"relief") * styleRelief;
    c.reliefBack = AUTune(@"reliefBack");
    c.reliefFront = AUTune(@"reliefFront");
    c.zFar = AUTune(@"zFar");
    c.zNear = MIN(AUTune(@"zNear"), c.focal * 0.8);
    double swing = AUTune(@"swing") * styleSwing * M_PI / 180;
    c.angleX = tilt.x * swing * strength;
    c.angleY = tilt.y * swing * strength;
    c.zOut = AUCameraZ(c, background);
    return c;
}

double AUSceneZoom(double strength) {
    return 1 + AUTune(@"zoom") * strength;
}

double AUCameraZ(AUCamera c, double depth) {
    return MAX(-c.zFar, MIN(c.zNear, (depth - c.pivot) * c.scale));
}

double AUCameraObjectZ(AUCamera c, double depth, double median, double relief) {
    // The relief in depth units, not stretched by the scene's depth scale: a body stays a body however deep the room.
    double own = MAX(-c.reliefBack, MIN(c.reliefFront, depth - median)) * c.relief * relief / MAX(1.0, c.scale);
    return MAX(-c.zFar, MIN(c.zNear, (median - c.pivot) * c.scale + own * c.scale));
}

typedef struct {
    double f, ca, sa, cb, sb;
} AUTurn;

static inline AUTurn turnOf(AUCamera c) {
    return (AUTurn){c.focal, cos(c.angleX), sin(c.angleX), cos(c.angleY), sin(c.angleY)};
}

static inline void project(AUTurn t, double qx, double qy, double z, double *sx, double *sy) {
    // Laid out at z so that, seen from straight ahead, it lands where it is on the cover; then turned round the
    // window's middle and seen in perspective.
    double k = (t.f - z) / t.f;
    double x = qx * k, y = qy * k;
    double x1 = x * t.ca + z * t.sa, z1 = -x * t.sa + z * t.ca;
    double y2 = y * t.cb + z1 * t.sb, z2 = -y * t.sb + z1 * t.cb;
    double w = t.f / (t.f - z2);
    *sx = x1 * w;
    *sy = y2 * w;
}

CGPoint AUCameraProject(AUCamera c, CGPoint p, double z) {
    double x, y;
    project(turnOf(c), p.x, p.y, z, &x, &y);
    return CGPointMake(x, y);
}

static inline double mirror(double u) {
    if (u < 0) u = -u;
    if (u > 1) u = 2 - u;
    return MAX(0.0, MIN(1.0, u));
}

static inline double gray(const uint8_t *p, size_t side, size_t high, double u, double v) {
    double x = MAX(0.0, MIN(side - 1.0, u * side - 0.5)), y = MAX(0.0, MIN(high - 1.0, v * high - 0.5));
    size_t x0 = (size_t)x, y0 = (size_t)y, x1 = MIN(x0 + 1, side - 1), y1 = MIN(y0 + 1, high - 1);
    double fx = x - x0, fy = y - y0;
    double top = p[y0 * side + x0] * (1 - fx) + p[y0 * side + x1] * fx;
    double bottom = p[y1 * side + x0] * (1 - fx) + p[y1 * side + x1] * fx;
    return (top * (1 - fy) + bottom * fy) / 255.0;
}

typedef struct {
    AUCamera camera;
    const uint8_t *plate, *raw;
    size_t plateSide, plateHigh, rawSide;
    double tall;            // the plate's height over its width: v runs 0...tall over it
    double still, median, relief;
    BOOL object, mirror;
} AUZContext;

static inline double zAt(const AUZContext *c, double qx, double qy) {
    double u = qx + 0.5, v = qy + 0.5;
    if (c->object) {
        if (!c->raw) return AUCameraZ(c->camera, c->median);
        return AUCameraObjectZ(c->camera, gray(c->raw, c->rawSide, c->rawSide, mirror(u), mirror(v)), c->median, c->relief);
    }
    if (c->mirror) return c->plate ? AUCameraZ(c->camera, gray(c->plate, c->plateSide, c->plateHigh, mirror(u), mirror(v) / c->tall)) : c->still;
    double inside = c->plate ? AUCameraZ(c->camera, gray(c->plate, c->plateSide, c->plateHigh, MAX(0.0, MIN(1.0, u)),
                                                       MAX(0.0, MIN(1.0, v / c->tall)))) : c->still;
    double out = MAX(0.0, MAX(MAX(-u, u - 1), MAX(-v, v - c->tall)));
    double t = MIN(1.0, out / 0.05);
    t = t * t * (3 - 2 * t);
    return inside * (1 - t) + c->camera.zOut * t;
}

// The picture point seen at screen point s: walked back from s (start from a nearby answer, then correct).
static inline void walkBack(const AUZContext *c, AUTurn turn, double sx, double sy, double *qx, double *qy, int steps) {
    for (int step = 0; step < steps; step++) {
        double px, py;
        project(turn, *qx, *qy, zAt(c, *qx, *qy), &px, &py);
        *qx += sx - px;
        *qy += sy - py;
    }
}

void AUSceneDraw3D(uint8_t *frame, size_t frameRow, size_t w, size_t h, CGRect square, AUScene *scene, AUCamera camera,
                   AUSceneSource source) {
    if (!frame || !source.pixels || square.size.width < 1) return;
    AUTurn turn = turnOf(camera);
    NSData *plate = scene.plateBytes, *raw = scene.rawBytes;
    AUZContext context = {camera, plate.bytes, raw.bytes, scene.plateSide, scene.plateHigh, scene.rawSide,
                          scene.plateHigh && scene.plateSide ? scene.plateHigh / (double)scene.plateSide : 1,
                          AUCameraZ(camera, scene.backgroundDepth), source.median, source.relief, source.object, source.mirror};
    const AUZContext *zc = &context;
    double midX = CGRectGetMidX(square), midY = CGRectGetMidY(square), sw = square.size.width, sh = square.size.height;
    CGRect box = CGRectIsNull(source.box) ? CGRectInfinite : CGRectInset(source.box, -0.25, -0.25);
    long y0 = 0, y1 = (long)h, xa = 0, xb = (long)w;
    if (!CGRectIsInfinite(box)) {
        y0 = MAX(0L, (long)floor(midY + CGRectGetMinY(box) * sh));
        y1 = MIN((long)h, (long)ceil(midY + CGRectGetMaxY(box) * sh));
        xa = MAX(0L, (long)floor(midX + CGRectGetMinX(box) * sw));
        xb = MIN((long)w, (long)ceil(midX + CGRectGetMaxX(box) * sw));
        if (y1 <= y0 || xb <= xa) return;
    }
    // The way back is smooth: found exactly on a grid every 8 pixels, and in between taken bilinearly from it.
    enum { kCell = 8 };
    const long gw = (xb - xa + kCell - 1) / kCell + 1, gh = (y1 - y0 + kCell - 1) / kCell + 1;
    double *grid = malloc(sizeof(double) * 2 * gw * gh);
    if (!grid) return;
    dispatch_apply((size_t)gh, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^(size_t j) {
        double sy = (y0 + (long)j * kCell + 0.5 - midY) / sh;
        double qx = (xa + 0.5 - midX) / sw, qy = sy;
        for (long i = 0; i < gw; i++) {
            double sx = (xa + i * kCell + 0.5 - midX) / sw;
            walkBack(zc, turn, sx, sy, &qx, &qy, i ? 4 : 8);
            grid[(j * gw + i) * 2] = qx;
            grid[(j * gw + i) * 2 + 1] = qy;
        }
    });
    const size_t width = source.width, height = source.height, row = source.row;
    const uint8_t *src = source.pixels;
    CGRect ss = source.square;
    BOOL object = source.object, mirrored = source.mirror;
    dispatch_apply((size_t)(y1 - y0), dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^(size_t index) {
        long y = y0 + (long)index;
        uint8_t *out = frame + y * frameRow;
        long j = (y - y0) / kCell;
        double ty = ((y - y0) % kCell) / (double)kCell;
        const double *r0 = grid + j * gw * 2, *r1 = grid + MIN(j + 1, gh - 1) * gw * 2;
        for (long x = xa; x < xb; x++) {
            long i = (x - xa) / kCell;
            double tx = ((x - xa) % kCell) / (double)kCell;
            long i1 = MIN(i + 1, gw - 1);
            double qx = (r0[i * 2] * (1 - tx) + r0[i1 * 2] * tx) * (1 - ty) + (r1[i * 2] * (1 - tx) + r1[i1 * 2] * tx) * ty;
            double qy = (r0[i * 2 + 1] * (1 - tx) + r0[i1 * 2 + 1] * tx) * (1 - ty) + (r1[i * 2 + 1] * (1 - tx) + r1[i1 * 2 + 1] * tx) * ty;
            double u = qx + 0.5, v = qy + 0.5;
            if (mirrored) {
                u = mirror(u);
                v = mirror(v);
            }
            double fx = ss.origin.x + u * ss.size.width - 0.5, fy = ss.origin.y + v * ss.size.height - 0.5;
            if (object && (fx < -1 || fy < -1 || fx > width || fy > height)) continue;
            fx = MAX(0.0, MIN(width - 1.001, fx));
            fy = MAX(0.0, MIN(height - 1.001, fy));
            size_t ix = (size_t)fx, iy = (size_t)fy;
            uint32_t ax = (uint32_t)((fx - ix) * 256), ay = (uint32_t)((fy - iy) * 256);
            const uint8_t *a = src + iy * row + ix * 4, *b = a + (iy + 1 < height ? row : 0);
            size_t step4 = ix + 1 < width ? 4 : 0;
            if (object && !a[3] && !a[step4 + 3] && !b[3] && !b[step4 + 3]) continue;
            uint8_t px[4];
            for (int c = 0; c < 4; c++) {
                uint32_t top = a[c] * (256 - ax) + a[c + step4] * ax, bottom = b[c] * (256 - ax) + b[c + step4] * ax;
                px[c] = (uint8_t)((top * (256 - ay) + bottom * ay + 32768) >> 16);
            }
            uint8_t *o = out + x * 4;
            if (!object) {
                memcpy(o, px, 4);
                continue;
            }
            // Premultiplied over: the alpha is the 4th byte in RGBA and the 4th in BGRA (little-endian ARGB) alike.
            uint32_t alpha = px[3];
            if (!alpha) continue;
            for (int c = 0; c < 4; c++) o[c] = (uint8_t)MIN(255u, px[c] + (o[c] * (255 - alpha) + 127) / 255);
        }
    });
    free(grid);
}

CGRect AUSceneAlphaBox(const uint8_t *pixels, size_t row, size_t side) {
    long minX = (long)side, minY = (long)side, maxX = -1, maxY = -1;
    for (size_t y = 0; y < side; y++) {
        const uint8_t *r = pixels + y * row;
        for (size_t x = 0; x < side; x++) {
            if (r[x * 4 + 3] < 8) continue;
            minX = MIN(minX, (long)x);
            maxX = MAX(maxX, (long)x);
            minY = MIN(minY, (long)y);
            maxY = MAX(maxY, (long)y);
        }
    }
    if (maxX < 0) return CGRectZero;
    return CGRectMake(minX / (double)side - 0.5, minY / (double)side - 0.5, (maxX - minX + 1) / (double)side,
                      (maxY - minY + 1) / (double)side);
}
