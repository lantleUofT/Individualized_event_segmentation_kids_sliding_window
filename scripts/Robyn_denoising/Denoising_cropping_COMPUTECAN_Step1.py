# import all packages needed
import sys
import numpy as np
import matplotlib.pyplot as plt
import pandas as pd
import shutil
import os
import nibabel as nib
import glob

# set working directory 
os.chdir('/scratch/leviaa/')  # set working directory
print(os.getcwd())            # prints working directory
main_dir = os.getcwd()        # sets working directory as a reuseable variable

# paths to preprocessed and raw data
data_dir = os.path.join(main_dir, 'HBN_full_fmriprep')   # final preprocessed data
data_dir_raw = os.path.join(main_dir, 'HBN_full_fmriprep')           # raw BIDS data

# subjects list
all_subjects = np.unique([
    f for f in os.listdir(data_dir_raw)
    if f.startswith('sub') and os.path.isdir(os.path.join(data_dir_raw, f))
])
all_subjects = np.sort(all_subjects)
print("All subjects:", all_subjects)

subjects = None

# 1) Slurm array mode: use SLURM_ARRAY_TASK_ID if present
if "SLURM_ARRAY_TASK_ID" in os.environ:
    idx = int(os.environ["SLURM_ARRAY_TASK_ID"])
    if idx < 0 or idx >= len(all_subjects):
        raise IndexError(
            f"SLURM_ARRAY_TASK_ID {idx} out of range for {len(all_subjects)} subjects"
        )
    sub = all_subjects[idx]
    subjects = [sub]
    print(f"Slurm array mode: index {idx}, subject {sub}")

# 2) Command-line single-subject mode
elif len(sys.argv) > 1:
    sub = sys.argv[1]
    if sub not in all_subjects:
        raise ValueError(f"Requested subject {sub} not found in final_bids_safe")
    subjects = [sub]
    print("Command-line mode: restricting to single subject:", sub)

# 3) Default: process all subjects
else:
    subjects = all_subjects
    print("No array index or subject arg: processing ALL subjects")

print("Subjects to process in this run:", subjects)

# global variable for final number of TRs (change this)
final_num_TRs = 355 

# Variables

# regressors to keep: GS, first 10 aCompCor, CSF, WM, 18-expansion of 6 motion estimates (x, y, z, pitch, yaw, roll)
regs = [
    "csf", "white_matter", "global_signal", "std_dvars", "framewise_displacement",
    "a_comp_cor_00", "a_comp_cor_01", "a_comp_cor_02", "a_comp_cor_03", "a_comp_cor_04",
    "a_comp_cor_05", "a_comp_cor_06", "a_comp_cor_07", "a_comp_cor_08", "a_comp_cor_09",
    "trans_x", "trans_x_derivative1", "trans_x_power2", "trans_x_derivative1_power2",
    "trans_y", "trans_y_derivative1", "trans_y_power2", "trans_y_derivative1_power2",
    "trans_z", "trans_z_derivative1", "trans_z_power2", "trans_z_derivative1_power2",
    "rot_x", "rot_x_derivative1", "rot_x_power2", "rot_x_derivative1_power2",
    "rot_y", "rot_y_derivative1", "rot_y_power2", "rot_y_derivative1_power2",
    "rot_z", "rot_z_derivative1", "rot_z_power2", "rot_z_derivative1_power2"
]

# global variable for extra cropping of 20TRs for initial burst in signal
extra_crop = 20

# suffixes for functional data and regressors
func_suffix = "_task-movieDM_space-MNI152NLin2009cAsym_desc-preproc_bold.nii.gz"
reg_suffix = "_task-movieDM_desc-confounds_timeseries.tsv"

# suffix for cropped functional data and regressors
func_crop_suffix = "_task-movieDM_space-MNI152NLin2009cAsym_desc-preproc_cropped_bold.nii.gz"
reg_crop_suffix = "_confounds.1D"

# suffix for filtered functional data
func_filt_suffix = "_task-movieDM_space-MNI152NLin2009cAsym_desc-preproc_cropped_filt_bold.nii"

# directories to where to save edited regressors and final confounds
regressor_dir       = os.path.join(data_dir, "regressors")
filtered_dir        = os.path.join(regressor_dir, "filtered")
final_confounds_dir = os.path.join(regressor_dir, "final_confounds")
func_dir            = os.path.join(data_dir, "data_raw")
func_crop_dir       = os.path.join(data_dir, "data_cropped")
func_filt_dir       = os.path.join(data_dir, "data_clean", "filtered")
func_final_dir      = os.path.join(data_dir, "data_clean", "regressed")

# print the directories to check if they are correct
print("Regressor directory:", regressor_dir)
print("Filtered directory:", filtered_dir)
print("Final confounds directory:", final_confounds_dir)
print("Functional data directory:", func_dir)
print("Functional data cropped directory:", func_crop_dir)
print("Functional data filtered directory:", func_filt_dir)
print("Functional data final directory:", func_final_dir)

# create directories if they do not exist (thread-safe with exist_ok=True)
os.makedirs(regressor_dir,       exist_ok=True)
os.makedirs(filtered_dir,        exist_ok=True)
os.makedirs(final_confounds_dir, exist_ok=True)
os.makedirs(func_dir,            exist_ok=True)
os.makedirs(func_crop_dir,       exist_ok=True)
os.makedirs(func_filt_dir,       exist_ok=True)
os.makedirs(func_final_dir,      exist_ok=True)

for sub in subjects:

    print("Processing subject: " + sub)

    # --------------------------
    # Confounds / regressors
    # --------------------------
    sub_filename  = sub + reg_suffix  # e.g., sub-XXX_task-movieDM_desc-confounds_timeseries.tsv
    confound_glob = os.path.join(
       data_dir, sub, "**", f"{sub}*task-movieDM*desc-confounds_timeseries.tsv"
    )
    confound_matches = sorted(glob.glob(confound_glob, recursive=True))

    if not confound_matches:
        print(f"Confound file for subject {sub} not found. Skipping.")
        continue
    if len(confound_matches) > 1:
        print(f"Warning: multiple confound files for {sub}: {confound_matches}. Using first.")
    confound_path = confound_matches[0]

    con_tot = pd.read_csv(confound_path, sep='\t')

    # subset regressors
    available_regs = [reg for reg in regs if reg in con_tot.columns]
    missing_regs   = [reg for reg in regs if reg not in con_tot.columns]

    if missing_regs:
        print(f"Warning: Missing regressors for {sub}: {missing_regs}")

    regs_subset = con_tot[available_regs]

    # Delete every other row, then crop
    regs_subset_crop = regs_subset.iloc[::2, :]
    regs_subset_crop = regs_subset_crop.iloc[extra_crop:, :]
    regs_subset_crop = regs_subset_crop.iloc[0:final_num_TRs]  # cropping final third of timecourse
    regs_subset_crop['TR'] = np.arange(len(regs_subset_crop)) + 1

    # Assert with a warning if the cropped length does not match the expected ground truth length
    assert regs_subset_crop.shape[0] == final_num_TRs, (
        f"Warning: Cropped length for subject {sub} is {regs_subset_crop.shape[0]}, "
        f"expected {final_num_TRs}."
    )

    # save confounds file
    reg_filename = sub + reg_crop_suffix
    regs_subset_crop.to_csv(
        os.path.join(regressor_dir, reg_filename),
        sep=" ",
        header=False,
        index=False
    )

    print("Saved cropped regressors for subject: " + sub)

    # --------------------------
    # Functional data
    # --------------------------
    func_glob = os.path.join(
    data_dir, sub, "**",
    f"{sub}*task-movieDM*space-MNI152NLin2009cAsym_desc-preproc_bold.nii.gz"
    )
    func_matches = sorted(glob.glob(func_glob, recursive=True))

    if not func_matches:
       print(f"Functional data file for subject {sub} not found. Skipping.")
       continue
    if len(func_matches) > 1:
       print(f"Warning: multiple functional files for {sub}: {func_matches}. Using first.")
    func_path = func_matches[0]
    func_data_total = nib.load(func_path)
    func_data       = func_data_total.get_fdata()

    # Downsample: keep every 2nd TR
    func_data_crop = func_data[..., ::2]

    # Remove first 20 TRs
    func_data_crop = func_data_crop[..., extra_crop:]

    # Crop to final number of TRs (355)
    func_data_crop = func_data_crop[..., :final_num_TRs]

    # Assert with a warning if the cropped functional data shape does not match the expected shape
    expected_shape = (
        func_data_crop.shape[0],
        func_data_crop.shape[1],
        func_data_crop.shape[2],
        final_num_TRs
    )
    assert func_data_crop.shape == expected_shape, (
        f"Warning: Cropped functional data shape for subject {sub} is {func_data_crop.shape}, "
        f"expected {expected_shape}."
    )

    # Subject-specific folder for cropped functional data
    subject_crop_dir = os.path.join(func_crop_dir, sub)
    os.makedirs(subject_crop_dir, exist_ok=True)

    # save cropped functional data in the subject-specific folder
    func_filename_crop = sub + func_crop_suffix
    nib.save(
        nib.Nifti1Image(func_data_crop, func_data_total.affine),
        os.path.join(subject_crop_dir, func_filename_crop)
    )

    print("Saved cropped functional data for subject: " + sub)
    print("Finished subject: " + sub)
