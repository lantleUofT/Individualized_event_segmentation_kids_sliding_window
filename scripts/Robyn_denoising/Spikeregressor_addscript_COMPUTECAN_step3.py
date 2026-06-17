# import all packages needed
import glob
import os
os.environ["MPLBACKEND"] = "Agg"   # safe for headless servers
import numpy as np
import matplotlib.pyplot as plt
import pandas as pd
import shutil
import nibabel as nib
import sys



# set working directory 
os.chdir('/scratch/leviaa/') #set working directory
print(os.getcwd()) #prints working directory
main_dir = os.getcwd() #sets working directory as a reuseable variable
data_dir = os.path.join(main_dir, 'HBN_full_fmriprep') #creates a new file path saved as a variable by combining working directory with the one I set this is the final preprocessed data
data_dir_raw = os.path.join(main_dir, 'HBN_full_fmriprep') #creates a new file path saved as a variable by combining working directory with the one I set this is the raw bids data
plots_dir = os.path.join(data_dir, "plots")

# subjects list

subjects = np.unique([
    f for f in os.listdir(data_dir_raw)
    if f.startswith('sub') and os.path.isdir(os.path.join(data_dir_raw, f))
])
subjects = np.sort(subjects)
print(subjects)

# Optionally restrict to a subset of subjects via an env var
subset_file = os.environ.get("SUBJECT_LIST_FILE")

if subset_file and os.path.exists(subset_file):
    with open(subset_file) as f:
        subset_ids = [line.strip() for line in f if line.strip()]

    # keep only those subjects that are in the subset list
    subjects = np.array([s for s in subjects if s in subset_ids])

    print(f"Using SUBJECT_LIST_FILE={subset_file}")
    print("Subset of subjects to process:", subjects)

    if len(subjects) == 0:
        print("No matching subjects found in subset file; exiting.")
        sys.exit(0)


# global variable for final number of TRs (change this)
final_num_TRs = 355 


# Variables

# regressors to keep: GS, first 10 aCompCor, CSF, WM, 18-expansion of 6 motion estimates (x, y, z, pitch, yaw, roll)

regs = ["csf","white_matter","global_signal","std_dvars","framewise_displacement",
           "a_comp_cor_00","a_comp_cor_01","a_comp_cor_02","a_comp_cor_03","a_comp_cor_04",
           "a_comp_cor_05","a_comp_cor_06","a_comp_cor_07","a_comp_cor_08","a_comp_cor_09",
           "trans_x","trans_x_derivative1","trans_x_power2","trans_x_derivative1_power2",
           "trans_y","trans_y_derivative1","trans_y_power2","trans_y_derivative1_power2",
           "trans_z","trans_z_derivative1","trans_z_power2","trans_z_derivative1_power2",
           "rot_x","rot_x_derivative1","rot_x_power2","rot_x_derivative1_power2",
           "rot_y","rot_y_derivative1","rot_y_power2","rot_y_derivative1_power2",
           "rot_z","rot_z_derivative1","rot_z_power2","rot_z_derivative1_power2"]

# global variable for extra cropping of 20TRs for initial burst in signal
extra_crop = 20
# suffixes for functional data and regressors
func_suffix = "_task-movieDM_space-MNI152NLin2009cAsym_desc-preproc_bold.nii.gz"
reg_suffix = "_task-movieDM_desc-confounds_timeseries.tsv"
# suffix for cropped functional data and regressors
func_crop_suffix = "_task-movieDM_space-MNI152NLin2009cAsym_desc-preproc_cropped_bold.nii.gz"
reg_crop_suffix = "_confounds.1D"
# suffix for filtered functional data
func_filt_suffix = "_task-movieDM_space-MNI152NLin2009cAsym_desc-preproc_cropped_filt_bold.nii.gz"

# directories to where to save edited regressors and final confounds - Another directory management thing
regressor_dir = os.path.join(data_dir,"regressors")
filtered_dir = os.path.join(regressor_dir,"filtered")
final_confounds_dir = os.path.join(regressor_dir,"final_confounds") 
func_dir = os.path.join(data_dir, "data_raw")
func_crop_dir = os.path.join(data_dir, "data_cropped")
func_filt_dir = os.path.join(data_dir, "data_clean","filtered")
func_final_dir = os.path.join(data_dir, "data_clean","regressed")

# print the directories to check if they are correct
print("Regressor directory:", regressor_dir)
print("Filtered directory:", filtered_dir)
print("Final confounds directory:", final_confounds_dir)
print("Functional data directory:", func_dir)
print("Functional data cropped directory:", func_crop_dir)
print("Functional data filtered directory:", func_filt_dir)
print("Functional data final directory:", func_final_dir)

# create directories if they do not exist
if not os.path.exists(regressor_dir):
    os.makedirs(regressor_dir)
if not os.path.exists(filtered_dir):
    os.makedirs(filtered_dir)
if not os.path.exists(final_confounds_dir):
    os.makedirs(final_confounds_dir)
if not os.path.exists(func_crop_dir):
    os.makedirs(func_crop_dir)
if not os.path.exists(func_dir):
    os.makedirs(func_dir) 
if not os.path.exists(func_filt_dir):
    os.makedirs(func_filt_dir)
if not os.path.exists(func_final_dir):
    os.makedirs(func_final_dir)
if not os.path.exists(plots_dir):
    os.makedirs(plots_dir, exist_ok=True)


# # visualize the cropped and filtered functional data and confound regressors for each subject
# for sub in subjects:
#     func_filename = sub + func_suffix

#     primary_path = os.path.join(func_dir, func_filename)  # /.../fmriprep/data_raw/<sub>...nii.gz
#     fallback_path = os.path.join(data_dir, sub, "func", func_filename)  # /.../fmriprep/<sub>/func/<sub>...nii.gz

#     if os.path.exists(primary_path):
#         func_path = primary_path
#     elif os.path.exists(fallback_path):
#         func_path = fallback_path
#         print(f"[{sub}] Using fallback functional path: {fallback_path}")
#     else:
#         print(f"[{sub}] Functional data not found at {primary_path} or {fallback_path}. Skipping this subject.")
#         continue

#     # per-subject plots folder
#     sub_plots_dir = os.path.join(plots_dir, sub)
#     os.makedirs(sub_plots_dir, exist_ok=True)

#     # load functional data
#     func_data_total = nib.load(func_path)
#     func_data = func_data_total.get_fdata()

#     # example: visualize a random voxel time series
#     # pick a fixed voxel for reproducibility or random if you prefer
#     x, y, z = 45, 50, 45
#     ts = func_data[x, y, z, :]

#     plt.figure(figsize=(10, 5))
#     plt.plot(ts)
#     plt.title(f"Raw Voxel Timeseries for {sub} @ ({x},{y},{z})")
#     plt.xlabel("Time (TR)")
#     plt.ylabel("Signal Intensity")
#     plt.grid()

#     # SAVE instead of show
#     out_png = os.path.join(sub_plots_dir, f"{sub}_raw_voxel_timeseries_{x}-{y}-{z}.png")
#     plt.savefig(out_png, dpi=150, bbox_inches="tight")
#     plt.close()  # free memory
#     print(f"Saved plot: {out_png}")


#     # load in filtered functional data
#     filtered_func_filename = sub + func_filt_suffix
#     # check if filtered functional data file exists
#     if not os.path.exists(os.path.join(func_filt_dir, sub, filtered_func_filename)):
#         print(f"Filtered functional data file for subject {sub} does not exist. Skipping this subject.")
#         continue
#     # load filtered functional data
#     filtered_func_data_total = nib.load(os.path.join(func_filt_dir, sub, filtered_func_filename))
#     filtered_func_data = filtered_func_data_total.get_fdata()
#     # visualize random voxel timeseries for filtered data
#     random_voxel_filtered = filtered_func_data[45, 50, 45, :]  # Change indices as needed
#     plt.figure(figsize=(10, 5))
#     plt.plot(random_voxel_filtered)
#     plt.title(f"Filtered Voxel Timeseries for Subject {sub}")
#     plt.xlabel("Time")
#     plt.ylabel("Signal Intensity")
#     plt.grid()
    
#     out_png = os.path.join(sub_plots_dir, f"{sub}_filtered_voxel_timeseries_{x}-{y}-{z}.png")
#     plt.savefig(out_png, dpi=150, bbox_inches="tight")
#     plt.close()
#     print(f"Saved plot: {out_png}")

#     # load in raw confound regressors
#     confound_filename = sub + reg_crop_suffix
#     # check if confound data file exists
#     if not os.path.exists(os.path.join(regressor_dir, confound_filename)):
#         print(f"Confound data file for subject {sub} does not exist. Skipping this subject.")
#         continue
#     # load confound data
#     confound_data = pd.read_csv(os.path.join(regressor_dir, confound_filename), sep=" ")
#     confound_data = confound_data.iloc[:,4] 
#     # visualize confound regressors vector
#     plt.figure(figsize=(10, 5))
#     plt.plot(confound_data, label="Confound Data Vector")
#     plt.title(f"Raw Confound Regressors Vector for Subject {sub}")
#     plt.xlabel("Time")
#     plt.ylabel("Signal Intensity")
#     plt.ylim(-1, 6)
#     plt.legend()
#     plt.grid()
    
#     out_png = os.path.join(sub_plots_dir, f"{sub}_raw_confounds_col5.png")
#     plt.savefig(out_png, dpi=150, bbox_inches="tight")
#     plt.close()
#     print(f"Saved plot: {out_png}")

#     # load in filtered confound regressors
#     filtered_confound_filename = sub + "_confounds.1D"

#     # check if filtered confound data file exists
#     filtered_confound_path = os.path.join(filtered_dir, filtered_confound_filename)
#     if not os.path.exists(filtered_confound_path):
#         print(f"Filtered confound data file for subject {sub} does not exist. Skipping this subject.")
#         continue

#     # load filtered confound data (.1D is whitespace-delimited and can have variable columns)
#     filtered_confound_data = pd.read_csv(
#         filtered_confound_path,
#         delim_whitespace=True,  # handle any number of spaces/tabs
#         header=None,            # .1D files have no header
#         comment="#",             # ignore comment lines
#         engine="python",         # tolerate ragged rows
#         usecols=[4],              # read only the 5th column (index 4)
#         on_bad_lines="warn"       # don't crash if a line has fewer/more fields
#     ).iloc[:, 0]  # get as Series

#     # visualize filtered confound regressors
#     plt.figure(figsize=(10, 5))
#     plt.plot(filtered_confound_data, label="Filtered Confound Data")
#     plt.title(f"Filtered Confound Regressors for Subject {sub}")
#     plt.xlabel("Time")
#     plt.ylabel("Signal Intensity")
#     plt.ylim(-1, 6)
#     plt.legend()
#     plt.grid()

#     out_png = os.path.join(sub_plots_dir, f"{sub}_filtered_confounds_col5.png")
#     plt.savefig(out_png, dpi=150, bbox_inches="tight")
#     plt.close()
#     print(f"Saved plot: {out_png}")


# # print completion message
# print(f"Data visualization completed for subject {sub}.")


# --- Build motion outlier spike columns robustly (avoid reindex errors) ---
new_mot_cols = []

for sub in subjects:
    reg_path = os.path.join(filtered_dir, f"{sub}_confounds.1D")
    if not os.path.exists(reg_path):
        print(f"[{sub}] missing {reg_path}; skipping.")
        continue

    # Read .1D robustly; we only need columns named in `regs`
    cf_all = pd.read_csv(
        reg_path,
        delim_whitespace=True,
        header=None,
        names=regs,        # create the expected columns
        comment="#",
        engine="python",
        on_bad_lines="warn"
    )

    # Sanity: ensure the two required columns exist
    if not {"std_dvars", "framewise_displacement"}.issubset(cf_all.columns):
        print(f"[{sub}] missing required columns; skipping.")
        continue

    # Make spike regressor (1 if dvars>1.5 OR fd>0.1, else 0)
    s = ((cf_all["std_dvars"] > 1.5) | (cf_all["framewise_displacement"] > 0.1)).astype(int)

    # Enforce positional index + consistent length
    s = s.iloc[:final_num_TRs].reset_index(drop=True)
    if len(s) < final_num_TRs:
        s = s.reindex(range(final_num_TRs), fill_value=0)

    s.name = sub
    new_mot_cols.append(s)

# Combine by columns (align by position, not by index labels)
if new_mot_cols:
    new_mot_regs = pd.concat(new_mot_cols, axis=1)
else:
    new_mot_regs = pd.DataFrame(index=range(final_num_TRs))

# Count the number of ones in each column of new_mot_regs
new_num_outlier = new_mot_regs.sum(axis=0)

# Print the counts for each subject
print("Number of ones in each column of new_mot_regs:")
print(new_num_outlier)


# Initialize a dictionary to store motion column counts for each subject
motion_column_counts = {}

# Loop through each subject
for sub in subjects:
    # Locate confounds TSV across both layouts (with or without ses-*)
    confound_glob = os.path.join(
        data_dir, sub, "**", f"{sub}*task-movieDM*desc-confounds_timeseries.tsv"
    )
    confound_matches = sorted(glob.glob(confound_glob, recursive=True))

    if not confound_matches:
        print(f"{sub}: confounds TSV not found; skipping.")
        continue
    if len(confound_matches) > 1:
        print(f"Warning: multiple confound files for {sub}: {confound_matches}. Using first.")
    confound_path = confound_matches[0]

    # Load the tsv file for the subject
    confound_data = pd.read_csv(confound_path, sep="\t")
    
    # Count the number of columns that start with "motion"
    motion_columns = [col for col in confound_data.columns if col.startswith("motion")]
    motion_column_count = len(motion_columns)
    
    # Store the count in the dictionary
    motion_column_counts[sub] = motion_column_count
    
    # Print the count for the subject
    print(f"{sub}: {motion_column_count}")

# Determine suffix for parallel-safe output
chunk_suffix = os.environ.get("CHUNK_TAG", "main")

out_path = os.path.join(
    filtered_dir,
    f"filtered_motion_outliers_{chunk_suffix}.csv"
)

print(f"Writing motion outlier summary to: {out_path}")
new_mot_regs.to_csv(out_path, index=False)



# Create and save a new dataframe for each column in new_mot_regs
for col in new_mot_regs.columns:
    # Extract non-zero values and their indices
    non_zero_indices = new_mot_regs[col].to_numpy().nonzero()[0]
    non_zero_values = new_mot_regs[col].iloc[non_zero_indices].to_numpy()

    # Create a new dataframe with indices and values as separate columns
    df_non_zero = pd.DataFrame({'index': non_zero_indices})

    # Save the dataframe to a CSV file
    output_filename = f"{col}_motion_outliers.csv"
    df_non_zero.to_csv(os.path.join(filtered_dir, output_filename), index=False)


# loop through participants and create new confound files with the new motion regressors
for sub in subjects:
    conf_path = os.path.join(filtered_dir, sub + '_confounds.1D')
    if not os.path.exists(conf_path):
        print(f"[{sub}] {conf_path} not found; skipping.")
        continue

    # open the confound file
    cf_orig = pd.read_csv(conf_path, delim_whitespace=True, names=regs)

    if cf_orig.sum().sum() == 0:
        # remove fwd and std_dvars and save to new directory
        cf_orig = cf_orig.drop(columns=['framewise_displacement', 'std_dvars'])
        # save to final confounds directory
        cf_orig.to_csv(os.path.join(final_confounds_dir, sub + '_confounds.1D'), sep=' ', index=False, header=False)
        # print message
        print(f"No motion outliers for subject {sub}. Original confound file saved without fwd and stdvars.")
        
        continue

    # ensure sequential row index
    cf_orig = cf_orig.reset_index(drop=True)

    # load motion outlier indices
    indices = pd.read_csv(os.path.join(filtered_dir, f"{sub}_motion_outliers.csv"))

    # keep only indices within the actual number of rows
    n_rows = len(cf_orig)
    valid_indices = [i for i in indices['index'] if i < n_rows]

    # add one spike regressor column per valid index
    for idx in valid_indices:
        colname = f"spike_{idx}"  # name avoids confusion with numeric col names
        cf_orig[colname] = 0
        cf_orig.loc[idx, colname] = 1


    
    # remove fwd and std_dvars and save to new directory
    cf_orig = cf_orig.drop(columns=['framewise_displacement', 'std_dvars'])
    # save the new confound file
    cf_orig.to_csv(os.path.join(final_confounds_dir, sub + '_confounds.1D'), sep=' ', index=False, header=False)



  
