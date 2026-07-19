#!/usr/bin/env python3
"""Golden-screenshot diff (21-testing-and-ci "golden screenshots").

Compares captured PNGs against committed goldens with a per-pixel channel
tolerance and a budget for how many pixels may differ at all, and writes a
side-by-side image for every regression so a CI artifact shows what moved.

The two thresholds are separate on purpose.  --tolerance absorbs the
harmless drift a different GPU or LOVE build puts into a blend; --max-diff
is what actually fails the run.  A shot where one sprite moved trips the
pixel budget even though every differing pixel is far outside the channel
tolerance, and a shot that got globally half a shade darker trips neither
-- which is the intent, because that is not a regression a reviewer wants
to bless a hundred goldens over.

Usage:
  tools/compare_shots.py GOLDEN_DIR SHOT_DIR [--tolerance N] [--max-diff N]
                         [--diff-dir DIR] [--bless]

Exits 0 when every shot matches, 1 on any regression, 2 on a usage or
missing-file problem.
"""

import argparse
import os
import shutil
import sys

try:
    from PIL import Image, ImageChops
except ImportError:
    sys.stderr.write(
        "compare_shots needs Pillow: python3 -m pip install pillow\n")
    sys.exit(2)


def load_rgb(path):
    """Goldens and captures must compare in one colour space; LOVE writes
    RGBA and a hand-made golden is often RGB."""
    with Image.open(path) as image:
        return image.convert("RGB")


def compare(golden_path, shot_path, tolerance, max_diff):
    """Returns (ok, message, diff_image_or_None)."""
    golden = load_rgb(golden_path)
    shot = load_rgb(shot_path)

    if golden.size != shot.size:
        return (False,
                "size %dx%d != golden %dx%d" % (shot.width, shot.height,
                                                golden.width, golden.height),
                side_by_side(golden, shot, None))

    delta = ImageChops.difference(golden, shot)
    # collapse the three channels to the worst single-channel deviation, so
    # a pixel counts as differing on its loudest channel rather than an
    # average that would hide a red-only shift
    worst = max_channel(delta)

    histogram = worst.histogram()
    differing = sum(histogram[tolerance + 1:])

    if differing > max_diff:
        return (False,
                "%d pixels differ by more than %d (budget %d)"
                % (differing, tolerance, max_diff),
                side_by_side(golden, shot, amplify(worst)))

    return (True, "%d pixels differ by more than %d" % (differing, tolerance), None)


def max_channel(delta):
    """Per-pixel max across R/G/B as an L image."""
    red, green, blue = delta.split()
    return ImageChops.lighter(ImageChops.lighter(red, green), blue)


def amplify(mask):
    """Difference masks are near-black; stretch so the diff is visible."""
    return mask.point(lambda value: 255 if value else 0)


def side_by_side(golden, shot, mask):
    """golden | shot | mask, for the CI artifact."""
    panels = [golden, shot]
    if mask is not None:
        panels.append(mask.convert("RGB"))
    width = sum(panel.width for panel in panels) + 4 * (len(panels) - 1)
    height = max(panel.height for panel in panels)
    canvas = Image.new("RGB", (width, height), (255, 0, 255))
    offset = 0
    for panel in panels:
        canvas.paste(panel, (offset, 0))
        offset += panel.width + 4
    return canvas


def shots_in(directory):
    if not os.path.isdir(directory):
        return None
    return sorted(name for name in os.listdir(directory)
                  if name.lower().endswith(".png"))


def main(argv):
    parser = argparse.ArgumentParser(description="diff captured shots against goldens")
    parser.add_argument("golden_dir")
    parser.add_argument("shot_dir")
    parser.add_argument("--tolerance", type=int, default=2,
                        help="per-channel value a pixel may drift without counting (default 2)")
    parser.add_argument("--max-diff", type=int, default=0,
                        help="how many pixels may exceed the tolerance (default 0)")
    parser.add_argument("--diff-dir", default=None,
                        help="where to write side-by-side images (default SHOT_DIR/diffs)")
    parser.add_argument("--bless", action="store_true",
                        help="overwrite the goldens with the captures instead of comparing")
    args = parser.parse_args(argv)

    goldens = shots_in(args.golden_dir)
    shots = shots_in(args.shot_dir)

    if shots is None:
        sys.stderr.write("no shot directory: %s\n" % args.shot_dir)
        return 2

    if args.bless:
        os.makedirs(args.golden_dir, exist_ok=True)
        for name in shots:
            shutil.copyfile(os.path.join(args.shot_dir, name),
                            os.path.join(args.golden_dir, name))
            print("blessed %s" % name)
        print("\n%d goldens written to %s" % (len(shots), args.golden_dir))
        return 0

    if goldens is None:
        sys.stderr.write(
            "no golden directory: %s (capture some and re-run with --bless)\n"
            % args.golden_dir)
        return 2

    if not goldens:
        sys.stderr.write(
            "no goldens in %s -- refusing to pass vacuously\n" % args.golden_dir)
        return 2

    diff_dir = args.diff_dir or os.path.join(args.shot_dir, "diffs")
    failures = 0

    for name in goldens:
        golden_path = os.path.join(args.golden_dir, name)
        shot_path = os.path.join(args.shot_dir, name)

        if not os.path.exists(shot_path):
            print("FAIL %s: no capture for this golden" % name)
            failures += 1
            continue

        ok, message, diff = compare(golden_path, shot_path,
                                    args.tolerance, args.max_diff)
        if ok:
            print("ok   %s (%s)" % (name, message))
        else:
            failures += 1
            print("FAIL %s: %s" % (name, message))
            if diff is not None:
                os.makedirs(diff_dir, exist_ok=True)
                out = os.path.join(diff_dir, name)
                diff.save(out)
                print("     diff written to %s" % out)

    # a capture with no golden is a new screen nobody blessed; report it,
    # but it is not a regression in an existing one
    for name in shots:
        if name not in goldens:
            print("note %s: captured but no golden (bless it to pin it)" % name)

    print("\n%d/%d shots matched" % (len(goldens) - failures, len(goldens)))
    print("ALL SHOTS MATCHED" if failures == 0 else "%d FAILURES" % failures)
    return 0 if failures == 0 else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
