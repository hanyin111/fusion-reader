"""Package the generated white-haired girl artwork as native launcher icons.

Resizing and format conversion only. The original artwork stays untouched.
Old launcher files are retained; native manifests select the new filenames.
"""

import json
from pathlib import Path

from PIL import Image


ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "assets/icon/whitehair-girl-original.png"
MASTER = ROOT / "assets/icon/whitehair-girl-1024.png"


def main():
    with Image.open(SOURCE) as source:
        if source.width != source.height:
            raise ValueError("The icon artwork must be square.")
        image = source.convert("RGB")

    def png(path, size):
        path.parent.mkdir(parents=True, exist_ok=True)
        image.resize((size, size), Image.Resampling.LANCZOS).save(path, optimize=True)
        with Image.open(path) as saved:
            if saved.size != (size, size) or saved.mode != "RGB":
                raise ValueError(f"Invalid icon: {path}")

    png(MASTER, 1024)
    for density, size in {"mdpi": 48, "hdpi": 72, "xhdpi": 96,
                          "xxhdpi": 144, "xxxhdpi": 192}.items():
        png(ROOT / f"android/app/src/main/res/mipmap-{density}/ic_launcher_whitehair.png", size)

    for platform in ("ios/Runner", "macos/Runner"):
        directory = ROOT / platform / "Assets.xcassets/AppIcon.appiconset"
        manifest_path = directory / "Contents.json"
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        generated = set()
        for entry in manifest["images"]:
            if "filename" not in entry:
                continue
            old = entry["filename"]
            name = old if old.startswith("whitehair_") else "whitehair_" + old
            size = round(float(entry["size"].split("x")[0]) * float(entry["scale"][:-1]))
            if name not in generated:
                png(directory / name, size)
                generated.add(name)
            entry["filename"] = name
        manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")

    ico = ROOT / "windows/runner/resources/app_icon_whitehair.ico"
    sizes = [(size, size) for size in (16, 24, 32, 48, 64, 128, 256)]
    image.save(ico, format="ICO", sizes=sizes)
    with Image.open(ico) as saved:
        if saved.ico.sizes() != set(sizes):
            raise ValueError("The Windows icon is missing an expected resolution.")
    print("Verified: opaque master, 5 Android icons, both Apple catalogs and 7 Windows ICO sizes.")


if __name__ == "__main__":
    main()
