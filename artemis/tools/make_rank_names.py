# /// script
# requires-python = ">=3.10"
# dependencies = [
#   "huggingface-hub",
# ]
# ///
"""Generate data/rank-names.tsv: English names for higher taxonomic ranks.

For every kingdom, class, order and family that occurs in the
TreeOfLife-200M taxa list, look up an English vernacular name in the GBIF
Backbone Taxonomy and emit a TSV row. The tagger uses this table to build
the English tag tree (Birds|Perching Birds|... next to
Aves|Passeriformes|...); ranks without a row simply keep their scientific
name.

This is a one-off generator — the resulting rank-names.tsv is committed to
the repository and meant to be hand-edited where GBIF's choice is awkward.

Usage:
    uv run tools/make_rank_names.py [--backbone /path/to/backbone.zip]

Without --backbone the ~1 GB GBIF backbone archive is downloaded to a
temporary file first (https://hosted-datasets.gbif.org/datasets/backbone/).
The TreeOfLife names JSON is fetched via the Hugging Face cache (already
present if the tagger has run once).
"""

import argparse
import collections
import csv
import io
import json
import sys
import tempfile
import urllib.request
import zipfile
from pathlib import Path

BACKBONE_URL = "https://hosted-datasets.gbif.org/datasets/backbone/current/backbone.zip"
EMB_REPO = "imageomics/TreeOfLife-200M"
EMB_JSON = "embeddings/txt_emb_bioclip-2.5-vith14.json"
OUT_FILE = Path(__file__).resolve().parent.parent / "data" / "rank-names.tsv"

# ranks the tagger emits tags for (phylum is never tagged, genus has no
# vernacular names to speak of)
WANTED_RANKS = {"kingdom": 0, "class": 2, "order": 3, "family": 4}

# words kept lowercase when title-casing GBIF's mixed-case vernaculars
SMALL_WORDS = {"and", "or", "of", "the", "a", "an", "for", "de"}

# collective nouns that must not be pluralized
INVARIANT = {"waterfowl", "fish", "deer", "sheep", "cattle", "moose",
             "grouse", "swine", "bison", "elk"}

# hand-curated names that beat whatever GBIF votes produce — GBIF
# vernaculars are inconsistent for the most-photographed groups (singular
# forms, or odd picks like Sciuridae -> "Marmots"); entries whose scientific
# name does not occur in TreeOfLife are silently dropped
OVERRIDES = {
    ("kingdom", "Animalia"): "Animals",
    ("kingdom", "Plantae"): "Plants",
    ("class", "Aves"): "Birds",
    ("class", "Mammalia"): "Mammals",
    ("class", "Insecta"): "Insects",
    ("class", "Amphibia"): "Amphibians",
    ("class", "Actinopterygii"): "Ray-finned Fishes",
    ("class", "Elasmobranchii"): "Sharks and Rays",
    ("class", "Squamata"): "Lizards and Snakes",
    ("class", "Arachnida"): "Arachnids",
    ("class", "Gastropoda"): "Snails and Slugs",
    ("class", "Bivalvia"): "Bivalves",
    ("class", "Cephalopoda"): "Cephalopods",
    ("class", "Malacostraca"): "Crabs, Lobsters and Shrimp",
    ("order", "Passeriformes"): "Perching Birds",
    ("order", "Accipitriformes"): "Hawks and Eagles",
    ("order", "Falconiformes"): "Falcons",
    ("order", "Strigiformes"): "Owls",
    ("order", "Charadriiformes"): "Shorebirds",
    ("order", "Anseriformes"): "Waterfowl",
    ("order", "Galliformes"): "Landfowl",
    ("order", "Columbiformes"): "Pigeons and Doves",
    ("order", "Apodiformes"): "Swifts and Hummingbirds",
    ("order", "Coraciiformes"): "Kingfishers and Rollers",
    ("order", "Piciformes"): "Woodpeckers and Toucans",
    ("order", "Pelecaniformes"): "Pelicans, Herons and Ibises",
    ("order", "Ciconiiformes"): "Storks",
    ("order", "Suliformes"): "Cormorants and Gannets",
    ("order", "Podicipediformes"): "Grebes",
    ("order", "Gruiformes"): "Cranes and Rails",
    ("order", "Psittaciformes"): "Parrots",
    ("order", "Cuculiformes"): "Cuckoos",
    ("order", "Caprimulgiformes"): "Nightjars",
    ("order", "Bucerotiformes"): "Hornbills and Hoopoes",
    ("order", "Lepidoptera"): "Butterflies and Moths",
    ("order", "Odonata"): "Dragonflies and Damselflies",
    ("order", "Coleoptera"): "Beetles",
    ("order", "Diptera"): "Flies",
    ("order", "Hymenoptera"): "Bees, Wasps and Ants",
    ("order", "Hemiptera"): "True Bugs",
    ("order", "Orthoptera"): "Grasshoppers and Crickets",
    ("order", "Mantodea"): "Mantises",
    ("order", "Carnivora"): "Carnivores",
    ("order", "Rodentia"): "Rodents",
    ("order", "Chiroptera"): "Bats",
    ("order", "Lagomorpha"): "Rabbits and Hares",
    ("order", "Artiodactyla"): "Even-toed Ungulates",
    ("order", "Perissodactyla"): "Odd-toed Ungulates",
    ("order", "Cetacea"): "Whales and Dolphins",
    ("order", "Anura"): "Frogs and Toads",
    ("order", "Caudata"): "Salamanders",
    ("order", "Testudines"): "Turtles",
    ("family", "Sciuridae"): "Squirrels",
    ("family", "Paridae"): "Tits and Chickadees",
    ("family", "Laridae"): "Gulls and Terns",
    ("family", "Anatidae"): "Ducks, Geese and Swans",
    ("family", "Nymphalidae"): "Brush-footed Butterflies",
    ("family", "Turdidae"): "Thrushes",
    ("family", "Corvidae"): "Crows and Jays",
    ("family", "Accipitridae"): "Hawks and Eagles",
    ("family", "Falconidae"): "Falcons",
    ("family", "Ardeidae"): "Herons and Egrets",
    ("family", "Picidae"): "Woodpeckers",
    ("family", "Fringillidae"): "Finches",
    ("family", "Passeridae"): "Old World Sparrows",
    ("family", "Hirundinidae"): "Swallows and Martins",
    ("family", "Troglodytidae"): "Wrens",
    ("family", "Sturnidae"): "Starlings",
    ("family", "Sittidae"): "Nuthatches",
    ("family", "Regulidae"): "Kinglets",
    ("family", "Motacillidae"): "Wagtails and Pipits",
    ("family", "Emberizidae"): "Buntings",
    ("family", "Alcedinidae"): "Kingfishers",
    ("family", "Columbidae"): "Pigeons and Doves",
    ("family", "Phasianidae"): "Pheasants and Partridges",
    ("family", "Rallidae"): "Rails and Coots",
    ("family", "Scolopacidae"): "Sandpipers",
    ("family", "Charadriidae"): "Plovers",
    ("family", "Podicipedidae"): "Grebes",
    ("family", "Phalacrocoracidae"): "Cormorants",
    ("family", "Threskiornithidae"): "Ibises and Spoonbills",
    ("family", "Ciconiidae"): "Storks",
    ("family", "Strigidae"): "Owls",
    ("family", "Tytonidae"): "Barn Owls",
    ("family", "Canidae"): "Dogs and Foxes",
    ("family", "Felidae"): "Cats",
    ("family", "Mustelidae"): "Weasels and Otters",
    ("family", "Cervidae"): "Deer",
    ("family", "Bovidae"): "Cattle, Antelopes and Goats",
    ("family", "Suidae"): "Pigs",
    ("family", "Ursidae"): "Bears",
    ("family", "Phocidae"): "True Seals",
    ("family", "Leporidae"): "Rabbits and Hares",
    ("family", "Erinaceidae"): "Hedgehogs",
}


def warn(msg):
    print(f"make_rank_names: {msg}", file=sys.stderr, flush=True)


def wanted_names():
    """rank -> set of scientific names occurring in TreeOfLife-200M."""
    from huggingface_hub import hf_hub_download

    names_file = hf_hub_download(EMB_REPO, EMB_JSON, repo_type="dataset")
    entries = json.loads(Path(names_file).read_text())
    wanted = {rank: set() for rank in WANTED_RANKS}
    for taxon, _ in entries:
        for rank, idx in WANTED_RANKS.items():
            if taxon[idx]:
                wanted[rank].add(taxon[idx])
    warn("TreeOfLife ranks: " + ", ".join(
        f"{len(v)} {k}s" for k, v in wanted.items()))
    return wanted


def download_backbone():
    tmp = tempfile.NamedTemporaryFile(suffix=".zip", delete=False)
    warn(f"downloading {BACKBONE_URL} (~1 GB) to {tmp.name}")

    def report(blocks, block_size, total):
        done = blocks * block_size
        if blocks % 2000 == 0:
            warn(f"  {done / 1e6:.0f} / {total / 1e6:.0f} MB")

    urllib.request.urlretrieve(BACKBONE_URL, tmp.name, reporthook=report)
    return Path(tmp.name)


def tsv_reader(zf, member):
    """Stream rows of a TSV member as dicts (the backbone files carry a
    header line)."""
    raw = zf.open(member)
    text = io.TextIOWrapper(raw, encoding="utf-8", errors="replace")
    reader = csv.reader(text, delimiter="\t", quoting=csv.QUOTE_NONE)
    header = next(reader)
    for row in reader:
        yield dict(zip(header, row))


def title_case(name):
    words = name.strip().split()
    out = []
    for i, w in enumerate(words):
        if i > 0 and w.lower() in SMALL_WORDS:
            out.append(w.lower())
        elif w and w[0].islower():
            out.append(w[0].upper() + w[1:])
        else:
            out.append(w)
    return " ".join(out)


def looks_collective(name):
    """True for names that already read as a group: plural last word, or a
    list ('Ducks, Geese and Swans')."""
    low = name.lower()
    last = low.split()[-1]
    return ("," in low or " and " in low or last in INVARIANT
            or (last.endswith("s") and not last.endswith("ss")))


def pluralize(name):
    """A rank name labels a group, so singular GBIF picks ('Perching Bird')
    get their last word pluralized."""
    words = name.split()
    last = words[-1]
    low = last.lower()
    if low.endswith(("sh", "ch", "x", "z", "s")):
        last += "es"
    elif low.endswith("y") and len(low) > 1 and low[-2] not in "aeiou":
        last = last[:-1] + "ies"
    else:
        last += "s"
    return " ".join(words[:-1] + [last])


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--backbone", type=Path, default=None,
                        help="path to an already-downloaded backbone.zip")
    args = parser.parse_args()

    wanted = wanted_names()
    backbone = args.backbone or download_backbone()

    # pass 1: accepted higher taxa whose (rank, canonical name) we want
    taxon_ids = {}  # taxonID -> (rank, scientific name)
    with zipfile.ZipFile(backbone) as zf:
        warn("scanning Taxon.tsv for accepted higher taxa")
        for row in tsv_reader(zf, "Taxon.tsv"):
            rank = row.get("taxonRank", "").lower()
            if rank not in WANTED_RANKS:
                continue
            if row.get("taxonomicStatus") != "accepted":
                continue
            name = row.get("canonicalName") or row.get("scientificName", "")
            if name in wanted[rank]:
                taxon_ids[row["taxonID"]] = (rank, name)
        warn(f"matched {len(taxon_ids)} accepted taxa")

        # pass 2: collect English vernaculars for those taxa
        warn("scanning VernacularName.tsv for English names")
        votes = collections.defaultdict(collections.Counter)
        for row in tsv_reader(zf, "VernacularName.tsv"):
            key = taxon_ids.get(row.get("taxonID", ""))
            if key is None or row.get("language") not in ("en", "eng"):
                continue
            vern = row.get("vernacularName", "").strip()
            if vern and vern.lower() != key[1].lower():
                votes[key][title_case(vern)] += 1

    # collective-looking names beat singular ones, then most frequent wins;
    # ties broken by shortest, then alphabetical. A singular winner gets
    # pluralized — a rank names a group, not an individual
    chosen = {}
    for (rank, name), counter in votes.items():
        best = sorted(counter.items(),
                      key=lambda kv: (not looks_collective(kv[0]),
                                      -kv[1], len(kv[0]), kv[0]))[0][0]
        if not looks_collective(best):
            best = pluralize(best)
        chosen[(rank, name)] = best

    for (rank, name), english in OVERRIDES.items():
        if name in wanted[rank]:
            chosen[(rank, name)] = english

    rows = [(name, rank, english)
            for (rank, name), english in chosen.items()]
    rows.sort(key=lambda r: (WANTED_RANKS[r[1]], r[0]))

    OUT_FILE.parent.mkdir(parents=True, exist_ok=True)
    with OUT_FILE.open("w") as f:
        f.write("# scientific name <TAB> rank <TAB> English name\n"
                "# generated by tools/make_rank_names.py from the GBIF "
                "Backbone Taxonomy — edit freely\n")
        for name, rank, best in rows:
            f.write(f"{name}\t{rank}\t{best}\n")

    total = {rank: len(v) for rank, v in wanted.items()}
    got = collections.Counter(r[1] for r in rows)
    warn("English names found: " + ", ".join(
        f"{got[r]}/{total[r]} {r}s" for r in WANTED_RANKS))
    warn(f"wrote {len(rows)} rows -> {OUT_FILE}")


if __name__ == "__main__":
    main()
