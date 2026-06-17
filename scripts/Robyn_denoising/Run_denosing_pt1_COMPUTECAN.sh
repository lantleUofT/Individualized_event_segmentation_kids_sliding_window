#!/bin/bash
#SBATCH --job-name=crop_bold_gnu
#SBATCH --account=def-amyfinn
#SBATCH --nodes=1               # one full Trillium node (192 cores, 745 GiB)
#SBATCH --cpus-per-task=192     # make all cores available to this job
#SBATCH --time=12:00:00
# no --mem on Trillium
#SBATCH --output=/scratch/leviaa/logs_crop/crop_bold_gnu_%j.out
#SBATCH --error=/scratch/leviaa/logs_crop/crop_bold_gnu_%j.err

echo "Job started on $(date)"
echo "Running on host: $(hostname)"
echo "PWD: $(pwd)"

module load StdEnv/2023
module load python/3.11.5
module load scipy-stack/2023b
module load nibabel/5.2.0

# Load GNU Parallel (module name may vary; if this fails, run `module spider parallel`)
module load parallel

# Work from scratch
cd /scratch/leviaa

echo "Building subject list from HBN_full_fmriprep..."

python - << 'EOF'
import os
import numpy as np

main_dir = "/scratch/leviaa"
data_dir_raw = os.path.join(main_dir, "HBN_full_fmriprep")

all_subjects = np.unique([
    f for f in os.listdir(data_dir_raw)
    if f.startswith('sub') and os.path.isdir(os.path.join(data_dir_raw, f))
])
all_subjects = np.sort(all_subjects)

print("Found", len(all_subjects), "subjects")
with open("subjects_for_gnu.txt", "w") as f:
    for s in all_subjects:
        f.write(s + "\n")
EOF

echo "Subject list written to subjects_for_gnu.txt"
echo "Starting GNU Parallel..."

# Use up to 180 cores in parallel (leave a little headroom)
parallel -j 90 --joblog gnu_parallel_crop.log --eta \
  python /project/def-amyfinn/leviaa/Denoising_cropping_COMPUTECAN_Step1.py {} \
  :::: subjects_for_gnu.txt

echo "All GNU Parallel jobs finished."
echo "Job finished on $(date)"
