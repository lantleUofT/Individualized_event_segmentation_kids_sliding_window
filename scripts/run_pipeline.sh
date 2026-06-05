#!/usr/bin/env bash
# =====================================================================
# runs full pipeline including toy data generation
#
# Order:  toy data gen  ->  s1 harmonization  ->  s2 sliding window
#         ->  s3 preprocessing  ->  s4 validation
#
# Run while cd'd into repo root:  bash scripts/run_pipeline.sh
# =====================================================================

# Halt on first error (-e), undefined var (-u), or failed pipe step (pipefail).
set -euo pipefail

# --- Anchor to the repo root (parent of this script's dir) ---
# Mirrors the Python __file__.parent.parent and R here() anchoring, so every
# stage runs against the same working directory no matter where you invoke from.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

echo "Repo root: ${REPO_ROOT}"
echo "Starting pipeline at $(date)"
echo "======================================================================"

# --- Step 0: generate toy data ---
echo ">>> [0/4] Generating toy data ..."
python3 scripts/Toy_data_generator.py

# --- Stage 1: data loading & harmonization ---
echo ">>> [1/4] Harmonization ..."
Rscript scripts/Data_loading_and_harmonization.R

# --- Stage 2: sliding window motion selection ---
echo ">>> [2/4] Sliding window analysis ..."
Rscript scripts/Sliding_window_analysis.R

# --- Stage 3: preprocessing for final analysis ---
echo ">>> [3/4] Preprocessing ..."
Rscript scripts/Data_preprocessing_for_final_analysis.R

# --- Stage 4: individualized validation ---
echo ">>> [4/4] Validation ..."
Rscript scripts/Individualized_event_segmentation_validation_kids.R

echo "======================================================================"
echo "Pipeline finished at $(date)"
echo "Outputs in: ${REPO_ROOT}/data/"