#!/usr/bin/env python3
"""Check catalog coverage against Xcode's source-string inventory, without a build."""

import json
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent
LANGUAGES = ("zh-Hans", "zh-Hant")
FORMAT = re.compile(r"%(?!arg)(?:(\d+)\$)?[-+ #0]*(?:\d+|\*)?(?:\.(?:\d+|\*))?(?:hh|ll|h|l|L|z|t|j)?[@diuoxXfFeEgGaAcCsSp]")


def signature(text):
    """Keep argument positions and types; allow translators to reorder arguments."""
    result = []
    for index, match in enumerate(FORMAT.finditer(text.replace("%%", "")), 1):
        token = match.group()
        token = re.sub(r"^%\d+\$", "%", token)
        result.append((int(match[1] or index), token))
    return sorted(result)


def normalized(key):
    # Lightweight extraction uses %arg where only the Swift compiler knows the type.
    return FORMAT.sub("%arg", key)


def units(value):
    if isinstance(value, dict):
        if "stringUnit" in value:
            yield value["stringUnit"]
        for key, child in value.items():
            if key != "stringUnit":
                yield from units(child)


def inventory(directories, errors):
    sources = sorted(p for directory in directories for p in (ROOT / directory).rglob("*.swift"))
    live = set()
    required = {}
    with tempfile.TemporaryDirectory(prefix="chahua-localizations-") as temporary:
        subprocess.run(
            ["xcrun", "xcstringstool", "extract", "--all-potential-swift-keys",
             "--modern-localizable-strings", "--SwiftUI", "--output-directory", temporary,
             *map(str, sources)], check=True, capture_output=True, text=True,
        )
        for path in Path(temporary).glob("*.stringsdata"):
            data = json.loads(path.read_text())
            source = Path(data["source"])
            source_bytes = source.read_bytes()
            for table, entries in data["tables"].items():
                for entry in entries:
                    key = normalized(entry["key"])
                    live.add(key)
                    line = entry["location"]["startingLine"]
                    offset = entry["location"]["startingOffset"]
                    prefix = source_bytes[max(0, offset - 300):offset].decode("utf-8", errors="ignore")
                    eager = re.search(r"(?:AppLanguage|Self)\.localized\(\s*$|LocalizedStringKey\(\s*$", prefix)
                    if source.relative_to(ROOT).parts[0] == "App" and re.search(
                        r"\bString\(\s*localized:\s*$", prefix
                    ):
                        errors.append(f"{source.relative_to(ROOT)}:{line}: use AppLanguage.localized to honor the app language")
                    # Preview galleries are not product UI. Still retain their live keys.
                    if "Fixtures" not in source.parts and (table == "Localizable" or eager):
                        required[key] = f"{source.relative_to(ROOT)}:{line}"
    return live, required


def plist_references(plist):
    """Nested type descriptions use their text as the catalog key, not the plist key."""
    references = dict(plist)

    def visit(value):
        if isinstance(value, dict):
            for key, child in value.items():
                if key == "UTTypeDescription" and isinstance(child, str):
                    # Keep top-level source values, including privacy usage descriptions.
                    references.setdefault(child, child)
                elif isinstance(child, (dict, list)):
                    visit(child)
        elif isinstance(value, list):
            for child in value:
                visit(child)

    visit(plist)
    return references


def check_catalog(relative, live, required, errors, external_prefix=None, source_values=None):
    path = ROOT / relative
    data = json.loads(path.read_text())
    if data["sourceLanguage"] != "en":
        errors.append(f"{relative}: sourceLanguage must be en")
    catalog = data["strings"]
    available = {normalized(key) for key in catalog}
    for key, location in sorted(required.items()):
        if key not in available:
            errors.append(f"{location}: missing catalog key {key!r} in {relative}")
    for key, entry in catalog.items():
        label = f"{relative}: {key!r}"
        external = external_prefix is not None and key.startswith(external_prefix)
        if normalized(key) not in live and not external:
            errors.append(f"{label}: orphaned key (no source reference)")
        if entry.get("extractionState") == "stale":
            errors.append(f"{label}: stale key")
        if entry.get("shouldTranslate") is False:
            if not entry.get("comment"):
                errors.append(f"{label}: non-translatable keys need a reason in comment")
            continue
        localizations = entry.get("localizations", {})
        source = localizations.get("en", {}).get("stringUnit", {}).get(
            "value", (source_values or {}).get(key, key))
        for language in LANGUAGES:
            translated = list(units(localizations.get(language, {})))
            if not translated:
                errors.append(f"{label}: missing {language}")
            for unit in translated:
                if unit.get("state") != "translated" or (source and not unit.get("value")):
                    errors.append(f"{label}: unfinished {language} translation")
                if signature(source) != signature(unit.get("value", "")):
                    errors.append(f"{label}: {language} format arguments differ from English")
    return len(catalog)


def main():
    errors = []
    count = 0
    for relative, directories, external in (
        ("App/Resources/Localizable.xcstrings", ("App", "Shared"), "push."),
        ("ShareExtension/Localizable.xcstrings", ("ShareExtension", "Shared"), None),
    ):
        live, required = inventory(directories, errors)
        # APNs (Apple Push Notification service) resolves server-supplied loc-key
        # values. These keys have no Swift call site and must not be pruned.
        count += check_catalog(relative, live, required, errors, external)
    plist_values = {}
    for path in (ROOT / "Config").glob("*.plist"):
        with path.open("rb") as file:
            plist_values.update(plist_references(plistlib.load(file)))
    count += check_catalog("Config/InfoPlist.xcstrings", {normalized(key) for key in plist_values}, {}, errors,
                           source_values=plist_values)
    if errors:
        print("Localization check failed:\n" + "\n".join(errors), file=sys.stderr)
        return 1
    print(f"Localization check passed: {count} keys; Simplified and Traditional Chinese complete.")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except subprocess.CalledProcessError as error:
        print(error.stderr or str(error), file=sys.stderr)
        sys.exit(1)
