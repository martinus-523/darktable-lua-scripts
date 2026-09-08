# /// script
# requires-python = ">=3.10"
# dependencies = [
#   "torch",
#   "open-clip-torch",
#   "huggingface-hub",
#   "numpy",
#   "pillow",
#   "rawpy",
# ]
# ///
"""Species identifier for the darktable artemis Lua script.

Classifies every image against the ~800k taxa of TreeOfLife-200M with the
BioCLIP 2.5 Huge model (hf-hub:imageomics/bioclip-2.5-vith14), using the
precomputed text embeddings published alongside the dataset. Predictions
follow the Linnaean hierarchy: the tagger walks class -> order -> family ->
genus -> species and emits a tag for the deepest rank whose aggregated
probability clears the threshold, so a sharp portrait yields a species while
a distant blur may only yield a family.

Usage:
    uv run tagger.py --in paths.txt --out tags.json \
        [--threshold 0.3 --topk 1 --scope animals --tag-style separate
         --batch 8 --progress progress.txt]

paths.txt holds one image path per line. Output JSON (with the default
'separate' style each identification yields a scientific and an English tag,
the latter translated via data/rank-names.tsv):
    { "<path>": [["Scientific|Aves|Passeriformes|Paridae|Parus major", 0.87],
                 ["English|Birds|Perching Birds|Tits and Chickadees|Great Tit",
                  0.87]],
      ... }

Tag paths start at class (kingdom is prepended when it is not Animalia),
under a Scientific| or English| branch except for the 'combined' style.
Unreadable files are skipped with a warning on stderr; the batch never aborts.

All file I/O declares encoding="utf-8" explicitly. Without it Python uses the
platform default, which is cp1252 on Windows and blows up on the accented
names in the TreeOfLife data.
"""

import argparse
import io
import json
import sys
from pathlib import Path

MODEL_STR = "hf-hub:imageomics/bioclip-2.5-vith14"
EMB_REPO = "imageomics/TreeOfLife-200M"
EMB_NPY = "embeddings/txt_emb_bioclip-2.5-vith14.npy"
EMB_JSON = "embeddings/txt_emb_bioclip-2.5-vith14.json"
CACHE_DIR = Path.home() / ".cache" / "artemis"

# English names for higher ranks (Aves -> Birds), used by the english and
# separate tag styles; see tools/make_rank_names.py
RANK_NAMES_FILE = Path(__file__).resolve().parent / "data" / "rank-names.tsv"

# taxonomy list indices in the names JSON (kingdom..species, 7 ranks); the
# hierarchy walk runs over class..species only — kingdom/phylum are too
# coarse to be useful tags and phylum is skipped entirely
KINGDOM, PHYLUM = 0, 1
WALK_RANKS = [2, 3, 4, 5, 6]  # class, order, family, genus, species

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
        # CHANGED: explicit encoding for consistency (content is ASCII)
        Path(path).write_text(f"{done} {total}\n", encoding="utf-8")
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

    The model only needs 224 px, so a full raw decode would be wasted work.
    Returns None (after warning) when the file cannot be read.
    """
    from PIL import Image

    try:
        if Path(path).suffix.lower() in RAW_EXTENSIONS:
            import rawpy

            # CHANGED: build and materialise the image inside the with block.
            # For ThumbFormat.BITMAP, thumb.data may be a view onto memory
            # owned by the rawpy handle; convert("RGB") forces a copy while
            # that memory is still valid.
            with rawpy.imread(path) as raw:
                thumb = raw.extract_thumb()
                if thumb.format == rawpy.ThumbFormat.JPEG:
                    img = Image.open(io.BytesIO(thumb.data))
                else:  # ThumbFormat.BITMAP: already an RGB ndarray
                    img = Image.fromarray(thumb.data)
                return img.convert("RGB")
        else:
            img = Image.open(path)
            return img.convert("RGB")
    except Exception as exc:  # noqa: BLE001 - skip, never abort the batch
        warn(f"skipping unreadable file {path}: {exc}")
        return None


def fetch_tol_data(np, torch):
    """Download (once) and load the TreeOfLife names + text embeddings.

    Returns (taxa, common_names, txt_feats) where taxa is a list of 7-rank
    name lists, common_names a list of strings, and txt_feats a float16 CPU
    tensor of L2-normalized embeddings, one row per taxon.
    """
    from huggingface_hub import hf_hub_download

    names_file = hf_hub_download(EMB_REPO, EMB_JSON, repo_type="dataset")
    emb_file = hf_hub_download(EMB_REPO, EMB_NPY, repo_type="dataset")

    # CHANGED: encoding="utf-8". The names file is UTF-8 and contains
    # accented common names; on Windows the cp1252 default raised
    # UnicodeDecodeError on the first byte it could not map.
    entries = json.loads(Path(names_file).read_text(encoding="utf-8"))
    taxa = [e[0] for e in entries]
    common_names = [e[1] or "" for e in entries]

    # the published matrix is float32 (~3.3 GB) and stored transposed as
    # (embedding dim, taxa); keep a float16 (taxa, dim) copy on disk so
    # later runs load half the bytes and hold half the RAM
    fp16_file = CACHE_DIR / (Path(EMB_NPY).stem + "-fp16.npy")
    txt = np.load(fp16_file, mmap_mode="r") if fp16_file.exists() else None
    if txt is None or txt.shape[0] != len(taxa):
        warn("converting text embeddings to float16 (one-time)")
        txt = np.load(emb_file, mmap_mode="r")
        if txt.shape[0] != len(taxa) and txt.shape[1] == len(taxa):
            txt = txt.T
        CACHE_DIR.mkdir(parents=True, exist_ok=True)
        out = np.lib.format.open_memmap(
            fp16_file, mode="w+", dtype=np.float16, shape=txt.shape
        )
        step = 65536
        for i in range(0, txt.shape[0], step):
            out[i : i + step] = txt[i : i + step].astype(np.float16)
        out.flush()
        txt = out

    if len(taxa) != txt.shape[0]:
        sys.exit(f"tagger: names/embeddings mismatch "
                 f"({len(taxa)} names vs {txt.shape[0]} rows)")
    return taxa, common_names, torch.from_numpy(np.ascontiguousarray(txt))


def build_groups(np, taxa):
    """Integer group ids per walked rank: rows sharing the lineage prefix
    down to that rank share an id. Cached because np.unique over ~800k
    joined strings takes a while."""
    key = f"groups-{len(taxa)}"
    cache_file = CACHE_DIR / f"{key}.npz"
    if cache_file.exists():
        data = np.load(cache_file)
        return [data[f"rank{r}"] for r in WALK_RANKS]

    warn("indexing taxonomy groups (one-time)")
    group_ids = []
    for rank in WALK_RANKS:
        prefixes = np.array(["|".join(t[: rank + 1]) for t in taxa])
        _, ids = np.unique(prefixes, return_inverse=True)
        group_ids.append(ids.astype(np.int32))
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    np.savez_compressed(
        cache_file,
        **{f"rank{r}": g for r, g in zip(WALK_RANKS, group_ids)},
    )
    return group_ids


def scope_mask(np, taxa, scope):
    if scope == "all":
        return None
    if scope == "birds":
        keep = [t[2] == "Aves" for t in taxa]
    else:  # animals
        keep = [t[0] == "Animalia" for t in taxa]
    return np.array(keep)


def load_rank_names():
    """data/rank-names.tsv -> {(rank index, scientific name): English name}.

    Generated by tools/make_rank_names.py from the GBIF Backbone Taxonomy
    and meant to be hand-edited; a missing file just means the English tag
    tree keeps the scientific rank names."""
    names = {}
    if not RANK_NAMES_FILE.exists():
        warn(f"no {RANK_NAMES_FILE.name}; English tags keep scientific ranks")
        return names
    rank_idx = {"kingdom": KINGDOM, "class": 2, "order": 3, "family": 4}
    # CHANGED: encoding="utf-8". Same failure mode as the names JSON —
    # accented English rank names would raise UnicodeDecodeError on Windows
    # or silently mojibake the English tag tree.
    for line in RANK_NAMES_FILE.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        parts = [p.strip() for p in line.split("\t")]
        if len(parts) >= 3 and parts[1] in rank_idx and parts[0] and parts[2]:
            names[(rank_idx[parts[1]], parts[0])] = parts[2]
    return names


def lineage(taxon, depth, leaf, translate):
    """Hierarchical tag for a lineage down to WALK_RANKS[depth]; the species
    component is replaced by `leaf`, all other ranks go through `translate`.
    Kingdom is prepended for non-animals so plants and fungi stay
    recognizable; empty ranks are skipped, and so is the genus level when
    the species leaf follows it anyway."""
    parts = []
    species_depth = len(WALK_RANKS) - 1
    if taxon[KINGDOM] != "Animalia":
        parts.append(translate(KINGDOM, taxon[KINGDOM]))
    for d in range(depth + 1):
        rank = WALK_RANKS[d]
        if rank == 5 and depth == species_depth:
            continue
        part = leaf if rank == 6 else translate(rank, taxon[rank])
        if part:
            parts.append(part)
    return "|".join(parts)


def make_tags(taxon, depth, common_name, score, args, rank_names):
    """The tag(s) for one identification, following the configured style:
    'separate' (default) emits a scientific and an English tree tag,
    'scientific' / 'english' just one of them, 'combined' a scientific tree
    whose species leaf carries the common name in parentheses. Scientific
    trees live under a Scientific| branch and English trees under English|,
    so the two stay apart in darktable's tag hierarchy; 'combined' is a
    single merged tree and gets no branch."""
    species = depth == len(WALK_RANKS) - 1
    binomial = f"{taxon[5]} {taxon[6]}".strip()
    common = (common_name or "").strip()
    if common:
        common = common[0].upper() + common[1:]

    ident = lambda rank, name: name
    trans = lambda rank, name: rank_names.get((rank, name), name)

    paths = []
    if args.tag_style in ("separate", "scientific"):
        paths.append("Scientific|" + lineage(taxon, depth,
                                             binomial if species else None,
                                             ident))
    if args.tag_style == "combined":
        leaf = None
        if species:
            leaf = f"{binomial} ({common})" if common else binomial
        paths.append(lineage(taxon, depth, leaf, ident))
    if args.tag_style in ("separate", "english"):
        leaf = (common or binomial) if species else None
        paths.append("English|" + lineage(taxon, depth, leaf, trans))
    return [(p, score) for p in paths]


def predict(np, probs, taxa, common_names, group_ids, mask, rank_names, args):
    """Tags for one image from its probability vector over all taxa."""
    if mask is not None:
        probs = probs * mask

    order = np.argsort(probs)[::-1]
    top = order[0]
    if probs[top] <= 0:
        return []

    # aggregate the probability mass per group at each rank, then descend
    # the hierarchy along the argmax child as long as the mass clears the
    # threshold; the deepest passing rank becomes the tag
    tags = []
    best_depth, best_group = -1, None
    for depth in range(len(WALK_RANKS)):
        ids = group_ids[depth]
        if best_group is None:
            sums = np.bincount(ids, weights=probs)
        else:
            parent = group_ids[depth - 1] == best_group
            sums = np.bincount(ids, weights=np.where(parent, probs, 0))
        g = int(np.argmax(sums))
        if sums[g] < args.threshold:
            break
        best_depth, best_group = depth, g
        best_score = float(sums[g])

    if best_depth < 0:
        return []

    rows = np.nonzero(group_ids[best_depth] == best_group)[0]
    taxon = taxa[rows[0]]
    if best_depth == len(WALK_RANKS) - 1:
        # species-level hit; add runner-up species that also clear the
        # threshold (feeder shots with several birds), up to topk
        tags += make_tags(taxon, best_depth, common_names[rows[0]],
                          round(best_score, 4), args, rank_names)
        found = 1
        for i in order[1:]:
            if found >= args.topk or probs[i] < args.threshold:
                break
            if int(i) == int(rows[0]):
                continue
            tags += make_tags(taxa[i], best_depth, common_names[i],
                              round(float(probs[i]), 4), args, rank_names)
            found += 1
    else:
        tags += make_tags(taxon, best_depth, None, round(best_score, 4),
                          args, rank_names)
    return tags


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--in", dest="infile", required=True,
                        help="text file with one image path per line")
    parser.add_argument("--out", dest="outfile", required=True,
                        help="where to write the JSON results")
    parser.add_argument("--threshold", type=float, default=0.3,
                        help="minimum aggregated probability for a rank to "
                             "be tagged (default 0.3)")
    parser.add_argument("--topk", type=int, default=1,
                        help="max species tags per image (default 1)")
    parser.add_argument("--scope", choices=["animals", "birds", "all"],
                        default="animals",
                        help="which taxa may become tags (default animals)")
    parser.add_argument("--tag-style", choices=["separate", "scientific",
                                                "english", "combined"],
                        default="separate", dest="tag_style",
                        help="separate (default): a scientific and an "
                             "English tag tree per identification; "
                             "scientific / english: only one of them; "
                             "combined: scientific tree with "
                             "'Parus major (Great Tit)' as species leaf")
    parser.add_argument("--batch", type=int, default=8,
                        help="images per inference batch (default 8)")
    parser.add_argument("--progress", default=None,
                        help="file to overwrite with 'done total' counts "
                             "while processing (drives the progress bar)")
    args = parser.parse_args()

    # CHANGED: encoding="utf-8". The Lua side writes this file; a non-ASCII
    # folder or file name would otherwise be decoded wrong and the image
    # would silently fail to open.
    paths = [p for p in
             Path(args.infile).read_text(encoding="utf-8").splitlines()
             if p.strip()]
    if not paths:
        # CHANGED: explicit encoding
        Path(args.outfile).write_text("{}\n", encoding="utf-8")
        return
    write_progress(args.progress, 0, len(paths))

    import numpy as np
    import torch
    import open_clip

    device = pick_device(torch)
    warn(f"loading {MODEL_STR} on {device} (first run downloads ~7 GB)")
    model, _, preprocess = open_clip.create_model_and_transforms(MODEL_STR)
    model = model.to(device).eval()

    taxa, common_names, txt_feats = fetch_tol_data(np, torch)
    group_ids = build_groups(np, taxa)
    mask = scope_mask(np, taxa, args.scope)
    rank_names = load_rank_names()
    with torch.no_grad():
        logit_scale = float(model.logit_scale.exp())

    results = {}
    batch_paths, batch_tensors = [], []

    def flush():
        if not batch_tensors:
            return
        images = torch.stack(batch_tensors).to(device)
        with torch.no_grad():
            img_feats = model.encode_image(images)
            img_feats = img_feats / img_feats.norm(dim=-1, keepdim=True)
        # the big matmul runs on the CPU against the fp16 matrix in chunks:
        # ~800k x 1024 does not fit comfortably in every GPU alongside a
        # ViT-H, and CPU fp32 chunks are plenty fast for photo batches
        feats = img_feats.float().cpu()
        logits = torch.empty(len(batch_paths), txt_feats.shape[0])
        step = 131072
        for i in range(0, txt_feats.shape[0], step):
            chunk = txt_feats[i : i + step].float()
            logits[:, i : i + step] = feats @ chunk.T
        # softmax always runs over the full Tree of Life so the scores mean
        # "how much of the probability mass lands on this lineage" — with a
        # narrower scope, off-scope images then simply fail the threshold
        probs = torch.softmax(logits * logit_scale, dim=1).numpy()
        for path, p in zip(batch_paths, probs):
            results[path] = predict(
                np, p, taxa, common_names, group_ids, mask, rank_names, args
            )
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

    # CHANGED: encoding="utf-8". json.dumps still defaults to
    # ensure_ascii=True, so the payload is ASCII (\uXXXX escapes) — if your
    # Lua JSON decoder does not unescape those, add ensure_ascii=False here,
    # which is now safe because the file is explicitly UTF-8.
    Path(args.outfile).write_text(json.dumps(results, indent=1) + "\n",
                                  encoding="utf-8")
    identified = sum(1 for tags in results.values() if tags)
    warn(f"identified {identified} of {len(results)} readable images "
         f"-> {args.outfile}")


if __name__ == "__main__":
    main()
