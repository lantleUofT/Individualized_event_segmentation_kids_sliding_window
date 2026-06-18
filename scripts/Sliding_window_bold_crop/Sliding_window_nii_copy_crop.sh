#!/bin/bash
#SBATCH --job-name=copy_crop_step5
#SBATCH --account=def-amyfinn
#SBATCH --nodes=1
#SBATCH --cpus-per-task=192          # this is a full trillium node, adjust as appropriate.
#SBATCH --time=04:00:00
#SBATCH --output=/scratch/%u/logs/copy_crop_step5_%j.out
#SBATCH --error=/scratch/%u/logs/copy_crop_step5_%j.err

set -e
trap "echo 'Interrupted. Exiting...'; exit 1" INT

########################################
# 0. Flag gate — only run when BOTH --real and --run_GSBS are passed
########################################
REAL=0
RUN_GSBS=0
for arg in "$@"; do
  case "$arg" in
    --real)     REAL=1 ;;
    --run_GSBS) RUN_GSBS=1 ;;
  esac
done

if [ "$REAL" -ne 1 ] || [ "$RUN_GSBS" -ne 1 ]; then
  echo ">>> [crop] skipped (needs --real AND --run_GSBS; got real=$REAL gsbs=$RUN_GSBS)"
  exit 0
fi

########################################
# 1. Environment & python via Apptainer
########################################
# source /cvmfs/soft.computecanada.ca/config/profile/bash.sh
# module load StdEnv/2023
# module load apptainer/1.3.5

# CONTAINER=/project/def-amyfinn/leviaa/containers/fmriprep-20.2.8.sif

# # container python (fmriprep image already ships numpy + nibabel)
# APPTAINER_PY="apptainer exec -B /scratch -B /project ${CONTAINER} python3"

# echo "[$(date)] Node: $(hostname)"
# echo "SLURM job: ${SLURM_JOB_ID}"

########################################
# 2. Paths
########################################
CONFIG_FILE="config_local.yaml"
 
if [ -n "${REPO_ROOT:-}" ]; then
  :  # provided by run_pipeline.sh
elif [ -n "${SLURM_SUBMIT_DIR:-}" ]; then
  REPO_ROOT="${SLURM_SUBMIT_DIR}"
else
  SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
  REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
fi
 
# Fail loudly if the resolved root isn't actually the repo.
if [ ! -f "${REPO_ROOT}/${CONFIG_FILE}" ]; then
  echo "ERROR: REPO_ROOT='${REPO_ROOT}' does not contain ${CONFIG_FILE}."
  echo ">> Standalone sbatch: cd into the repo root first, then submit:"
  echo "     cd /path/to/repo && sbatch scripts/Sliding_window_bold_crop/Sliding_window_nii_copy_crop.sh --real --run_GSBS"
  echo ">> Or run it through scripts/run_pipeline.sh, which sets REPO_ROOT for you."
  exit 1
fi
cd "${REPO_ROOT}"

IFS=$'\t' read -r regressed_rel cropped_rel bold_suffix output_suffix s2_rel \
                  manifest_kids_name manifest_adults_name python_exec < <(
  python3 -c "
import yaml
c = yaml.safe_load(open('${CONFIG_FILE}'))
b = c['bold_crop']
cont = c.get('container', {})
print('\t'.join(str(x) for x in [
    b['regressed_dir'], b['cropped_dir'], b['bold_suffix'], b['output_suffix'],
    c['paths']['output_dir_s2'], b['manifest_kids'], b['manifest_adults'],
    cont.get('python_exec', 'python3'),
]))
"
)

if [ -z "$regressed_rel" ] || [ -z "$s2_rel" ]; then
  echo "ERROR: failed to read paths from ${CONFIG_FILE}"; exit 1
fi




# --- Filepaths --- #
regressed_root="${REPO_ROOT}/${regressed_rel}"
cropped_root="${REPO_ROOT}/${cropped_rel}"
manifest_kids="${REPO_ROOT}/${s2_rel}/${manifest_kids_name}"
manifest_adults="${REPO_ROOT}/${s2_rel}/${manifest_adults_name}"
config_file="${REPO_ROOT}/${CONFIG_FILE}"

# --- The python worker ---#
PY="${python_exec:-python3}"
WORKER=${REPO_ROOT}/scripts/Sliding_window_bold_crop/crop_bold.py

# --- existence checks (fail loud, fail early) --- #
if [ ! -f "$manifest_kids" ]; then
  echo "ERROR: kids manifest not found at: $manifest_kids"
  echo ">> Point 'manifest_kids' at the best_windows_kids.csv produced by Stage 2."
  exit 1
fi

if [ ! -f "$manifest_adults" ]; then
  echo "ERROR: adults manifest not found at: $manifest_adults"
  echo ">> Point 'manifest_adults' at the best_windows_adults.csv produced by Stage 2."
  exit 1
fi

if [ ! -f "$config_file" ]; then
  echo "ERROR: config not found at: $config_file"
  echo ">> Point 'config_file' at the config (config_local.yaml) the pipeline ran with."
  exit 1
fi

if [ ! -f "$WORKER" ]; then
  echo "ERROR: python worker not found at: $WORKER"
  exit 1
fi

if [ ! -d "$regressed_root" ]; then
  echo "ERROR: regressed input dir not found: $regressed_root"
  exit 1
fi

mkdir -p "$cropped_root"

########################################
# 3. Subject discovery (union of both manifests, not the NIfTI dir)
########################################
# Extract the 'subject' column from a CSV header-aware: find its index by name,
# print it, skip the header, strip quotes/whitespace, keep non-empty entries.
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

subjects=$( { extract_subjects "$manifest_kids"; extract_subjects "$manifest_adults"; } | sort -u )

if [ -z "$subjects" ]; then
  echo "ERROR: no subjects found. Check that both manifests have a non-empty 'subject' column."
  exit 1
fi

subjects_array=($subjects)
TOTAL_SUBJECTS=${#subjects_array[@]}
echo "Subjects (kids + adults, unioned): ${TOTAL_SUBJECTS}"

########################################
# 4. Parallel layout on a 192-core node
########################################
TOTAL_CORES=${SLURM_CPUS_PER_TASK:-$(nproc 2>/dev/null || echo 4)}

# Cropping is I/O-bound, not compute-bound: a few cores each, many subjects at once.
CORES_PER_SUBJECT=2
JOBS=$(( TOTAL_CORES / CORES_PER_SUBJECT ))
if (( JOBS < 1 )); then JOBS=1; fi

echo "TOTAL_CORES       = ${TOTAL_CORES}"
echo "CORES_PER_SUBJECT = ${CORES_PER_SUBJECT}"
echo "Parallel subjects (JOBS) = ${JOBS}"

########################################
# 5. Run copy+crop in parallel over subjects
########################################
parallel --jobs ${JOBS} --linebuffer --joblog "${cropped_root}/copy_crop_parallel.log" '
  sub={};
  echo "[$(date)] Starting subject ${sub}"

  infile="'"${regressed_root}"'/${sub}'"${bold_suffix}"'"
  if [ ! -f "${infile}" ]; then
    echo "[${sub}] Missing input NIfTI: ${infile} — skipping." >&2
    exit 0
  fi

  outfile="'"${cropped_root}"'/${sub}'"${output_suffix}"'"

  '"$PY"' "'"$WORKER"'" \
    --subject         "${sub}" \
    --infile          "${infile}" \
    --outfile         "${outfile}" \
    --manifest-kids   "'"$manifest_kids"'" \
    --manifest-adults "'"$manifest_adults"'" \
    --config          "'"$config_file"'"

  echo "[$(date)] Finished subject ${sub}"
' ::: "${subjects_array[@]}"

echo "[$(date)] All subjects finished."
