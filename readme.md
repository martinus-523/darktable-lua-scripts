# lua script for darktable

This repository contains a collection of lua scripts for darktable.

## Utilities

- **find_missing_lut** this script searches in the library and tags all photo's for which the LUT is missing with the tag: *missing-lut*.

- **find_missing_raster_mask** this script searches in the library and tags all photo's for which the raster mask is missing with the tag *missing-raster-mask*.

# Argus

Argus tags the selected images with subject and scene keywords, fully
locally, using a zero-shot image-recognition model (SigLIP). Every image is
scored against a fixed vocabulary of ~1000 labels — the 365 scene categories
of Places365, the 601 object classes of OpenImages V7, and a small
user-extendable extras list (sunset, fog, …) — and the matches are attached
as hierarchical tags such as `Argus|Animals|Dog`, `Argus|Location|Indoor|Kitchen`
or `Argus|Light|Sunset`.