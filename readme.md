# lua script for darktable

This repository contains a collection of lua scripts for darktable.

## Utilities

- **find_missing_lut** this script searches in the library and tags all photo's for which the LUT is missing with the tag: *missing-lut*.

- **find_missing_raster_mask** this script searches in the library and tags all photo's for which the raster mask is missing with the tag *missing-raster-mask*.

## Argus
Argus tags the selected images with subject and scene keywords, fully
locally, using a zero-shot image-recognition model (SigLIP) that runs
inside darktable through the `darktable.ai` Lua API (darktable ≥ 5.6) — no
Python at tagging time. Every image is scored against a fixed vocabulary of
~1000 labels — the 365 scene categories of Places365, the 601 object
classes of OpenImages V7, and a small extras list (sunset, fog, …) — and
the matches are attached as hierarchical tags such as `Argus|Animals|Dog`,
`Argus|Location|Indoor|Kitchen` or `Argus|Light|Sunset`.

## Artemis
Artemis identifies the animal or bird species in the selected images, fully
locally, with the BioCLIP 2.5 Huge model trained on TreeOfLife-200M, running
inside darktable through the `darktable.ai` Lua API (darktable ≥ 5.6) — no
Python at tagging time. Every
image is scored against the ~800,000 taxa of the Tree of Life and tagged
with the predicted taxonomy down to the deepest rank the model is confident
about — e.g. `Artemis|Aves|Passeriformes|Paridae|Parus major (Great Tit)`
for a sharp portrait, or just `Artemis|Aves|Charadriiformes|Laridae` for a
distant gull silhouette.

## Nature
Nature is a review companion for Artemis: a lighttable panel that shows the
`Artemis` tags of the selected image and lets you **accept** them (each tag
is copied under `Nature` instead of `Artemis`) or **reject** them (the
`Artemis` tags are removed). The buttons are disabled when the image has no
`Artemis` tags, or already carries `Nature` tags from an earlier review —
reviewed images show their accepted `Nature` tags instead. An **identify**
button starts Artemis right from the panel for images that carry neither
`Artemis` nor `Nature` tags yet.
Artemis can be configured to ignore images already tagged with `Nature`.