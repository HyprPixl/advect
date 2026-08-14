/* Bridging header: exposes the C march to Swift.
 *
 * The Python CLI compiles advect_accel.c on demand with cc; the app links it at
 * build time instead, so a machine running the app needs no compiler at all. */
#ifndef ADVECT_ACCEL_H
#define ADVECT_ACCEL_H

#include <stdint.h>

void fp_march(const double *g, double cell, double twist,
              int w, int h,
              const double *px, const double *py,
              const uint8_t *pmode, const double *palpha, const uint8_t *pcol,
              int n, int steps, const double *tw,
              uint8_t *buf,
              int use_glow, float *light, int lw, int lh, int ds, double light_k);

void fp_composite(uint8_t *buf, const float *light, double glow,
                  int lw, int lh, int ds, int w, int h);

#endif
