/* advect_accel — the hot flow-field march, in C.
 *
 * Mirrors the pure-Python render() inner loop exactly (doubles throughout, same
 * truncation semantics) so --backend c is a drop-in accelerator: identical seed,
 * identical image, ~50x faster. Python still owns every rng draw and hands us the
 * noise grid + the fully-decided per-particle spec; we only march and splat.
 *
 * Built on demand by advect via `cc -O3` into ~/.cache/advect/ and loaded
 * through ctypes (stdlib), so the script stays dependency-free.
 */
#include <math.h>
#include <stdint.h>

/* value noise + fBm, byte-for-byte the same as Noise.raw / Noise.fbm */
static inline double raw(const double *g, double cell, double x, double y) {
    double gx = x / cell, gy = y / cell;
    int ix = ((int)gx) & 63, iy = ((int)gy) & 63;
    double fx = gx - (int)gx, fy = gy - (int)gy;
    double sx = fx * fx * (3 - 2 * fx), sy = fy * fy * (3 - 2 * fy);
    int ix1 = (ix + 1) & 63, iy1 = (iy + 1) & 63;
    double a = g[iy * 64 + ix], b = g[iy * 64 + ix1];
    double c = g[iy1 * 64 + ix], d = g[iy1 * 64 + ix1];
    return a + (b - a) * sx + (c - a) * sy + (a - b - c + d) * sx * sy;
}

static inline double fbm(const double *g, double cell, double x, double y) {
    return raw(g, cell, x, y) * 0.5
         + raw(g, cell, x * 2.1 + 31, y * 2.1 + 57) * 0.3
         + raw(g, cell, x * 4.3 + 89, y * 4.3 + 13) * 0.2;
}

/* March every particle. Sharp strokes alpha-blend into buf in particle order
 * (order-dependent, exactly like Python); diffuse strokes accumulate into the
 * coarse light grid. */
/* tw[s] is a per-step taper weight (0..1) so strokes fade in/out at their ends
 * instead of stopping dead — shared with Python for exact parity. */
void fp_march(const double *g, double cell, double twist,
              int w, int h,
              const double *px, const double *py,
              const uint8_t *pmode, const double *palpha, const uint8_t *pcol,
              int n, int steps, const double *tw,
              uint8_t *buf,
              int use_glow, float *light, int lw, int lh, int ds, double light_k) {
    for (int p = 0; p < n; p++) {
        double x = px[p], y = py[p];
        int cr = pcol[p * 3], cg = pcol[p * 3 + 1], cb = pcol[p * 3 + 2];
        if (use_glow && pmode[p]) {                 /* diffuse: emit light */
            double er = cr * light_k, eg = cg * light_k, eb = cb * light_k;
            for (int s = 0; s < steps; s++) {
                double theta = fbm(g, cell, x, y) * twist;
                x += cos(theta) * 1.6;
                y += sin(theta) * 1.6;
                if (!(1 <= x && x < w - 1 && 1 <= y && y < h - 1)) break;
                double e = tw[s];
                long li = (((long)y / ds) * lw + (long)x / ds) * 3;
                light[li]     = (float)(light[li] + er * e);
                light[li + 1] = (float)(light[li + 1] + eg * e);
                light[li + 2] = (float)(light[li + 2] + eb * e);
            }
        } else {                                    /* sharp: crisp AA line */
            double a = palpha[p];
            for (int s = 0; s < steps; s++) {
                double theta = fbm(g, cell, x, y) * twist;
                x += cos(theta) * 1.6;
                y += sin(theta) * 1.6;
                if (!(1 <= x && x < w - 1 && 1 <= y && y < h - 1)) break;
                double at = a * tw[s];
                int x0 = (int)x, y0 = (int)y;
                double fx = x - x0, fy = y - y0;
                double wt[4] = {(1 - fx) * (1 - fy), fx * (1 - fy),
                                (1 - fx) * fy,       fx * fy};
                int dxdy[4][2] = {{0, 0}, {1, 0}, {0, 1}, {1, 1}};
                for (int t = 0; t < 4; t++) {
                    long i = ((long)(y0 + dxdy[t][1]) * w + (x0 + dxdy[t][0])) * 3;
                    double aw = at * wt[t];
                    buf[i]     = (int)(buf[i]     + (cr - buf[i])     * aw);
                    buf[i + 1] = (int)(buf[i + 1] + (cg - buf[i + 1]) * aw);
                    buf[i + 2] = (int)(buf[i + 2] + (cb - buf[i + 2]) * aw);
                }
            }
        }
    }
}

static inline int clampi(int v, int lo, int hi) { return v < lo ? lo : (v > hi ? hi : v); }

/* Add the blurred light layer back over the image with bilinear upsampling:
 * each full-res pixel samples the 4 nearest light cells, so the glow is smooth
 * instead of showing DS×DS blocks. */
void fp_composite(uint8_t *buf, const float *light, double glow,
                  int lw, int lh, int ds, int w, int h) {
    for (int y = 0; y < h; y++) {
        double gy = (y + 0.5) / ds - 0.5;
        int ly0 = (int)floor(gy);
        double ty = gy - ly0;
        int cy0 = clampi(ly0, 0, lh - 1), cy1 = clampi(ly0 + 1, 0, lh - 1);
        for (int x = 0; x < w; x++) {
            double gx = (x + 0.5) / ds - 0.5;
            int lx0 = (int)floor(gx);
            double tx = gx - lx0;
            int cx0 = clampi(lx0, 0, lw - 1), cx1 = clampi(lx0 + 1, 0, lw - 1);
            double w00 = (1 - tx) * (1 - ty), w01 = tx * (1 - ty),
                   w10 = (1 - tx) * ty,       w11 = tx * ty;
            long i00 = ((long)cy0 * lw + cx0) * 3, i01 = ((long)cy0 * lw + cx1) * 3,
                 i10 = ((long)cy1 * lw + cx0) * 3, i11 = ((long)cy1 * lw + cx1) * 3;
            long o = ((long)y * w + x) * 3;
            for (int c = 0; c < 3; c++) {
                double lv = light[i00 + c] * w00 + light[i01 + c] * w01
                          + light[i10 + c] * w10 + light[i11 + c] * w11;
                double v = buf[o + c] + lv * glow;
                buf[o + c] = v > 255 ? 255 : (int)v;
            }
        }
    }
}
