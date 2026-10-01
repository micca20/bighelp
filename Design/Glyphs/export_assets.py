"""Copies generated glyph SVGs into the app's asset catalog as template vectors."""
import json
import os
import sys

SOURCE = sys.argv[1]
TARGET = os.path.join(os.path.dirname(__file__), "..", "..", "Bighelp", "Resources", "Assets.xcassets", "Glyphs")

for file in sorted(os.listdir(SOURCE)):
    if not file.endswith(".svg") or file.startswith("_"):
        continue
    name = file[:-4]
    asset = "Glyph" + name[0].upper() + name[1:]
    folder = os.path.join(TARGET, asset + ".imageset")
    os.makedirs(folder, exist_ok=True)
    with open(os.path.join(SOURCE, file)) as source, open(os.path.join(folder, asset + ".svg"), "w") as target:
        target.write(source.read())
    with open(os.path.join(folder, "Contents.json"), "w") as contents:
        json.dump({"images": [{"filename": asset + ".svg", "idiom": "universal"}],
                   "info": {"author": "xcode", "version": 1},
                   "properties": {"preserves-vector-representation": True,
                                  "template-rendering-intent": "template"}}, contents, indent=2)
