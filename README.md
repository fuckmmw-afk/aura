# Aura

On-device AI effects for the **Taurus** redesigned Spotify player on iOS, as a separate add-on dylib.

Aura is not a fork of Taurus and contains none of its code. It runs next to an unmodified Taurus build in the same
app and reaches it only through the functions and classes Taurus's dylib exports, at run time. Without Taurus, or with
Taurus's native look, Aura stays off.

## What it does (phase A)

| Feature | How | Model |
|---|---|---|
| Theme from the cover | k-means over the cover's pixels (vDSP); Liquid Glass panes take the accent as their tint, the player's lit controls slide to it through Taurus's *Follow the cover* | none |
| Living covers | depth map of the cover, rendered on Metal with steep parallax, driven by the gyroscope | Depth Anything V2 Small, 8-bit palettized (Apple Core ML) |
| The artist steps out of the cover | Vision person instance mask; the subject is drawn over the cover, unclipped, the cover behind it blurred | system (Vision) |
| Upscaled small covers | covers under 600 px go through Real-ESRGAN x4 in 128 px tiles | realesr-general-x4v3, converted with `scripts/convert_esrgan.py` |

Models are not inside the dylib: the phone fetches them on first use from a model server (manifest + files + sha256,
see `scripts/publish_model.py`), compiles them once and keeps them in Application Support. Results are cached per cover.
Settings: Taurus's Mod Settings → **Aura**.

## Build

GitHub Actions (`.github/workflows/build.yml`) on a macOS runner with Theos. Secrets:

- `AURA_MODELS_URL` — the model server's base URL, compiled in (never in the repository);
- `AURA_ARTIFACT_KEY` — the artifact is uploaded encrypted with it, since the repository and its artifacts are public.

Locally: `THEOS=~/theos make AURA_MODELS_URL=https://…/aura/models`.

The result is `Aura.dylib`, injected into the app next to Taurus by the signer.

## Credits and licenses

- Aura's own code: MIT (`LICENSE`).
- **Taurus** — Copyright Vojtěch Škopek (https://github.com/skopevoj/spoti.pw), PolyForm Strict License 1.0.0. Not
  included, not modified, not distributed here; Aura only calls it at run time.
- **Depth Anything V2 Small** Core ML (apple/coreml-depth-anything-v2-small) — Apache-2.0. Lihe Yang et al., *Depth Anything V2*.
- **Real-ESRGAN** realesr-general-x4v3 (xinntao/Real-ESRGAN) — BSD-3-Clause. Xintao Wang et al.
- Not affiliated with Spotify or with Taurus.
