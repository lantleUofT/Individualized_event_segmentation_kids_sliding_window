#--- Import packages + yaml pathing ---#
libs = c("readr", "purrr", "tibble", "tidyr", "dplyr", "here", "yaml", "smoother", "data.table")
suppressPackageStartupMessages(
  invisible(lapply(libs, require, character.only = TRUE))
)

cfg <- yaml::read_yaml(here::here("config.yaml"))

local_path <- here::here("config_local.yaml")
if (file.exists(local_path)) {
  local <- yaml::read_yaml(local_path)
  cfg <- modifyList(cfg, local)
}

cfg$paths <- lapply(cfg$paths, here::here)

#--- Define input directory ---#
output_dir_s3 <- cfg$paths$output_dir_s3

#--- Define and create output directory ---#
output_dir_s4 <- cfg$paths$output_dir_s4
dir.create(output_dir_s4, showWarnings = FALSE, recursive = TRUE)

#--- Final analysis neural data file ---#
neural_confound_extracted_windows_df <- readRDS(file.path(output_dir_s3, "neural_confound_extracted_windows_df.rds"))

#--- Set all parameters ---#
high_motion_TR_threshold <- cfg$validation$high_motion_tr_threshold
fdr_method <- cfg$validation$fdr_method
fdr_alpha <- cfg$validation$fdr_alpha


###--- Motion location x boundary location correlation analysis ---###
#correlate motion against boundary strength within each subject x Roi
cor_stats_indiv_mot <- neural_confound_extracted_windows_df %>%
  group_by(subject, roi) %>%
  group_modify(~ {
    ct <- cor.test(.x$fwd_gaus, .x$strength_gaus, method = "kendall")
    tibble(mot_neur_tau = unname(ct$estimate), mot_neur_p_val = ct$p.value)
  }) %>%
  ungroup()

#collapse each subject to a single correlation value
mot_neur_subject <- cor_stats_indiv_mot %>%
  group_by(subject) %>%
  summarize(mot_neur_tau_z = mean(DescTools::FisherZ(mot_neur_tau), na.rm = TRUE),
            .groups = "drop")

#one sample t.test against 0 on transformed values
mot_ttest <- t.test(mot_neur_subject$mot_neur_tau_z)
cat(sprintf("Motion x boundary (subject-level): t(%.0f) = %.2f, p = %.3f, mean z = %.4f\n",
            mot_ttest$parameter, mot_ttest$statistic, mot_ttest$p.value,
            mot_ttest$estimate))

#average each subjects per-ROI correlations into a raw tau per subject
mot_neur_subject_raw <- cor_stats_indiv_mot %>%
  group_by(subject) %>%
  summarize(mot_neur_tau = mean(mot_neur_tau, na.rm = TRUE), .groups="drop")

#print the distribution of raw per subject tau
cat(sprintf("Per-subject raw tau: mean = %.4f, median = %.4f, range [%.4f, %.4f]\n",
            mean(mot_neur_subject_raw$mot_neur_tau),
            median(mot_neur_subject_raw$mot_neur_tau),
            min(mot_neur_subject_raw$mot_neur_tau),
            max(mot_neur_subject_raw$mot_neur_tau)))




###--- # high motion TR x average event boundary count correlation ---###
# Count raw boundaries per subject × ROI
bounds_per_roi <- neural_confound_extracted_windows_df %>%
  group_by(subject, roi) %>%
  summarize(n_boundaries = sum(boundary, na.rm = TRUE), .groups = "drop")

# Average boundaries across ROIs (per subject)
bounds_avg_subj <- bounds_per_roi %>%
  group_by(subject) %>%
  summarize(mean_boundaries = mean(n_boundaries), .groups = "drop")

# Number of high motion TRs per subject
# (roi == 1 picks one ROI's rows so each TR's motion is counted once because FD is identical across ROIs)
high_motion_trs <- neural_confound_extracted_windows_df %>%
  filter(roi == 1) %>%
  group_by(subject) %>%
  summarize(n_high_motion_TRs = sum(framewise_displacement > high_motion_TR_threshold, na.rm = TRUE),
            .groups = "drop")

# Join average boundaries per subject and high motion TRs per subject
motion_boundary_df <- bounds_avg_subj %>%
  left_join(high_motion_trs, by = "subject")

#pearson correlation
pearson_res <- cor.test(motion_boundary_df$mean_boundaries,
                        motion_boundary_df$n_high_motion_TRs,
                        method = "pearson")

#print the output
cat(sprintf("High-motion TRs x mean boundaries: r = %.5f, t(%.0f) = %.5f, p = %.5f, n = %d\n",
            pearson_res$estimate, pearson_res$parameter, pearson_res$statistic,
            pearson_res$p.value, nrow(motion_boundary_df)))




###--- Pearson correlation behavioral vs neural boundary timeseries (grouped ROIs) ---###
#pooled sample (kids + adults) for behavioral-neural analyses
neural_confound_extracted_windows_pooled_df <- dplyr::bind_rows(
  neural_confound_extracted_windows_df,
  neural_confound_extracted_windows_adult_df
)

#correlate behavioral boundary density against boundary strength within each subject x ROI
cor_stats_indiv_beh <- neural_confound_extracted_windows_pooled_df %>%
  group_by(subject, roi) %>%
  group_modify(~ {
    ct <- cor.test(.x$norm_resamp_gaus, .x$strength_gaus, method = "pearson")
    tibble(beh_neur_r = unname(ct$estimate), beh_neur_p_val = ct$p.value)
  }) %>%
  ungroup()

#collapse each subject to a single (Fisher-z'd) correlation value
beh_neur_subject <- cor_stats_indiv_beh %>%
  group_by(subject) %>%
  mutate(beh_neur_r_z = DescTools::FisherZ(beh_neur_r)) %>%
  summarize(
    beh_neur_r_z = mean(beh_neur_r_z, na.rm = TRUE),
    .groups = "drop"
  )

#one sample t-test against 0 on transformed values
beh_ttest <- t.test(beh_neur_subject$beh_neur_r_z)
cat(sprintf("Behavioral x neural (subject-level): t(%.0f) = %.2f, p = %.3g, mean z = %.4f\n",
            beh_ttest$parameter, beh_ttest$statistic, beh_ttest$p.value,
            beh_ttest$estimate))

#average each subject's per-ROI correlations into a raw r per subject
beh_neur_subject_raw <- cor_stats_indiv_beh %>%
  group_by(subject) %>%
  summarize(beh_neur_r = mean(beh_neur_r, na.rm = TRUE), .groups = "drop")

#print the distribution of raw per-subject correlations
cat(sprintf("Per-subject raw r: mean = %.4f, median = %.4f, range [%.4f, %.4f]\n",
            mean(beh_neur_subject_raw$beh_neur_r),
            median(beh_neur_subject_raw$beh_neur_r),
            min(beh_neur_subject_raw$beh_neur_r),
            max(beh_neur_subject_raw$beh_neur_r)))




###--- Pearson correlation behavioral vs neural boundary timeseries (Individual ROIs) ---###
#correlate behavioral density against boundary strength per subject x ROI
cor_subject_roi_beh <- neural_confound_extracted_windows_pooled_df %>%
  group_by(subject, roi) %>%
  group_modify(~ {
    x <- .x$norm_resamp_gaus
    y <- .x$strength_gaus
    ok <- complete.cases(x, y)
    x <- x[ok]; y <- y[ok]
    if (length(x) < 3 || sd(x) == 0 || sd(y) == 0) {       # r undefined
      return(tibble(beh_neur_r = NA_real_, beh_neur_p_val = NA_real_))
    }
    ct <- cor.test(x, y, method = "pearson")               # computed once
    tibble(beh_neur_r = unname(ct$estimate), beh_neur_p_val = ct$p.value)
  }) %>%
  ungroup()

#Aggregate to ROI level Fisher-Z and conduct a one sample t-test per ROI (BH_FDR corretion)
roi_results_all <- cor_subject_roi_beh %>%
  mutate(beh_neur_r_z = DescTools::FisherZ(beh_neur_r)) %>%
  group_by(roi) %>%
  group_modify(~ {
    z <- .x$beh_neur_r_z[is.finite(.x$beh_neur_r_z)]
    n <- length(z)
    if (n < 2 || sd(z) == 0) {
      return(tibble(
        n_subj = n,
        mean_r = mean(.x$beh_neur_r, na.rm = TRUE),
        mean_r_z = if (n) mean(z) else NA_real_,
        t_stat = NA_real_, df = NA_real_, p_val = NA_real_,
        ci_low = NA_real_, ci_high = NA_real_
      ))
    }
    tt <- t.test(z)
    tibble(
      n_subj   = n,
      mean_r   = mean(.x$beh_neur_r, na.rm = TRUE),
      mean_r_z = unname(tt$estimate),
      t_stat   = unname(tt$statistic),
      df       = unname(tt$parameter),
      p_val    = tt$p.value,
      ci_low   = tt$conf.int[1],
      ci_high  = tt$conf.int[2]
    )
  }) %>%
  ungroup() %>%
  mutate(p_fdr = p.adjust(p_val, method = fdr_method)) %>%
  arrange(p_fdr)  

#significant ROIs after FDR correction
roi_results_sig <- roi_results_all %>%
  filter(p_fdr < fdr_alpha) %>%
  arrange(p_fdr) %>%
  select(roi, n_subj, mean_r, t_stat, df, p_val, p_fdr, ci_low, ci_high)

#print results
cat(sprintf("ROI-level behavioral-neural: %d of %d ROIs significant after BH-FDR (p < .05)\n",
            nrow(roi_results_sig), nrow(roi_results_all)))




###--- Save analysis results ---###
saveRDS(roi_results_all, file.path(output_dir_s4, "roi_results_all.rds"))
readr::write_csv(roi_results_all, file.path(output_dir_s4, "roi_results_all.csv"))
readr::write_csv(roi_results_sig, file.path(output_dir_s4, "roi_results_sig.csv"))

