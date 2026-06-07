#!/usr/bin/env bash
set -euo pipefail
 
# --- Parse args: optional --real flag, optional output dir ---
REAL=0
OUTDIR=""
for arg in "$@"; do
  case "$arg" in
    --real) REAL=1 ;;
    *)      OUTDIR="$arg" ;;
  esac
done
 
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SIF="${HERE}/eventseg.sif"
OUTDIR="${OUTDIR:-${HERE}}"
 
[ -f "${SIF}" ] || { echo "ERROR: eventseg.sif not found beside this script"; exit 1; }
mkdir -p "${OUTDIR}/data"
 
if [ "${REAL}" -eq 1 ]; then
  # --- REAL data mode ---
  CONFIG_LOCAL="${HERE}/config_local.yaml"
  REAL_DATA="${HERE}/real_data"
  [ -f "${CONFIG_LOCAL}" ] || { echo "ERROR: config_local.yaml not found beside this script (required for --real)"; exit 1; }
  [ -d "${REAL_DATA}" ]    || { echo "ERROR: real_data/ directory not found beside this script (required for --real)"; exit 1; }
 
  apptainer exec \
    --bind "${REAL_DATA}:/data" \
    --bind "${CONFIG_LOCAL}:/pipeline/config_local.yaml" \
    --bind "${OUTDIR}/data:/pipeline/data" \
    "${SIF}" \
    bash /pipeline/scripts/run_pipeline.sh --real
else
  # --- TOY demo mode ---
  mkdir -p "${OUTDIR}/Toy_data_directory"
  apptainer exec \
    --bind "${OUTDIR}/Toy_data_directory:/pipeline/Toy_data_directory" \
    --bind "${OUTDIR}/data:/pipeline/data" \
    "${SIF}" \
    bash /pipeline/scripts/run_pipeline.sh
fi
 
echo "Outputs written to: ${OUTDIR}/data"