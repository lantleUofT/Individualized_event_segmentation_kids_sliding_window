#!/bin/bash
#SBATCH --job-name=bandpass_parallel
#SBATCH --account=def-amyfinn
#SBATCH --nodes=1                  # one full Trillium node (192 cores)
#SBATCH --cpus-per-task=192        # make all cores available to this job
#SBATCH --time=12:00:00
#SBATCH --output=/scratch/%u/logs/bandpass_parallel_%A_%a.out
#SBATCH --error=/scratch/%u/logs/bandpass_parallel_%A_%a.err
# NOTE: you control how many nodes via:  sbatch --array=0-5 this_script

set -e
trap "echo 'Interrupted. Exiting...'; exit 1" INT

########################################
# 1. Environment & modules
########################################
source /cvmfs/soft.computecanada.ca/config/profile/bash.sh
module load StdEnv/2023
module load apptainer/1.3.5
# DO NOT: module load parallel   # parallel is already in StdEnv/2023

CONTAINER=/project/def-amyfinn/leviaa/containers/fmriprep-20.2.8.sif

AFNI_1D="apptainer exec ${CONTAINER} 1dBandpass"
AFNI_3D="apptainer exec ${CONTAINER} 3dBandpass"

echo "[$(date)] Node: $(hostname)"
echo "SLURM job: ${SLURM_JOB_ID}, array task: ${SLURM_ARRAY_TASK_ID}"

########################################
# 2. Build subject list
########################################
subjects=($(find /scratch/leviaa/HBN_full_fmriprep \
    -maxdepth 1 -type d -name "sub-NDAR*" -exec basename {} \;))

TOTAL_SUBJECTS=${#subjects[@]}
if (( TOTAL_SUBJECTS == 0 )); then
    echo "ERROR: no sub-NDAR* directories found under /scratch/leviaa/HBN_full_fmriprep"
    exit 1
fi

echo "Total subjects detected: ${TOTAL_SUBJECTS}"

########################################
# 3. Split subjects across array tasks
########################################
# If you submit with: sbatch --array=0-5 this_script
# then NUM_CHUNKS=6 and each task gets ~1/6 of the subjects.
NUM_CHUNKS=${SLURM_ARRAY_TASK_COUNT:-1}
CHUNK_ID=${SLURM_ARRAY_TASK_ID:-0}

CHUNK_SIZE=$(( (TOTAL_SUBJECTS + NUM_CHUNKS - 1) / NUM_CHUNKS ))

START_IDX=$(( CHUNK_ID * CHUNK_SIZE ))
END_IDX=$(( START_IDX + CHUNK_SIZE - 1 ))
if (( END_IDX >= TOTAL_SUBJECTS )); then
    END_IDX=$(( TOTAL_SUBJECTS - 1 ))
fi

if (( START_IDX >= TOTAL_SUBJECTS )); then
    echo "No subjects assigned to this chunk (CHUNK_ID=${CHUNK_ID}), exiting."
    exit 0
fi

echo "NUM_CHUNKS       = ${NUM_CHUNKS}"
echo "CHUNK_ID         = ${CHUNK_ID}"
echo "CHUNK_SIZE       = ${CHUNK_SIZE}"
echo "Processing indices ${START_IDX} to ${END_IDX}"

WORK_ROOT=/scratch/${USER}/bandpass_work
mkdir -p "${WORK_ROOT}"
CHUNK_FILE=${WORK_ROOT}/bandpass_subjects_chunk_${CHUNK_ID}.txt
: > "${CHUNK_FILE}"

for ((i = START_IDX; i <= END_IDX; i++)); do
    echo "${subjects[$i]}" >> "${CHUNK_FILE}"
done

echo "Chunk file: ${CHUNK_FILE}"
echo "Subjects in this chunk:"
cat "${CHUNK_FILE}"

########################################
# 4. Parallel configuration
########################################
TOTAL_CORES=${SLURM_CPUS_PER_TASK:-192}
CORES_PER_SUBJECT=8   # AFNI is mostly single-threaded; this just spreads jobs

JOBS=$(( TOTAL_CORES / CORES_PER_SUBJECT ))
if (( JOBS < 1 )); then
    JOBS=1
fi

export OMP_NUM_THREADS=${CORES_PER_SUBJECT}

echo "TOTAL_CORES       = ${TOTAL_CORES}"
echo "CORES_PER_SUBJECT = ${CORES_PER_SUBJECT}"
echo "Subjects in parallel on this node (JOBS) = ${JOBS}"

########################################
# 5. Run bandpass with GNU Parallel
########################################
cd "${WORK_ROOT}"

parallel --jobs ${JOBS} --linebuffer --joblog bandpass_parallel_node_${CHUNK_ID}.log '
    sub={};
    echo "[$(date)] Node '"$(hostname)"', chunk '"${CHUNK_ID}"': starting subject ${sub}";

    # -------------------
    # Regressors
    # -------------------
    cd /scratch/leviaa/HBN_full_fmriprep/regressors || exit 1
    reg_input="${sub}_confounds.1D"
    reg_output="filtered/${sub}_confounds.1D"

    if [ ! -f "${reg_input}" ]; then
        echo "[${sub}] WARNING: MISSING regressor file: ${reg_input}, skipping." >&2
        exit 0
    fi

    '"$AFNI_1D"' -dt 1.6 0.006 0.22 "${reg_input}" > "${reg_output}"

    # -------------------
    # Functional data
    # -------------------
    cd /scratch/leviaa/HBN_full_fmriprep/data_cropped/${sub} 2>/dev/null || {
        echo "[${sub}] WARNING: missing data_cropped folder, skipping." >&2
        exit 0
    }

    func_input="${sub}_task-movieDM_space-MNI152NLin2009cAsym_desc-preproc_cropped_bold.nii.gz"
    if [ ! -f "${func_input}" ]; then
        echo "[${sub}] WARNING: MISSING functional file: ${func_input}, skipping." >&2
        exit 0
    fi

    out_dir="/scratch/leviaa/HBN_full_fmriprep/data_clean/filtered/${sub}"
    mkdir -p "${out_dir}"

    func_output="${out_dir}/${sub}_task-movieDM_space-MNI152NLin2009cAsym_desc-preproc_cropped_filt_bold.nii.gz"

    '"$AFNI_3D"' -dt 1.6 -band 0.006 0.22 -prefix "${func_output}" "${func_input}"

    echo "[$(date)] Finished subject ${sub}"
' :::: "${CHUNK_FILE}"

echo "[$(date)] All subjects in chunk ${CHUNK_ID} finished."
