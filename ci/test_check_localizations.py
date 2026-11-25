#!/usr/bin/env python3
"""Regression coverage using the app's existing property lists and string catalog."""

import importlib.util
import json
from pathlib import Path
import plistlib
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location(
    "check_localizations", Path(__file__).with_name("check-localizations.py")
)
checker = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(checker)
CATALOG = "Config/InfoPlist.xcstrings"


class PropertyListLocalizationTests(unittest.TestCase):
    def setUp(self):
        self.references = {}
        for path in (checker.ROOT / "Config").glob("*.plist"):
            self.references.update(checker.plist_references(plistlib.loads(path.read_bytes())))
        self.live = {checker.normalized(key) for key in self.references}
        self.catalog = json.loads((checker.ROOT / CATALOG).read_text())
        self.app_plists = [
            plistlib.loads((checker.ROOT / "Config" / name).read_bytes())
            for name in ("Info.plist", "Info-Local.plist", "Info-macOS.plist")
        ]
        self.description = self.app_plists[0]["UTExportedTypeDeclarations"][0]["UTTypeDescription"]

    def test_registered_type_descriptions_are_not_orphaned(self):
        errors = []
        checker.check_catalog(CATALOG, self.live, {}, errors, source_values=self.references)
        self.assertEqual(errors, [])

    def test_nested_descriptions_still_require_both_chinese_translations(self):
        entry = self.catalog["strings"][self.description]
        for language in checker.LANGUAGES:
            with self.subTest(language=language):
                translation = entry["localizations"].pop(language)
                try:
                    errors = []
                    with patch.object(Path, "read_text", return_value=json.dumps(self.catalog)):
                        checker.check_catalog(
                            CATALOG, self.live, {}, errors, source_values=self.references
                        )
                    self.assertEqual(
                        errors, [f"{CATALOG}: {self.description!r}: missing {language}"]
                    )
                finally:
                    entry["localizations"][language] = translation

    def test_type_identifiers_are_not_strings_and_privacy_sources_are_preserved(self):
        for plist in self.app_plists:
            references = checker.plist_references(plist)
            for declaration in plist["UTExportedTypeDeclarations"]:
                self.assertNotIn(declaration["UTTypeIdentifier"], references)
                for identifier in declaration["UTTypeConformsTo"]:
                    self.assertNotIn(identifier, references)
            for key, source in plist.items():
                if key.startswith("NS") and key.endswith("UsageDescription"):
                    self.assertEqual(references[key], source)


if __name__ == "__main__":
    unittest.main()
