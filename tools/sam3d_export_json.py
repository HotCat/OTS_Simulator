#!/usr/bin/env python3
"""Run SAM 3D Body and save pose records as portable, compact JSON.

Install SAM 3D Body separately following its official repository, then point
--sam3d-repo at that checkout.  Either supply local --checkpoint-path and
--mhr-path files or a Hugging Face repository id.  The resulting JSON is
consumed by image_to_gdpose.py with ``--format sam3d-mhr``.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any


def _json_value(value: Any) -> Any:
    if value is None or isinstance(value, (str, int, float, bool)):
        return value
    if hasattr(value, "tolist"):
        return _json_value(value.tolist())
    if isinstance(value, dict):
        return {str(key): _json_value(item) for key, item in value.items()}
    if isinstance(value, (list, tuple)):
        return [_json_value(item) for item in value]
    return str(value)


POSE_OUTPUT_KEYS = (
    "bbox",
    "focal_length",
    "pred_keypoints_3d",
    "pred_keypoints_2d",
    "pred_cam_t",
    "pred_pose_raw",
    "global_rot",
    "body_pose_params",
    "hand_pose_params",
    "scale_params",
    "shape_params",
    "pred_joint_coords",
    "pred_global_rots",
    "mhr_model_params",
)


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("image", type=Path)
    parser.add_argument("--output", type=Path, required=True,
                        help="JSON file containing SAM estimator output records")
    parser.add_argument("--sam3d-repo", type=Path, required=True,
                        help="local facebookresearch/sam-3d-body checkout")
    parser.add_argument("--hf-repo", default="facebook/sam-3d-body-vith",
                        help="Hugging Face model id used when local paths are omitted")
    parser.add_argument("--checkpoint-path", type=Path,
                        help="local model.ckpt (must be paired with --mhr-path)")
    parser.add_argument("--mhr-path", type=Path,
                        help="local assets/mhr_model.pt (must be paired with --checkpoint-path)")
    parser.add_argument("--device", default="cuda", help="cuda, mps, or cpu")
    parser.add_argument("--bbox", type=float, nargs=4, metavar=("X1", "Y1", "X2", "Y2"),
                        help="manual person bounding box; bypasses human detection")
    parser.add_argument("--inference-type", choices=("body", "full"), default="body",
                        help="body avoids the CUDA-only hand refinement path")
    parser.add_argument("--include-vertices", action="store_true",
                        help="include the large pred_vertices mesh array")
    parser.add_argument("--person-index", type=int, default=None,
                        help="write only one person record instead of all records")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    try:
        repo = args.sam3d_repo.resolve()
        if not (repo / "notebook" / "utils.py").exists():
            raise RuntimeError("--sam3d-repo does not look like a sam-3d-body checkout")
        sys.path.insert(0, str(repo))
        import numpy as np  # type: ignore
        from sam_3d_body import SAM3DBodyEstimator, load_sam_3d_body  # type: ignore

        if not args.image.is_file():
            raise RuntimeError(f"could not read image: {args.image}")
        if (args.checkpoint_path is None) != (args.mhr_path is None):
            raise RuntimeError("--checkpoint-path and --mhr-path must be supplied together")
        if args.checkpoint_path is not None:
            if not args.checkpoint_path.is_file():
                raise RuntimeError(f"checkpoint does not exist: {args.checkpoint_path}")
            if not args.mhr_path.is_file():
                raise RuntimeError(f"MHR model does not exist: {args.mhr_path}")
            model, cfg = load_sam_3d_body(
                checkpoint_path=str(args.checkpoint_path),
                mhr_path=str(args.mhr_path),
                device=args.device,
            )
        else:
            # Resolve the files ourselves because the current upstream
            # load_sam_3d_body_hf helper silently drops its device argument.
            from huggingface_hub import snapshot_download  # type: ignore
            snapshot = Path(snapshot_download(repo_id=args.hf_repo))
            model, cfg = load_sam_3d_body(
                checkpoint_path=str(snapshot / "model.ckpt"),
                mhr_path=str(snapshot / "assets" / "mhr_model.pt"),
                device=args.device,
            )

        # Optional detector, segmentor, and FOV networks are deliberately not
        # created here.  A supplied box is more reliable for overlapping carry
        # poses and keeps this export command self-contained.
        estimator = SAM3DBodyEstimator(model, cfg)
        boxes = np.asarray([args.bbox], dtype=np.float32) if args.bbox else None
        outputs = estimator.process_one_image(
            str(args.image.resolve()),
            bboxes=boxes,
            inference_type=args.inference_type,
        )
        compact_outputs = []
        for output in outputs:
            keys = POSE_OUTPUT_KEYS + (("pred_vertices",) if args.include_vertices else ())
            compact_outputs.append({key: output[key] for key in keys if key in output})
        outputs = compact_outputs
        if args.person_index is not None:
            if args.person_index < 0 or args.person_index >= len(outputs):
                raise RuntimeError(f"person index {args.person_index} is out of range (found {len(outputs)})")
            outputs = [outputs[args.person_index]]
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(_json_value(outputs), indent=2) + "\n", encoding="utf-8")
        print(f"wrote {len(outputs)} SAM 3D Body record(s) to {args.output}")
        return 0
    except (OSError, RuntimeError, ValueError, ImportError) as error:
        print(f"sam3d_export_json: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
