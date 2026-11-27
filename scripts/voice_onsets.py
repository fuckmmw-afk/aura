# Prototype of the live syllable tracker (Aura's AUVoice): vocal onsets from the centre of the mix.
import sys, numpy as np
SR = 44100
x = np.fromfile(sys.argv[1], np.float32).reshape(-1, 2)
N, HOP = 2048, 441          # 10 ms hop
win = np.hanning(N).astype(np.float32)
mid = (x[:, 0] + x[:, 1]) / 2
side = (x[:, 0] - x[:, 1]) / 2
freqs = np.fft.rfftfreq(N, 1 / SR)
band = (freqs >= 180) & (freqs <= 4000)
frames = (len(mid) - N) // HOP
prev = None
flux, voiced, energy = [], [], []
hist = []
for i in range(frames):
    s = i * HOP
    M = np.abs(np.fft.rfft(mid[s:s + N] * win))
    S = np.abs(np.fft.rfft(side[s:s + N] * win))
    C = np.maximum(M - 1.0 * S, 0)[band]
    L = np.log1p(30 * C)
    hist.append(L)
    if len(hist) > 3: hist.pop(0)
    ref = np.maximum(hist[0], hist[1]) if len(hist) >= 3 else L
    d = np.maximum(L - ref, 0)
    flux.append(d.sum())
    # how tonal the rise is: peaky (a voice's harmonics) or flat (a drum)
    p = d + 1e-6
    flat = np.exp(np.log(p).mean()) / p.mean()
    voiced.append(1 - flat)
    energy.append(L.sum())
flux = np.array(flux); voiced = np.array(voiced); energy = np.array(energy)
o = flux * voiced ** 2
# live peak picking: the value must beat a running threshold from the past 0.6 s only
t_on = []
last = -1
for i in range(2, len(o) - 1):
    past = o[max(0, i - 60):i]
    thr = np.median(past) * 1.5 + 0.15 * (past.max() if len(past) else 0) + 1e-3
    if o[i] > thr and o[i] >= o[i - 1] and o[i] >= o[i + 1] and (i - last) * HOP / SR > 0.085:
        t_on.append(i * HOP / SR + N / 2 / SR)
        last = i
t_on = np.array(t_on)
cuts = [0.517, 3.55, 6.617, 9.75, 12.517]
for a, b in zip(cuts, cuts[1:]):
    sel = t_on[(t_on >= a - 0.3) & (t_on < b - 0.3)]
    print('%.2f-%.2f: %d onsets  %s' % (a, b, len(sel), ' '.join('%.2f' % t for t in sel)))
np.save('/tmp/onsets.npy', t_on)
