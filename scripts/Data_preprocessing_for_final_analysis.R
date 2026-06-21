#--- Import packages + yaml pathing ---#
libs = c("readr", "purrr", "tibble", "tidyr", "dplyr", "here", "yaml", "smoother", "data.table")
suppressPackageStartupMessages(
  invisible(lapply(libs, require, character.only = TRUE))
)

args <- commandArgs(trailingOnly = TRUE)
config_file <- if (length(args) >= 1) args[1] else "config.yaml"

cfg <- yaml::read_yaml(here::here(config_file))

cfg$paths <- lapply(cfg$paths, here::here)


#--- Define input directories ---#
output_dir_s1 <- cfg$paths$output_dir_s1
output_dir_s2 <- cfg$paths$output_dir_s2


#--- Define and create output directory ---#
output_dir_s3 <- cfg$paths$output_dir_s3
dir.create(output_dir_s3, showWarnings = FALSE, recursive = TRUE)


#--- Neural data files ---#
neural_file   <- cfg$paths$neural_file_full
neural_partial_file <- cfg$paths$neural_file_partial

#--- Set all parameters ---#
neural_tr_offset <- cfg$preprocessing$neural_tr_offset
smooth_window    <- cfg$preprocessing$smooth_window



###--- Load all data ---###
#stage 1 output: behavioral group-level boundary density (key col: norm_resamp_gaus)
behavioral_bounds_resamp_smoothed <- readRDS(file.path(output_dir_s1, "behavioral_bounds_resamp_smoothed.rds"))

#stage 2 output: confound data trimmed to selected motion windows
kept_windows_confounds <- readRDS(file.path(output_dir_s2, "kept_windows_confounds_kids.rds"))
kept_windows_confounds_adult <- readRDS(file.path(output_dir_s2, "kept_windows_confounds_adults.rds"))
kept_windows_confounds_full       <- readRDS(file.path(output_dir_s2, "kept_windows_confounds_kids_full.rds"))
kept_windows_confounds_adult_full <- readRDS(file.path(output_dir_s2, "kept_windows_confounds_adults_full.rds"))

#stage 2 output: best windows for TR relabel for partial to account for GSBS reset
best_windows_kids   <- readRDS(file.path(output_dir_s2, "best_windows_kids.rds"))
best_windows_adults <- readRDS(file.path(output_dir_s2, "best_windows_adults.rds"))

#neural boundary data (subject x roi x TR)
neural_df <- fread(
  neural_file,
  sep = "\t",
  colClasses = c(
    subject  = "character",
    roi      = "integer",
    TR       = "integer",
    boundary = "integer",
    strength = "numeric"
  )
)

#partial timeseries neural boundary data
neural_partial_df <- fread(
  neural_partial_file,
  sep = "\t",
  colClasses = c(
    subject  = "character",
    roi      = "integer",
    TR       = "integer",
    boundary = "integer",
    strength = "numeric"
  )
)



#--- Relabel partial GSBS local TR (0-based, per-window) to real confound TR ---#
#No neural_tr_offset: start_TR is already in the confound timebase.
partial_starts <- data.table::rbindlist(
  list(best_windows_kids, best_windows_adults)
)[, .(subject, start_TR)]

#one window per subject post-selection — guard against accidental dupes
stopifnot(!any(duplicated(partial_starts$subject)))

setDT(neural_partial_df)
neural_partial_df <- merge(neural_partial_df, partial_starts, by = "subject", all.x = TRUE)

#fail loudly if any subject in the MASTER has no manifest window
n_unmapped <- neural_partial_df[is.na(start_TR), data.table::uniqueN(subject)]
if (n_unmapped > 0L) {
  stop(sprintf("%d partial subjects have no start_TR in best_windows manifests", n_unmapped))
}

neural_partial_df[, TR := start_TR + TR]
neural_partial_df[, start_TR := NULL]
neural_df[, TR := TR + as.integer(neural_tr_offset)]


###--- Data Preprocessing (integration + smoothing) ---###
#--- kids (full timeseries) ---#
#Inner join the neural and confound window dataframes on subject and TR
neural_confound_extracted_windows_full_df <- neural_df %>%
  inner_join(kept_windows_confounds_full, by = c("subject","TR"))

#Smooth the extracted windows neural data
setDT(neural_confound_extracted_windows_full_df)
setorder(neural_confound_extracted_windows_full_df, subject, roi, TR)

neural_confound_extracted_windows_full_df[, `:=`(
  boundary_gaus = replace_na(smth(boundary,                window = smooth_window, method = "gaussian")),
  strength_gaus = replace_na(smth(strength,                window = smooth_window, method = "gaussian")),
  fwd_gaus      = replace_na(smth(framewise_displacement,  window = smooth_window, method = "gaussian"))
), by = .(subject, roi)]


#--- kids (partial window) ---#
neural_confound_partial_df <- neural_partial_df %>%
  inner_join(kept_windows_confounds, by = c("subject","TR"))

setDT(neural_confound_partial_df)
setorder(neural_confound_partial_df, subject, roi, TR)

neural_confound_partial_df[, `:=`(
  boundary_gaus = replace_na(smth(boundary, window = smooth_window, method = "gaussian")),
  strength_gaus = replace_na(smth(strength, window = smooth_window, method = "gaussian")),
  fwd_gaus      = replace_na(smth(framewise_displacement, window = smooth_window, method = "gaussian"))
), by = .(subject, roi)]

neural_confound_partial_df <- neural_confound_partial_df %>%
  left_join(behavioral_bounds_resamp_smoothed %>% select(TR, norm_resamp_gaus), by = "TR")

na_frac_partial <- mean(is.na(neural_confound_partial_df$norm_resamp_gaus))
cat("Fraction of partial neural rows with no behavioral match (kids):", round(na_frac_partial, 4), "\n")
stopifnot(na_frac_partial == 0)



#--- adults (full timeseries) ---#
#Inner join the neural and confound window dataframes on subject and TR
neural_confound_extracted_windows_adult_full_df <- neural_df %>%
  inner_join(kept_windows_confounds_adult_full, by = c("subject","TR"))

#Smooth the extracted windows neural data
setDT(neural_confound_extracted_windows_adult_full_df)
setorder(neural_confound_extracted_windows_adult_full_df, subject, roi, TR)

neural_confound_extracted_windows_adult_full_df[, `:=`(
  boundary_gaus = replace_na(smth(boundary,                window = smooth_window, method = "gaussian")),
  strength_gaus = replace_na(smth(strength,                window = smooth_window, method = "gaussian")),
  fwd_gaus      = replace_na(smth(framewise_displacement,  window = smooth_window, method = "gaussian"))
), by = .(subject, roi)]


#Join the group-level behavioral boundary density by TR
neural_confound_extracted_windows_adult_full_df <- neural_confound_extracted_windows_adult_full_df %>%
  left_join(behavioral_bounds_resamp_smoothed %>% select(TR, norm_resamp_gaus), by = "TR")

#verify the behavioral join aligned (should be exactly 0)
na_frac_adult_full <- mean(is.na(neural_confound_extracted_windows_adult_full_df$norm_resamp_gaus))
cat("Fraction of full neural rows with no behavioral match (adults):", round(na_frac_adult_full, 4), "\n")
stopifnot(na_frac_adult_full == 0)



#--- adults (partial window) ---#
neural_confound_partial_adult_df <- neural_partial_df %>%
  inner_join(kept_windows_confounds_adult, by = c("subject","TR"))

setDT(neural_confound_partial_adult_df)
setorder(neural_confound_partial_adult_df, subject, roi, TR)

neural_confound_partial_adult_df[, `:=`(
  boundary_gaus = replace_na(smth(boundary, window = smooth_window, method = "gaussian")),
  strength_gaus = replace_na(smth(strength, window = smooth_window, method = "gaussian")),
  fwd_gaus      = replace_na(smth(framewise_displacement, window = smooth_window, method = "gaussian"))
), by = .(subject, roi)]

neural_confound_partial_adult_df <- neural_confound_partial_adult_df %>%
  left_join(behavioral_bounds_resamp_smoothed %>% select(TR, norm_resamp_gaus), by = "TR")

na_frac_partial_adult <- mean(is.na(neural_confound_partial_adult_df$norm_resamp_gaus))
cat("Fraction of partial neural rows with no behavioral match (adults):", round(na_frac_partial_adult, 4), "\n")
stopifnot(na_frac_partial_adult == 0)



#--- adult full timeseries group average (per ROI x TR) ---#
#Average smoothed boundary and strength across adult subjects, one value per ROI x TR
adult_full_group_avg <- neural_confound_extracted_windows_adult_full_df[
  , .(
    boundary_gaus_mean = mean(boundary_gaus, na.rm = TRUE),
    strength_gaus_mean = mean(strength_gaus, na.rm = TRUE),
    n_subj             = data.table::uniqueN(subject)
  ),
  by = .(roi, TR)
]
setorder(adult_full_group_avg, roi, TR)



###--- Save stage 3 output ---###
saveRDS(neural_confound_extracted_windows_full_df,
        file.path(output_dir_s3, "neural_confound_extracted_windows_full_df.rds"))
readr::write_csv(neural_confound_extracted_windows_full_df,
                 file.path(output_dir_s3, "neural_confound_extracted_windows_full_df.csv"))
saveRDS(neural_confound_extracted_windows_adult_full_df,
        file.path(output_dir_s3, "neural_confound_extracted_windows_adult_full_df.rds"))
readr::write_csv(neural_confound_extracted_windows_adult_full_df,
                 file.path(output_dir_s3, "neural_confound_extracted_windows_adult_full_df.csv"))
saveRDS(adult_full_group_avg,
        file.path(output_dir_s3, "adult_full_group_avg.rds"))
readr::write_csv(adult_full_group_avg,
                 file.path(output_dir_s3, "adult_full_group_avg.csv"))
saveRDS(neural_confound_partial_df,
        file.path(output_dir_s3, "neural_confound_partial_df.rds"))
readr::write_csv(neural_confound_partial_df,
                 file.path(output_dir_s3, "neural_confound_partial_df.csv"))
saveRDS(neural_confound_partial_adult_df,
        file.path(output_dir_s3, "neural_confound_partial_adult_df.rds"))
readr::write_csv(neural_confound_partial_adult_df,
                 file.path(output_dir_s3, "neural_confound_partial_adult_df.csv"))


