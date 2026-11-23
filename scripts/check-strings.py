#!/usr/bin/env python3
"""Check the String Catalog against the strings the compiler extracted from RunningOutUI.

Run after scripts/build-app.sh (xcodebuild writes the .stringsdata files):

    python3 -I scripts/check-strings.py

Fails when a string in the code is missing from the catalog or has no Korean translation, or when the
catalog keeps a string the code no longer uses.
"""
import glob
import json
import os
import re
import sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
CATALOG = os.path.join(ROOT, "Sources", "RunningOutUI", "Resources", "Localizable.xcstrings")
# Xcode 27 names the folder RunningOutUI-t.build; earlier versions RunningOutUI.build.
DATA = os.path.join(ROOT, ".build", "xcode", "Build", "Intermediates.noindex", "**", "RunningOutUI*.build", "**",
                    "*.stringsdata")

# Only the most recently built configuration (Debug or Release): an older build keeps old strings.
by_configuration = {}
for path in glob.glob(DATA, recursive=True):
    configuration = re.split(re.escape(os.sep) + r"RunningOutUI[^" + re.escape(os.sep) + r"]*\.build", path)[0]
    configuration = configuration.rsplit(os.sep, 1)[-1]
    by_configuration.setdefault(configuration, []).append(path)
newest = max(by_configuration.values(), key=lambda paths: max(map(os.path.getmtime, paths)), default=[])
used = set()
for path in newest:
    with open(path, encoding="utf-8") as fh:
        for entries in json.load(fh).get("tables", {}).values():
            used.update(entry["key"] for entry in entries)
if not used:
    sys.exit("no extracted strings found: run scripts/build-app.sh first")

with open(CATALOG, encoding="utf-8") as fh:
    strings = json.load(fh)["strings"]

problems = []
for key in sorted(used - strings.keys()):
    problems.append(f"missing from the catalog: {key!r}")
for key in sorted(strings.keys() - used):
    problems.append(f"no longer used: {key!r}")
SPECIFIER = re.compile(r"%(?:\d+\$)?(@|lld|ld|d|f)")


def kinds(text):
    """The placeholder types in a string, ignoring their positions (%2$@ counts as @)."""
    return sorted(SPECIFIER.findall(text))


for key in sorted(used & strings.keys()):
    ko = strings[key].get("localizations", {}).get("ko", {}).get("stringUnit", {})
    if ko.get("state") != "translated" or not ko.get("value"):
        problems.append(f"no Korean translation: {key!r}")
    elif kinds(ko["value"]) != kinds(key):
        problems.append(f"placeholders differ in Korean: {key!r} -> {ko['value']!r}")
if problems:
    print("\n".join(problems))
    sys.exit(1)
print(f"strings: {len(used)} used, all in the catalog with Korean")
