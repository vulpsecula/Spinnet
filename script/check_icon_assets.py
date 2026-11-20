# /// script
# requires-python = ">=3.11"
# dependencies = ["pillow==13.0.0", "resvg-py==0.5.0"]
# ///
"""Compare the generated vector artwork against the supplied logo reference.

Run after build_icon_assets.py. This checks the design before macOS adds its
enclosure rendering; it doesn't claim pixel identity with the raster source.
"""
from io import BytesIO
import json
import math
from pathlib import Path
import xml.etree.ElementTree as ET

from PIL import Image, ImageChops, ImageDraw, ImageStat
import resvg_py

ROOT = Path(__file__).resolve().parents[1]
DESIGN = ROOT / "Resources/IconDesign"
PROJECT = ROOT / "Resources/AppIcon.icon"
OUTPUT = ROOT / "dist/IconPreviews"


def differences(reference, rendered, box):
    difference = ImageChops.difference(reference.crop(box), rendered.crop(box))
    stats = ImageStat.Stat(difference)
    return {
        "mean_absolute_rgb": sum(stats.mean) / 3,
        "rgb_rms": math.sqrt(sum(value * value for value in stats.rms) / 3),
    }


def main():
    OUTPUT.mkdir(parents=True, exist_ok=True)
    reference = Image.open(DESIGN / "References/AppIcon.png").convert("RGB")
    tree = ET.parse(DESIGN / "AppIcon.svg")
    tree.getroot().set("width", str(reference.width))
    tree.getroot().set("height", str(reference.height))
    tree.getroot().set("viewBox", f"0 0 {reference.width} {reference.height}")
    png = resvg_py.svg_to_bytes(svg_string=ET.tostring(tree.getroot(), encoding="unicode"))
    rendered = Image.open(BytesIO(png)).convert("RGB")

    # Identical source coordinates: no registration, stretching or automatic
    # alignment may hide an incorrect shape or placement.
    regions = {
        "subject": (220, 230, 1025, 1045),
        "lower_s": (220, 590, 760, 1045),
        "upper_s": (250, 245, 685, 620),
        "upper_corner": (805, 300, 890, 380),
        "blue_right_corner": (935, 485, 1015, 565),
        "right_lower_corner": (940, 710, 1020, 790),
        "lower_bottom_corner": (810, 885, 895, 965),
    }
    report = {name: differences(reference, rendered, box) for name, box in regions.items()}

    namespace = {"svg": "http://www.w3.org/2000/svg"}
    document = json.loads((PROJECT / "icon.json").read_text())
    for group in document["groups"]:
        for layer in group["layers"]:
            assert layer["glass"] is False
            asset = ET.parse(PROJECT / "Assets" / layer["image-name"])
            assert asset.getroot().get("viewBox") == "98 100 1060 1060"
            assert not asset.findall(".//svg:image", namespace), "Embedded bitmap in vector artwork"
            ids = [element.get("id") for element in asset.iter() if element.get("id")]
            assert len(ids) == len(set(ids)), "Duplicate SVG ID"

    box = regions["subject"]
    first, second = reference.crop(box), rendered.crop(box)
    comparison = Image.new("RGB", (first.width * 2, first.height + 36), "white")
    comparison.paste(first, (0, 36))
    comparison.paste(second, (first.width, 36))
    draw = ImageDraw.Draw(comparison)
    draw.text((14, 12), "Original logo.png", fill="#243047")
    draw.text((first.width + 14, 12), "Reference-traced SVG", fill="#243047")
    comparison.save(OUTPUT / "AppIcon-reference-comparison.png")
    Image.blend(first, second, .5).save(OUTPUT / "AppIcon-reference-overlay.png")
    rendered.save(OUTPUT / "AppIcon-reference-vector-full.png")
    (OUTPUT / "AppIcon-reference-verification.json").write_text(json.dumps(report, indent=2) + "\n")

    # These limits allow raster texture/antialiasing differences, while
    # rejecting the previous guessed outlines and straight pie-slice corners.
    assert report["subject"]["mean_absolute_rgb"] < 1.5, report
    for name in regions:
        assert report[name]["mean_absolute_rgb"] < 2, (name, report[name])
    print(json.dumps(report, indent=2))
    print("Reference comparison and vector resource checks passed.")


if __name__ == "__main__":
    main()
