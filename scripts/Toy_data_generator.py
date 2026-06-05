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


#randomly generate behavioral data
np.random.seed(1738)
desired_beh_participants = cfg["toy_data"]["desired_beh_participants"]

for x in range(desired_beh_participants):
    probabilities = pd.Series(np.random.uniform(low=0, high=1, size=750))
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
        "V1": np.zeros(750),
        "V2": np.zeros(750),
        "V3": np.zeros(750),
        "V4": np.random.normal(mp.loc["std_dvars", "mean"],
                               mp.loc["std_dvars", "sd"], 750),
        "V5": np.random.normal(mp.loc["framewise_displacement", "mean"],
                               mp.loc["framewise_displacement", "sd"], 750),
    })
    (TOY / "Confounds_data").mkdir(parents=True, exist_ok=True)
    motion_conf.to_csv(TOY / "Confounds_data" / f"sub-{eid}_confounds.1D", sep=" ", header=False, index=False)



#randomly generate neural data
frames = []
prob_vec = neural_boundary_prob["prob"].to_numpy()
strength_mean = neural_strength_dists["mean"].to_numpy()
strength_sd   = neural_strength_dists["sd"].to_numpy()

for eid in pheno_df["EID"]:
    base = pd.DataFrame({
        "subject": f"sub-{eid}",
        "roi": np.repeat(np.arange(1, 101), 355),
        "TR":  np.tile(np.arange(0, 355), 100),
    })
    draws = np.random.uniform(0, 1, size=len(base))
    base["boundary"] = (draws < prob_vec).astype(int)
    base["strength"] = np.clip(np.random.normal(strength_mean, strength_sd), 0, None)
    frames.append(base)

neural_df = pd.concat(frames, ignore_index=True)
(TOY / "Neural_data").mkdir(parents=True, exist_ok=True)
neural_df.to_csv(TOY / "Neural_data" / "MASTER_allSubjects_allrois_boundaries_stacked.tsv", sep="\t", index=False)
    