#!/bin/bash
#SBATCH --job-name=gsbs_sch100_4nodes
#SBATCH --account=def-amyfinn
#SBATCH --nodes=1
#SBATCH --cpus-per-task=192
#SBATCH --time=12:00:00
#SBATCH --output=/scratch/%u/logs/gsbs_sch100_9nodes_%A_%a.out
#SBATCH --error=/scratch/%u/logs/gsbs_sch100_9nodes_%A_%a.err
#SBATCH --array=0-3

set -e
trap "echo 'Interrupted. Exiting...'; exit 1" INT

############################
# 1. Environment
############################
source /cvmfs/soft.computecanada.ca/config/profile/bash.sh
module load StdEnv/2023
module load apptainer/1.3.5
# module load parallel   # uncomment if you need to load GNU parallel as a module

CONTAINER=/project/def-amyfinn/leviaa/containers/gsbs_py_amd64.sif
SCRIPT=/project/def-amyfinn/leviaa/gsbs/GSBS_support_COMPUTECAN.py
SUBJECTS_FILE=/scratch/leviaa/subjects_partial_window.txt

# 🔴 NEW: resampled Schaefer atlas on SCRATCH
ATLAS_FILE=/scratch/${USER}/atlases/Schaefer2018_100Parcels_7Networks_movieDM_resamp_2p4mm_cropped.nii.gz

if [ ! -f "${ATLAS_FILE}" ]; then
  echo "ERROR: Resampled atlas not found at:"
  echo "  ${ATLAS_FILE}"
  exit 1
fi
echo "Using atlas file:"
echo "  ${ATLAS_FILE}"

# Per-subject threading (inside container)
CORES_PER_SUBJECT=4
export OMP_NUM_THREADS=${CORES_PER_SUBJECT}
export OPENBLAS_NUM_THREADS=${CORES_PER_SUBJECT}
export MKL_NUM_THREADS=${CORES_PER_SUBJECT}
export NUMEXPR_NUM_THREADS=${CORES_PER_SUBJECT}

############################
# 2. Load full subject list
############################
if [ ! -f "${SUBJECTS_FILE}" ]; then
  echo "ERROR: subjects file not found: ${SUBJECTS_FILE}"
  exit 1
fi

mapfile -t SUBJECTS < "${SUBJECTS_FILE}"
NSUBJECTS=${#SUBJECTS[@]}

if (( NSUBJECTS == 0 )); then
  echo "ERROR: subjects file is empty: ${SUBJECTS_FILE}"
  exit 1
fi

echo "[$(date)] Node: $(hostname)"
echo "SLURM job: ${SLURM_JOB_ID}, array task: ${SLURM_ARRAY_TASK_ID}"
echo "Total subjects in list: ${NSUBJECTS}"

############################
# 3. Divide subjects across 4 nodes
############################
NODES=4
TASK_ID=${SLURM_ARRAY_TASK_ID}

CHUNK_SIZE=$(( (NSUBJECTS + NODES - 1) / NODES ))
START_INDEX=$(( TASK_ID * CHUNK_SIZE ))
if (( START_INDEX >= NSUBJECTS )); then
  echo "No subjects assigned to this array task (START_INDEX=${START_INDEX} >= NSUBJECTS=${NSUBJECTS})."
  exit 0
fi

END_INDEX=$(( START_INDEX + CHUNK_SIZE ))
if (( END_INDEX > NSUBJECTS )); then
  END_INDEX=${NSUBJECTS}
fi

NUM_THIS_NODE=$(( END_INDEX - START_INDEX ))
echo "Subjects assigned to this node: indices ${START_INDEX}..$((END_INDEX-1)) (count=${NUM_THIS_NODE})"

SUBSET=("${SUBJECTS[@]:${START_INDEX}:${NUM_THIS_NODE}}")

echo "First subject on this node: ${SUBSET[0]}"
echo "Last subject on this node : ${SUBSET[$((NUM_THIS_NODE-1))]}"

############################
# 4. Parallel layout on this node
############################
TOTAL_CORES=${SLURM_CPUS_PER_TASK:-192}
JOBS=$(( TOTAL_CORES / CORES_PER_SUBJECT ))   # 192 / 4 = 48

if (( JOBS < 1 )); then
  JOBS=1
fi

echo "TOTAL_CORES        = ${TOTAL_CORES}"
echo "CORES_PER_SUBJECT  = ${CORES_PER_SUBJECT}"
echo "Max parallel subjects on this node = ${JOBS}"

############################
# 5. Run GSBS in parallel for this node's subjects
############################
cd /project/def-amyfinn/leviaa/gsbs

parallel --jobs ${JOBS} --linebuffer \
  --joblog /scratch/${USER}/logs/gsbs_parallel_${SLURM_JOB_ID}_${TASK_ID}.log '
    sub={};
    echo "[$(date)] [${SLURM_JOB_ID}/${SLURM_ARRAY_TASK_ID}] Starting subject ${sub}"

    apptainer exec \
      --bind /project:/project \
      --bind /scratch:/scratch \
      "'"${CONTAINER}"'" \
      python "'"${SCRIPT}"'" \
        --subject "${sub}" \
        --kmax 89 \
        --atlas-nifti "'"${ATLAS_FILE}"'"

    echo "[$(date)] [${SLURM_JOB_ID}/${SLURM_ARRAY_TASK_ID}] Finished subject ${sub}"
  ' ::: "${SUBSET[@]}"

echo "[$(date)] All subjects for this node finished."
