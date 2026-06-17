#!/bin/bash
#SBATCH --job-name=copy_crop_step5
#SBATCH --account=def-amyfinn
#SBATCH --nodes=1
#SBATCH --cpus-per-task=192          # full Trillium node
#SBATCH --time=04:00:00
#SBATCH --output=/scratch/%u/logs/copy_crop_step5_%j.out
#SBATCH --error=/scratch/%u/logs/copy_crop_step5_%j.err

set -e
trap "echo 'Interrupted. Exiting...'; exit 1" INT

########################################
# 1. Environment & python via Apptainer
########################################
source /cvmfs/soft.computecanada.ca/config/profile/bash.sh
module load StdEnv/2023
module load apptainer/1.3.5

CONTAINER=/project/def-amyfinn/leviaa/containers/fmriprep-20.2.8.sif

# container python (fmriprep image already ships numpy + nibabel)
APPTAINER_PY="apptainer exec ${CONTAINER} python3"

echo "[$(date)] Node: $(hostname)"
echo "SLURM job: ${SLURM_JOB_ID}"

########################################
# 2. Paths
########################################
regressed_root="/scratch/leviaa/HBN_full_fmriprep/data_clean/regressed"
cropped_root="/scratch/leviaa/HBN_full_fmriprep/data_clean/partial_window"

# Authoritative pass lists: the one-window-per-subject sliding-window tables.
# This step slots BETWEEN Stage 2 (sliding window) and Stage 3 (preprocessing).
# It reads Stage 2's post-selection output; it does NOT feed Stage 3 (side output).
# Input = ALL children + adults who passed the 225TR window selection, so we read
# both manifests and union their subjects.
# TODO: wire these to config.yaml output_dir_s2 later. Hardcoded placeholders for now:
manifest_kids="/scratch/leviaa/HBN_full_fmriprep/windows/best_windows_kids.csv"
manifest_adults="/scratch/leviaa/HBN_full_fmriprep/windows/best_windows_adults.csv"

# Config the worker reads win_length (225) from. Point at the SAME config the
# pipeline ran with (config_local.yaml on the cluster), not the toy config.
config_file="/scratch/leviaa/Sliding_window_analysis_git/config_local.yaml"

# The python worker (lives beside this script)
WORKER="$(dirname "$(readlink -f "$0")")/crop_bold.py"

# --- existence checks (fail loud, fail early) ---
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
TOTAL_CORES=${SLURM_CPUS_PER_TASK:-192}

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

  infile="'"${regressed_root}"'/${sub}_task-movieDM_space-MNI152NLin2009cAsym_desc-preproc_cropped_bold.nii.gz"
  if [ ! -f "${infile}" ]; then
    echo "[${sub}] Missing input NIfTI: ${infile} — skipping." >&2
    exit 0
  fi

  outfile="'"${cropped_root}"'/${sub}_task-movieDM_space-MNI152NLin2009cAsym_desc-preproc_partial_window_bold.nii.gz"

  '"$APPTAINER_PY"' "'"$WORKER"'" \
    --subject         "${sub}" \
    --infile          "${infile}" \
    --outfile         "${outfile}" \
    --manifest-kids   "'"$manifest_kids"'" \
    --manifest-adults "'"$manifest_adults"'" \
    --config          "'"$config_file"'"

  echo "[$(date)] Finished subject ${sub}"
' ::: "${subjects_array[@]}"

echo "[$(date)] All subjects finished."
