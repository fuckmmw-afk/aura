#!/usr/bin/env python3
"""Real-ESRGAN realesr-general-x4v3 (SRVGGNetCompact, BSD-3-Clause, xinntao/Real-ESRGAN) -> Core ML.

One fixed 128x128 RGB tile in, the 512x512 tile out, both as images, fp16, so the Neural Engine runs it.
The network is defined here (it is 30 lines in Real-ESRGAN), so basicsr is not needed.

    python convert_esrgan.py realesr-general-x4v3.pth out/RealESRGANGeneralX4v3.mlpackage
"""
import sys
import torch
import torch.nn as nn
import torch.nn.functional as F
import coremltools as ct

TILE = 128


class SRVGGNetCompact(nn.Module):
    def __init__(self, num_in_ch=3, num_out_ch=3, num_feat=64, num_conv=32, upscale=4):
        super().__init__()
        self.upscale = upscale
        self.body = nn.ModuleList()
        self.body.append(nn.Conv2d(num_in_ch, num_feat, 3, 1, 1))
        self.body.append(nn.PReLU(num_parameters=num_feat))
        for _ in range(num_conv):
            self.body.append(nn.Conv2d(num_feat, num_feat, 3, 1, 1))
            self.body.append(nn.PReLU(num_parameters=num_feat))
        self.body.append(nn.Conv2d(num_feat, num_out_ch * upscale * upscale, 3, 1, 1))
        self.upsampler = nn.PixelShuffle(upscale)

    def forward(self, x):
        out = x
        for layer in self.body:
            out = layer(out)
        out = self.upsampler(out)
        base = F.interpolate(x, scale_factor=self.upscale, mode="nearest")
        return out + base


class Wrapped(nn.Module):
    """0..1 in (the image input's scale), 0..255 out, clamped, as an image output wants."""

    def __init__(self, net):
        super().__init__()
        self.net = net

    def forward(self, x):
        return torch.clamp(self.net(x), 0.0, 1.0) * 255.0


def main(src, dst):
    net = SRVGGNetCompact()
    state = torch.load(src, map_location="cpu")
    state = state.get("params", state.get("params_ema", state))
    net.load_state_dict(state, strict=True)
    net.eval()
    model = Wrapped(net).eval()
    example = torch.rand(1, 3, TILE, TILE)
    with torch.no_grad():
        traced = torch.jit.trace(model, example)
    mlmodel = ct.convert(
        traced,
        inputs=[ct.ImageType(name="image", shape=example.shape, scale=1 / 255.0, color_layout=ct.colorlayout.RGB)],
        outputs=[ct.ImageType(name="upscaled", color_layout=ct.colorlayout.RGB)],
        compute_precision=ct.precision.FLOAT16,
        minimum_deployment_target=ct.target.iOS16,
        convert_to="mlprogram",
    )
    mlmodel.short_description = "Real-ESRGAN realesr-general-x4v3, 128px tile x4 (BSD-3-Clause, xinntao/Real-ESRGAN)"
    mlmodel.license = "BSD-3-Clause"
    mlmodel.user_defined_metadata["aura.tile"] = str(TILE)
    mlmodel.user_defined_metadata["aura.scale"] = "4"
    mlmodel.save(dst)
    params = sum(p.numel() for p in net.parameters())
    print(f"saved {dst}, {params} parameters")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
