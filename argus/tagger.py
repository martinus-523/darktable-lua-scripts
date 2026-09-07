# /// script
# requires-python = ">=3.10"
# dependencies = [
#   "torch",
#   "open-clip-torch",
#   "transformers",
#   "sentencepiece",
#   "pillow",
#   "rawpy",
# ]
# ///
"""Zero-shot image tagger for the darktable argus Lua script.

Scores every image against the labels in data/vocabulary.tsv (Places365
scenes, OpenImages V7 boxable objects, and a user-editable extras group)
with a SigLIP model via OpenCLIP. Each label is scored independently
(sigmoid, no softmax across labels), so an image can be both "Beach" and
"Sunset".

Usage:
    uv run tagger.py --in paths.txt --out tags.json \
        [--threshold 0.001 --topk-scene 3 --topk-object 8 --topk-extra 3
         --batch 16 --progress progress.txt]

paths.txt holds one image path per line. Labels are emitted as the
hierarchical tag paths from vocabulary.tsv. Output JSON:
    { "<path>": { "scene": [["Landscape|Beach", 0.83], ...],
                  "object": [["Animals|Dog", 0.91], ...],
                  "extra": [["Light|Sunset", 0.44], ...] }, ... }

Unreadable files are skipped with a warning on stderr; the batch never aborts.
"""

import argparse
import hashlib
import io
import json
import sys
from pathlib import Path

MODEL_NAME = "ViT-B-16-SigLIP"
PRETRAINED = "webli"
PROMPT = "a photo of a {}"
CACHE_DIR = Path.home() / ".cache" / "argus"

# one row per label: <label> TAB <group> TAB <tag path>; user-editable
VOCAB_FILE = Path(__file__).resolve().parent / "data" / "vocabulary.tsv"
# fallback branch for rows without a tag path
FALLBACK_BRANCH = {"scene": "Location", "object": "Objects"}

RAW_EXTENSIONS = {
    ".3fr", ".ari", ".arw", ".bay", ".cap", ".cr2", ".cr3", ".crw", ".dcr",
    ".dcs", ".dng", ".drf", ".eip", ".erf", ".fff", ".iiq", ".k25", ".kdc",
    ".mdc", ".mef", ".mos", ".mrw", ".nef", ".nrw", ".orf", ".pef", ".ptx",
    ".pxn", ".raf", ".raw", ".rw2", ".rwl", ".sr2", ".srf", ".srw", ".x3f",
}


def warn(msg):
    print(f"tagger: {msg}", file=sys.stderr, flush=True)


def write_progress(path, done, total):
    """Overwrite the progress file with "done total"; the Lua script polls
    it to drive darktable's progress bar. Never let it break a run."""
    if not path:
        return
    try:
        Path(path).write_text(f"{done} {total}\n")
    except OSError:
        pass


def pick_device(torch):
    if torch.cuda.is_available():
        return "cuda"
    if torch.backends.mps.is_available():
        return "mps"
    return "cpu"


def load_image(path):
    """Return a PIL RGB image, using the embedded JPEG preview for raw files.

    The model only needs ~384 px, so a full raw decode would be wasted work.
    Returns None (after warning) when the file cannot be read.
    """
    from PIL import Image

    try:
        if Path(path).suffix.lower() in RAW_EXTENSIONS:
            import rawpy

            with rawpy.imread(path) as raw:
                thumb = raw.extract_thumb()
            if thumb.format == rawpy.ThumbFormat.JPEG:
                img = Image.open(io.BytesIO(thumb.data))
            else:  # ThumbFormat.BITMAP: already an RGB ndarray
                img = Image.fromarray(thumb.data)
        else:
            img = Image.open(path)
        return img.convert("RGB")
    except Exception as exc:  # noqa: BLE001 - skip, never abort the batch
        warn(f"skipping unreadable file {path}: {exc}")
        return None


def load_vocabulary():
    """Read vocabulary.tsv: group -> list of (label, tag path)."""
    vocab = {}
    for lineno, line in enumerate(VOCAB_FILE.read_text().splitlines(), 1):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        parts = [p.strip() for p in line.split("\t")]
        if len(parts) < 2 or not parts[0]:
            warn(f"{VOCAB_FILE.name}:{lineno}: malformed row skipped: {line!r}")
            continue
        label, group = parts[0], parts[1]
        path = parts[2] if len(parts) > 2 and parts[2] else \
            f"{FALLBACK_BRANCH.get(group, group.capitalize())}|{label}"
        vocab.setdefault(group, []).append((label, path))
    return vocab


def text_embeddings(torch, open_clip, model, tokenizer, device, group, labels):
    """Encode the prompts for one label group, cached on disk."""
    key = hashlib.sha1(
        "\n".join([MODEL_NAME, PRETRAINED, PROMPT, group, *labels]).encode()
    ).hexdigest()[:16]
    cache_file = CACHE_DIR / f"text-{group}-{key}.pt"
    if cache_file.exists():
        return torch.load(cache_file, map_location=device)

    warn(f"encoding {len(labels)} '{group}' prompts (cached after first run)")
    prompts = [PROMPT.format(label.lower()) for label in labels]
    feats = []
    with torch.no_grad():
        for i in range(0, len(prompts), 256):
            tokens = tokenizer(prompts[i : i + 256]).to(device)
            f = model.encode_text(tokens)
            feats.append(f / f.norm(dim=-1, keepdim=True))
    feats = torch.cat(feats)

    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    torch.save(feats.cpu(), cache_file)
    return feats.to(device)


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--in", dest="infile", required=True,
                        help="text file with one image path per line")
    parser.add_argument("--out", dest="outfile", required=True,
                        help="where to write the JSON results")
    # SigLIP sigmoid scores are calibrated against caption-style matches, so
    # generic vocabulary labels score low in absolute terms: correct labels
    # typically land between 0.001 and 0.3, noise stays below 0.0001.
    parser.add_argument("--threshold", type=float, default=0.001,
                        help="minimum sigmoid score for a label (default 0.001)")
    parser.add_argument("--topk-scene", type=int, default=3,
                        help="max scene labels per image (default 3)")
    parser.add_argument("--topk-object", type=int, default=8,
                        help="max object labels per image (default 8)")
    parser.add_argument("--topk-extra", type=int, default=3,
                        help="max labels per image for the extra group and "
                             "any custom groups (default 3)")
    parser.add_argument("--batch", type=int, default=16,
                        help="images per inference batch (default 16)")
    parser.add_argument("--progress", default=None,
                        help="file to overwrite with 'done total' counts "
                             "while processing (drives the progress bar)")
    args = parser.parse_args()

    paths = [p for p in Path(args.infile).read_text().splitlines() if p.strip()]
    if not paths:
        Path(args.outfile).write_text("{}\n")
        return
    write_progress(args.progress, 0, len(paths))

    import torch
    import open_clip

    device = pick_device(torch)
    warn(f"loading {MODEL_NAME}/{PRETRAINED} on {device}")
    model, _, preprocess = open_clip.create_model_and_transforms(
        MODEL_NAME, pretrained=PRETRAINED
    )
    model = model.to(device).eval()
    tokenizer = open_clip.get_tokenizer(MODEL_NAME)

    vocab = load_vocabulary()
    groups = {}  # group -> (tag paths, features, topk)
    topk = {"scene": args.topk_scene, "object": args.topk_object}
    for group, entries in vocab.items():
        labels = [label for label, _ in entries]
        feats = text_embeddings(
            torch, open_clip, model, tokenizer, device, group, labels
        )
        # any group beyond scene/object (extra and self-made ones) gets the
        # extra top-k cap
        groups[group] = ([path for _, path in entries], feats,
                         topk.get(group, args.topk_extra))

    logit_scale = model.logit_scale.exp()
    logit_bias = model.logit_bias

    results = {}
    batch_paths, batch_tensors = [], []

    def flush():
        if not batch_tensors:
            return
        images = torch.stack(batch_tensors).to(device)
        with torch.no_grad():
            img_feats = model.encode_image(images)
            img_feats = img_feats / img_feats.norm(dim=-1, keepdim=True)
            for path, feat in zip(batch_paths, img_feats):
                entry = {}
                for group, (tag_paths, txt_feats, k) in groups.items():
                    scores = torch.sigmoid(
                        feat @ txt_feats.T * logit_scale + logit_bias
                    )
                    top = torch.topk(scores, min(k, len(tag_paths)))
                    entry[group] = [
                        [tag_paths[i], round(s, 4)]
                        for s, i in zip(top.values.tolist(), top.indices.tolist())
                        if s >= args.threshold
                    ]
                results[path] = entry
        batch_paths.clear()
        batch_tensors.clear()

    for done, path in enumerate(paths, 1):
        img = load_image(path)
        if img is None:
            write_progress(args.progress, done, len(paths))
            continue
        batch_paths.append(path)
        batch_tensors.append(preprocess(img))
        if len(batch_tensors) >= args.batch:
            flush()
            write_progress(args.progress, done, len(paths))
            warn(f"processed {done}/{len(paths)}")
    flush()
    write_progress(args.progress, len(paths), len(paths))

    Path(args.outfile).write_text(json.dumps(results, indent=1) + "\n")
    warn(f"tagged {len(results)} of {len(paths)} images -> {args.outfile}")


if __name__ == "__main__":
    main()
