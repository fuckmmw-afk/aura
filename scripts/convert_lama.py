#!/usr/bin/env python3
"""Big-LaMa (advimman/lama, Apache-2.0) -> Core ML, one fixed 384 x 512 (w x h) canvas.

LaMa's Fourier units use torch.fft.rfftn / irfftn. At a fixed size they are exact matrix products with the discrete
Fourier transform's cos/sin matrices, which Core ML runs (on the Neural Engine too), so the units are rewritten that
way here and checked against the FFT before converting. Inputs: the image (RGB) and the mask (gray, white = fill);
output: the filled image.

    convert_lama.py <lama repo> <big-lama.safetensors> <out.mlpackage>
"""
import math, sys
import numpy as np
import torch
import torch.nn as nn

LAMA, WEIGHTS, OUT = sys.argv[1], sys.argv[2], sys.argv[3]
W, H = 384, 512
sys.path.insert(0, LAMA)
import types  # noqa: E402
for name in ('pytorch_lightning',):
    stub = types.ModuleType(name)
    stub.seed_everything = lambda *a, **k: None
    sys.modules[name] = stub
from saicinpainting.training.modules import ffc  # noqa: E402

_dft = {}


def dft(n, half):
    key = (n, half)
    if key not in _dft:
        k = np.arange(n // 2 + 1 if half else n)
        m = np.arange(n)
        angle = 2 * math.pi * np.outer(m, k) / n  # (n, k)
        _dft[key] = (torch.tensor(np.cos(angle), dtype=torch.float32), torch.tensor(np.sin(angle), dtype=torch.float32))
    return _dft[key]


def rfft2_ortho(x):
    """x (..., h, w) real -> (re, im) (..., h, w//2+1), as torch.fft.rfftn(dim=(-2,-1), norm='ortho')."""
    h, w = x.shape[-2], x.shape[-1]
    cw, sw = dft(w, True)          # (w, wr)
    a = torch.matmul(x, cw)        # re along w
    b = -torch.matmul(x, sw)       # im along w
    ch, sh = dft(h, False)         # (h, h), symmetric
    re = torch.matmul(ch, a) + torch.matmul(sh, b)
    im = torch.matmul(ch, b) - torch.matmul(sh, a)
    s = 1.0 / math.sqrt(h * w)
    return re * s, im * s


def irfft2_ortho(re, im, h, w):
    """Inverse of the above to a real (..., h, w)."""
    ch, sh = dft(h, False)
    zr = torch.matmul(ch, re) - torch.matmul(sh, im)
    zi = torch.matmul(ch, im) + torch.matmul(sh, re)
    cw, sw = dft(w, True)          # (w, wr)
    wr = w // 2 + 1
    weight = torch.full((wr,), 2.0)
    weight[0] = 1.0
    if w % 2 == 0:
        weight[-1] = 1.0
    out = torch.matmul(zr * weight, cw.t()) - torch.matmul(zi * weight, sw.t())
    return out / math.sqrt(h * w)


def fourier_forward(self, x):
    # Sizes are constants (recorded by an eager pass, see record_shapes), so the traced graph holds no shape maths.
    c, h, w = self._aura_shape if hasattr(self, '_aura_shape') else tuple(int(v) for v in x.shape[1:])
    re, im = rfft2_ortho_sized(x, h, w)
    ffted = torch.stack((re, im), dim=2).reshape(1, c * 2, h, w // 2 + 1)
    ffted = self.relu(self.bn(self.conv_layer(ffted)))
    ffted = ffted.reshape(1, -1, 2, h, w // 2 + 1)
    return irfft2_ortho(ffted[:, :, 0], ffted[:, :, 1], h, w)


def rfft2_ortho_sized(x, h, w):
    cw, sw = dft(w, True)
    a = torch.matmul(x, cw)
    b = -torch.matmul(x, sw)
    ch, sh = dft(h, False)
    re = torch.matmul(ch, a) + torch.matmul(sh, b)
    im = torch.matmul(ch, b) - torch.matmul(sh, a)
    s = 1.0 / math.sqrt(h * w)
    return re * s, im * s


def record_shapes(net, *inputs):
    hooks = []
    for m in net.modules():
        if isinstance(m, ffc.FourierUnit):
            hooks.append(m.register_forward_pre_hook(lambda mod, args: setattr(mod, '_aura_shape', tuple(int(v) for v in args[0].shape[1:]))))
    with torch.no_grad():
        net(*inputs)
    for h in hooks:
        h.remove()


original_forward = ffc.FourierUnit.forward


def build():
    kw = dict(input_nc=4, output_nc=3, ngf=64, n_downsampling=3, n_blocks=18, add_out_act='sigmoid',
              init_conv_kwargs=dict(ratio_gin=0, ratio_gout=0, enable_lfu=False),
              downsample_conv_kwargs=dict(ratio_gin=0, ratio_gout=0, enable_lfu=False),
              resnet_conv_kwargs=dict(ratio_gin=0.75, ratio_gout=0.75, enable_lfu=False))
    net = ffc.FFCResNetGenerator(**kw)
    from safetensors.torch import load_file
    state = load_file(WEIGHTS)
    state = {k.split('generator.', 1)[1]: v for k, v in state.items() if 'generator.' in k}
    missing, unexpected = net.load_state_dict(state, strict=False)
    print('missing', len(missing), missing[:5], 'unexpected', len(unexpected), unexpected[:5])
    assert not missing, 'weights do not match the generator'
    return net.eval()


class Wrapped(nn.Module):
    def __init__(self, net):
        super().__init__()
        self.net = net

    def forward(self, image, mask):
        mask = (mask > 0.5).float()
        masked = image * (1 - mask)
        out = self.net(torch.cat([masked, mask], dim=1))
        # Only the hole is the model's; the rest stays the picture's own.
        out = out * mask + image * (1 - mask)
        return torch.clamp(out, 0, 1) * 255.0


def main():
    net = build()
    # The rewrite must match the FFT: one unit, both ways, on noise.
    unit = next(m for m in net.modules() if isinstance(m, ffc.FourierUnit))
    x = torch.randn(1, unit.conv_layer.in_channels // 2, 64, 48)
    with torch.no_grad():
        a = original_forward(unit, x)
        b = fourier_forward(unit, x)
    err = (a - b).abs().max().item()
    print('fourier rewrite max error', err)
    assert err < 1e-3
    ffc.FourierUnit.forward = fourier_forward
    model = Wrapped(net).eval()
    img = torch.rand(1, 3, H, W)
    mask = torch.zeros(1, 1, H, W)
    mask[..., 100:300, 100:250] = 1
    record_shapes(model, img, mask)
    with torch.no_grad():
        traced = torch.jit.trace(model, (img, mask))
    import coremltools as ct
    mlmodel = ct.convert(
        traced,
        inputs=[ct.ImageType(name='image', shape=img.shape, scale=1 / 255.0, color_layout=ct.colorlayout.RGB),
                ct.ImageType(name='mask', shape=mask.shape, scale=1 / 255.0, color_layout=ct.colorlayout.GRAYSCALE)],
        outputs=[ct.ImageType(name='filled', color_layout=ct.colorlayout.RGB)],
        compute_precision=ct.precision.FLOAT16,
        minimum_deployment_target=ct.target.iOS17,
        convert_to='mlprogram',
    )
    import coremltools.optimize.coreml as cto
    # Only the convolutions: the Fourier matrices (64 x 64 at most) stay exact.
    config = cto.OptimizationConfig(global_config=cto.OpPalettizerConfig(mode='kmeans', nbits=8, weight_threshold=8192))
    mlmodel = cto.palettize_weights(mlmodel, config)
    mlmodel.short_description = 'Big-LaMa inpainting (advimman/lama, Apache-2.0), 384x512, 8-bit palettized'
    mlmodel.license = 'Apache-2.0'
    mlmodel.save(OUT)
    print('saved', OUT)


if __name__ == '__main__':
    main()
