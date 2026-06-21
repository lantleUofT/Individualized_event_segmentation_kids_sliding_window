#import packages
from __future__ import annotations
import numpy as np
import pandas as pd
from pathlib import Path
import yaml


#setup yaml paths
REPO_ROOT = Path(__file__).resolve().parent.parent
TOY = REPO_ROOT / "Toy_data_directory"
ARRAYS = REPO_ROOT / "Data_gen_arrays"
with open(REPO_ROOT / "config.yaml") as f:
    cfg = yaml.safe_load(f)


#import probability arrays for data generation
beh_params           = pd.read_csv(ARRAYS / "p_per_tr.csv")
motion_params        = pd.read_csv(ARRAYS / "confound_stats.csv")
neural_boundary_prob = pd.read_csv(ARRAYS / "boundary_prob_roi_tr.csv")
neural_strength_dists = pd.read_csv(ARRAYS / "strength_stats_roi_tr.csv")


#handle adjusted TR length in the config
n_roi = 100
prob_vec      = neural_boundary_prob["prob"].to_numpy()
strength_mean = neural_strength_dists["mean"].to_numpy()
strength_sd   = neural_strength_dists["sd"].to_numpy()

n_tr_native    = len(prob_vec) // n_roi      # neural array TR span (355)
n_tr_stimulus  = len(beh_params)             # behavioral/stimulus TR span (~750)
assert len(prob_vec) == n_roi * n_tr_native, "prob array isn't a clean roi×TR grid"

win_length      = cfg["sliding_window"]["win_length"]        # partial
win_length_full = cfg["sliding_window"]["win_length_full"]

if win_length > win_length_full:
    raise SystemExit(f"win_length ({win_length}) > win_length_full ({win_length_full}); "
                     f"partial can't exceed full.")
if win_length_full > n_tr_stimulus:
    raise SystemExit(f"win_length_full ({win_length_full}) exceeds the behavioral/stimulus "
                     f"timeline ({n_tr_stimulus} TRs); stage 3's behavioral join will fail. "
                     f"Lower it or regenerate the behavioral arrays for a longer stimulus.")

def resample_tr(vec_roi_major, target_len):
    """Slice if target <= native, tile (wrap) if longer. Preserves per-TR structure."""
    mat = vec_roi_major.reshape(n_roi, n_tr_native)
    idx = np.arange(target_len) % n_tr_native
    return mat[:, idx].reshape(-1)

#randomly generate behavioral data
np.random.seed(1738)
desired_beh_participants = cfg["toy_data"]["desired_beh_participants"]

for x in range(desired_beh_participants):
    probabilities = pd.Series(np.random.uniform(low=0, high=1, size=n_tr_stimulus))
    df = pd.DataFrame({'TR': probabilities.values < beh_params['x']})
    df = df[df["TR"]].copy()
    df["TR"] = df.index  
    
    beh_bounds = pd.DataFrame({
        "Participant": f'{x +1}',   
        "TR": df["TR"].values,         
        "continuous": 1                
        })
    (TOY / "Behavioral_data").mkdir(parents=True, exist_ok=True)
    beh_bounds.to_csv(TOY / "Behavioral_data" / f"participant_{x}.csv", index=False)



#randomly generate neural data
desired_neural_participants = cfg["toy_data"]["desired_neural_participants"]
alphabet = np.array(list("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"))

def make_eid():
    chars = np.random.choice(alphabet, size=8, replace=True)
    return "NDAR" + "".join(chars)

holding = []
for x in range(desired_neural_participants):
    age = np.random.uniform(5, 22)
    EID = make_eid()
    holding.append({"EID": EID, "Age": age})

pheno_df = pd.DataFrame(holding) 

(TOY / "Phenotype_data").mkdir(parents=True, exist_ok=True)
pheno_df.to_csv(TOY / "Phenotype_data" / "HBN_complete_Pheno.csv", index=False)



#randomly generate confounds file
mp = motion_params.set_index("measure")

for eid in pheno_df["EID"]:
    motion_conf = pd.DataFrame({
        "V1": np.zeros(win_length_full),
        "V2": np.zeros(win_length_full),
        "V3": np.zeros(win_length_full),
        "V4": np.random.normal(mp.loc["std_dvars", "mean"],
                               mp.loc["std_dvars", "sd"], win_length_full),
        "V5": np.random.normal(mp.loc["framewise_displacement", "mean"],
                               mp.loc["framewise_displacement", "sd"], win_length_full),
    })
    (TOY / "Confounds_data").mkdir(parents=True, exist_ok=True)
    motion_conf.to_csv(TOY / "Confounds_data" / f"sub-{eid}_confounds.1D", sep=" ", header=False, index=False)



#randomly generate FULL neural data (length = win_length_full from config)
prob_full  = resample_tr(prob_vec,      win_length_full)
smean_full = resample_tr(strength_mean, win_length_full)
ssd_full   = resample_tr(strength_sd,   win_length_full)

frames = []
for eid in pheno_df["EID"]:
    base = pd.DataFrame({
        "subject": f"sub-{eid}",
        "roi": np.repeat(np.arange(1, 101), win_length_full),
        "TR":  np.tile(np.arange(0, win_length_full), 100),
    })
    draws = np.random.uniform(0, 1, size=len(base))
    base["boundary"] = (draws < prob_full).astype(int)
    base["strength"] = np.clip(np.random.normal(smean_full, ssd_full), 0, None)
    frames.append(base)

neural_df = pd.concat(frames, ignore_index=True)
(TOY / "Neural_data").mkdir(parents=True, exist_ok=True)
neural_df.to_csv(TOY / "Neural_data" / "MASTER_allSubjects_allrois_boundaries_stacked.tsv", sep="\t", index=False)



#randomly generate PARTIAL-window neural data 
prob_part  = resample_tr(prob_vec,      win_length)
smean_part = resample_tr(strength_mean, win_length)
ssd_part   = resample_tr(strength_sd,   win_length)

frames_partial = []
for eid in pheno_df["EID"]:
    base = pd.DataFrame({
        "subject": f"sub-{eid}",
        "roi": np.repeat(np.arange(1, 101), win_length),
        "TR":  np.tile(np.arange(0, win_length), 100),   # 0-based local index
    })
    draws = np.random.uniform(0, 1, size=len(base))
    base["boundary"] = (draws < prob_part).astype(int)
    base["strength"] = np.clip(np.random.normal(smean_part, ssd_part), 0, None)
    frames_partial.append(base)

neural_partial_df = pd.concat(frames_partial, ignore_index=True)
neural_partial_df.to_csv(
    TOY / "Neural_data" / "MASTER_partial_allrois_boundaries_stacked.tsv",
    sep="\t", index=False
)

    