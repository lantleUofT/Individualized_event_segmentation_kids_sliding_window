import argparse
import os
import numpy as np
import nibabel as nib

from gsbs import GSBS


def load_func_4d(func_path: str):
    """
    Load 4D functional NIfTI and return:
      - data_2d: (T, V_all) array, where V_all = X * Y * Z
      - spatial_shape: (X, Y, Z)
    """
    img = nib.load(func_path)
    data = img.get_fdata()

    if data.ndim != 4:
        raise ValueError(f"Expected 4D fMRI data, got shape {data.shape}")

    # Typical fMRIPrep output: (X, Y, Z, T)
    if data.shape[-1] < 5000:
        X, Y, Z, T = data.shape
        data = data.reshape(X * Y * Z, T).T  # (T, V_all)
        spatial_shape = (X, Y, Z)
    else:
        # Less likely: (T, X, Y, Z)
        T, X, Y, Z = data.shape
        data = data.reshape(T, X * Y * Z)    # (T, V_all)
        spatial_shape = (X, Y, Z)

    return data, spatial_shape


def load_schaefer_atlas(atlas_path: str, spatial_shape):
    """
    Load Schaefer parcellation NIfTI and return:
      - atlas_flat: 1D array of labels (size X*Y*Z)
      - labels: sorted unique labels > 0
    """
    atlas_img = nib.load(atlas_path)
    atlas = atlas_img.get_fdata()

    if atlas.shape != spatial_shape:
        raise ValueError(
            f"Atlas shape {atlas.shape} does not match functional spatial shape {spatial_shape}"
        )

    atlas_flat = atlas.reshape(-1)
    labels = np.unique(atlas_flat)
    labels = labels[labels > 0]  # ignore 0 / background

    return atlas_flat, labels


def main():
    parser = argparse.ArgumentParser(
        description=(
            "Run GSBS on regressed fMRI using Schaefer 7-networks 100-parcel atlas, "
            "running GSBS separately for each ROI with voxels as features."
        )
    )

    # You only have to specify the subject; paths are derived from this
    parser.add_argument(
        "--subject",
        type=str,
        required=True,
        help="Subject ID (e.g. sub-NDARXXXXXXX).",
    )

    # Defaults match your current layout; override only if needed
    parser.add_argument(
        "--regressed-root",
        type=str,
        default="/scratch/leviaa/HBN_full_fmriprep/data_clean/regressed",
        help="Root directory for regressed NIfTIs.",
    )
    parser.add_argument(
        "--atlas-nifti",
        type=str,
        default="/scratch/leviaa/atlases/"
                "Schaefer2018_100Parcels_7Networks_movieDM_resamp_2p4mm_cropped.nii.gz",
        help="Path to Schaefer 100-parcel atlas NIfTI (resampled to 2.4mm movieDM grid).",
    )
    parser.add_argument(
        "--output-root",
        type=str,
        default="/scratch/leviaa/HBN_full_fmriprep/gsbs_schaefer100",
        help="Root directory for GSBS outputs.",
    )

    # GSBS hyperparameters
    parser.add_argument(
        "--kmax",
        type=int,
        default=140,
        help="Max number of states to consider (default: 50, we use 140).",
    )
    parser.add_argument(
        "--dmin",
        type=int,
        default=1,
        help="Number of TRs around diagonal to ignore in t-distance (default: 1).",
    )
    parser.add_argument(
        "--blocksize",
        type=int,
        default=25,
        help="Minimum block size for boundary search (default: 25).",
    )
    parser.add_argument(
        "--no-statewise",
        action="store_true",
        help="Disable statewise detection (use original GSBS: 1 boundary per iteration).",
    )
    parser.add_argument(
        "--finetune",
        type=int,
        default=1,
        help="Finetuning window in TRs around each boundary (0 = no finetune, <0 = full series).",
    )
    parser.add_argument(
        "--finetune-strongest-first",
        action="store_true",
        help="If set, finetune order is strongest->weakest (default: weakest->strongest).",
    )

    args = parser.parse_args()
    sub = args.subject

    # ---------- Build paths automatically ----------
    input_nifti = os.path.join(
        args.regressed_root,
        f"{sub}_task-movieDM_space-MNI152NLin2009cAsym_desc-preproc_cropped_bold.nii.gz",
    )

    if not os.path.isfile(input_nifti):
        raise FileNotFoundError(f"Input NIfTI not found: {input_nifti}")

    if not os.path.isfile(args.atlas_nifti):
        raise FileNotFoundError(f"Atlas NIfTI not found: {args.atlas_nifti}")

    # Per-subject output directory
    output_dir = os.path.join(args.output_root, sub)
    os.makedirs(output_dir, exist_ok=True)

    print(f"Subject: {sub}")
    print(f"Input NIfTI: {input_nifti}")
    print(f"Atlas NIfTI: {args.atlas_nifti}")
    print(f"Output directory: {output_dir}")

    # --- Load functional ---
    print("Loading functional NIfTI...")
    func_2d, spatial_shape = load_func_4d(input_nifti)
    T, V_all = func_2d.shape
    print(f"Functional data shape after flattening: T={T}, V_all={V_all}")

    # --- Load Schaefer atlas ---
    print("Loading Schaefer atlas NIfTI...")
    atlas_flat, labels = load_schaefer_atlas(args.atlas_nifti, spatial_shape)
    print(f"Atlas labels detected (excluding 0): {len(labels)} parcels")

    # --- GSBS parameters (shared across ROIs) ---
    statewise_detection = not args.no_statewise
    finetune_order = not args.finetune_strongest_first

    print("GSBS parameters:")
    print(f"  kmax               = {args.kmax}")
    print(f"  statewise_detection= {statewise_detection}")
    print(f"  finetune           = {args.finetune}")
    print(f"  finetune_order     = {'weakest->strongest' if finetune_order else 'strongest->weakest'}")
    print(f"  blocksize          = {args.blocksize}")
    print(f"  dmin               = {args.dmin}")

    # --- Run GSBS independently for each ROI (voxels as features) ---
    for i, lab in enumerate(labels):
        roi_label = int(lab)
        idx = atlas_flat == lab
        n_vox = int(np.sum(idx))

        if n_vox < 2:
            print(f"\n=== Skipping ROI label {roi_label} (index {i}) ===")
            print(f"  Not enough voxels for GSBS (n_vox={n_vox} < 2).")
            continue

        x_roi = func_2d[:, idx]  # (T, V_roi)
    # --- Parity filter --- #
        roi_std = np.std(x_roi, axis=0)
        valid_vox = roi_std > 0
        n_dropped = int((~valid_vox).sum())
        x_roi = x_roi[:, valid_vox]
        n_vox_valid = x_roi.shape[1]

        if n_dropped > 0:
            print(f"  Dropped {n_dropped}/{n_vox} zero-SD voxels in ROI {roi_label}")

        if n_vox_valid < 2:
            print(f"  Skipping ROI {roi_label}: only {n_vox_valid} valid voxels after SD filter.")
            continue

        print(f"\n=== Running GSBS for ROI label {roi_label} (index {i}) ===")
        print(f"  ROI voxel count (valid): {n_vox_valid} (of {n_vox} total)")
        print(f"  ROI time series matrix shape: {x_roi.shape}")

        gsbs = GSBS(
            kmax=args.kmax,
            x=x_roi,
            statewise_detection=statewise_detection,
            finetune=args.finetune,
            finetune_order=finetune_order,
            y=None,
            blocksize=args.blocksize,
            dmin=args.dmin,
        )

        print("  Calling GSBS.fit()...")
        gsbs.fit(showProgressBar=False)
        print("  GSBS.fit() complete for ROI", roi_label)

        nstates = gsbs.nstates
        deltas = gsbs.deltas         # 0/1 per TR
        states = gsbs.states         # state index per TR
        strengths = gsbs.strengths   # boundary strength per TR

        print(f"  nstates (ROI {roi_label}): {nstates}")

        roi_prefix = os.path.join(
            output_dir,
            f"{sub}_schaefer100_roi-{roi_label:03d}"
        )

        # Save arrays for this ROI
        np.save(f"{roi_prefix}_deltas.npy", deltas)
        np.save(f"{roi_prefix}_states.npy", states)
        np.save(f"{roi_prefix}_strengths.npy", strengths)

        # Human-readable summary for this ROI
        boundary_indices = np.where(deltas == 1)[0]
        with open(f"{roi_prefix}_summary.txt", "w") as f:
            f.write(f"roi_label: {roi_label}\n")
            f.write(f"nstates: {nstates}\n")
            f.write(f"T (timepoints): {T}\n")
            f.write(f"V_roi (voxels): {n_vox}\n")
            f.write(f"num_boundaries: {len(boundary_indices)}\n")
            f.write("boundary_TRs: " + ", ".join(map(str, boundary_indices)) + "\n")

        # Boundaries + strengths TSV for this ROI
        out_tsv = f"{roi_prefix}_boundaries.tsv"
        with open(out_tsv, "w") as f:
            f.write("TR\tboundary\tstrength\n")
            for tr in range(T):
                f.write(f"{tr}\t{int(deltas[tr])}\t{float(strengths[tr])}\n")

    print("\nDone: GSBS run separately for all ROIs (voxels as features).")


if __name__ == "__main__":
    main()
