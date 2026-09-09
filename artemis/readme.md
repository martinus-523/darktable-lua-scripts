# artemis

Automatic animal and bird species identification for darktable — no server,
no Python, everything local. [BioCLIP 2.5 Huge](https://huggingface.co/imageomics/bioclip-2.5-vith14)
(a ViT-H/14 model trained on the 200-million-image
[TreeOfLife-200M](https://huggingface.co/datasets/imageomics/TreeOfLife-200M)
dataset) runs inside darktable through the `darktable.ai` Lua API
(darktable ≥ 5.6), scores every image against the ~800,000 taxa of the Tree
of Life, and attaches the predicted taxonomy as hierarchical tags — by
default one scientific and one English tag per identification:

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

## How it works

The build tool splits BioCLIP into two ONNX models packaged as one
`.dtmodel`: **tower.onnx** turns a 224×224 crop into an image embedding,
and **scorer.onnx** holds the float16 text embeddings of all ~800k taxa
plus the taxonomy aggregation — softmax over the whole Tree of Life and,
per walked rank, the probability mass of every taxonomic group (taxa are
sorted at build time so each group is a contiguous row range, which makes
the aggregation a cumulative sum inside the graph). The scorer returns the
top-64 groups per rank; `artemis.lua` walks those, resolves names through
`data/taxa.bin` (a fixed-width record file written by the build in the
same row order), and attaches the tags. darktable's bundled ONNX Runtime
does the inference, on GPU where available (CoreML, CUDA, …).

Python is involved only at *build* time, never at tagging time.

## Setup

1. **Build the model** once with [uv](https://docs.astral.sh/uv/):

   ```sh
   cd artemis/tools
   uv run build_model.py
   ```

   The first run downloads ~10 GB from Hugging Face (the BioCLIP weights
   and the precomputed taxa embeddings), all cached under
   `~/.cache/huggingface/`. It writes
   `artemis/build/artemis-bioclip.dtmodel` (~2.9 GB) and
   `artemis/data/taxa.bin` (~200 MB, must stay next to `artemis.lua`),
   and validates the export against PyTorch. Add `--test-image photo.jpg`
   for an end-to-end identification check.

2. **Install the model** in darktable: *preferences → AI → install model
   from file*, pick the `.dtmodel`. (Or unzip it into darktable's models
   directory, e.g. `~/.local/share/darktable/models/`.)

3. **Enable** `artemis/artemis.lua` in darktable's script manager.

darktable must be ≥ 5.6 with AI support enabled. `taxa.bin` and the
model package are built together and must stay in sync — rebuild and
reinstall both whenever you regenerate one.

## Use

Select images in the lighttable and press the **artemis: identify species**
button in the *selected image[s]* panel (or assign the shortcut of the same
name). The model sees a center crop of the *developed* image — darktable's
full edit pipeline output. ViT-H/14 is a big model: the first inference
after a darktable start is slow (the execution provider compiles the
graph), after that expect around a second per image on Apple Silicon, more
on CPU. A progress bar in darktable's lower-left corner tracks the run and
can cancel it.

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
the genus/family levels above it as near-certain.

The scorer's top-64-per-rank shortcut is exact for any threshold above
1/64 ≈ 0.016 (probabilities sum to 1, so no group outside the top 64 of its
rank can clear such a threshold) — every practical setting qualifies.

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
