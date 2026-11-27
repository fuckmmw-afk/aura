// AUVoice's listening, in plain C so it can be run on a recording off the phone (Tests/voice_dsp_test.c): sung
// syllable starts in the centre of a mix. One 2048-point frame every 10 ms over mid and side; the rise in the log
// spectrum of the centre (mid less side) between 180 Hz and 4 kHz, weighted by how tonal it is (1 − spectral
// flatness of the rise, squared), is peak-picked one frame late against a threshold from the last 0.6 s.
#pragma once
#include <stdint.h>

typedef struct AUVoiceDSP AUVoiceDSP;
AUVoiceDSP *AUVoiceDSPCreate(void);
// Every whole frame from where it stopped up to `written` samples of the rings (size mask + 1, a power of two);
// `onset` gets the sample each syllable starts at. A jump back or far ahead starts afresh at the newest samples.
void AUVoiceDSPRun(AUVoiceDSP *dsp, const float *mid, const float *side, uint64_t mask, uint64_t written, double rate,
                   double sensitivity, void (*onset)(uint64_t sample, double rate, void *context), void *context);
