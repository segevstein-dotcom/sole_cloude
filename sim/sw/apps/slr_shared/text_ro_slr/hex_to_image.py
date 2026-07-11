#!/usr/bin/env python3
"""
command: 
python hex_to_image.py outputs/slr_ds_mnx.txt -o outputs/hex_to_image_out.png -i 13

---------------
Generate a labeled grayscale image from a hex array text file.

Input file format:
  - Each line contains space-separated hex byte values (e.g. "00 1A FF b7 ...")
  - Lines starting with '#' are treated as comments and skipped
  - Empty lines are skipped
  - The script auto-detects the width from the first data line and the
    height from the number of data lines (supports non-square arrays too)

Usage:
  python hex_to_image.py <input_file> [options]

Options:
  -o, --output    Output PNG path          (default: <input_file>.png)
  -c, --cell      Cell size in pixels      (default: 40)
  -f, --fontsize  Font size for labels     (default: 10)
  -g, --grid      Grid line color as R,G,B (default: 64,64,64)
  --no-labels     Omit hex labels
  --no-grid       Omit grid lines

Examples:
  python hex_to_image.py data.txt
  python hex_to_image.py data.txt -o result.png -c 50 -f 12
  python hex_to_image.py data.txt --no-labels -c 20
"""

import argparse
import sys
from pathlib import Path

try:
    from PIL import Image, ImageDraw, ImageFont
except ImportError:
    sys.exit("Pillow is required. Install it with:  pip install Pillow")


# ---------------------------------------------------------------------------
# Parsing
# ---------------------------------------------------------------------------

def parse_hex_file(args, path: str) -> tuple[list[int], int, int]:
    """Read a hex text file and return (flat pixel list, width, height)."""
    rows = []
    valid_row_cnt=0
    with open(path, "r") as fh:
        for line in fh:
            line = line.strip()
            if 'idx:' in line :
              img_idx = int(line.split()[7])        
            if not line or "#" in line :
                continue

            if args.i==img_idx :
              values = [int(tok, 16) for tok in line.split()]           
              rows.append(values)
              valid_row_cnt += 1            
              if valid_row_cnt==32:
                  break

    if not rows:
        sys.exit("No data found in input file.")

    width = len(rows[0])
    for i, row in enumerate(rows):
        if len(row) != width:
            print(
                f"Warning: row {i} has {len(row)} values (expected {width}). "
                "It will be zero-padded or truncated.",
                file=sys.stderr,
            )
            # Normalize length
            rows[i] = (row + [0] * width)[:width]

    height = len(rows)
    pixels = [v for row in rows for v in row]
    return pixels, width, height


# ---------------------------------------------------------------------------
# Image generation
# ---------------------------------------------------------------------------

def load_font(size: int) -> ImageFont.FreeTypeFont:
    """Try to load a TTF font; fall back to the PIL built-in."""
    candidates = [
        "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
        "/usr/share/fonts/truetype/liberation/LiberationMono-Bold.ttf",
        "/System/Library/Fonts/Helvetica.ttc",           # macOS
        "C:/Windows/Fonts/arialbd.ttf",                  # Windows
    ]
    for path in candidates:
        try:
            return ImageFont.truetype(path, size)
        except (IOError, OSError):
            continue
    return ImageFont.load_default()


def build_image(
    pixels: list[int],
    width: int,
    height: int,
    cell_size: int = 40,
    font_size: int = 10,
    grid_color: tuple[int, int, int] = (64, 64, 64),
    show_labels: bool = True,
    show_grid: bool = True,
) -> Image.Image:
    img_w = width * cell_size
    img_h = height * cell_size
    img = Image.new("RGB", (img_w, img_h), (0, 0, 0))
    draw = ImageDraw.Draw(img)
    font = load_font(font_size) if show_labels else None

    for row in range(height):
        for col in range(width):
            val = pixels[row * width + col]
            x0 = col * cell_size
            y0 = row * cell_size
            x1 = x0 + cell_size - 1
            y1 = y0 + cell_size - 1

            # Fill cell with grayscale shade
            draw.rectangle([x0, y0, x1, y1], fill=(val, val, val))

            # Optional grid border
            if show_grid:
                draw.rectangle([x0, y0, x1, y1], outline=grid_color)

            # Optional hex label
            if show_labels and font is not None:
                text = f"{val:02X}"
                text_color = (255, 255, 255) if val < 128 else (0, 0, 0)
                bbox = draw.textbbox((0, 0), text, font=font)
                tw = bbox[2] - bbox[0]
                th = bbox[3] - bbox[1]
                tx = x0 + (cell_size - tw) // 2
                ty = y0 + (cell_size - th) // 2
                draw.text((tx, ty), text, fill=text_color, font=font)

    return img


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def parse_rgb(s: str) -> tuple[int, int, int]:
    parts = [int(x) for x in s.split(",")]
    if len(parts) != 3:
        raise argparse.ArgumentTypeError("Color must be R,G,B (e.g. 64,64,64)")
    return tuple(parts)


def main():
    parser = argparse.ArgumentParser(
        description="Generate a labeled grayscale image from a hex array text file.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    parser.add_argument("input", help="Path to the input hex text file")
    parser.add_argument("-i", "-img_idx", type=int, default=0, help="image index within input dataset file")
    parser.add_argument("-f", "--fontsize", type=int, default=10, help="Font size for labels (default: 10)")
    parser.add_argument("-o", "--output", help="Output PNG path (default: input file name + .png)")
    parser.add_argument("-c", "--cell", type=int, default=40, help="Cell size in pixels (default: 40)")    
    parser.add_argument("-g", "--grid", type=parse_rgb, default=(64, 64, 64),   
                        metavar="R,G,B", help="Grid line color (default: 64,64,64)")
    parser.add_argument("--no-labels", action="store_true", help="Omit hex value labels")
    parser.add_argument("--no-grid", action="store_true", help="Omit grid lines")
    args = parser.parse_args()

    input_path = Path(args.input)
    if not input_path.exists():
        sys.exit(f"Input file not found: {input_path}")

    output_path = Path(args.output) if args.output else input_path.with_suffix(".png")

    print(f"Reading:  {input_path}")
    pixels, width, height = parse_hex_file(args,str(input_path))
    print(f"Array:    {width} x {height}  ({width * height} pixels)")

    img = build_image(
        pixels=pixels,
        width=width,
        height=height,
        cell_size=args.cell,
        font_size=args.fontsize,
        grid_color=args.grid,
        show_labels=not args.no_labels,
        show_grid=not args.no_grid,
    )

    img.save(str(output_path))
    print(f"Saved:    {output_path}  ({img.width} x {img.height} px)")


if __name__ == "__main__":
    main()
