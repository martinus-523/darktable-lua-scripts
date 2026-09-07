# nature

A small review companion for [artemis](../artemis/readme.md). Artemis attaches
its identifications as `Artemis|…` tags; nature lets you go through the images
one by one and accept or reject what was found.

Enable `nature/nature.lua` in darktable's script manager; a **nature** panel
appears on the right side of the lighttable. Select a single image and the
panel shows its Artemis identifications, e.g.

```
Scientific › Aves › Passeriformes › Paridae › Parus major
English › Birds › Perching Birds › Tits and Chickadees › Great Tit
```

- **accept** copies each `Artemis|` tag as a `Nature|` tag
  (`Artemis|Scientific|Aves|…` → `Nature|Scientific|Aves|…`) and removes the
  `Artemis|` tags. Disable the *remove artemis tags on accept* preference
  (lua options) to keep them instead; either way the `Nature|` tags mark the
  image as reviewed.
- **reject** removes the `Artemis|` tags from the image.

Both buttons are disabled when there is nothing to review: the image has no
`Artemis|` tags, or it already carries `Nature|` tags (i.e. it was accepted
earlier).

With several images selected the panel switches to batch mode: it shows how
many of them are still up for review and **accept** processes the whole
selection — each image gets copies of *its own* `Artemis|` tags only, and
untagged or already reviewed images are skipped. Rejecting stays a per-image
decision, so **reject** is disabled in batch mode.

Nature follows the *tag prefix* preference of artemis, so if you changed the
Artemis root there, nature looks for tags under that root instead.

The `Nature` root is configurable too, via nature's own *tag prefix*
preference (lua options). It is also used to detect already reviewed images —
both here and by artemis, which skips accepted images when scanning — so
after changing it, images accepted under the old prefix count as unreviewed
again.
