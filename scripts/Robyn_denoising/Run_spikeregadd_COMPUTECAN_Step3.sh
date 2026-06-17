#!/bin/bash
#SBATCH --job-name=spike_step3
#SBATCH --account=def-amyfinn
#SBATCH --time=12:00:00
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=64
#SBATCH --output=/scratch/leviaa/logs/spike_step3_%j.out
#SBATCH --error=/scratch/leviaa/logs/spike_step3_%j.err

module load StdEnv/2023
module load python/3.11.5
module load scipy-stack/2025a
module load nibabel/5.2.0

# Keep threaded libraries from oversubscribing per process
export OMP_NUM_THREADS=1
export MKL_NUM_THREADS=1
export OPENBLAS_NUM_THREADS=1

cd /scratch/leviaa

# 1) Build a master subject list from final_bids_safe
find HBN_full_fmriprep -maxdepth 1 -type d -name "sub-NDAR*" -printf "%f\n" | sort > subject_list_all.txt

# 2) Split into 4 roughly equal chunks (subject_chunk_aa, subject_chunk_ab, ...)
split -n l/4 subject_list_all.txt subject_chunk_

echo "Subject chunks:"
ls subject_chunk_*

# 3) Run the Python script once per chunk, in parallel (4 parallel jobs)
# Each job gets a different SUBJECT_LIST_FILE and processes only those subjects
parallel -j 4 'CHUNK_TAG={#} SUBJECT_LIST_FILE={} python Spikeregressor_addscript_COMPUTECAN_step3.py' ::: subject_chunk_*

