# /// script
# requires-python = ">=3.10"
# dependencies = [
#   "torch",
#   "open-clip-torch",
#   "huggingface-hub",
#   "numpy",
#   "onnx",
#   "onnxruntime",
#   "pillow",
# ]
# ///
"""Build the artemis-bioclip .dtmodel package for darktable's AI subsystem.

Exports BioCLIP 2.5 Huge as two ONNX models so artemis.lua can identify
species without Python at tagging time:

  tower.onnx   image [1,3,224,224] sRGB 0-1 (CLIP center crop, done by
               the Lua script) -> L2-normalized embedding [1,D].
               Weights in float16 to stay under ONNX's 2 GB limit.
  scorer.onnx  embedding [1,D] -> the taxonomy walk's raw material:
               softmax over all ~800k TreeOfLife taxa, probability mass
               aggregated per taxonomic group at each walked rank
               (class, order, family, genus, species), and the top-64
               groups per rank as (sums, start row, end row) triples.

The aggregation is exact: taxa are sorted by lineage at build time so
every group at every rank is one contiguous row range, which turns the
per-group sums into a cumulative sum plus gathers at precomputed group
boundaries — all inside the graph. The Lua script walks the hierarchy
over just 5 x 64 candidate groups and resolves names through
data/taxa.bin, a fixed-width record file written here in the same
sorted row order (256 bytes per row: the 7 rank names and the common
name, pipe-separated).

Top-64 keeps the walk exact for thresholds above 1/64: probabilities
sum to 1, so no group outside the top 64 of its rank can ever clear
such a threshold.

Usage:
    uv run build_model.py [--out-dir ../build] [--test-image photo.jpg]

Produces <out-dir>/artemis-bioclip/{tower.onnx,scorer.onnx,config.json},
the installable <out-dir>/artemis-bioclip.dtmodel, and ../data/taxa.bin
(which must ship next to artemis.lua). Rebuild both together — the row
order baked into scorer.onnx must match taxa.bin.

The BioCLIP weights (~7 GB) and TreeOfLife embeddings (~3.3 GB) are
downloaded from Hugging Face once and cached.
"""

import argparse
import json
import sys
import zipfile
from pathlib import Path

MODEL_STR = "hf-hub:imageomics/bioclip-2.5-vith14"
EMB_REPO = "imageomics/TreeOfLife-200M"
EMB_NPY = "embeddings/txt_emb_bioclip-2.5-vith14.npy"
EMB_JSON = "embeddings/txt_emb_bioclip-2.5-vith14.json"

MODEL_ID = "artemis-bioclip"
OPSET = 18
TOPK = 64
RECORD_SIZE = 256

# taxonomy list indices (kingdom..species); the walk covers class..species
WALK_RANKS = [2, 3, 4, 5, 6]

TOOLS_DIR = Path(__file__).resolve().parent
TAXA_BIN = TOOLS_DIR.parent / "data" / "taxa.bin"


def warn(msg):
    print(f"build_model: {msg}", file=sys.stderr, flush=True)


def fetch_tol_data(np):
    """Sorted TreeOfLife data: (taxa, common_names, fp16 embeddings).

    Rows are sorted by full 7-rank lineage so that every group at every
    rank is contiguous; the embedding matrix is permuted to match.
    """
    from huggingface_hub import hf_hub_download

    names_file = hf_hub_download(EMB_REPO, EMB_JSON, repo_type="dataset")
    emb_file = hf_hub_download(EMB_REPO, EMB_NPY, repo_type="dataset")

    entries = json.loads(Path(names_file).read_text())
    txt = np.load(emb_file, mmap_mode="r")
    if txt.shape[0] != len(entries) and txt.shape[1] == len(entries):
        txt = txt.T
    if txt.shape[0] != len(entries):
        sys.exit(f"names/embeddings mismatch ({len(entries)} names vs "
                 f"{txt.shape} embeddings)")

    order = sorted(range(len(entries)),
                   key=lambda i: tuple(entries[i][0]))
    taxa = [entries[i][0] for i in order]
    common = [(entries[i][1] or "") for i in order]

    warn(f"permuting + converting {len(order)} embeddings to fp16")
    perm = np.asarray(order, dtype=np.int64)
    out = np.empty((txt.shape[0], txt.shape[1]), dtype=np.float16)
    step = 65536
    for i in range(0, len(perm), step):
        out[i:i + step] = txt[perm[i:i + step]].astype(np.float16)
    return taxa, common, out


def rank_boundaries(np, taxa):
    """Per walked rank: (starts, ends) int64 arrays of the contiguous row
    range of every group (rows sharing the lineage prefix down to that
    rank), in row order."""
    bounds = []
    for rank in WALK_RANKS:
        keys = ["|".join(t[:rank + 1]) for t in taxa]
        cut = [0] + [i for i in range(1, len(keys))
                     if keys[i] != keys[i - 1]] + [len(keys)]
        b = np.asarray(cut, dtype=np.int64)
        bounds.append((b[:-1], b[1:]))
    return bounds


def write_taxa_bin(taxa, common):
    """Fixed-width record file for O(1) row lookups from Lua."""
    TAXA_BIN.parent.mkdir(parents=True, exist_ok=True)
    truncated = 0
    with TAXA_BIN.open("wb") as f:
        for t, c in zip(taxa, common):
            fields = [x.replace("|", "/").replace("\0", " ")
                      for x in [*t, c]]
            rec = "|".join(fields).encode("utf-8")
            if len(rec) >= RECORD_SIZE:
                rec = rec[:RECORD_SIZE - 1]
                truncated += 1
            f.write(rec.ljust(RECORD_SIZE, b"\0"))
    if truncated:
        warn(f"{truncated} record(s) truncated to {RECORD_SIZE} bytes")
    print(f"wrote {TAXA_BIN} ({len(taxa)} records)")


def check_preprocess(preprocess):
    """The Lua script replicates CLIP preprocessing (shortest side to the
    model size via darktable's resampler, then a center crop); fail
    loudly if this model expects anything else. Returns (size, mean, std)."""
    from torchvision import transforms as T

    size = mean = std = None
    for t in preprocess.transforms:
        if isinstance(t, T.Resize):
            size = t.size if isinstance(t.size, int) else t.size[0]
        elif isinstance(t, T.CenterCrop):
            crop = t.size[0] if isinstance(t.size, (tuple, list)) else t.size
            if size is not None and crop != size:
                sys.exit(f"unexpected preprocess: resize {size} vs "
                         f"crop {crop}")
        elif isinstance(t, T.Normalize):
            mean, std = list(t.mean), list(t.std)
    if size is None or mean is None:
        sys.exit(f"unexpected preprocess pipeline: {preprocess}")
    return size, mean, std


def build_tower(torch, model, mean, std):
    import torch.nn.functional as F

    class Tower(torch.nn.Module):
        def __init__(self):
            super().__init__()
            self.visual = model.visual.half()
            self.register_buffer(
                "mean", torch.tensor(mean).view(1, 3, 1, 1))
            self.register_buffer(
                "std", torch.tensor(std).view(1, 3, 1, 1))

        def forward(self, image):  # [1,3,S,S] sRGB in [0,1]
            x = (image - self.mean) / self.std
            feat = self.visual(x.half()).float()
            return F.normalize(feat, dim=-1)

    return Tower().eval()


def build_scorer(torch, text_fp16, logit_scale, bounds):
    class Scorer(torch.nn.Module):
        def __init__(self):
            super().__init__()
            self.register_buffer("text", text_fp16)  # [N, D] fp16
            self.logit_scale = float(logit_scale)
            for d, (s, e) in enumerate(bounds):
                self.register_buffer(f"starts{d}", s)
                self.register_buffer(f"ends{d}", e)

        def forward(self, emb):  # [1, D] fp32, L2-normalized
            logits = (emb.half() @ self.text.t()).float()
            probs = torch.softmax(logits * self.logit_scale, dim=1)
            # cumulative sum in float64: group sums come out as long-range
            # differences, which float32 accumulation would degrade
            c = torch.cumsum(probs[0].double(), dim=0)
            cpad = torch.nn.functional.pad(c, (1, 0))
            outs = []
            for d in range(len(bounds)):
                starts = getattr(self, f"starts{d}")
                ends = getattr(self, f"ends{d}")
                sums = (cpad.index_select(0, ends)
                        - cpad.index_select(0, starts)).float()
                k = min(TOPK, sums.shape[0])
                val, idx = torch.topk(sums, k)
                outs += [val.unsqueeze(0),
                         starts.index_select(0, idx).float().unsqueeze(0),
                         ends.index_select(0, idx).float().unsqueeze(0)]
            return tuple(outs)

    return Scorer().eval()


def export(torch, module, dummy, path, in_name, out_names):
    torch.onnx.export(
        module, (dummy,), str(path),
        input_names=[in_name], output_names=out_names,
        opset_version=OPSET, dynamo=False,
    )


def validate(torch, np, tower, scorer, tower_path, scorer_path, image_size):
    import onnxruntime as ort

    so = ort.SessionOptions()
    so.log_severity_level = 3
    tsess = ort.InferenceSession(str(tower_path), so,
                                 providers=["CPUExecutionProvider"])
    ssess = ort.InferenceSession(str(scorer_path), so,
                                 providers=["CPUExecutionProvider"])

    x = torch.rand(1, 3, image_size, image_size)
    with torch.no_grad():
        ref_emb = tower(x).numpy()
    emb = tsess.run(None, {"image": x.numpy()})[0]
    cos = float((ref_emb * emb).sum()
                / (np.linalg.norm(ref_emb) * np.linalg.norm(emb)))
    print(f"tower validated: cosine(torch fp16, onnx) = {cos:.6f}")
    if cos < 0.999:
        warn("tower similarity lower than expected — inspect before shipping")

    # topk TIES (the ~zero-probability tail) are ordered differently by
    # torch and onnxruntime, so compare the sorted sum values per rank
    # (tie-order independent) and the walk outcome, not raw index order
    worst, walks_agree = 0.0, True
    for _ in range(3):
        e = torch.nn.functional.normalize(torch.rand(1, emb.shape[1]) - 0.5,
                                          dim=-1)
        with torch.no_grad():
            ref = [t.numpy() for t in scorer(e)]
        out = ssess.run(None, {"embedding": e.numpy()})
        for d in range(len(WALK_RANKS)):
            worst = max(worst,
                        float(np.abs(ref[3 * d] - out[3 * d]).max()))
        rw = walk(ref, threshold=0.05, scope="all")
        ow = walk(out, threshold=0.05, scope="all")
        if (rw is None) != (ow is None) or (rw and rw[2:] != ow[2:]):
            walks_agree = False
    print(f"scorer validated: max |sum diff| = {worst:.2e}, "
          f"walk outcomes {'agree' if walks_agree else 'DIFFER'}")
    if worst > 5e-3 or not walks_agree:
        warn("scorer mismatch larger than expected — inspect before shipping")
    return tsess, ssess


# --- reference walk (mirrors the argus.lua port; used for --test-image) ------

def read_record(row):
    with TAXA_BIN.open("rb") as f:
        f.seek(row * RECORD_SIZE)
        rec = f.read(RECORD_SIZE).split(b"\0", 1)[0].decode("utf-8")
    return rec.split("|")


def walk(outputs, threshold=0.3, scope="animals"):
    def in_scope(rec):
        if scope == "birds":
            return rec[2] == "Aves"
        if scope == "animals":
            return rec[0] == "Animalia"
        return True

    best = None  # (depth, sum, start, end)
    for d in range(len(WALK_RANKS)):
        sums, starts, ends = (outputs[3 * d][0], outputs[3 * d + 1][0],
                              outputs[3 * d + 2][0])
        pick = None
        for s, a, b in zip(sums, starts, ends):  # sorted desc: first valid
            a, b = int(a), int(b)
            if best is not None and not (a >= best[2] and b <= best[3]):
                continue
            if not in_scope(read_record(a)):
                continue
            pick = (d, float(s), a, b)
            break
        if pick is None or pick[1] < threshold:
            break
        best = pick
    return best


def run_test_image(np, tsess, ssess, image_size, path):
    from PIL import Image

    img = Image.open(path).convert("RGB")
    scale = image_size / min(img.size)
    img = img.resize((round(img.width * scale), round(img.height * scale)),
                     Image.LANCZOS)
    left = (img.width - image_size) // 2
    top = (img.height - image_size) // 2
    img = img.crop((left, top, left + image_size, top + image_size))
    x = (np.asarray(img, dtype=np.float32) / 255.0).transpose(2, 0, 1)[None]

    emb = tsess.run(None, {"image": x})[0]
    outputs = ssess.run(None, {"embedding": emb})
    print(f"\n{path}:")
    for scope in ("animals", "all"):
        best = walk(outputs, scope=scope)
        if best is None:
            print(f"  scope {scope}: no rank above threshold")
            continue
        d, s, a, _ = best
        rec = read_record(a)
        depth_name = ["class", "order", "family", "genus", "species"][d]
        common = f" ({rec[7]})" if d == 4 and len(rec) > 7 and rec[7] else ""
        print(f"  scope {scope}: {depth_name} "
              f"{'|'.join(p for p in rec[2:WALK_RANKS[d] + 1] if p)}"
              f"{common}  p={s:.3f}")


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--out-dir", default=str(TOOLS_DIR.parent / "build"),
                        help="output directory (default: artemis/build)")
    parser.add_argument("--test-image", default=None,
                        help="optional image to identify with the exported "
                             "models as a sanity check")
    args = parser.parse_args()

    import numpy as np
    import torch
    import open_clip

    print(f"loading {MODEL_STR} (first run downloads ~7 GB)")
    model, _, preprocess = open_clip.create_model_and_transforms(MODEL_STR)
    model = model.eval()
    image_size, mean, std = check_preprocess(preprocess)
    with torch.no_grad():
        logit_scale = float(model.logit_scale.exp())

    taxa, common, txt_fp16 = fetch_tol_data(np)
    bounds = [(torch.from_numpy(np.ascontiguousarray(s)),
               torch.from_numpy(np.ascontiguousarray(e)))
              for s, e in rank_boundaries(np, taxa)]
    write_taxa_bin(taxa, common)

    out_dir = Path(args.out_dir)
    model_dir = out_dir / MODEL_ID
    model_dir.mkdir(parents=True, exist_ok=True)
    tower_path = model_dir / "tower.onnx"
    scorer_path = model_dir / "scorer.onnx"

    print(f"exporting {tower_path} (input {image_size}px, fp16 weights)")
    tower = build_tower(torch, model, mean, std)
    export(torch, tower, torch.rand(1, 3, image_size, image_size),
           tower_path, "image", ["embedding"])

    print(f"exporting {scorer_path} ({len(taxa)} taxa, top {TOPK}/rank)")
    emb_dim = txt_fp16.shape[1]
    scorer = build_scorer(torch, torch.from_numpy(txt_fp16),
                          logit_scale, bounds)
    out_names = []
    for name in ("class", "order", "family", "genus", "species"):
        out_names += [f"sums_{name}", f"starts_{name}", f"ends_{name}"]
    export(torch, scorer, torch.zeros(1, emb_dim), scorer_path,
           "embedding", out_names)

    tsess, ssess = validate(torch, np, tower, scorer,
                            tower_path, scorer_path, image_size)

    config = {
        "id": MODEL_ID,
        "name": "Artemis BioCLIP identifier",
        "description":
            "BioCLIP 2.5 Huge (imageomics/bioclip-2.5-vith14) split in "
            f"tower.onnx (image [1,3,{image_size},{image_size}] sRGB 0-1 "
            "-> embedding) and scorer.onnx (embedding -> per-rank top-64 "
            f"TreeOfLife group sums over {len(taxa)} taxa). Row indices "
            "refer to the taxa.bin shipped with artemis.lua.",
        "task": "artemis",
        "version": "1.0.0",
    }
    (model_dir / "config.json").write_text(
        json.dumps(config, indent=2) + "\n")

    dtmodel = out_dir / f"{MODEL_ID}.dtmodel"
    with zipfile.ZipFile(dtmodel, "w", zipfile.ZIP_DEFLATED) as z:
        for f in sorted(model_dir.iterdir()):
            z.write(f, arcname=f"{MODEL_ID}/{f.name}")
    print(f"\nwrote {dtmodel} ({dtmodel.stat().st_size / 2**30:.1f} GB)")
    print("install: darktable preferences -> AI -> install model from file")

    if args.test_image:
        run_test_image(np, tsess, ssess, image_size, args.test_image)


if __name__ == "__main__":
    main()
