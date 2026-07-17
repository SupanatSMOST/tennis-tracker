"""Convert Phase-0 pretrained weights to CoreML.

Usage (from repo root):
    python cv/convert_models.py
    python cv/convert_models.py --ball_model cv/models/ball_track.pt \
                                 --bounce_model cv/models/bounce.cbm \
                                 --out_dir cv/models/

Writes:
    <out_dir>/BallTracker.mlpackage   -- TrackNet heatmap model (input: 1×9×360×640)
    <out_dir>/BounceDetector.mlmodel  -- CatBoost regressor (12-column features)

Prints input/output tensor specs for both models to stdout (AC4).
Heavy imports (torch, coremltools, catboost) are guarded inside main() so that
`--help` works without any of them installed.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Convert Phase-0 ball-track + bounce weights to CoreML packages.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=(
            "Both model paths must exist before conversion runs.\n"
            "Output directory is created automatically if it does not exist.\n"
        ),
    )
    parser.add_argument(
        "--ball_model",
        default="cv/models/ball_track.pt",
        metavar="PATH",
        help="Path to TrackNet state-dict (.pt). Default: cv/models/ball_track.pt",
    )
    parser.add_argument(
        "--bounce_model",
        default="cv/models/bounce.cbm",
        metavar="PATH",
        help="Path to CatBoost bounce model (.cbm). Default: cv/models/bounce.cbm",
    )
    parser.add_argument(
        "--out_dir",
        default="cv/models/",
        metavar="DIR",
        help="Directory to write converted CoreML files. Default: cv/models/",
    )
    return parser.parse_args()


def _check_inputs(ball_path: Path, bounce_path: Path) -> None:
    """Raise SystemExit with a clear message if either weight file is missing."""
    missing: list[str] = []
    if not ball_path.exists():
        missing.append(f"  ball_model  : {ball_path}")
    if not bounce_path.exists():
        missing.append(f"  bounce_model: {bounce_path}")
    if missing:
        print("ERROR: The following weight files were not found:", file=sys.stderr)
        for m in missing:
            print(m, file=sys.stderr)
        print(
            "\nDownload them from Google Drive (see cv/README.md) and place them in the"
            " expected location, then re-run.",
            file=sys.stderr,
        )
        sys.exit(1)


# ---------------------------------------------------------------------------
# BallTrackerNet architecture — copied verbatim from Phase-0 tracknet.py so
# the state-dict keys match.  Do NOT import from the spike directory; it is
# gitignored and lives in a separate repo.
# ---------------------------------------------------------------------------

def _build_ball_tracker_net() -> "torch.nn.Module":  # noqa: F821
    """Instantiate BallTrackerNet matching Phase-0 checkpoint (input_channels=9, out_channels=256)."""
    import torch.nn as nn

    class ConvBlock(nn.Module):
        def __init__(
            self,
            in_channels: int,
            out_channels: int,
            kernel_size: int = 3,
            pad: int = 1,
            stride: int = 1,
            bias: bool = True,
        ) -> None:
            super().__init__()
            self.block = nn.Sequential(
                nn.Conv2d(in_channels, out_channels, kernel_size, stride=stride, padding=pad, bias=bias),
                nn.ReLU(),
                nn.BatchNorm2d(out_channels),
            )

        def forward(self, x: "torch.Tensor") -> "torch.Tensor":  # noqa: F821
            return self.block(x)  # type: ignore[no-any-return]

    class BallTrackerNet(nn.Module):
        def __init__(self, input_channels: int = 3, out_channels: int = 14) -> None:
            super().__init__()
            self.out_channels = out_channels
            self.input_channels = input_channels

            self.conv1 = ConvBlock(in_channels=self.input_channels, out_channels=64)
            self.conv2 = ConvBlock(in_channels=64, out_channels=64)
            self.pool1 = nn.MaxPool2d(kernel_size=2, stride=2)
            self.conv3 = ConvBlock(in_channels=64, out_channels=128)
            self.conv4 = ConvBlock(in_channels=128, out_channels=128)
            self.pool2 = nn.MaxPool2d(kernel_size=2, stride=2)
            self.conv5 = ConvBlock(in_channels=128, out_channels=256)
            self.conv6 = ConvBlock(in_channels=256, out_channels=256)
            self.conv7 = ConvBlock(in_channels=256, out_channels=256)
            self.pool3 = nn.MaxPool2d(kernel_size=2, stride=2)
            self.conv8 = ConvBlock(in_channels=256, out_channels=512)
            self.conv9 = ConvBlock(in_channels=512, out_channels=512)
            self.conv10 = ConvBlock(in_channels=512, out_channels=512)
            self.ups1 = nn.Upsample(scale_factor=2)
            self.conv11 = ConvBlock(in_channels=512, out_channels=256)
            self.conv12 = ConvBlock(in_channels=256, out_channels=256)
            self.conv13 = ConvBlock(in_channels=256, out_channels=256)
            self.ups2 = nn.Upsample(scale_factor=2)
            self.conv14 = ConvBlock(in_channels=256, out_channels=128)
            self.conv15 = ConvBlock(in_channels=128, out_channels=128)
            self.ups3 = nn.Upsample(scale_factor=2)
            self.conv16 = ConvBlock(in_channels=128, out_channels=64)
            self.conv17 = ConvBlock(in_channels=64, out_channels=64)
            self.conv18 = ConvBlock(in_channels=64, out_channels=self.out_channels)

            self._init_weights()

        def forward(self, x: "torch.Tensor") -> "torch.Tensor":  # noqa: F821
            x = self.conv1(x)
            x = self.conv2(x)
            x = self.pool1(x)
            x = self.conv3(x)
            x = self.conv4(x)
            x = self.pool2(x)
            x = self.conv5(x)
            x = self.conv6(x)
            x = self.conv7(x)
            x = self.pool3(x)
            x = self.conv8(x)
            x = self.conv9(x)
            x = self.conv10(x)
            x = self.ups1(x)
            x = self.conv11(x)
            x = self.conv12(x)
            x = self.conv13(x)
            x = self.ups2(x)
            x = self.conv14(x)
            x = self.conv15(x)
            x = self.ups3(x)
            x = self.conv16(x)
            x = self.conv17(x)
            x = self.conv18(x)
            return x  # type: ignore[return-value]

        def _init_weights(self) -> None:
            import torch.nn as nn_inner

            for module in self.modules():
                if isinstance(module, nn_inner.Conv2d):
                    nn_inner.init.uniform_(module.weight, -0.05, 0.05)
                    if module.bias is not None:
                        nn_inner.init.constant_(module.bias, 0)
                elif isinstance(module, nn_inner.BatchNorm2d):
                    nn_inner.init.constant_(module.weight, 1)
                    nn_inner.init.constant_(module.bias, 0)

    return BallTrackerNet(input_channels=9, out_channels=256)


def _print_model_specs(label: str, mlmodel: object) -> None:
    """Print input and output tensor specs for a CoreML model (AC4)."""
    import coremltools as ct  # type: ignore[import-not-found]

    assert isinstance(mlmodel, ct.models.MLModel)
    spec = mlmodel.get_spec()
    print(f"\n--- {label} ---")
    print("  Inputs:")
    for inp in spec.description.input:
        shape = tuple(inp.type.multiArrayType.shape)
        dtype = inp.type.multiArrayType.dataType
        print(f"    name={inp.name!r}  shape={shape}  dtype={dtype}")
    print("  Outputs:")
    for out in spec.description.output:
        shape = tuple(out.type.multiArrayType.shape)
        dtype = out.type.multiArrayType.dataType
        print(f"    name={out.name!r}  shape={shape}  dtype={dtype}")


def _convert_ball_tracker(ball_path: Path, out_dir: Path) -> None:
    """Trace BallTrackerNet and export as BallTracker.mlpackage."""
    import torch
    import coremltools as ct  # type: ignore[import-not-found]

    print(f"[ball] Loading state-dict from {ball_path} ...")
    model = _build_ball_tracker_net()
    state = torch.load(str(ball_path), map_location="cpu")
    model.load_state_dict(state)
    model.eval()

    example_input = torch.zeros(1, 9, 360, 640)
    print("[ball] Tracing model with example input shape (1, 9, 360, 640) ...")
    traced = torch.jit.trace(model, example_input)

    print("[ball] Converting to CoreML ...")
    mlmodel = ct.convert(
        traced,
        inputs=[ct.TensorType(name="input", shape=(1, 9, 360, 640))],
        convert_to="mlprogram",
    )

    out_path = out_dir / "BallTracker.mlpackage"
    mlmodel.save(str(out_path))
    print(f"[ball] Saved -> {out_path}")

    loaded = ct.models.MLModel(str(out_path))
    _print_model_specs("BallTracker.mlpackage", loaded)


def _convert_bounce_detector(bounce_path: Path, out_dir: Path) -> None:
    """Export CatBoost bounce regressor as BounceDetector.mlmodel."""
    import catboost as ctb  # type: ignore[import-not-found]
    import coremltools as ct  # type: ignore[import-not-found]

    print(f"\n[bounce] Loading CatBoost model from {bounce_path} ...")
    model = ctb.CatBoostRegressor()
    model.load_model(str(bounce_path))

    out_path = out_dir / "BounceDetector.mlmodel"
    print("[bounce] Exporting to CoreML ...")
    model.save_model(str(out_path), format="coreml")
    print(f"[bounce] Saved -> {out_path}")

    loaded = ct.models.MLModel(str(out_path))
    _print_model_specs("BounceDetector.mlmodel", loaded)


def main() -> None:
    args = _parse_args()

    ball_path = Path(args.ball_model)
    bounce_path = Path(args.bounce_model)
    out_dir = Path(args.out_dir)

    _check_inputs(ball_path, bounce_path)

    out_dir.mkdir(parents=True, exist_ok=True)
    print(f"Output directory: {out_dir.resolve()}")

    _convert_ball_tracker(ball_path, out_dir)
    _convert_bounce_detector(bounce_path, out_dir)

    print("\nConversion complete.")
    print("Next: copy the converted files into the iOS bundle — see cv/README.md §4.")


if __name__ == "__main__":
    main()
