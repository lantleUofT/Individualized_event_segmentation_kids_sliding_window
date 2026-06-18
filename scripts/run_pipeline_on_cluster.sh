#!/usr/bin/env bash
set -euo pipefail
 
# --- Parse args: optional --real flag, optional output dir ---
REAL=0
RUN_GSBS=0
OUTDIR=""
PIPELINE_FLAGS=()   
for arg in "$@"; do
  case "$arg" in
    --real)
      REAL=1
      PIPELINE_FLAGS+=("$arg") ;;
    --run_GSBS)
      RUN_GSBS=1
      PIPELINE_FLAGS+=("$arg") ;;
    --run_validation)
      PIPELINE_FLAGS+=("$arg") ;;
    --*)
      echo "ERROR: unknown flag '$arg'" >&2; exit 1 ;;
    *)
      OUTDIR="$arg" ;;
  esac
done


# --run_GSBS is meaningless without --real (toy mode has no BOLDs to crop).
#Fail loudly
if [ "${RUN_GSBS}" -eq 1 ] && [ "${REAL}" -ne 1 ]; then
  echo "ERROR: --run_GSBS requires --real (the bold crop has nothing to run on in toy mode)." >&2
  exit 1
fi
 
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
    bash /pipeline/scripts/run_pipeline.sh ${PIPELINE_FLAGS[@]+"${PIPELINE_FLAGS[@]}"}
else
  # --- TOY demo mode ---
  mkdir -p "${OUTDIR}/Toy_data_directory"
  apptainer exec \
    --bind "${OUTDIR}/Toy_data_directory:/pipeline/Toy_data_directory" \
    --bind "${OUTDIR}/data:/pipeline/data" \
    "${SIF}" \
    bash /pipeline/scripts/run_pipeline.sh ${PIPELINE_FLAGS[@]+"${PIPELINE_FLAGS[@]}"}
fi
 
echo "Outputs written to: ${OUTDIR}/data"