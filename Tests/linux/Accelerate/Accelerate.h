// The few vDSP calls AUVoiceDSP makes, in plain C, so Tests/voice_dsp_test.c runs on Linux. Same scaling as vDSP:
// vDSP_fft_zrip's output is twice the plain DFT, packed (DC in realp[0], Nyquist in imagp[0]).
#pragma once
#include <math.h>
#include <stdlib.h>
typedef struct { float *realp, *imagp; } DSPSplitComplex;
typedef struct { float real, imag; } DSPComplex;
typedef struct { int log2n; } *FFTSetup;
enum { kFFTRadix2 = 0, FFT_FORWARD = 1, vDSP_HANN_NORM = 2 };
static inline FFTSetup vDSP_create_fftsetup(long log2n, int radix) { FFTSetup s = malloc(sizeof *s); s->log2n = (int)log2n; return s; }
static inline void vDSP_hann_window(float *w, long n, int flag) { for (long i = 0; i < n; i++) w[i] = 0.5f * (1 - cosf(2 * (float)M_PI * i / n)); }
static inline void vDSP_ctoz(const DSPComplex *c, long stride, const DSPSplitComplex *z, long zs, long n) {
    for (long i = 0; i < n; i++) { z->realp[i] = c[i].real; z->imagp[i] = c[i].imag; }
}
static inline void vDSP_fft_zrip(FFTSetup s, const DSPSplitComplex *z, long stride, long log2n, int direction) {
    long n = 1L << log2n, h = n / 2;
    double *re = malloc(sizeof(double) * n), *im = calloc(n, sizeof(double));
    for (long i = 0; i < h; i++) { re[2 * i] = z->realp[i]; re[2 * i + 1] = z->imagp[i]; }
    for (long i = 1, j = 0; i < n; i++) {   // bit reversal
        long bit = n >> 1;
        for (; j & bit; bit >>= 1) j ^= bit;
        j ^= bit;
        if (i < j) { double t = re[i]; re[i] = re[j]; re[j] = t; t = im[i]; im[i] = im[j]; im[j] = t; }
    }
    for (long len = 2; len <= n; len <<= 1) {
        double a = -2 * M_PI / len;
        for (long i = 0; i < n; i += len)
            for (long k = 0; k < len / 2; k++) {
                double wr = cos(a * k), wi = sin(a * k);
                double xr = re[i + k + len / 2] * wr - im[i + k + len / 2] * wi, xi = re[i + k + len / 2] * wi + im[i + k + len / 2] * wr;
                re[i + k + len / 2] = re[i + k] - xr; im[i + k + len / 2] = im[i + k] - xi;
                re[i + k] += xr; im[i + k] += xi;
            }
    }
    z->realp[0] = (float)(2 * re[0]); z->imagp[0] = (float)(2 * re[h]);
    for (long k = 1; k < h; k++) { z->realp[k] = (float)(2 * re[k]); z->imagp[k] = (float)(2 * im[k]); }
    free(re); free(im);
}
static inline void vDSP_zvabs(const DSPSplitComplex *z, long s, float *out, long os, long n) {
    for (long i = 0; i < n; i++) out[i] = hypotf(z->realp[i], z->imagp[i]);
}
