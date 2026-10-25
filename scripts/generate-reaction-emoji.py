#!/usr/bin/env python3
"""Generate the bundled Unicode reaction catalog; no third-party dependencies.

Run from any directory: python3 scripts/generate-reaction-emoji.py
Use --source /path/to/emoji-test.txt for offline generation of the same pinned data.
Search metadata comes from the pinned, generated PWA emojibase-data 17.0.0 snapshot;
--search-source can select another checkout of that exact snapshot.
Distribute the catalog with Unicode-LICENSE.txt and reaction-emoji-search-LICENSE.txt.
"""

import argparse
import hashlib
import json
from pathlib import Path
import re
import urllib.request

SOURCE_URL = "https://www.unicode.org/Public/17.0.0/emoji/emoji-test.txt"
SOURCE_SHA256 = "1d8a944f88d7952f7ef7c5167fef3c67995bcae24543949710231b03a201acda"
UNICODE_VERSION = "17.0"
SEARCH_SOURCE_SHA256 = "188a4ebbdbec1fc8b54ccac1a1ffcc1d9c58a254994c9945af7b9a20a38288b0"
SEARCH_SOURCE_DESCRIPTION = "emojibase-data 17.0.0; PWA picker-emojis.generated.json (en, zh, zh-hant)"
ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "App/Resources/reaction-emoji-17.json"
SEARCH_SOURCE = ROOT.parent / "chahua/pwa/src/app/messages/emoji-picker/picker-emojis.generated.json"
TONE = re.compile(r"(?:light|medium-light|medium|medium-dark|dark) skin tone")
ROW = re.compile(r"^([0-9A-F ]+)\s*;\s*fully-qualified\s*#\s*\S+\s+E([0-9.]+) (.+)$")


def normalized_sequence(sequence):
    return sequence.replace("\ufe0f", "")


def search_metadata(source):
    if hashlib.sha256(source).hexdigest() != SEARCH_SOURCE_SHA256:
        raise ValueError("Search metadata does not match the pinned PWA snapshot SHA-256")
    document = json.loads(source)
    metadata = {}
    for entry in document["emojis"]:
        keywords = list(dict.fromkeys([entry["name"], *entry["keywords"]]))
        for sequence in [entry["char"], *entry.get("skins", [])]:
            key = normalized_sequence(sequence)
            if key in metadata:
                raise ValueError(f"Duplicate search sequence: {sequence!r}")
            metadata[key] = keywords if sequence == entry["char"] else []
    return metadata


def generate(source, search_source):
    if hashlib.sha256(source).hexdigest() != SOURCE_SHA256:
        raise ValueError("emoji-test.txt does not match the pinned Unicode 17 source SHA-256")
    metadata = search_metadata(search_source)
    groups = []
    subgroups = []
    entries = []
    group = None
    subgroup = None
    for line in source.decode("utf-8").splitlines():
        if line.startswith("# group: "):
            name = line.removeprefix("# group: ")
            group = None if name == "Component" else len(groups)
            if group is not None:
                groups.append(name)
        elif line.startswith("# subgroup: ") and group is not None:
            subgroup = len(subgroups)
            subgroups.append(line.removeprefix("# subgroup: "))
        elif group is not None and (match := ROW.match(line)):
            codepoints, version, name = match.groups()
            sequence = "".join(chr(int(value, 16)) for value in codepoints.split())
            entries.append({"e": sequence, "n": name, "v": version, "g": group,
                            "s": subgroup, "o": len(entries)})
    if not entries or len(groups) != 9:
        raise ValueError("Unexpected Unicode emoji group structure")
    bases = {entry["n"]: entry["o"] for entry in entries
             if not any(0x1F3FB <= ord(scalar) <= 0x1F3FF for scalar in entry["e"])}
    for entry in entries:
        if any(0x1F3FB <= ord(scalar) <= 0x1F3FF for scalar in entry["e"]):
            # Names, not synthesized codepoints, connect mixed-tone handshake,
            # holding-hands, kiss and couple sequences to their unmodified base.
            stem, _, qualifiers = entry["n"].partition(": ")
            retained = [part for part in qualifiers.split(", ") if part and not TONE.fullmatch(part)]
            # Unicode spells the neutral two-person kiss/couple base without
            # the participant qualifier used by its explicit mixed-tone forms.
            if stem in ("kiss", "couple with heart") and retained == ["person", "person"]:
                retained = []
            base_name = stem + (": " + ", ".join(retained) if retained else "")
            if base_name not in bases:
                raise ValueError(f"No unmodified base for {entry['n']!r}: {base_name!r}")
            entry["b"] = bases[base_name]
        # The PWA snapshot combines English, Simplified Chinese and Traditional
        # Chinese CLDR/emojibase labels and tags, independent of UI language.
        # Like PWA, simple tone variants remain in the tone menu and exact lookup,
        # rather than repeating each base's textual search result five times.
        entry["k"] = metadata[normalized_sequence(entry["e"])]
    return {"unicodeVersion": UNICODE_VERSION, "source": SOURCE_URL,
            "sourceSHA256": SOURCE_SHA256, "license": "Unicode-LICENSE.txt",
            "searchSource": SEARCH_SOURCE_DESCRIPTION, "searchSourceSHA256": SEARCH_SOURCE_SHA256,
            "searchLicense": "reaction-emoji-search-LICENSE.txt",
            "groups": groups, "subgroups": subgroups, "entries": entries}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, help="Use a local copy of the pinned source")
    parser.add_argument("--search-source", type=Path, default=SEARCH_SOURCE,
                        help="Use the pinned PWA generated en/zh/zh-hant metadata snapshot")
    args = parser.parse_args()
    source = args.source.read_bytes() if args.source else urllib.request.urlopen(SOURCE_URL).read()
    catalog = generate(source, args.search_source.read_bytes())
    OUTPUT.write_text(json.dumps(catalog, ensure_ascii=False, separators=(",", ":")) + "\n", encoding="utf-8")
    print(f"Generated {OUTPUT.relative_to(ROOT)}: {len(catalog['entries'])} qualified sequences")


if __name__ == "__main__":
    main()
