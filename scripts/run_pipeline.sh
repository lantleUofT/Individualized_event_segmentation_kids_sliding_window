#!/usr/bin/env bash
# =====================================================================
# Runs full pipeline including toy data generation
#
# Order:  toy data gen  ->  s1 harmonization  ->  s2 sliding window
#         ->  s3 preprocessing  ->  s4 validation
#
# Run while cd'd into repo root:  bash scripts/run_pipeline.sh
# =====================================================================

# Halt on first error (-e), undefined var (-u), or failed pipe step (pipefail).
set -euo pipefail



# --- Default config ---
CONFIG_FILE="config.yaml"



# --- Parse flags ---
SKIP_TOY=0
for arg in "$@"; do
  case "$arg" in
    --real)
      SKIP_TOY=1
      CONFIG_FILE="config_local.yaml"
      ;;
    *)
      echo "Unknown option: $arg" >&2; exit 1 ;;
  esac
done



# --- Anchor to the repo root (parent of this script's dir) ---
# Every stage runs against the same working directory no matter where you invoke from.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

echo "Repo root: ${REPO_ROOT}"
echo "Starting pipeline at $(date)"
echo "======================================================================"



# --- Step 0: generate toy data ---
if [ "${SKIP_TOY}" -eq 0 ]; then
  echo ">>> [0/4] Generating toy data ..."
  python3 scripts/Toy_data_generator.py
else
  echo ">>> [skip] Toy data generation skipped (--real); using existing/real data."
fi



# --- Stage 1: data loading & harmonization ---
echo ">>> [1/4] Harmonization ..."
Rscript scripts/Data_loading_and_harmonization.R "${CONFIG_FILE}"



# --- Stage 2: sliding window motion selection ---
echo ">>> [2/4] Sliding window analysis ..."
Rscript scripts/Sliding_window_analysis.R "${CONFIG_FILE}"



# --- Stage 3: preprocessing for final analysis ---
echo ">>> [3/4] Preprocessing ..."
Rscript scripts/Data_preprocessing_for_final_analysis.R "${CONFIG_FILE}"



# --- Stage 4: individualized validation ---
echo ">>> [4/4] Validation ..."
Rscript scripts/Individualized_event_segmentation_validation_kids.R "${CONFIG_FILE}"

echo "======================================================================"
echo "Pipeline finished at $(date)"
echo "Outputs in: ${REPO_ROOT}/data/"