# artemis

Automatic animal and bird species identification for darktable — no server,
everything local. [BioCLIP 2.5 Huge](https://huggingface.co/imageomics/bioclip-2.5-vith14)
(a ViT-H/14 model trained on the 200-million-image
[TreeOfLife-200M](https://huggingface.co/datasets/imageomics/TreeOfLife-200M)
dataset) scores every image against the ~800,000 taxa of the Tree of Life
and attaches the predicted taxonomy as hierarchical tags — by default one
scientific and one English tag per identification:

```
Artemis|Scientific|Aves|Passeriformes|Paridae|Parus major
Artemis|English|Birds|Perching Birds|Tits and Chickadees|Great Tit

Artemis|Scientific|Mammalia|Rodentia|Sciuridae|Sciurus vulgaris
Artemis|English|Mammals|Rodents|Squirrels|Red Squirrel
```

The English tree is built from `data/rank-names.tsv`, a table of English
names for every class, order and family occurring in TreeOfLife-200M,
generated from the [GBIF Backbone Taxonomy](https://www.gbif.org/dataset/d7dddbf4-2cf0-4f39-9b2a-bb099caae36c)
by `tools/make_rank_names.py`. Not every rank has an accepted English name
(most insect families don't); untranslatable ranks keep their scientific
name, so mixed paths like `Insects|Coleoptera|Carabidae` can occur. The TSV
is meant to be hand-edited — fix any name you disagree with, one
tab-separated row per rank.

Unlike a plain classifier, artemis walks the Linnaean hierarchy — class,
order, family, genus, species — and stops at the deepest rank whose
probability still clears the confidence threshold. A sharp portrait yields
the species; a distant silhouette of *some* gull may only yield

```
Artemis|Scientific|Aves|Charadriiformes|Laridae
```

and an image whose probability mass never concentrates on any animal class
(a landscape, a street scene) gets no tag at all. The scores come from a
softmax over the *entire* Tree of Life, so they mean "how much of the
probability mass lands on this lineage" regardless of the configured scope.

## Setup

The only requirement is [uv](https://docs.astral.sh/uv/):

```sh
brew install uv        # macOS
# or: curl -LsSf https://astral.sh/uv/install.sh | sh
```

`tagger.py` carries its own dependency metadata — uv creates the Python
environment (PyTorch, OpenCLIP, …) automatically on first run.

**The first run downloads ~7 GB**: the BioCLIP 2.5 Huge weights (~3.9 GB)
and the precomputed text embeddings for all TreeOfLife-200M taxa (~3.3 GB),
both cached by Hugging Face under `~/.cache/huggingface/`. A float16 copy of
the embeddings and a taxonomy index (~1.7 GB) are additionally cached under
`~/.cache/artemis/`, so runs after the first load fast.

Then enable `artemis/artemis.lua` in darktable's script manager.

## Use

Select images in the lighttable and press the **artemis: identify species**
button in the *selected image[s]* panel (or assign the shortcut of the same
name). Images are processed in batches on the GPU if one is available (CUDA
or Apple Silicon), otherwise on the CPU. ViT-H/14 is a big model — expect
roughly a second per image on an Apple Silicon GPU, more on CPU. A progress
bar in darktable's lower-left corner tracks the run; it stays at 0% while
the model loads, which dominates the very first run.

Preferences (*preferences → lua options*):

| preference | default | meaning |
|---|---|---|
| tag prefix | `Artemis` | root under which all tags are attached (without the trailing `\|`) |
| taxa scope | `animals` | which taxa may become tags: `animals`, `birds` (class Aves only), or `all` (every kingdom — plants and fungi get their kingdom prepended, e.g. `Artemis\|Scientific\|Plantae\|Magnoliopsida\|…`) |
| tag style | `separate` | `separate` → two tags, a scientific tree (`Scientific\|Aves\|…\|Parus major`) and an English tree (`English\|Birds\|…\|Great Tit`); `scientific` / `english` → only one of them; `combined` → scientific tree ending in `Parus major (Great Tit)`, without the `Scientific`/`English` branch. English names fall back to scientific ones where none are known |
| confidence threshold | 0.3 | minimum probability for a rank to be tagged; raise for fewer, surer identifications, lower to tag more distant/blurry subjects |
| max species tags | 1 | cap for photos with several confidently identified species in frame |
| skip already tagged | on | leave out images that already have any tag under the prefix |

Note that "skip already tagged" matches the *current* prefix — after changing
the prefix, images tagged under the old one are treated as untagged.

Images with any tag under the nature prefix (`Nature` by default, configurable
in the nature module's preferences) are always skipped, regardless of the
preferences above: those identifications were already accepted in the nature
review panel (see the nature module).

Species-level accuracy is genuinely good for birds, mammals, butterflies and
other well-photographed groups, but among 800k taxa confusable sibling
species exist everywhere — treat a species tag as a strong suggestion, and
the genus/family levels above it as near-certain. Raw files are identified
from their embedded JPEG preview, so no full raw decode is needed.

## Standalone use

The tagger is a plain CLI and works without darktable:

```sh
uv run tagger.py --in paths.txt --out tags.json \
    [--threshold 0.3 --topk 1 --scope animals --tag-style separate --batch 8
     --progress progress.txt]
```

`paths.txt` holds one image path per line; unreadable files are skipped with
a warning. Output:

```json
{ "/photos/IMG_1234.NEF": [
    ["Scientific|Aves|Passeriformes|Paridae|Parus major", 0.87],
    ["English|Birds|Perching Birds|Tits and Chickadees|Great Tit", 0.87]
  ],
  "/photos/IMG_1235.NEF": [
    ["Scientific|Aves|Charadriiformes|Laridae", 0.62],
    ["English|Birds|Shorebirds|Gulls, Terns and Skimmers", 0.62]
  ],
  "/photos/IMG_1236.NEF": [] }
```

To regenerate `data/rank-names.tsv` (e.g. after a GBIF backbone update):

```sh
uv run tools/make_rank_names.py    # downloads the ~1 GB GBIF backbone once
```

## Credits

Model and embeddings by the [Imageomics Institute](https://imageomics.osu.edu):
[BioCLIP 2: Emergent Properties from Scaling Hierarchical Contrastive
Learning](https://imageomics.github.io/bioclip-2/) (NeurIPS 2025 Spotlight).
Both are MIT licensed. English rank names derived from the
[GBIF Backbone Taxonomy](https://doi.org/10.15468/39omei) (CC BY 4.0).
