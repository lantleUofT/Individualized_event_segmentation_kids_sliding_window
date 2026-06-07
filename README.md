# Event Segmentation Pipeline
![pipeline](https://github.com/lantleUofT/Individualized_event_segmentation_kids_sliding_window/actions/workflows/pipeline.yml/badge.svg)

A reproducible pipeline for extracting **neural event segmentation timeseries** 
in developmental fMRI data. It conducts and runs validation of a sliding window analysis 
that should be implemented downstream of the denoising pipeline outlined in 
(Wilford et al., 2025) (Repo in progress). 

It extracts reliable windows of individualized neural state boundary timeseries 
unbiased by motion in children (which Wilford et al's (2025) pipeline was unable
to do). The reliable windows will be outputted into /data/final_harmonization_output

The validation analyses include: ensuring number and location of boundaries are 
not correlated with motion, as well as that neural state boundaries significantly 
correlate with behavioral event boundaries, a hallmark of typical neural event 
segmentation studies.


## Repo File Structure

```
Individualized_event_segmentation_kids_sliding_window/
├── .github/
│   └── workflows/
│       └── pipeline.yml
├── scripts/
│   ├── Toy_data_generator.py
│   ├── Data_loading_and_harmonization.R
│   ├── Sliding_window_analysis.R
│   ├── Data_preprocessing_for_final_analysis.R
│   ├── Individualized_event_segmentation_validation_kids.R
│   ├── run_pipeline.sh
│   └── run_pipeline_on_cluster.sh
├── Data_gen_arrays/
│   ├── boundary_prob_roi_tr.csv
│   ├── confound_stats.csv
│   ├── p_per_tr.csv
│   └── strength_stats_roi_tr.csv
├── .dockerignore
├── .gitignore
├── .here
├── Dockerfile
├── README.md
├── _dependencies.R
├── config.yaml
├── renv.lock
└── requirements.txt
```

## Running it

The pipeline runs inside a container with two options, Docker and 
Apptainer/Singularity.


### Docker

**Toy data:**

```bash
docker build -t eventseg-pipeline .
docker run --rm eventseg-pipeline
```

`docker run` executes all five steps (toy-data generation + harmonization, a sliding window
analysis, preprocessing and then the validation). It prints a summary for each. 
To recover the output files onto your host, mount a volume over the output directory:

```bash
docker run --rm -v "$(pwd)/data:/pipeline/data" eventseg-pipeline
```

Please note that running without the volume mount (`docker run --rm eventseg-pipeline`) 
still runs the full pipeline and prints a summary for each stage, but the output 
files stay inside the container and are discarded: useful for verifying it 
works, not for keeping results.


**Real data:**

When running it with your real data, create a config_local.yaml that is identical
to the config.yaml except for the input data filepaths. 

You must build your docker container with your real data in it or mount the directories
onto the docker container for a run with real data to resolve successfully.

To run with real data use:

```bash
docker build -t eventseg-pipeline .
docker run --rm eventseg-pipeline --real
```

`docker run --real` executes four steps (harmonization, a sliding window
analysis, preprocessing and then the validation). It prints a summary for each 
step. To recover the output files onto your host, mount a volume over the 
output directory:

```bash
docker run --rm -v "$(pwd)/data:/pipeline/data" eventseg-pipeline --real
```

Please note that running without the volume mount (e.g. 
`docker run --rm eventseg-pipeline --real`) still runs the full pipeline and 
prints a summary for each stage, but the output files stay inside the container 
and are discarded: useful for verifying it works, not for keeping results.

### Apptainer (HPC / Singularity environments)

A prebuilt `.sif` is attached to the latest [Release](../../releases). Download it
alongside the repository `run_pipeline_on_cluster.sh`, place both in the same 
directory (`run_pipeline_on_cluster.sh` ships in repo/scripts), and run:

```bash
bash run_pipeline_on_cluster.sh
```


**Real data:**

Place your inputs in a `real_data/` directory next to the script and a `config_local.yaml` 
(also next to the script) whose `paths:` point at the container mount under `/data/` 
— not your host paths:


Then run:

```bash
bash run_pipeline_on_cluster.sh --real
```

This skips toy-data generation, binds your `real_data/` and `config_local.yaml`
into the container, and writes results to `data/`. To write outputs elsewhere, 
pass a path:

```bash
bash run_pipeline_on_cluster.sh --real /scratch/your_user/results
```


**Build your own .sif:**
To build the `.sif` yourself instead of downloading it, build the Docker image (above),
then convert it:

```bash
docker save eventseg-pipeline:latest -o eventseg-pipeline.tar
apptainer build eventseg.sif docker-archive://eventseg-pipeline.tar
```
---

## Expected Input

### 1. Neural state-boundary timeseries (GSBS output)

A single tab-separated file (`neural_file` in config), stacking all subjects,
ROIs, and timepoints. One row per subject × ROI × TR. This should also contain a
binary event boundary timeseries and a boundary strength timeseries with one value
per row.


### 2. Behavioural boundary annotations

One CSV **per rater** in the behavioural directory (`behavioral_dir` in config). 
Each file lists the TRs at which that rater marked an event boundary 
(one row per boundary, not a full timeseries).


### 3. Head-motion confounds

One whitespace-delimited `.1D` file per subject in the confounds directory
(`confound_dir` in config), named `sub-<ID>_confounds.1D`. **No header.** 
The loader reads columns by position. Please note that these confounds.1D file 
should be the ones outputted by Wilford et al's (2025) denoising pipeline not 
raw fMRIprep .1D confound files. 

You may find Wilford et al's (2025) pipeline at: (repo in progress)

You can find my version of this pipeline optimized for use in HPC environment with
slurm at: (repo in progress)


### 4. Phenotype file

A single CSV (`phenotype_file` in config) with one row per subject, containing 
EID (subject ID with or without sub-) and an Age value.

---


## What the pipeline does

The analysis runs in four sequential stages. Each stage reads the previous stage's
output, so they must run in order.

1. **Harmonization** (`Data_loading_and_harmonization.R`)
   Loads behavioural boundary annotations, head-motion confounds, and phenotype
   data, then aligns them onto a common timebase. Behavioural boundaries are
   shifted for haemodynamic lag, downsampled by 2x to approach the fMRI sampling 
   rate then cropped by 40 TRs, smoothed, and collapsed into a group-average 
   boundary-density timeseries.

2. **Sliding-window motion selection** (`Sliding_window_analysis.R`)
   For each participant, scans for the lowest-motion usable window of scan time
   (using framewise-displacement and DVARS thresholds) and keeps the window with the 
   lowest mean framewise-displacement per participant. Excludes adult participants 
   from this analysis; they are retained separately as a comparison group for 
   the developmental sample once the method is validated.

3. **Preprocessing** (`Data_preprocessing_for_final_analysis.R`)
   Joins the neural boundary/strength timeseries to the selected motion windows and
   the group behavioural timeseries, smooths the neural signals, and produces the
   single analysis-ready dataframe for children and adults.

4. **Validation** (`Individualized_event_segmentation_validation_kids.R`)
   The core test. Within each participant and brain region it computes:
   - **Motion × neural boundaries** — a confound check: does head motion predict
     neural boundary strength and number? (Correlation should be non-significant)
   - **Behaviour × neural boundaries** — Can we replicate the commonly found behavioral
     x neural event boundary correlation (as a validation check). 
   Per-region correlations are Fisher-z transformed, tested against zero at the
   group level, and corrected across regions with Benjamini–Hochberg FDR.

Stage 0 (`Toy_data_generator.py`) fabricates synthetic behavioural, phenotype,
motion, and neural data so the pipeline has something to run on.

---


## Configuration reference

All parameters live in `config.yaml`, grouped by pipeline stage. Defaults shown are
the shipped (toy-data) values. Edit this file to change behaviour; you should not
need to touch the scripts.

### `paths`
| Key | Default | Description |
|-----|---------|-------------|
| `confound_dir` | `Toy_data_directory/Confounds_data` | Directory of per-subject `.1D` motion confound files |
| `behavioral_dir` | `Toy_data_directory/Behavioral_data` | Directory of per-rater behavioural boundary CSVs |
| `phenotype_file` | `Toy_data_directory/Phenotype_data/HBN_complete_Pheno.csv` | Per-subject phenotype CSV (EID + Age) |
| `neural_file` | `Toy_data_directory/Neural_data/MASTER_...stacked.tsv` | Stacked neural boundary/strength timeseries (GSBS output) |
| `output_dir_s1` | `data/harmonization_output` | Stage 1 output directory |
| `output_dir_s2` | `data/sliding_window_output` | Stage 2 output directory |
| `output_dir_s3` | `data/final_harmonization_output` | Stage 3 output directory |
| `output_dir_s4` | `data/validation_analysis_output` | Stage 4 output directory |

Paths are relative to the repo root (resolved via `here::here()`); absolute paths
also work.

### `toy_data`
| Key | Default | Description |
|-----|---------|-------------|
| `desired_beh_participants` | `10` | Number of synthetic behavioural raters to generate |
| `desired_neural_participants` | `20` | Number of synthetic subjects to generate |

### `harmonization` (Stage 1)
| Key | Default | Description |
|-----|---------|-------------|
| `TR_max` | `750` | Length of the behavioural timeseries in TRs (full pre-crop range) |
| `hrf_shift_tr` | `7` | TRs to shift behavioural boundaries forward for haemodynamic lag |
| `n_dummy_tr` | `40` | Leading TRs cropped after downsampling |
| `n_trs_stim` | `751` | Upper TR bound for the crop (keeps TR < this value) |
| `smooth_window` | `6` | Gaussian smoothing window (TRs) for behavioural boundaries |

### `sliding_window` (Stage 2)
| Key | Default | Description |
|-----|---------|-------------|
| `fd_threshold` | `0.3` | Framewise-displacement cutoff; TRs above this count as high-motion |
| `dvars_threshold` | `1.5` | Standardized DVARS cutoff for usable TRs |
| `win_length` | `355` | Length of the candidate motion window in TRs |
| `max_window_number` | `1` | Number of windows kept per subject (lowest-motion) |
| `adult_age_min` | `16` | Subjects at or above this age are excluded as adults |
| `age_col` | `"Age"` | Name of the age column in the phenotype file |

### `preprocessing` (Stage 3)
| Key | Default | Description |
|-----|---------|-------------|
| `neural_tr_offset` | `1` | Offset added to neural TR indices to align with the motion windows |
| `smooth_window` | `6` | Gaussian smoothing window (TRs) for neural boundary/strength/FD signals |

### `validation` (Stage 4)
| Key | Default | Description |
|-----|---------|-------------|
| `high_motion_tr_threshold` | `0.2` | FD cutoff for counting high-motion TRs in the motion×boundary analysis |
| `fdr_method` | `"BH"` | Multiple-comparison correction method (passed to `p.adjust`) |
| `fdr_alpha` | `0.05` | Significance threshold applied to FDR-corrected p-values |


## Outputs

Results are written to `data/` (visible on your host only when you mount the
volume, as shown above):

- `harmonization_output/` — aligned confound + behavioural timeseries
- `sliding_window_output/` — selected low-motion windows per participant
- `final_harmonization_output/` — the analysis-ready dataframe
- `validation_analysis_output/` — behavioral validation outputs:
    `roi_results_all.csv` (every region) and
    `roi_results_sig.csv` (regions surviving FDR correction)

Because the toy data is randomized based on real participants whose data passed
the sliding window analysis + validation, the *toy values* are not meaningful.
Demonstrating a clean end-to-end run is the point. 

Expected results are:
- Non-significant for motion correlations (or a 0 variance warning if no TR's with
  high enough motion are generated for the motion x boundary number analysis).
- Significant at the group level for behavioral correlation (but not for any
  ROI's)


---


## Reproducibility

- **R packages** are pinned in `renv.lock` (R 4.5.1).
- **Python packages** are pinned in `requirements.txt`.
- The container rebuilds both environments from those lockfiles, so a build on any
  machine reproduces the same package versions.

`_dependencies.R` declares the R packages for `renv`'s scanner and is not run by the
pipeline itself.


## Citations
Robyn Erica Wilford, Huiqin Chen, Erika Wharton-Shukster, 
Amy S. Finn, Katherine Duncan; 
Personalized Neural State Segmentation: Validating the Greedy State Boundary Search 
Algorithm for Individual-level Functional Magnetic Resonance Imaging Data. 
J Cogn Neurosci 2025; 37 (11): 1889–1912. doi: https://doi.org/10.1162/jocn_a_02345
