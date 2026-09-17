#!/usr/bin/env python3
"""
Converts InsightFace's ArcFace recognition model (w600k_mbf, MobileFaceNet
backbone trained with ArcFace loss) into a Core ML .mlpackage that Glance's
Swift code can load directly.

Pipeline: ONNX (InsightFace's official weights) -> torch (via onnx2torch)
-> traced TorchScript -> Core ML, with preprocessing baked into the model so
Swift only ever hands over a raw RGB 112x112 image.

Usage:
    python3 -m venv .venv && source .venv/bin/activate
    pip install -r tools/requirements.txt
    python tools/convert_arcface.py --variant w600k_mbf

Output:
    glance/Models/ArcFace.mlpackage
        input:  "input_image", 112x112 RGB CVPixelBuffer/CGImage
        output: "embedding", 512 floats (NOT yet L2-normalized — Swift does that)

This script does not modify the Xcode project or any Swift source. It only
produces the model file; wiring it in is a separate, reviewable step.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_OUTPUT = REPO_ROOT / "glance" / "Models" / "ArcFace.mlpackage"

VARIANT_ONNX_NAMES = {
    "w600k_mbf": "w600k_mbf.onnx",   # buffalo_s pack, ~13MB, MobileFaceNet backbone
    "w600k_r50": "w600k_r50.onnx",   # buffalo_l pack, ~166MB, ResNet50 backbone
}
VARIANT_PACK = {
    "w600k_mbf": "buffalo_s",
    "w600k_r50": "buffalo_l",
}


def fail(message: str) -> None:
    print(f"\nERROR: {message}\n", file=sys.stderr)
    sys.exit(1)


def locate_or_download_onnx(variant: str, explicit_path: str | None) -> Path:
    """Returns a local path to the recognition-model .onnx file.

    Prefers an explicit --onnx-path if given (for when auto-download fails
    or the user already has the weights). Otherwise downloads the official
    InsightFace model pack via the `insightface` package's own model zoo,
    which is the actively-maintained source for these weights — more
    resilient than us hardcoding a URL that could move.
    """
    if explicit_path:
        path = Path(explicit_path).expanduser().resolve()
        if not path.is_file():
            fail(f"--onnx-path does not exist: {path}")
        return path

    try:
        from insightface.app import FaceAnalysis
    except ImportError:
        fail(
            "The 'insightface' package is required to auto-download weights.\n"
            "Install it with: pip install insightface onnxruntime opencv-python\n"
            "Or download w600k_mbf.onnx yourself and pass --onnx-path."
        )

    pack_name = VARIANT_PACK[variant]
    print(f"Downloading InsightFace '{pack_name}' model pack (first run only)...")
    # .prepare() triggers the download+unzip into ~/.insightface/models/<pack>/
    # and validates every model in the pack loads correctly.
    app = FaceAnalysis(name=pack_name, providers=["CPUExecutionProvider"])
    app.prepare(ctx_id=-1)

    model_dir = Path.home() / ".insightface" / "models" / pack_name
    onnx_name = VARIANT_ONNX_NAMES[variant]
    matches = list(model_dir.glob(f"*{onnx_name}"))
    if not matches:
        fail(
            f"Downloaded pack '{pack_name}' but couldn't find {onnx_name} in {model_dir}. "
            f"Contents: {list(model_dir.iterdir()) if model_dir.exists() else 'directory missing'}"
        )
    return matches[0]


def convert_to_coreml(onnx_path: Path, output_path: Path, variant: str, precision: str) -> None:
    import numpy as np
    import onnx
    import coremltools as ct
    from onnx2torch import convert
    import torch

    print(f"Loading ONNX model from {onnx_path} ({onnx_path.stat().st_size / 1e6:.1f} MB)...")
    onnx_model = onnx.load(str(onnx_path))
    onnx.checker.check_model(onnx_model)

    print("Converting ONNX -> torch (via onnx2torch)...")
    torch_model = convert(onnx_model)
    torch_model.eval()

    dummy_input = torch.randn(1, 3, 112, 112)
    with torch.no_grad():
        traced = torch.jit.trace(torch_model, dummy_input)

    print("Converting torch -> Core ML (preprocessing baked in: RGB, (px-127.5)/127.5)...")
    mlmodel = ct.convert(
        traced,
        inputs=[
            ct.ImageType(
                name="input_image",
                shape=(1, 3, 112, 112),
                scale=1.0 / 127.5,
                bias=[-1.0, -1.0, -1.0],
                color_layout=ct.colorlayout.RGB,
            )
        ],
        outputs=[ct.TensorType(name="embedding")],
        minimum_deployment_target=ct.target.macOS14,
        compute_precision=ct.precision.FLOAT32 if precision == "float32" else ct.precision.FLOAT16,
        compute_units=ct.ComputeUnit.ALL,
    )

    mlmodel.short_description = f"ArcFace ({variant}, {precision}) face embedding — 512-d, on-device"
    mlmodel.input_description["input_image"] = "112x112 RGB aligned face crop"
    mlmodel.output_description["embedding"] = "512-float embedding (not L2-normalized)"

    return mlmodel, onnx_path


def verify_parity(mlmodel, onnx_path: Path) -> None:
    """The real correctness check: feed identical random pixels through both
    the original ONNX graph and the converted Core ML model, and confirm
    they agree. Shape-only checks would miss a channel-order or scale bug —
    exactly the kind of mistake that silently wrecks ArcFace accuracy
    without ever throwing an error.
    """
    import numpy as np
    import onnxruntime as ort
    from PIL import Image

    sess = ort.InferenceSession(str(onnx_path), providers=["CPUExecutionProvider"])
    onnx_input_name = sess.get_inputs()[0].name

    def agreement(pixels: "np.ndarray") -> float:
        chw = pixels.astype(np.float32).transpose(2, 0, 1)[None]
        onnx_out = sess.run(None, {onnx_input_name: (chw - 127.5) / 127.5})[0].flatten()
        coreml_out = np.array(
            mlmodel.predict({"input_image": Image.fromarray(pixels, mode="RGB")})["embedding"]
        ).flatten()
        if onnx_out.shape != (512,) or coreml_out.shape != (512,):
            fail(f"Unexpected output shape: onnx={onnx_out.shape}, coreml={coreml_out.shape} (expected (512,))")
        return float(np.dot(onnx_out, coreml_out) / (np.linalg.norm(onnx_out) * np.linalg.norm(coreml_out)))

    rng = np.random.default_rng(0)

    # Uniform noise. Deliberately the worst case — it is nothing like a face,
    # so the network is operating far outside its training distribution and
    # numerical error is at its largest. This stays the gate.
    noise_cos = agreement(rng.integers(0, 256, size=(112, 112, 3), dtype=np.uint8))

    # A smooth, low-frequency image at face scale. Still not a face, but much
    # closer to the statistics of one than uniform noise, and therefore a
    # better estimate of the error the app will actually see.
    yy, xx = np.mgrid[0:112, 0:112] / 111.0
    smooth = np.stack([
        0.45 + 0.35 * np.sin(3.0 * xx + 0.7) * np.cos(2.2 * yy),
        0.50 + 0.30 * np.cos(2.4 * xx) * np.sin(2.9 * yy + 1.1),
        0.40 + 0.25 * np.sin(2.0 * xx + 2.0) * np.cos(3.3 * yy),
    ], axis=-1)
    smooth_cos = agreement(np.clip(smooth * 255, 0, 255).astype(np.uint8))

    print(f"  uniform noise (worst case): {noise_cos:.6f}")
    print(f"  smooth face-scale input:    {smooth_cos:.6f}")
    if noise_cos < 0.999:
        fail(
            f"Parity check failed: {noise_cos:.6f} on uniform noise, below the 0.999 gate.\n"
            "  A cosine this HIGH is not a preprocessing bug — a channel-order or scale/bias\n"
            "  mistake lands nearer 0.3-0.7. Above ~0.99 the cause is almost always numerical\n"
            "  precision accumulating through the network, which hurts deeper backbones such as\n"
            "  w600k_r50 far more than w600k_mbf. Re-run with --precision float32.\n"
            "  Nothing has been written to the output path."
        )
    print("Parity check passed. The conversion is numerically correct.")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--variant", choices=sorted(VARIANT_ONNX_NAMES), default="w600k_mbf")
    parser.add_argument("--onnx-path", default=None, help="Skip auto-download; use this local .onnx file instead.")
    parser.add_argument("--output", default=str(DEFAULT_OUTPUT), help="Output .mlpackage path.")
    parser.add_argument("--skip-verify", action="store_true", help="Skip the ONNX/Core ML parity check.")
    parser.add_argument(
        "--precision", choices=["float16", "float32"], default="float16",
        help="Core ML compute precision. float16 halves the file; float32 is more faithful to "
             "the original weights and is usually needed for the deeper w600k_r50 backbone.",
    )
    args = parser.parse_args()

    output_path = Path(args.output)
    onnx_path = locate_or_download_onnx(args.variant, args.onnx_path)
    mlmodel, onnx_path = convert_to_coreml(onnx_path, output_path, args.variant, args.precision)

    if not args.skip_verify:
        verify_parity(mlmodel, onnx_path)

    # Written only once the parity check has passed, so a failed conversion can
    # never leave an unusable model sitting in the repository.
    output_path.parent.mkdir(parents=True, exist_ok=True)
    mlmodel.save(str(output_path))
    print(f"Saved {output_path}")

    print(f"\nDone. Model ready at: {args.output}")
    print("Next: add this file to the Xcode project (glance/Models/ArcFace.mlpackage) if not auto-picked-up,")
    print("then build — ArcFaceEmbedder.swift will load it from the app bundle at runtime.")


if __name__ == "__main__":
    main()
