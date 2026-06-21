# Event Segmentation Pipeline
![pipeline](https://github.com/lantleUofT/Individualized_event_segmentation_kids_sliding_window/actions/workflows/pipeline.yml/badge.svg)

A reproducible pipeline for extracting **neural event segmentation timeseries** 
in developmental fMRI data. It conducts and runs validation of a sliding window analysis 
that should be implemented downstream of the denoising pipeline outlined in 
(Wilford et al., 2025) (Repo in progress). 

It extracts reliable windows of individualized neural state boundary timeseries 
unbiased by motion in children (which Wilford et al's (2025) pipeline was unable
to do). The selected windows will be output into /data/final_harmonization_output

> **Beta:** GSBS event segmentation (stages 2.4/2.6) and neural-data stitching
> (stage 2.8) are now run inside the pipeline rather than supplied as external
> input. These stages are under active development — see the flags and stage
> descriptions below.


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
│   ├── Sliding_window_bold_crop/
│   │   ├── Sliding_window_nii_copy_crop.sh
│   │   └── crop_bold.py
│   ├── GSBS_run/
│   │   ├── run_GSBS_driver.sh
│   │   └── GSBS_worker.py
│   ├── stitch_neural_data.sh
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

### Flags

The pipeline accepts these optional flags, applied in any combination:

- `--real` — use real data and `config_local.yaml` instead of generating toy data.
- `--run_crop` — run the bold-crop step (2.5), which crops each subject's BOLD to its
  selected sliding window for downstream GSBS. Gated: requires `--real` (toy mode has
  no BOLDs to crop).
- `--run_GSBS` *(beta)* — run GSBS event segmentation on the full and cropped BOLD
  (stages 2.4 and 2.6), writing per-ROI boundary timeseries. Gated: requires `--real`.
- `--stitch_neural_data` *(beta)* — assemble the per-ROI GSBS outputs into the stacked
  MASTER neural file(s) consumed by stage 3 (stage 2.8). Gated: requires `--real`.
- `--run_validation` — run the validation stage (4). Off by default; valid in either
  toy or real mode.

With no flags the pipeline runs toy data generation, harmonization, sliding-window
selection, and preprocessing — it stops before the crop, GSBS, stitch, and validation
stages. The GSBS and stitch stages only apply to real data and are each gated behind
their own flag in addition to `--real`.

## Running it

The pipeline runs inside a container with two options, Docker and 
Apptainer/Singularity.


### Docker

**Toy data:**

```bash
docker build -t eventseg-pipeline .
docker run --rm eventseg-pipeline
```

`docker run` executes toy-data generation, harmonization, sliding-window selection,
and preprocessing, printing a summary for each. Validation (stage 4) and the bold
crop (step 2.5) are opt-in; add `--run_validation` and `--run_crop` to include them.

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

`docker run --real` executes harmonization, sliding-window selection, and
preprocessing on your real data. To also crop BOLDs to they match the extracted
sliding windows, run GSBS and run validation, add the following gated flags:

```bash
docker run --rm -v "$(pwd)/data:/pipeline/data" eventseg-pipeline --real --run_crop --run_GSBS --stitch_neural_data --run_validation
```

Please note that running without the volume mount (e.g. 
`docker run --rm eventseg-pipeline --real`) still runs the full pipeline and 
prints a summary for each stage, but the output files stay inside the container 
and are discarded: useful for verifying it works, not for keeping results.

### Apptainer (HPC / Singularity environments)

Build the `.sif` yourself from the Docker image (see **Build your own .sif** below),
place it in the same directory as `run_pipeline_on_cluster.sh` (which ships in
repo/scripts) and run:

```bash
bash run_pipeline_on_cluster.sh
```


**Real data:**

Place your inputs in a `real_data/` directory next to the script and a `config_local.yaml` 
(also next to the script) whose `paths:` point at the container mount under `/data/`, not your host paths:


Then run:

```bash
bash run_pipeline_on_cluster.sh --real --run_crop --run_GSBS --stitch_neural_data --run_validation
```

This skips toy-data generation, binds your `real_data/` and `config_local.yaml`
into the container, runs the crop and validation stages, and writes results to
`data/`. The flags are forwarded into the container and gated there, exactly as in
the Docker path; `--run_crop` without `--real` is rejected. 

To write outputs
elsewhere, pass a path as the final argument. This becomes the **data root** for the
run: the script binds `<path>/data` to `/pipeline/data` inside the container, and
every stage reads its inputs from and writes its outputs to that location. Because
later stages consume earlier stages' outputs from this same directory, your real
input data must already be staged under `<path>/data/` before launching — the path
is not output-only. With no path argument, the data root defaults to `./data` next 
to the script.


```bash
bash run_pipeline_on_cluster.sh --real --run_crop --run_validation /scratch/your_user/results
```


**Build your own .sif:**
To build the `.sif` yourself, build the Docker image (above), then convert it:

```bash
docker build -t eventseg-pipeline .
docker save eventseg-pipeline:latest -o eventseg-pipeline.tar
apptainer build eventseg.sif docker-archive://eventseg-pipeline.tar
```

On an Apple Silicon (ARM) Mac you must target `linux/amd64`, or the
`apptainer build` will fail on x86 clusters with `linux/amd64 image not found in index`:

```bash
docker build --platform linux/amd64 -t eventseg-pipeline .
docker save eventseg-pipeline:latest -o eventseg-pipeline.tar
apptainer build eventseg.sif docker-archive://eventseg-pipeline.tar
```

If you change dependencies (e.g. `requirements.txt` or the `Dockerfile`), you must
rebuild the `.sif` from the updated image — the `.sif` is a snapshot, not a live mount.

---

## Expected Input

### 1. Head-motion confounds

One whitespace-delimited `.1D` file per subject in the confounds directory
(`confound_dir` in config), named `sub-<ID>_confounds.1D`. **No header.** 
The loader reads columns by position. Please note that these confounds.1D file 
should be the ones outputted by Wilford et al's (2025) denoising pipeline not 
raw fMRIprep .1D confound files. 

You may find Wilford et al's (2025) pipeline at: (Repo in progress)


### 2. Behavioural boundary annotations

One CSV **per rater** in the behavioural directory (`behavioral_dir` in config). 
Each file lists the TRs at which that rater marked an event boundary 
(one row per boundary, not a full timeseries).


### 3. Phenotype file

A single CSV (`phenotype_file` in config) with one row per subject, containing 
EID (subject ID with or without sub-) and an Age value.


### 4. Neural state-boundary timeseries (GSBS output)

There are two ways to provide neural data, depending on whether you run the
in-pipeline GSBS stages.

**Option A — run GSBS in-pipeline (beta, `--run_GSBS --stitch_neural_data`).**
Supply each subject's full-length preprocessed BOLD as a 4D NIfTI in the GSBS
full-input directory (`gsbs.input_dir_full` in config, default `data/neural_test_data`),
named `sub-<ID>` + `gsbs.input_suffix_full`. The crop stage (2.5) derives the
partial-window BOLD into `gsbs.input_dir_partial`, GSBS (2.4/2.6) segments both, and
the stitch stage (2.8) assembles them into the stacked neural file(s) that stage 3
reads. This path also requires a parcellation atlas NIfTI at `gsbs.atlas_nifti`
(default is the atlas `data/atlases/Schaefer2018_100Parcels_7Networks_movieDM_resamp_2p4mm_cropped.nii.gz`),
which must be present in /data/atlases/your_file_name and specified in the config_local.yaml


**Option B — supply your own stacked neural file.** If you skip the GSBS stages,
provide a single tab-separated file (`neural_file` in config) directly, stacking all
subjects, ROIs, and timepoints: one row per subject × ROI × TR, with columns
`subject, roi, TR, boundary, strength` (a binary event-boundary value and a boundary
strength per row). This is the format the stitch stage produces and the format toy
data generates.

> **Beta note:** the GSBS path is under active development. Until it stabilizes,
> Option B (bringing a pre-stacked neural file) is the more reliable route.









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
   For each participant, scans for low-motion usable windows of scan time (using
   framewise-displacement and DVARS thresholds). Two passes run: a first window
   (`win_length`) and a second "full" window (`win_length_full`). In the first-window
   pass, each subject is reduced to a single window, the one whose mean FD is closest
   to the group mean. The full pass retains all selected windows. Participants whose
   timeseries never exceed the thresholds are kept as well. Adult participants
   (age ≥ `adult_age_min`) are separated from children in the outputs and retained as a
   comparison group for the developmental sample once the method is validated.

2.2. **Bold crop** (`Sliding_window_bold_crop/Sliding_window_nii_copy_crop.sh`, `crop_bold.py`)
   Optional, gated behind `--real --run_crop`. For each subject in the kids and adults
   window manifests, crops the 4D BOLD to the selected `win_length` TR window and writes
   a new NIfTI to `bold_crop.cropped_dir`, leaving the input untouched. This prepares
   per-subject inputs for downstream GSBS. Subjects parallelize across available cores.

2.4 + 2.6. **GSBS event segmentation** (`GSBS_run/run_GSBS_driver.sh`, `GSBS_worker.py`) *(beta)*
   Optional, gated behind `--real --run_GSBS`. Runs Greedy State Boundary Search on
   both the full-length BOLD (stage 2.4) and the cropped partial-window BOLD (stage 2.6),
   producing per-subject, per-ROI neural state-boundary timeseries (binary boundary +
   boundary strength per TR). Outputs are written per subject into the GSBS output
   directories for each window.

2.8. **Neural data stitching** (`stitch_neural_data.sh`) *(beta)*
   Optional, gated behind `--real --stitch_neural_data`. Assembles the per-subject,
   per-ROI GSBS outputs into the single stacked MASTER neural file(s) that stage 3
   reads — one row per subject × ROI × TR. Runs once per window (full and partial).

3. **Preprocessing** (`Data_preprocessing_for_final_analysis.R`)
   Reads the stacked neural file(s) (from stage 2.8, or supplied directly), aligns the neural boundary/strength timeseries to the confound windows (applying a
   TR offset), inner-joins them to the kept motion windows, Gaussian-smooths the neural
   signals (boundary, strength, framewise displacement), and joins the group behavioural
   boundary density by TR (not for full timeseries). Produces four analysis-ready dataframes, children and adults,
   each in first-window and full-timeseries versions as well as an adult full-timeseries
   group average (mean smoothed boundary and strength per ROI × TR).

4. **Validation** (`Individualized_event_segmentation_validation_kids.R`)
   Within each participant and brain region it computes:
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
| `neural_file_full` | *(derived: `_full` suffix on `neural_file`)* | Stacked full-window neural file; defaults to `neural_file` with `_full` inserted before the extension if unset |
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
| `fd_threshold` | `0.25` | Framewise-displacement cutoff; TRs above this count as not compatible with a window |
| `dvars_threshold` | `1.5` | Standardized DVARS cutoff for usable TRs |
| `win_length` | `225` | Length of the candidate motion window in TRs |
| `max_window_number` | `1` | Number of windows kept per subject (lowest-motion) |
| `adult_age_min` | `16` | Subjects at or above this age are excluded as adults |
| `age_col` | `"Age"` | Name of the age column in the phenotype file |
| `win_length_full` | `355` | full length of fMRI timeseries for second sliding window |
| `max_w_num_full` | `1` | Number of windows kept per subject in second sliding window |


### `bold_crop` (Stage 2.2)
| Key | Default | Description |
|-----|---------|-------------|
| `regressed_dir` | `data/neural_test_data` | Input dir of per-subject 4D BOLD NIfTIs to crop |
| `cropped_dir` | `data/cropped_partial_window` | Output dir for cropped windows (must differ from `regressed_dir`) |
| `bold_suffix` | `_task-movieDM_..._cropped_bold.nii.gz` | Filename suffix appended to subject ID for input files |
| `output_suffix` | `_task-movieDM_..._partial_window_bold.nii.gz` | Filename suffix for cropped outputs |


### `gsbs` (Stages 2.4 / 2.6, beta)
| Key | Default | Description |
|-----|---------|-------------|
| `input_dir_full` | `data/neural_test_data` | Input dir of full-length 4D BOLD NIfTIs for the full GSBS pass |
| `input_suffix_full` | `_task-movieDM_..._cropped_bold.nii.gz` | Filename suffix appended to subject ID for full-pass inputs |
| `output_dir_full` | `data/gsbs_output/neural_test_data` | Output dir for full-window per-ROI boundary timeseries |
| `kmax_full` | `140` | Maximum number of states GSBS searches for in the full pass |
| `input_dir_partial` | `data/cropped_partial_window` | Input dir of cropped partial-window BOLDs (bold_crop output) |
| `input_suffix_partial` | `_task-movieDM_..._partial_window_bold.nii.gz` | Filename suffix for partial-pass inputs |
| `output_dir_partial` | `data/gsbs_output/cropped_partial_window` | Output dir for partial-window per-ROI boundary timeseries |
| `kmax_partial` | `89` | Maximum number of states GSBS searches for in the partial pass |
| `atlas_nifti` | `data/atlases/Schaefer2018_100Parcels_7Networks_movieDM_resamp_2p4mm_cropped.nii.gz` | Parcellation atlas NIfTI defining the ROIs |
| `dmin` | `1` | Minimum TR distance from the diagonal ignored in the t-distance |
| `blocksize` | `25` | Block size for GSBS state detection |
| `finetune` | `1` | Finetuning window (TRs) around each boundary |
| `cores_per_subject` | `4` | Thread cap per subject (sets OMP/BLAS/MKL/NUMEXPR thread limits) |
| `statewise_detection` | `'true'` | Statewise GSBS detection (`'true'`) vs original one-boundary-per-iteration. Quoted string fed to the lambda boolean parser |
| `finetune_order_weakest_first` | `'true'` | Finetune boundaries weakest-first (`'true'`). Quoted string for the lambda boolean parser |


### `container`
| Key | Default | Description |
|-----|---------|-------------|
| `python_exec` | `python3` | Interpreter prefix for the crop, GSBS, and stitch workers. `python3` works for both Docker and Apptainer (the pipeline already runs inside the container). |


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


## Pipeline Outputs
Results are written to `data/` (visible on your host only when you mount the
volume, as shown above):

- `harmonization_output/` (stage 1) — aligned confound, phenotype, and behavioural timeseries
    `confounds_pheno.rds` (per subject × TR confound data, framewise displacement and std DVARS, left-joined with phenotype columns; subjects with no phenotype match dropped)
    `behavioral_bounds_resamp_smoothed.rds` (group-average behavioural boundary timeseries: one row per TR, HRF-shifted, downsampled, cropped, and Gaussian-smoothed; key column `norm_resamp_gaus`)

- `sliding_window_output/` (stage 2) — selected low-motion windows per participant. Two object types per group:
  `best_windows_*` is the window-level index (one row per selected window: win_num, start_TR, end_TR, mean_fd).
  `kept_windows_confounds_*` is the TR-level confound + phenotype data for those windows (one row per retained TR).
  Groups follow a kids/adults × first-window/second-window ("full") split:
    `best_windows_kids` / `kept_windows_confounds_kids` (kids, first window; reduced to one window per subject. Selected by FD closest to group mean)
    `best_windows_adults` / `kept_windows_confounds_adults` (adults age ≥ adult_age_min, first window; one window per subject)
    `best_windows_kids_full` / `kept_windows_confounds_kids_full` (kids, second window; ALL selected windows retained, not reduced)
    `best_windows_adults_full` / `kept_windows_confounds_adults_full` (adults, second window; all selected windows retained)
  Also writes two diagnostic CSVs: `subjects_pass_window_age16plus.csv` and `subjects_pass_window_full_age16plus.csv` (subjects age ≥ adult_age_min who passed each window pass).

- `final_harmonization_output/` (stage 3) — analysis-ready neural × confound × behavioural dataframes (saved as both .rds and .csv). Neural TRs are offset to align with confound windows, inner-joined to the kept windows, Gaussian-smoothed (boundary, strength, framewise displacement), and joined to the group behavioural density by TR:
    `neural_confound_extracted_windows_df` (kids, first window)
    `neural_confound_extracted_windows_adult_df` (adults, first window)
    `neural_confound_extracted_windows_full_df` (kids, second/full window)
    `neural_confound_extracted_windows_adult_full_df` (adults, second/full window)
    `adult_full_group_avg` (adult full-window data averaged across subjects: one row per ROI × TR, with mean smoothed boundary, mean smoothed strength, and subject count)

- `validation_analysis_output/` (stage 4) — behavioural validation outputs (kids analysis; behavioural-neural correlations pool kids + adults):
    `roi_results_all.rds` / `roi_results_all.csv` (per-ROI one-sample t-test of Fisher-z behavioural-neural correlations vs 0: n_subj, mean_r, mean_r_z, t_stat, df, p_val, p_fdr, ci_low, ci_high — every ROI)
    `roi_results_sig.csv` (subset of the above surviving BH-FDR correction at p_fdr < fdr_alpha)
  Note: the motion×boundary and high-motion×boundary-count analyses are printed to console only — no file output.

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

## Data License & Attribution

### Derived data in this repository

The matrices for toy data generation in this repository are aggregate data derived from the
Healthy Brain Network (HBN) neuroimaging (fMRI) dataset. They were produced
through extensive preprocessing, algorithmic transformation, and averaging across
subjects into probability matrices. No raw HBN data are redistributed here.

Because the source data combine participants released under both the
Creative Commons Attribution-NonCommercial-ShareAlike 4.0 (CC BY-NC-SA 4.0) and
Creative Commons Attribution 4.0 (CC BY 4.0) licenses, the derived matrices in
this repository are released under the more restrictive of the two:

**Creative Commons Attribution-NonCommercial-ShareAlike 4.0 International
(CC BY-NC-SA 4.0)** — https://creativecommons.org/licenses/by-nc-sa/4.0/

This means you may share and adapt these matrices provided that you:
- **Attribute** this repository and the original HBN source (see Citations section);
- Do **not** use them for commercial purposes;
- Distribute any derivative works under the same CC BY-NC-SA 4.0 license.

### Randomly generated age data

Any age values included in this repository are generated completely at random and
are **not** derived from, conditioned on, or computed from the HBN data or the
probability matrices. They are fully synthetic and carry no license restriction from HBN.

### Source attribution

Source neuroimaging data: Healthy Brain Network (HBN), Child Mind Institute,
distributed via the 1000 Functional Connectomes Project / INDI on NITRC.
https://fcon_1000.projects.nitrc.org/indi/cmi_healthy_brain_network/


## Citations
Robyn Erica Wilford, Huiqin Chen, Erika Wharton-Shukster, 
Amy S. Finn, Katherine Duncan; 
Personalized Neural State Segmentation: Validating the Greedy State Boundary Search 
Algorithm for Individual-level Functional Magnetic Resonance Imaging Data. 
J Cogn Neurosci 2025; 37 (11): 1889–1912. doi: https://doi.org/10.1162/jocn_a_02345

Alexander, L., Escalera, J., Ai, L. et al. An open resource for transdiagnostic research 
in pediatric mental health and learning disorders. Sci Data 4, 170181 (2017). 
https://doi.org/10.1038/sdata.2017.181
