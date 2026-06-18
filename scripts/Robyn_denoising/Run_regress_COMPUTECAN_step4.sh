#!/bin/bash
#SBATCH --job-name=regress_step4
#SBATCH --account=def-amyfinn
#SBATCH --nodes=1
#SBATCH --cpus-per-task=192          # full Trillium node
#SBATCH --time=12:00:00
#SBATCH --output=/scratch/%u/logs/regress_step4_%j.out
#SBATCH --error=/scratch/%u/logs/regress_step4_%j.err

set -e
trap "echo 'Interrupted. Exiting...'; exit 1" INT

########################################
# 1. Environment & AFNI via Apptainer
########################################
source /cvmfs/soft.computecanada.ca/config/profile/bash.sh
module load StdEnv/2023
module load apptainer/1.3.5

CONTAINER=/project/def-amyfinn/leviaa/containers/fmriprep-20.2.8.sif

AFNI_RESAMPLE="apptainer exec ${CONTAINER} 3dresample"
AFNI_TPROJECT="apptainer exec ${CONTAINER} 3dTproject"

echo "[$(date)] Node: $(hostname)"
echo "SLURM job: ${SLURM_JOB_ID}"

########################################
# 2. Paths & subject discovery
########################################
filtered_root="/scratch/leviaa/HBN_full_fmriprep/data_clean/filtered"
regressed_root="/scratch/leviaa/HBN_full_fmriprep/data_clean/regressed"
confounds_root="/scratch/leviaa/HBN_full_fmriprep/regressors/final_confounds"

# Put the mask somewhere the container can see (scratch/project is ideal)
mask_template="/project/def-amyfinn/leviaa/MNI152_T1_2mm_brain_mask.nii.gz"

if [ ! -f "$mask_template" ]; then
  echo "Mask not found at: $mask_template"
  echo ">> Copy your MNI152_T1_2mm_brain_mask.nii.gz there or update mask_template."
  exit 1
fi

mkdir -p "$regressed_root"

# Discover subjects from filtered data (output of bandpass step)
subjects=$(find "${filtered_root}" \
  -maxdepth 1 -type d -name "sub-NDAR*" -exec basename {} \;)

subjects_array=($subjects)
TOTAL_SUBJECTS=${#subjects_array[@]}

echo "Number of subjects detected: ${TOTAL_SUBJECTS}"

if (( TOTAL_SUBJECTS == 0 )); then
  echo "ERROR: no sub-NDAR* directories found under ${filtered_root}"
  exit 1
fi

########################################
# 3. Parallel layout on a 192-core node
########################################
TOTAL_CORES=${SLURM_CPUS_PER_TASK:-192}

# How many cores each AFNI job should use
CORES_PER_SUBJECT=6

JOBS=$(( TOTAL_CORES / CORES_PER_SUBJECT ))
if (( JOBS < 1 )); then
  JOBS=1
fi

export OMP_NUM_THREADS=${CORES_PER_SUBJECT}

echo "TOTAL_CORES       = ${TOTAL_CORES}"
echo "CORES_PER_SUBJECT = ${CORES_PER_SUBJECT}"
echo "Parallel subjects (JOBS) = ${JOBS}"

########################################
# 4. Run regression in parallel over subjects
########################################
cd "${filtered_root}"

parallel --jobs ${JOBS} --linebuffer --joblog "${regressed_root}/regress_parallel.log" '
  sub={};
  echo "[$(date)] Starting subject ${sub}"

  sub_filtered_dir="'"${filtered_root}"'/${sub}"
  if [ ! -d "${sub_filtered_dir}" ]; then
    echo "[${sub}] Missing filtered directory: ${sub_filtered_dir} — skipping." >&2
    exit 0
  fi

  cd "${sub_filtered_dir}" || {
    echo "[${sub}] Cannot cd to ${sub_filtered_dir} — skipping." >&2
    exit 0
  }

  # Find input NIfTI (filtered functional)
  shopt -s nullglob
  files=("${sub}_task"*.nii.gz)
  shopt -u nullglob

  if [ ${#files[@]} -eq 0 ]; then
    echo "[${sub}] No input NIfTI matching ${sub}_task*.nii.gz — skipping." >&2
    exit 0
  fi

  infile="${files[0]}"
  echo "[${sub}] infile: ${infile}"

  # Output path (same naming scheme as your original script)
  outfile="'"${regressed_root}"'/${sub}_task-movieDM_space-MNI152NLin2009cAsym_desc-preproc_cropped_bold.nii.gz"
  echo "[${sub}] outfile: ${outfile}"

  confounds="'"${confounds_root}"'/${sub}_confounds.1D"
  if [ ! -f "${confounds}" ]; then
    echo "[${sub}] Missing confounds: ${confounds} — skipping." >&2
    exit 0
  fi
  echo "[${sub}] confounds: ${confounds}"

  # Resample mask to functional grid
  resampled_mask="/tmp/${sub}_mask_resamp.nii.gz"

  '"$AFNI_RESAMPLE"' \
    -master "${infile}" \
    -inset "'"$mask_template"'" \
    -prefix "${resampled_mask}" \
    -rmode NN

  # Run regression
  '"$AFNI_TPROJECT"' \
    -input "${infile}" \
    -prefix "${outfile}" \
    -ort "${confounds}" \
    -mask "${resampled_mask}" \
    -dt 1.6

  rm -f "${resampled_mask}"

  echo "[$(date)] Finished subject ${sub}"
' ::: "${subjects_array[@]}"

echo "[$(date)] All subjects finished."
