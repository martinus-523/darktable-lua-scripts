# argus

Automatic image tagging for darktable with standardised subject and scene
keywords — no server, no Python, everything local. A SigLIP model runs
inside darktable through the `darktable.ai` Lua API (darktable ≥ 5.6) and
scores every image against the labels in `data/vocabulary.tsv`:

- **scene** group — the 365 categories of
  [Places365](http://places2.csail.mit.edu)
- **object** group — the 601 boxable classes of
  [OpenImages V7](https://storage.googleapis.com/openimages/web/index.html)
- **extra** group — terms the two datasets lack (Sunset, Sunrise, Forest,
  Fog, …)

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

Scoring is multi-label: each label gets an independent sigmoid score, so an
image can be `beach` *and* `sunset`. Labels above a configurable threshold
are kept, capped per group (defaults: 3 scenes, 8 objects). The model sees
the *developed* image — darktable's full edit pipeline output — not the
camera preview.

## How it works

The whole scoring pipeline is baked into a single ONNX model
(`argus-siglip`): SigLIP's squash-resize and normalization, the
ViT-B-16-SigLIP image tower, the precomputed text embeddings of all ~1000
vocabulary prompts, and the final sigmoid. `argus.lua` feeds it one image
tensor and reads back one score per label — darktable's bundled ONNX
Runtime does the inference, on GPU where available (CoreML, CUDA, …).

The text tower runs only at *build* time: `tools/build_model.py` encodes
the vocabulary prompts and packages everything as a `.dtmodel`. That is
the one place Python is still involved — as a build tool, never at
tagging time.

## Setup

1. **Get the model.** Build it once with [uv](https://docs.astral.sh/uv/)
   (downloads the SigLIP weights, ~800 MB, from Hugging Face):

   ```sh
   cd argus/tools
   uv run build_model.py
   ```

   This writes `argus/build/argus-siglip.dtmodel` (~350 MB) and validates
   the export against PyTorch. Add `--test-image photo.jpg` to see the
   top-10 labels for a photo of your own.

2. **Install it** in darktable: *preferences → AI → install model from
   file*, pick the `.dtmodel`. (Or unzip it into darktable's models
   directory, e.g. `~/.local/share/darktable/models/`.)

3. **Enable** `argus/argus.lua` in darktable's script manager.

darktable must be ≥ 5.6 with AI support enabled.

## Use

Select images in the lighttable and press the **argus: auto tag** button in
the *selected image[s]* panel (or assign the shortcut of the same name).
The first inference after a darktable start is slower (the execution
provider compiles the model graph); after that, expect a fraction of a
second per image. A progress bar in darktable's lower-left corner tracks
the run and can cancel it.

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

## Changing the vocabulary

`data/vocabulary.tsv` is still the single source of truth — one row per
label, three tab-separated columns (label, group, tag path):

```
Lake natural	scene	Landscape|Lake
Dog	object	Animals|Dog
Sunset	extra	Light|Sunset
```

But because the text embeddings are baked into the model, **the model must
be rebuilt after any edit**: run `uv run build_model.py` again and
reinstall the `.dtmodel`. `argus.lua` reads the same file in the same
order to map score indices back to tag paths, and refuses to run when the
label count no longer matches the installed model.
