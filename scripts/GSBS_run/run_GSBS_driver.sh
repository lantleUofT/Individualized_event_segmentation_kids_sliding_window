#!/bin/bash
# =====================================================================
# run_GSBS_driver.sh — GSBS event segmentation driver (local / in-container)
# Runs GSBS_worker.py twice: step 2.40 (full) and step 2.60 (partial).
# Gated: requires --real AND --run_GSBS (mirrors the bold-crop gate).
# Assumes the pipeline already runs inside the container, so it calls
# python directly rather than self-invoking apptainer.
# =====================================================================

set -euo pipefail
trap "echo 'Interrupted. Exiting...'; exit 1" INT

# --- Config + flag gate: --run_GSBS requires --real ---
CONFIG_FILE="config.yaml"
REAL=0
RUN_GSBS=0
for arg in "$@"; do
  case "$arg" in
    --real)     REAL=1; CONFIG_FILE="config_local.yaml" ;;
    --run_GSBS) RUN_GSBS=1 ;;
  esac
done

if [ "${REAL}" -ne 1 ] || [ "${RUN_GSBS}" -ne 1 ]; then
  echo ">>> [GSBS] skipped (needs --real AND --run_GSBS; got real=${REAL} gsbs=${RUN_GSBS})."
  exit 0
fi

# --- Anchor to repo root (provided by run_pipeline.sh, else derive) ---
if [ -n "${REPO_ROOT:-}" ]; then
  :  # provided by run_pipeline.sh
elif [ -n "${SLURM_SUBMIT_DIR:-}" ]; then
  REPO_ROOT="${SLURM_SUBMIT_DIR}"
else
  SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
  REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
fi

# --- Fail loudly if the resolved root isn't actually the repo ---
if [ ! -f "${REPO_ROOT}/${CONFIG_FILE}" ]; then
  echo "ERROR: REPO_ROOT='${REPO_ROOT}' does not contain ${CONFIG_FILE}."
  echo ">> Run through scripts/run_pipeline.sh, or cd into repo root first."
  exit 1
fi
cd "${REPO_ROOT}"

# --- Read the gsbs block + s2 output dir + python_exec from config ---
# Tab-separated so values survive intact; field order matches the read below.
IFS=$'\t' read -r \
  in_dir_full in_suffix_full out_dir_full kmax_full \
  in_dir_partial in_suffix_partial out_dir_partial kmax_partial \
  atlas_nifti dmin blocksize finetune cores_per_subject \
  statewise finetune_weakest s2_rel python_exec < <(
  python3 -c "
import yaml
c = yaml.safe_load(open('${CONFIG_FILE}'))
g = c['gsbs']
cont = c.get('container', {})
print('\t'.join(str(x) for x in [
    g['input_dir_full'],    g['input_suffix_full'],    g['output_dir_full'],    g['kmax_full'],
    g['input_dir_partial'], g['input_suffix_partial'], g['output_dir_partial'], g['kmax_partial'],
    g['atlas_nifti'], g['dmin'], g['blocksize'], g['finetune'], g['cores_per_subject'],
    g['statewise_detection'], g['finetune_order_weakest_first'],
    c['paths']['output_dir_s2'], cont.get('python_exec', 'python3'),
]))
"
)

if [ -z "${in_dir_full}" ] || [ -z "${s2_rel}" ]; then
  echo "ERROR: failed to read gsbs paths from ${CONFIG_FILE}"; exit 1
fi

# --- Resolve absolute paths and tooling ---
PY="${python_exec:-python3}"
GSBS_DIR="${REPO_ROOT}/scripts/GSBS_run"
WORKER="${GSBS_DIR}/GSBS_worker.py"
ATLAS="${REPO_ROOT}/${atlas_nifti}"
S2_DIR="${REPO_ROOT}/${s2_rel}"

# gsbs.py lives alongside the worker; make `from gsbs import GSBS` resolve.
export PYTHONPATH="${GSBS_DIR}:${PYTHONPATH:-}"

# Thread caps inside the container (per subject).
export OMP_NUM_THREADS="${cores_per_subject}"
export OPENBLAS_NUM_THREADS="${cores_per_subject}"
export MKL_NUM_THREADS="${cores_per_subject}"
export NUMEXPR_NUM_THREADS="${cores_per_subject}"

# --- Existence checks for things that must always be present ---
if [ ! -f "${WORKER}" ]; then
  echo "ERROR: GSBS worker not found at: ${WORKER}"; exit 1
fi
if [ ! -f "${ATLAS}" ]; then
  echo "ERROR: atlas NIfTI not found at: ${ATLAS}"; exit 1
fi

# --- Parallel layout (no SLURM array; one machine, many subjects) ---
TOTAL_CORES=${SLURM_CPUS_PER_TASK:-$(nproc 2>/dev/null || echo 4)}
JOBS=$(( TOTAL_CORES / cores_per_subject ))
if (( JOBS < 1 )); then JOBS=1; fi
echo "TOTAL_CORES=${TOTAL_CORES}  CORES_PER_SUBJECT=${cores_per_subject}  JOBS=${JOBS}"

# ---------------------------------------------------------------------
# Subject discovery: extract the 'subject' column from a CSV, header-aware.
# (Same awk logic as the bold-crop step, so both stages agree on parsing.)
# ---------------------------------------------------------------------
extract_subjects() {
  awk -F',' '
    NR==1 {
      for (i=1; i<=NF; i++) { gsub(/^[ \t"]+|[ \t"]+$/, "", $i); if ($i=="subject") col=i }
      if (!col) { print "NO_SUBJECT_COL" > "/dev/stderr"; exit 2 }
      next
    }
    { val=$col; gsub(/^[ \t"]+|[ \t"]+$/, "", val); if (val!="") print val }
  ' "$1"
}

# Union subjects across two manifests; skip-with-warning if either is absent.
discover_subjects() {
  local mk="$1" ma="$2"
  local found=""
  if [ ! -f "${mk}" ]; then
    echo "WARNING: kids manifest not found, skipping it: ${mk}" >&2
  else
    found="${found}$(extract_subjects "${mk}")"$'\n'
  fi
  if [ ! -f "${ma}" ]; then
    echo "WARNING: adults manifest not found, skipping it: ${ma}" >&2
  else
    found="${found}$(extract_subjects "${ma}")"$'\n'
  fi
  printf '%s' "${found}" | sed '/^$/d' | sort -u
}


# ---------------------------------------------------------------------
# Run one GSBS pass over a subject list.
#   $1 label  $2 input_root(rel)  $3 input_suffix  $4 output_root(rel)  $5 kmax
#   $6.. subject IDs
# ---------------------------------------------------------------------
run_gsbs_pass() {
  local label="$1" in_root="$2" in_suffix="$3" out_root="$4" kmax="$5"; shift 5
  local subjects=("$@")
  local n=${#subjects[@]}

  local in_abs="${REPO_ROOT}/${in_root}"
  local out_abs="${REPO_ROOT}/${out_root}"

  echo ">>> GSBS pass [${label}]: ${n} subjects"
  echo "      input  : ${in_abs}"
  echo "      suffix : ${in_suffix}"
  echo "      output : ${out_abs}"
  echo "      kmax   : ${kmax}"

  if (( n == 0 )); then
    echo "WARNING: no subjects for pass [${label}]; nothing to do." >&2
    return 0
  fi

  mkdir -p "${out_abs}"

  parallel --jobs "${JOBS}" --linebuffer \
    --joblog "${out_abs}/gsbs_${label}_parallel.log" '
    sub={};
    infile="'"${in_abs}"'/${sub}'"${in_suffix}"'"
    if [ ! -f "${infile}" ]; then
      echo "[['"${label}"']] [${sub}] missing input NIfTI: ${infile} — skipping." >&2
      exit 0
    fi
    echo "[$(date)] [['"${label}"']] starting ${sub}"
    '"$PY"' "'"$WORKER"'" \
      --subject                      "${sub}" \
      --regressed-root               "'"${in_abs}"'" \
      --input-suffix                 "'"${in_suffix}"'" \
      --output-root                  "'"${out_abs}"'" \
      --atlas-nifti                  "'"${ATLAS}"'" \
      --kmax                         "'"${kmax}"'" \
      --dmin                         "'"${dmin}"'" \
      --blocksize                    "'"${blocksize}"'" \
      --finetune                     "'"${finetune}"'" \
      --statewise-detection          "'"${statewise}"'" \
      --finetune-order-weakest-first "'"${finetune_weakest}"'"
    echo "[$(date)] [['"${label}"']] finished ${sub}"
  ' ::: "${subjects[@]}"
}

# --- Step 2.40 — full window ---
mapfile -t SUBJECTS_FULL < <(discover_subjects \
  "${S2_DIR}/best_windows_kids_full.csv" \
  "${S2_DIR}/best_windows_adults_full.csv")
run_gsbs_pass "full" "${in_dir_full}" "${in_suffix_full}" "${out_dir_full}" "${kmax_full}" \
  "${SUBJECTS_FULL[@]}"

# --- Step 2.60 — partial window ---
mapfile -t SUBJECTS_PARTIAL < <(discover_subjects \
  "${S2_DIR}/best_windows_kids.csv" \
  "${S2_DIR}/best_windows_adults.csv")
run_gsbs_pass "partial" "${in_dir_partial}" "${in_suffix_partial}" "${out_dir_partial}" "${kmax_partial}" \
  "${SUBJECTS_PARTIAL[@]}"

echo "[$(date)] GSBS driver finished (full + partial)."