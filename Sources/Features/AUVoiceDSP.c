#include "AUVoiceDSP.h"
#include <Accelerate/Accelerate.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>

enum { kN = 2048, kLog2N = 11, kHistory = 60 };

struct AUVoiceDSP {
    FFTSetup fft;
    float window[kN], frame[kN], real[kN / 2], imag[kN / 2], mid[kN / 2], side[kN / 2];
    float previous[2][kN / 2];
    int filled;
    uint64_t next;          // the first sample of the next frame
    double rate;
    float history[kHistory];
    int historyCount;
    float last[2];          // the two newest values
    uint64_t lastStart[2];
    uint64_t lastOnset;
};

AUVoiceDSP *AUVoiceDSPCreate(void) {
    AUVoiceDSP *dsp = calloc(1, sizeof(AUVoiceDSP));
    if (!dsp) return NULL;
    dsp->fft = vDSP_create_fftsetup(kLog2N, kFFTRadix2);
    vDSP_hann_window(dsp->window, kN, vDSP_HANN_NORM);
    return dsp;
}

static void spectrum(AUVoiceDSP *s, const float *ring, uint64_t mask, float *out) {
    for (int i = 0; i < kN; i++) s->frame[i] = ring[(s->next + (uint64_t)i) & mask] * s->window[i];
    DSPSplitComplex split = {s->real, s->imag};
    vDSP_ctoz((const DSPComplex *)s->frame, 2, &split, 1, kN / 2);
    vDSP_fft_zrip(s->fft, &split, 1, kLog2N, FFT_FORWARD);
    split.imagp[0] = 0;
    vDSP_zvabs(&split, 1, out, 1, kN / 2);
}

static int compareFloats(const void *a, const void *b) {
    float x = *(const float *)a, y = *(const float *)b;
    return x < y ? -1 : x > y;
}

void AUVoiceDSPRun(AUVoiceDSP *s, const float *mid, const float *side, uint64_t mask, uint64_t written, double rate,
                   double sensitivity, void (*onset)(uint64_t sample, double rate, void *context), void *context) {
    if (!s || rate < 8000) return;
    if (rate != s->rate) {
        s->rate = rate;
        s->filled = 0;
        s->historyCount = 0;
    }
    if (written < s->next || written - s->next > (mask + 1) / 2) {   // a fresh start, or fallen far behind: from now
        s->next = written > kN ? written - kN : 0;
        s->filled = 0;
    }
    uint64_t hop = (uint64_t)fmax(64, round(rate / 100));
    int low = (int)ceil(180.0 * kN / rate), high = (int)floor(4000.0 * kN / rate);
    if (high > kN / 2 - 1) high = kN / 2 - 1;
    int bins = high - low + 1;
    while (s->next + kN <= written) {
        spectrum(s, mid, mask, s->mid);
        spectrum(s, side, mask, s->side);
        float current[kN / 2];
        memset(current, 0, sizeof current);
        for (int b = low; b <= high; b++) {
            // vDSP's real FFT is twice the plain DFT: 15 here is the prototype's 30 (scripts/voice_onsets.py).
            float centre = fmaxf(s->mid[b] - s->side[b], 0);
            current[b] = log1pf(15 * centre);
        }
        float flux = 0, logSum = 0, sum = 0;
        if (s->filled >= 2) {
            for (int b = low; b <= high; b++) {
                float rise = fmaxf(current[b] - fmaxf(s->previous[0][b], s->previous[1][b]), 0);
                flux += rise;
                logSum += logf(rise + 1e-6f);
                sum += rise + 1e-6f;
            }
        }
        float flat = sum > 0 ? expf(logSum / bins) / (sum / bins) : 1;
        float value = flux * (1 - flat) * (1 - flat);
        memcpy(s->previous[0], s->previous[1], sizeof s->previous[0]);
        memcpy(s->previous[1], current, sizeof current);
        s->filled++;
        // A peak one frame late: the frame before is above both neighbours and the threshold of the frames before it.
        if (s->historyCount >= 8) {
            float sorted[kHistory];
            int n = s->historyCount < kHistory ? s->historyCount : kHistory;
            memcpy(sorted, s->history, sizeof(float) * (size_t)n);
            qsort(sorted, (size_t)n, sizeof(float), compareFloats);
            float threshold = (sorted[n / 2] * 1.5f + 0.15f * sorted[n - 1] + 1e-3f) / (float)fmax(0.3, sensitivity);
            float peak = s->last[1];
            uint64_t at = s->lastStart[1] + kN / 2;
            if (s->filled > 3 && peak > threshold && peak >= s->last[0] && peak >= value &&
                (s->lastOnset == 0 || at > s->lastOnset + (uint64_t)(0.085 * rate))) {
                s->lastOnset = at;
                onset(at, rate, context);
            }
        }
        // The threshold's past is the frames before the one judged.
        if (s->filled > 1) {
            if (s->historyCount < kHistory) s->history[s->historyCount++] = s->last[1];
            else {
                memmove(s->history, s->history + 1, sizeof(float) * (kHistory - 1));
                s->history[kHistory - 1] = s->last[1];
            }
        }
        s->last[0] = s->last[1];
        s->lastStart[0] = s->lastStart[1];
        s->last[1] = value;
        s->lastStart[1] = s->next;
        s->next += hop;
    }
}
