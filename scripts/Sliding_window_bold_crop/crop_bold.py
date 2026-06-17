#!/usr/bin/env python3
"""
crop_bold.py — crop one subject's 4D NIfTI to the 225TR (win_length) window
selected by the sliding-window analysis.

Slots between Stage 2 (sliding window) and Stage 3 (preprocessing) of the
event-segmentation pipeline. Reads ONLY; writes a brand-new file. Never modifies
or overwrites the input.

Window indexing: the manifest's start_TR/end_TR are 1-based inclusive (R seq),
referring to the same volume series as the cropped input NIfTI (timebase already
reconciled upstream via neural_tr_offset). Converted to numpy half-open as
[start_TR-1 : end_TR].

Usage:
  python3 crop_bold.py \
    --subject sub-NDARXXXXXXX \
    --infile  /path/to/<sub>_..._cropped_bold.nii.gz \
    --outfile /path/to/<sub>_..._window225_bold.nii.gz \
    --manifest-kids   /path/best_windows_kids.csv \
    --manifest-adults /path/best_windows_adults.csv \
    --config  /path/config.yaml
"""

import argparse
import csv
import os
import sys


def die(msg, code=1):
    """Print a clear error to stderr and exit. No traceback noise."""
    sys.stderr.write(f"ERROR: {msg}\n")
    sys.exit(code)


def read_win_length(config_path):
    """Read sliding_window.win_length from config.yaml.

    Uses PyYAML if available; otherwise falls back to a minimal line parser so
    the worker doesn't hard-depend on yaml being in the container.
    """
    if not os.path.isfile(config_path):
        die(f"config not found: {config_path}")

    try:
        import yaml  # type: ignore
        with open(config_path) as f:
            cfg = yaml.safe_load(f)
        try:
            return int(cfg["sliding_window"]["win_length"])
        except (KeyError, TypeError):
            die(f"could not find sliding_window.win_length in {config_path}")
    except ImportError:
        # Minimal fallback: find the sliding_window block, then win_length under it.
        in_block = False
        with open(config_path) as f:
            for line in f:
                stripped = line.strip()
                if stripped.startswith("#") or not stripped:
                    continue
                # top-level key (no leading indent) ends the block
                if not line[:1].isspace():
                    in_block = stripped.startswith("sliding_window:")
                    continue
                if in_block and stripped.startswith("win_length:"):
                    val = stripped.split(":", 1)[1].strip().strip('"').strip("'")
                    try:
                        return int(val)
                    except ValueError:
                        die(f"win_length is not an integer in {config_path}: {val!r}")
        die(f"could not find sliding_window.win_length in {config_path}")


def lookup_window(subject, manifest_path):
    """Return (start_TR, end_TR) for subject from a manifest CSV, or None if absent."""
    if not os.path.isfile(manifest_path):
        die(f"manifest not found: {manifest_path}")

    hits = []
    with open(manifest_path, newline="") as f:
        reader = csv.DictReader(f)
        for col in ("subject", "start_TR", "end_TR"):
            if col not in reader.fieldnames:
                die(f"manifest {manifest_path} missing required column '{col}' "
                    f"(found: {reader.fieldnames})")
        for row in reader:
            if row["subject"].strip() == subject:
                hits.append((int(float(row["start_TR"])), int(float(row["end_TR"]))))

    if not hits:
        return None
    if len(hits) > 1:
        die(f"subject {subject} appears {len(hits)} times in {manifest_path} "
            f"(expected exactly one window per subject post-selection)")
    return hits[0]


def main():
    p = argparse.ArgumentParser(description="Crop one subject's 4D NIfTI to its sliding-window TR range.")
    p.add_argument("--subject", required=True)
    p.add_argument("--infile", required=True)
    p.add_argument("--outfile", required=True)
    p.add_argument("--manifest-kids", required=True, dest="manifest_kids")
    p.add_argument("--manifest-adults", required=True, dest="manifest_adults")
    p.add_argument("--config", required=True)
    args = p.parse_args()

    sub = args.subject

    # --- defensive import: clear message if the container lacks nibabel/numpy ---
    try:
        import numpy as np
        import nibabel as nib
    except ImportError as e:
        die(f"[{sub}] required package missing in this python environment: {e.name}. "
            f"This worker needs numpy and nibabel (e.g. inside the fmriprep .sif).")

    # --- read window length from config (canonical source of truth) ---
    win_length = read_win_length(args.config)

    # --- locate the subject's window: kids first, then adults ---
    win_kids = lookup_window(sub, args.manifest_kids)
    win_adults = lookup_window(sub, args.manifest_adults)

    if win_kids is not None and win_adults is not None:
        die(f"[{sub}] found in BOTH kids and adults manifests — ambiguous; "
            f"the age split should make these disjoint.")
    window = win_kids if win_kids is not None else win_adults
    if window is None:
        die(f"[{sub}] not found in either manifest — should not have been dispatched.")
    start_tr, end_tr = window  # 1-based inclusive

    # --- window sanity against config ---
    n_window = end_tr - start_tr + 1
    if n_window != win_length:
        die(f"[{sub}] manifest window length {n_window} "
            f"(start_TR={start_tr}, end_TR={end_tr}) != config win_length {win_length}. "
            f"Refusing to crop a wrong-length window.")
    if start_tr < 1:
        die(f"[{sub}] start_TR={start_tr} is < 1; expected 1-based indexing.")

    # --- input checks ---
    if not os.path.isfile(args.infile):
        die(f"[{sub}] input NIfTI not found: {args.infile}")

    in_real = os.path.realpath(args.infile)
    out_real = os.path.realpath(args.outfile)

    # GUARD 1: never write onto the input itself
    if out_real == in_real:
        die(f"[{sub}] outfile resolves to the input file — refusing (would destroy original).")

    # GUARD 2: never write into the input's directory (keeps regressed/ untouched)
    if os.path.dirname(out_real) == os.path.dirname(in_real):
        die(f"[{sub}] outfile is in the same directory as the input — refusing. "
            f"Write crops to a separate output directory.")

    os.makedirs(os.path.dirname(out_real), exist_ok=True)

    # --- load (input is opened read-only by nibabel) ---
    img = nib.load(args.infile)
    if img.ndim != 4:
        die(f"[{sub}] input is {img.ndim}D, expected 4D timeseries: {args.infile}")
    n_vols = img.shape[3]

    # GUARD 3: input must actually contain the requested window
    if end_tr > n_vols:
        die(f"[{sub}] window end_TR={end_tr} exceeds input volume count {n_vols}. "
            f"Timebase mismatch — refusing to crop.")

    # --- crop: 1-based inclusive -> numpy half-open ---
    lo = start_tr - 1
    hi = end_tr  # exclusive stop == inclusive end_tr
    data = img.dataobj[..., lo:hi]  # lazy slice, avoids loading the whole array
    data = np.asarray(data)

    # GUARD 4: output must be exactly win_length volumes
    if data.shape[3] != win_length:
        die(f"[{sub}] cropped to {data.shape[3]} volumes, expected {win_length}. "
            f"Refusing to save.")

    # --- write a fresh image, preserving affine + header (time dim updates itself) ---
    out_img = nib.Nifti1Image(data, img.affine, img.header)
    nib.save(out_img, out_real)

    sys.stdout.write(
        f"[{sub}] cropped TRs {start_tr}-{end_tr} ({win_length} vols) "
        f"from {n_vols}-vol input -> {out_real}\n"
    )


if __name__ == "__main__":
    main()
