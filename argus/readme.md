# argus

Automatic image tagging for darktable with standardised subject and scene
keywords — no server, everything local. A SigLIP model (via OpenCLIP) scores
every image against the labels in `data/vocabulary.tsv`:

- **scene** group — the 365 categories of
  [Places365](http://places2.csail.mit.edu)
- **object** group — the 601 boxable classes of
  [OpenImages V7](https://storage.googleapis.com/openimages/web/index.html)
- **extra** group — terms the two datasets lack (Sunset, Sunrise, Forest,
  Fog, …), meant to be extended by you

Every label is filed into a photographer-oriented hierarchy under `Argus|`:

```
Argus|Landscape|Beach            Argus|Objects|Vehicles|Car
Argus|Location|Indoor|Kitchen    Argus|Objects|Music|Guitar
Argus|Location|Outdoor|Street    Argus|Weather|Rainbow
Argus|People|Portrait            Argus|Light|Sunset
Argus|Animals|Dog                Argus|Season|Autumn
Argus|Plants|Rose                Argus|Food & Drink|Pizza
```

Top levels: Landscape, Location (Indoor/Outdoor), People, Animals, Plants,
Food & Drink, Objects (with subgroups such as Vehicles, Furniture,
Electronics, Clothing & Accessories, Sports, Music, Tools), Weather, Light,
Season.

`vocabulary.tsv` is the single place to adjust all of this. One row per
label, three tab-separated columns:

```
Lake natural	scene	Landscape|Lake
Dog	object	Animals|Dog
Sunset	extra	Light|Sunset
```

The first column is the text the model scores (it goes into the prompt
"a photo of a …"), the second the group whose top-k cap applies, the third
where the tag lands (rooted at the configurable tag prefix (default `Argus|`)). So you can re-home a label by editing
its path, rename a tag without changing what is scored, remove a label by
deleting its row, and add your own terms as new `extra` rows. Changed labels
are re-encoded and re-cached automatically on the next run; a row without a
path falls back to a coarse per-group branch.

Scoring is multi-label: each label gets an independent sigmoid score, so an
image can be `beach` *and* `sunset`. Labels above a configurable threshold
are kept, capped per group (defaults: 3 scenes, 8 objects). Everything runs
locally; raw files are tagged from their embedded JPEG preview, so no full
raw decode is needed.

## Setup

The only requirement is [uv](https://docs.astral.sh/uv/):

```sh
brew install uv        # macOS
# or: curl -LsSf https://astral.sh/uv/install.sh | sh
```

`tagger.py` carries its own dependency metadata — uv creates the Python
environment (PyTorch, OpenCLIP, …) automatically on first run, and the model
weights (~800 MB, ViT-B-16-SigLIP) are downloaded once from Hugging Face.
The prompt text embeddings are cached under `~/.cache/argus/`.

Then enable `argus/argus.lua` in darktable's script manager.

## Use

Select images in the lighttable and press the **auto tag (SigLIP)** button in
the *selected image[s]* panel (or assign the shortcut of the same name). The
first run is slow (environment + model download); after that, images are
tagged in batches on the GPU if one is available (CUDA or Apple Silicon),
otherwise on the CPU.

Preferences (*preferences → lua options*):

| preference | default | meaning |
|---|---|---|
| tag prefix | `Argus` | root under which all tags are attached (without the trailing `\|`) |
| capitalize tag prefix | on | force the prefix's first letter to a capital (off forces lowercase) |
| score threshold | 0.001 | minimum score for a label to become a tag |
| max scene tags | 3 | top-k cap for the scene group |
| max object tags | 8 | top-k cap for the object group |
| max extra tags | 3 | top-k cap for the extra group |
| skip already tagged | on | leave out images that already have any tag under the prefix |

Note that "skip already tagged" matches the *current* prefix — after changing
the prefix, images tagged under the old one are treated as untagged.

The threshold looks unusually small because SigLIP's sigmoid is calibrated
against caption-style matches: a generic label like *tower* on an Eiffel
Tower photo scores ~0.003 while unrelated labels stay below 0.0001, so
correct labels typically land anywhere between 0.001 and 0.3. Raise the
threshold (e.g. 0.01) for fewer, higher-precision tags; the top-k caps do
the rest of the pruning.

## Standalone use

The tagger is a plain CLI and works without darktable:

```sh
uv run tagger.py --in paths.txt --out tags.json \
    [--threshold 0.001 --topk-scene 3 --topk-object 8 --topk-extra 3 --batch 16]
```

`paths.txt` holds one image path per line; unreadable files are skipped with
a warning. Output:

```json
{ "/photos/IMG_1234.NEF": {
    "scene":  [["Landscape|Beach", 0.83], ["Landscape|Coast", 0.41]],
    "object": [["Animals|Dog", 0.91], ["Objects|Sports|Ball", 0.33]],
    "extra":  [["Light|Sunset", 0.44]] } }
```
