#--- Import packages + yaml pathing ---#
libs = c("readr", "purrr", "tibble", "tidyr", "dplyr", "here", "yaml", "smoother", "data.table")
lapply(libs, require, character.only = TRUE)

cfg <- yaml::read_yaml(here::here("config.yaml"))

local_path <- here::here("config_local.yaml")
if (file.exists(local_path)) {
  local <- yaml::read_yaml(local_path)
  cfg <- modifyList(cfg, local)
}

cfg$paths <- lapply(cfg$paths, here::here)


#--- Define input directories ---#
output_dir_s1 <- cfg$paths$output_dir_s1
output_dir_s2 <- cfg$paths$output_dir_s2


#--- Define and create output directory ---#
output_dir_s3 <- cfg$paths$output_dir_s3
dir.create(output_dir_s3, showWarnings = FALSE, recursive = TRUE)


#--- Neural data file ---#
neural_file   <- cfg$paths$neural_file


#--- Set all parameters ---#
neural_tr_offset <- cfg$preprocessing$neural_tr_offset
smooth_window    <- cfg$preprocessing$smooth_window



###--- Load all data ---###
#stage 1 output: behavioral group-level boundary density (key col: norm_resamp_gaus)
behavioral_bounds_resamp_smoothed <- readRDS(file.path(output_dir_s1, "behavioral_bounds_resamp_smoothed.rds"))

#stage 2 output: confound data trimmed to selected motion windows
kept_windows_confounds <- readRDS(file.path(output_dir_s2, "kept_windows_confounds.rds"))

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



###--- Data Preprocessing (integration + smoothing) ---###
#Adjust the neural TR numbers to align with the confound window TR numbers
neural_df[, TR := TR + as.integer(neural_tr_offset)]

#Inner join the neural and confound window dataframes on subject and TR
neural_confound_extracted_windows_df <- neural_df %>% inner_join(kept_windows_confounds, by = c("subject","TR"))

#Smooth the extracted windows neural data
setDT(neural_confound_extracted_windows_df)
setorder(neural_confound_extracted_windows_df, subject, roi, TR)

neural_confound_extracted_windows_df[, `:=`(
  boundary_gaus  = replace_na(smth(boundary,  window = smooth_window, method = "gaussian"), 0),
  strength_gaus  = replace_na(smth(strength,  window = smooth_window, method = "gaussian"), 0),
  fwd_gaus   = replace_na(smth(framewise_displacement, window = smooth_window, method = "gaussian"), 0) 
), by = .(subject, roi)]

#Join the group-level behavioral boundary density by TR
neural_confound_extracted_windows_df <- neural_confound_extracted_windows_df %>%
  left_join(behavioral_bounds_resamp_smoothed %>% select(TR, norm_resamp_gaus), by = "TR")

#verify the behavioral join aligned (should be exactly 0)
na_frac <- mean(is.na(neural_confound_extracted_windows_df$norm_resamp_gaus))
cat("Fraction of neural rows with no behavioral match:", round(na_frac, 4), "\n")
stopifnot(na_frac == 0)



###--- Save stage 3 output ---###
saveRDS(neural_confound_extracted_windows_df,
        file.path(output_dir_s3, "neural_confound_extracted_windows_df.rds"))


