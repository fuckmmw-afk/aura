// AUVoiceDSP on a recording (raw stereo float32 at 44.1 kHz): prints the syllable starts it hears, in seconds.
// Linux: cc -O2 -ITests/linux -ISources Tests/voice_dsp_test.c Sources/Features/AUVoiceDSP.c -lm
#include <stdio.h>
#include <stdlib.h>
#include "Features/AUVoiceDSP.h"
enum { kRing = 1 << 17 };
static float mid[kRing], side[kRing];
static void onset(uint64_t sample, double rate, void *context) { printf("%.2f\n", sample / rate); }
int main(int argc, char **argv) {
    FILE *f = fopen(argv[1], "rb");
    if (!f) return 1;
    AUVoiceDSP *dsp = AUVoiceDSPCreate();
    float block[512 * 2];
    uint64_t written = 0;
    size_t got;
    while ((got = fread(block, sizeof(float) * 2, 512, f)) > 0) {
        for (size_t i = 0; i < got; i++) {
            mid[(written + i) & (kRing - 1)] = (block[2 * i] + block[2 * i + 1]) / 2;
            side[(written + i) & (kRing - 1)] = (block[2 * i] - block[2 * i + 1]) / 2;
        }
        written += got;
        AUVoiceDSPRun(dsp, mid, side, kRing - 1, written, 44100, argc > 2 ? atof(argv[2]) : 1.0, onset, NULL);
    }
    return 0;
}
