#!/bin/bash
# =====================================================================
# Gated: requires --real AND --stitch_neural_data (mirrors the GSBS gate).
# =====================================================================

set -euo pipefail
trap "echo 'Interrupted. Exiting...'; exit 1" INT


# --- Config + flag gate: --stitch_neural_data requires --real ---
CONFIG_FILE="config.yaml"
REAL=0
RUN_STITCH=0
for arg in "$@"; do
  case "$arg" in
    --real)                REAL=1; CONFIG_FILE="config_local.yaml" ;;
    --stitch_neural_data)  RUN_STITCH=1 ;;
  esac
done

if [ "${REAL}" -ne 1 ] || [ "${RUN_STITCH}" -ne 1 ]; then
  echo ">>> [stitch] skipped (needs --real AND --stitch_neural_data; got real=${REAL} stitch=${RUN_STITCH})."
  exit 0
fi




# --- Anchor to repo root (provided by run_pipeline.sh, else derive) ---
if [ -n "${REPO_ROOT:-}" ]; then
  :  # provided by run_pipeline.sh
elif [ -n "${SLURM_SUBMIT_DIR:-}" ]; then
  REPO_ROOT="${SLURM_SUBMIT_DIR}"
else
  SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
  REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
fi

if [ ! -f "${REPO_ROOT}/${CONFIG_FILE}" ]; then
  echo "ERROR: REPO_ROOT='${REPO_ROOT}' does not contain ${CONFIG_FILE}."
  echo ">> Run through scripts/run_pipeline.sh, or cd into repo root first."
  exit 1
fi
cd "${REPO_ROOT}"


# --- Read GSBS output roots + neural file targets from config ---
IFS=$'\t' read -r out_dir_full out_dir_partial neural_file neural_file_full python_exec < <(
  python3 -c "
import yaml, os
c = yaml.safe_load(open('${CONFIG_FILE}'))
g = c['gsbs']; p = c['paths']; cont = c.get('container', {})
nf = p['neural_file_partial']
root, ext = os.path.splitext(nf)
nf_full = p.get('neural_file_full', root + '_full' + ext)
print('\t'.join(str(x) for x in [
    g['output_dir_full'], g['output_dir_partial'],
    nf, nf_full, cont.get('python_exec', 'python3'),
]))
"
)

if [ -z "${out_dir_partial}" ] || [ -z "${neural_file}" ]; then
  echo "ERROR: failed to read gsbs/neural paths from ${CONFIG_FILE}"; exit 1
fi

PY="${python_exec:-python3}"


# --- Resolve absolute paths (config paths are repo-relative) ---
abspath() { case "$1" in /*) printf '%s' "$1";; *) printf '%s' "${REPO_ROOT}/$1";; esac; }
FULL_ROOT="$(abspath "${out_dir_full}")"
PARTIAL_ROOT="$(abspath "${out_dir_partial}")"
NEURAL_PARTIAL="$(abspath "${neural_file}")"
NEURAL_FULL="$(abspath "${neural_file_full}")"

echo ">>> [stitch] full source    : ${FULL_ROOT}"
echo ">>> [stitch] partial source : ${PARTIAL_ROOT}"
echo ">>> [stitch] partial MASTER : ${NEURAL_PARTIAL}"
echo ">>> [stitch] full MASTER    : ${NEURAL_FULL}"

# ---------------------------------------------------------------------
# stacks roi-001..100 boundary TSVs (adding a roi column), concatenates 
# across subjects (adding a subject column), and writes the MASTER. 
# Reports missing ROIs and unparsable names.
# ---------------------------------------------------------------------
stitch_window() {
  local label="$1" src_root="$2" out_file="$3"

  if [ ! -d "${src_root}" ]; then
    echo "WARNING: [${label}] source root not found, skipping: ${src_root}" >&2
    return 0
  fi
  mkdir -p "$(dirname "${out_file}")"

  SRC_ROOT="${src_root}" OUT_FILE="${out_file}" LABEL="${label}" "${PY}" - <<'PY'
import os, re
from pathlib import Path
import pandas as pd

src_root = Path(os.environ["SRC_ROOT"])
out_file = Path(os.environ["OUT_FILE"])
label    = os.environ["LABEL"]

roi_pat = re.compile(r"_schaefer100_roi-(\d+)_boundaries\.tsv$")

def roi_num(name: str) -> int:
    m = roi_pat.search(name)
    return int(m.group(1)) if m else 10**9

# Per-subject directories named sub-NDAR...
subdirs = sorted(p for p in src_root.iterdir()
                 if p.is_dir() and p.name.startswith("sub-NDAR"))
print(f"[{label}] subject dirs found: {len(subdirs)}")
if not subdirs:
    raise SystemExit(f"[{label}] no subject dirs under {src_root}")

subject_frames = []
skipped = 0

for subdir in subdirs:
    subj = subdir.name
    files = sorted(subdir.glob(f"{subj}_schaefer100_roi-*_boundaries.tsv"),
                   key=lambda p: roi_num(p.name))
    if not files:
        print(f"[{label}] [SKIP] {subj}: no boundary TSVs")
        skipped += 1
        continue

    roi_frames, present = [], set()
    for f in files:
        r = roi_num(f.name)
        if r == 10**9:
            continue
        present.add(r)
        df = pd.read_csv(f, sep="\t")          # TR, boundary, strength
        df.insert(0, "roi", r)                  # -> roi, TR, boundary, strength
        roi_frames.append(df)

    if not roi_frames:
        print(f"[{label}] [SKIP] {subj}: TSVs found but none matched roi pattern")
        skipped += 1
        continue

    missing = [r for r in range(1, 101) if r not in present]
    sub_df = pd.concat(roi_frames, ignore_index=True)
    sub_df.insert(0, "subject", subj)           # -> subject, roi, TR, boundary, strength
    subject_frames.append(sub_df)

    if missing:
        print(f"[{label}] [OK] {subj}: rows={len(sub_df)} MISSING_ROIS={len(missing)} (e.g. {missing[:10]})")

if not subject_frames:
    raise SystemExit(f"[{label}] no usable subject data; nothing written.")

master = pd.concat(subject_frames, ignore_index=True)
out_file.parent.mkdir(parents=True, exist_ok=True)
master.to_csv(out_file, sep="\t", index=False)

print(f"[{label}] WROTE {out_file}")
print(f"[{label}] rows={len(master)} cols={list(master.columns)} "
      f"subjects={master['subject'].nunique()} skipped={skipped}")
PY
}

stitch_window "partial" "${PARTIAL_ROOT}" "${NEURAL_PARTIAL}"
stitch_window "full"    "${FULL_ROOT}"    "${NEURAL_FULL}"

echo "[$(date)] stitch_neural_data finished (partial + full)."