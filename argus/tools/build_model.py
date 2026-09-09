# /// script
# requires-python = ">=3.10"
# dependencies = [
#   "torch",
#   "open-clip-torch",
#   "transformers",
#   "sentencepiece",
#   "onnx",
#   "onnxruntime",
#   "pillow",
# ]
# ///
"""Build the argus-siglip .dtmodel package for darktable's AI subsystem.

Exports the ViT-B-16-SigLIP image tower to ONNX with the whole Argus
scoring pipeline baked into the graph. The exported model takes one
sRGB image tensor [1,3,H,W] (any H/W, values 0-1) and returns [1,N]
per-label sigmoid scores, one per row of data/vocabulary.tsv (in file
order, comments and malformed rows skipped) — so argus.lua needs no
preprocessing beyond darktable's own load_image + linear_to_srgb, and
no Python at runtime.

Baked into the graph:
  * squash-resize to the model's native input size (bicubic,
    antialiased — SigLIP's training-time "squash" resize mode)
  * SigLIP normalization (mean = std = 0.5)
  * the image tower
  * the N precomputed text embeddings ("a photo of a <label>")
  * logit scale/bias and the final sigmoid

Usage:
    uv run build_model.py [--out-dir ../build] [--test-image photo.jpg]

Produces <out-dir>/argus-siglip/{model.onnx,config.json} and the
installable zip <out-dir>/argus-siglip.dtmodel (darktable requires the
model-id directory as the archive's top level). Install it via
darktable preferences -> AI -> install from file, or unzip it into
darktable's models directory yourself.

Rebuild and reinstall whenever data/vocabulary.tsv changes: the label
order at build time must match what argus.lua reads at tag time (the
script cross-checks only the label *count* against the model output).
"""

import argparse
import json
import sys
import zipfile
from pathlib import Path

MODEL_NAME = "ViT-B-16-SigLIP"
PRETRAINED = "webli"
PROMPT = "a photo of a {}"
MODEL_ID = "argus-siglip"
OPSET = 18

TOOLS_DIR = Path(__file__).resolve().parent
VOCAB_FILE = TOOLS_DIR.parent / "data" / "vocabulary.tsv"
# fallback branch for rows without a tag path (kept in sync with argus.lua)
FALLBACK_BRANCH = {"scene": "Location", "object": "Objects"}


def warn(msg):
    print(f"build_model: {msg}", file=sys.stderr, flush=True)


def load_vocabulary():
    """Read vocabulary.tsv in file order: list of (label, group, tag path).

    Must skip exactly the rows argus.lua skips (comments, blanks, rows
    without label or group) so index i in the model output is row i here.
    """
    rows = []
    for lineno, line in enumerate(VOCAB_FILE.read_text().splitlines(), 1):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        parts = [p.strip() for p in line.split("\t")]
        if len(parts) < 2 or not parts[0] or not parts[1]:
            warn(f"{VOCAB_FILE.name}:{lineno}: malformed row skipped: {line!r}")
            continue
        label, group = parts[0], parts[1]
        path = parts[2] if len(parts) > 2 and parts[2] else \
            f"{FALLBACK_BRANCH.get(group, group.capitalize())}|{label}"
        rows.append((label, group, path))
    return rows


def build_wrapper(torch, model, text_feats, image_size):
    import torch.nn.functional as F

    class ArgusModel(torch.nn.Module):
        def __init__(self):
            super().__init__()
            self.visual = model.visual
            self.register_buffer("text_feats", text_feats)          # [N, D]
            self.register_buffer("logit_scale",
                                 model.logit_scale.detach().exp())
            self.register_buffer("logit_bias", model.logit_bias.detach())
            self.antialias = True

        def forward(self, image):  # [1,3,H,W] sRGB in [0,1]
            x = F.interpolate(image, size=(image_size, image_size),
                              mode="bicubic", align_corners=False,
                              antialias=self.antialias)
            # PIL's resize lands in uint8, which clamps bicubic overshoot
            x = x.clamp(0.0, 1.0)
            x = x * 2.0 - 1.0  # SigLIP normalization: mean = std = 0.5
            feat = self.visual(x)
            feat = F.normalize(feat, dim=-1)
            logits = feat @ self.text_feats.t() * self.logit_scale \
                + self.logit_bias
            return torch.sigmoid(logits)

    return ArgusModel().eval()


def export_onnx(torch, wrapper, onnx_path):
    dummy = torch.rand(1, 3, 313, 467)

    def attempt():
        torch.onnx.export(
            wrapper, (dummy,), str(onnx_path),
            input_names=["image"], output_names=["scores"],
            dynamic_axes={"image": {2: "height", 3: "width"}},
            opset_version=OPSET, dynamo=False,
        )

    try:
        attempt()
    except Exception as exc:
        # antialiased Resize needs opset 18 exporter support; fall back
        # to plain bicubic (slightly softer scores) rather than failing
        warn(f"export with antialias failed ({exc}); retrying without")
        wrapper.antialias = False
        attempt()
    return wrapper.antialias


def validate(torch, wrapper, onnx_path, n_labels):
    """Compare ONNX Runtime output against the torch wrapper."""
    import numpy as np
    import onnxruntime as ort

    sess = ort.InferenceSession(str(onnx_path),
                                providers=["CPUExecutionProvider"])
    worst = 0.0
    for shape in [(1, 3, 384, 256), (1, 3, 240, 384), (1, 3, 224, 224)]:
        x = torch.rand(*shape)
        with torch.no_grad():
            ref = wrapper(x).numpy()
        out = sess.run(None, {"image": x.numpy()})[0]
        if out.shape != (1, n_labels):
            raise SystemExit(
                f"output shape {out.shape} != (1, {n_labels})")
        worst = max(worst, float(np.abs(out - ref).max()))
    print(f"validated against torch: max |diff| = {worst:.2e} "
          f"over 3 input shapes")
    if worst > 1e-3:
        warn("difference larger than expected — inspect before shipping")
    return sess


def run_test_image(sess, rows, path, topk=10):
    import numpy as np
    from PIL import Image

    img = Image.open(path).convert("RGB")
    x = np.asarray(img, dtype=np.float32) / 255.0
    x = x.transpose(2, 0, 1)[None]  # HWC -> [1,3,H,W], like dt's load_image
    scores = sess.run(None, {"image": x})[0][0]
    print(f"\ntop {topk} labels for {path}:")
    for i in np.argsort(scores)[::-1][:topk]:
        label, group, tag = rows[i]
        print(f"  {scores[i]:.4f}  {tag}  ({group})")


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--out-dir", default=str(TOOLS_DIR.parent / "build"),
                        help="output directory (default: argus/build)")
    parser.add_argument("--test-image", default=None,
                        help="optional image to score with the exported "
                             "model as a sanity check")
    args = parser.parse_args()

    rows = load_vocabulary()
    if not rows:
        raise SystemExit(f"no labels found in {VOCAB_FILE}")
    print(f"{len(rows)} labels from {VOCAB_FILE.name}")

    import torch
    import open_clip

    print(f"loading {MODEL_NAME}/{PRETRAINED} (downloads once)")
    model, _, _ = open_clip.create_model_and_transforms(
        MODEL_NAME, pretrained=PRETRAINED)
    model = model.eval()
    tokenizer = open_clip.get_tokenizer(MODEL_NAME)
    image_size = getattr(model.visual, "image_size", None) \
        or open_clip.get_model_config(MODEL_NAME)["vision_cfg"]["image_size"]
    if isinstance(image_size, (tuple, list)):
        image_size = image_size[0]

    print(f"encoding {len(rows)} label prompts")
    prompts = [PROMPT.format(label.lower()) for label, _, _ in rows]
    feats = []
    with torch.no_grad():
        for i in range(0, len(prompts), 256):
            f = model.encode_text(tokenizer(prompts[i:i + 256]))
            feats.append(f / f.norm(dim=-1, keepdim=True))
    text_feats = torch.cat(feats)

    wrapper = build_wrapper(torch, model, text_feats, image_size)

    out_dir = Path(args.out_dir)
    model_dir = out_dir / MODEL_ID
    model_dir.mkdir(parents=True, exist_ok=True)
    onnx_path = model_dir / "model.onnx"

    print(f"exporting to {onnx_path} (input {image_size}px, opset {OPSET})")
    antialias = export_onnx(torch, wrapper, onnx_path)
    if not antialias:
        warn("model was exported WITHOUT antialiased resize")

    sess = validate(torch, wrapper, onnx_path, len(rows))

    config = {
        "id": MODEL_ID,
        "name": "Argus SigLIP tagger",
        "description":
            f"{MODEL_NAME} ({PRETRAINED}) image tower with the "
            f"{len(rows)}-label Argus vocabulary baked in. Input: sRGB "
            "image [1,3,H,W] in 0-1 (any size); output: [1,N] per-label "
            "sigmoid scores in vocabulary.tsv order.",
        "task": "argus",
        "version": "1.0.0",
        "spatial_dims": ["height", "width"],
    }
    (model_dir / "config.json").write_text(
        json.dumps(config, indent=2) + "\n")

    # darktable derives the model id from the archive's top-level directory
    dtmodel = out_dir / f"{MODEL_ID}.dtmodel"
    with zipfile.ZipFile(dtmodel, "w", zipfile.ZIP_DEFLATED) as z:
        for f in sorted(model_dir.iterdir()):
            z.write(f, arcname=f"{MODEL_ID}/{f.name}")

    size_mb = dtmodel.stat().st_size / 2**20
    print(f"\nwrote {dtmodel} ({size_mb:.0f} MB)")
    print("install: darktable preferences -> AI -> install model from file")

    if args.test_image:
        run_test_image(sess, rows, args.test_image)


if __name__ == "__main__":
    main()
