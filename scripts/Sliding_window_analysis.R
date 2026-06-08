#--- Import packages + yaml pathing ---#
libs = c("readr", "purrr", "tibble", "tidyr", "dplyr", "here", "yaml", "smoother", "data.table")
suppressPackageStartupMessages(
  invisible(lapply(libs, require, character.only = TRUE))
)

args <- commandArgs(trailingOnly = TRUE)
config_file <- if (length(args) >= 1) args[1] else "config.yaml"

cfg <- yaml::read_yaml(here::here(config_file))

cfg$paths <- lapply(cfg$paths, here::here)

#--- Define Input Directory ---#
output_dir_s1 <- cfg$paths$output_dir_s1


#--- Define and Create Output Directory ---#
output_dir_s2 <- cfg$paths$output_dir_s2
dir.create(output_dir_s2, showWarnings = FALSE, recursive = TRUE)


#--- Load all data ---#
confounds_pheno <- readRDS(file.path(output_dir_s1, "confounds_pheno.rds"))


#--- Set all parameters ---#
fd_threshold      <- cfg$sliding_window$fd_threshold
win_length        <- cfg$sliding_window$win_length
max_window_number <- cfg$sliding_window$max_window_number
dvars_threshold   <- cfg$sliding_window$dvars_threshold
adult_age_min <- cfg$sliding_window$adult_age_min
age_col       <- cfg$sliding_window$age_col
win_length_full <- cfg$sliding_window$win_length_full
max_w_num_full <- cfg$sliding_window$max_w_num_full


###--- Define Pick Best Windows Function ---###
pick_best_windows <- function(df_run, keys, win_len, max_win) {
  df_run <- df_run %>% arrange(TR)
  n_tr <- nrow(df_run)
  
  empty <- tibble(win_num = integer(), start_TR = integer(),
                  end_TR = integer(), mean_fd = double())
  
  k <- min(max_win, floor(n_tr / win_len))
  if (k == 0) return(empty)
  win_mean <- slider::slide_dbl(
    df_run$framewise_displacement, mean,
    .before = 0, .after = win_len - 1, .complete = TRUE
  )
  
  cand <- tibble(start_TR = df_run$TR, mean_fd = win_mean) %>%
    filter(!is.na(mean_fd)) %>%
    mutate(end_TR = start_TR + win_len - 1)
  
  m <- nrow(cand)
  if (m == 0) return(empty)

  next_ok <- findInterval(cand$start_TR + win_len - 1, cand$start_TR) + 1L
  
  INF <- Inf
  dp  <- matrix(INF, nrow = m + 1, ncol = k + 1)
  dp[, 1] <- 0                      
  choice <- matrix(0L, nrow = m + 1, ncol = k + 1) 
  
  for (i in m:1) {
    for (j in 2:(k + 1)) {          
      skip <- dp[i + 1, j]                                  
      take <- cand$mean_fd[i] + dp[min(next_ok[i], m + 1), j - 1]  
      if (take <= skip) {
        dp[i, j] <- take; choice[i, j] <- 1L
      } else {
        dp[i, j] <- skip; choice[i, j] <- 0L
      }
    }
  }
  
  # If we can't place k windows anywhere, fall back to as many as possible.
  if (is.infinite(dp[1, k + 1])) {
    feasible_k <- max(which(is.finite(dp[1, ]))) - 1
    if (feasible_k <= 0) return(empty)
    k <- feasible_k
  }
  
  # Backtrack from (i=1, j=k+1) to recover which candidates were taken.
  picked <- integer(0)
  i <- 1L; j <- k + 1L
  while (j > 1 && i <= m) {
    if (choice[i, j] == 1L) {
      picked <- c(picked, i)
      i <- next_ok[i]; j <- j - 1L
    } else {
      i <- i + 1L
    }
  }
  
  cand %>%
    slice(picked) %>%
    arrange(start_TR) %>%
    mutate(win_num = row_number()) %>%
    select(win_num, start_TR, end_TR, mean_fd)
}

###--- Define window selection function ---###
select_one_window_per_subject <- function(windows_df, confounds_df) {
  ref_mean <- mean(windows_df$mean_fd)
  
  selected <- windows_df %>%
    group_by(subject) %>%
    slice_min(abs(mean_fd - ref_mean), n = 1, with_ties = FALSE) %>%
    ungroup()
  
  keep_trs <- selected %>%
    rowwise() %>%
    summarise(subject = subject,
              TR = list(seq.int(start_TR, end_TR)),
              .groups = "drop") %>%
    unnest(TR)
  
  trimmed_confounds <- confounds_df %>%
    semi_join(keep_trs, by = c("subject", "TR"))
  
  list(windows = selected, confounds = trimmed_confounds)
}



###--- Apply Sliding Window Analysis To Truncated Timeseries---###

#Create table to apply sliding window analysis too
fd_by_tr <- confounds_pheno %>%
  distinct(subject, TR, framewise_displacement, std_dvars) %>%
  arrange(subject, TR)

#Group usable TRs into runs for use in pick best window function
good_trs_tagged <- fd_by_tr %>%
  group_by(subject) %>%
  mutate(
    is_good = coalesce(
      framewise_displacement <= fd_threshold & std_dvars <= dvars_threshold,
      FALSE
    ),
    run_id = cumsum(
      is_good != lag(is_good, default = first(is_good)) |
        TR != lag(TR, default = first(TR)) + 1
    )
  ) %>%
  filter(is_good) %>%
  ungroup()

#Select max_window_number best runs using the pick best windows function
best_windows <- good_trs_tagged %>%
  group_by(subject, run_id) %>%
  group_modify(~ pick_best_windows(.x, keys = .y, win_len = win_length, max_win = max_window_number)) %>%
  ungroup()

#Create a long table of every subject TR pair that falls inside the kept windows
good_trs <- best_windows %>%
  rowwise() %>%
  summarise(subject = subject, TR = list(seq.int(start_TR, end_TR))) %>%
  unnest(TR)

#Trim the confound dataset down to include only the kept windows
kept_windows_confounds <- confounds_pheno %>%
  semi_join(good_trs, by = c("subject", "TR")) %>%
  arrange(subject, TR)   

#extract windows pre age exclusion
best_windows_pre           <- best_windows
kept_windows_confounds_pre <- kept_windows_confounds



###--- Sliding window truncated version summary ---###
n_windows_kept  <- nrow(best_windows)
n_subjects_kept <- dplyr::n_distinct(best_windows$subject)
cat(sprintf("Sliding window truncated: %d windows kept across %d subjects\n",
            n_windows_kept, n_subjects_kept))



###--- Exclude participants aged 16+ for use as "adult" sample ---###

#create list of people 16+ who passed the sliding window
passed_participants_16_plus <- confounds_pheno %>%
  filter(subject %in% unique(best_windows$subject)) %>%
  distinct(subject, age = .data[[age_col]]) %>%
  filter(age >= adult_age_min) %>%
  arrange(subject)

readr::write_csv(passed_participants_16_plus, file.path(output_dir_s2, "subjects_pass_window_age16plus.csv"))



###--- Select best windows for child sample ---###

#remove excluded subjects from best_windows and kept_windows_confounds
best_windows_dev <- best_windows %>%
  anti_join(passed_participants_16_plus, by = "subject")

kept_windows_confounds_dev <- kept_windows_confounds %>%
  anti_join(passed_participants_16_plus, by = "subject")


#retain 1 window per subject with closest fwd to mean fwd
if (nrow(best_windows_dev) > 0) {
  dev_sel <- select_one_window_per_subject(best_windows_dev, kept_windows_confounds_dev)
  best_windows           <- dev_sel$windows
  kept_windows_confounds <- dev_sel$confounds
} else {
  cat("Note: no child subjects passed window selection; adult outputs will be empty.\n")
}


###--- Select best windows for adult sample ---###

#only include 16+ subjects in best_windows_adult and kept_windows_confounds
best_windows_adult <- best_windows_pre %>%
  semi_join(passed_participants_16_plus, by = "subject")

kept_windows_confounds_adult <- kept_windows_confounds_pre %>%
  semi_join(passed_participants_16_plus, by = "subject")

if (nrow(best_windows_adult) > 0) {
  adult_sel <- select_one_window_per_subject(best_windows_adult, kept_windows_confounds_adult)
  best_windows_adult           <- adult_sel$windows
  kept_windows_confounds_adult <- adult_sel$confounds
} else {
  cat("Note: no 16+ subjects passed window selection; adult outputs will be empty.\n")
}



###--- Apply Sliding Window Analysis to Full Timeseries ---#

#Select max_window_number best runs using the pick best windows function
best_windows_full <- good_trs_tagged %>%
  group_by(subject, run_id) %>%
  group_modify(~ pick_best_windows(.x, keys = .y, win_len = win_length_full, max_win = max_w_num_full)) %>%
  ungroup()

#Create a long table of every subject TR pair that falls inside the kept windows
good_trs_full <- best_windows_full %>%
  rowwise() %>%
  summarise(subject = subject, TR = list(seq.int(start_TR, end_TR))) %>%
  unnest(TR)

#Trim the confound dataset down to include only the kept windows
kept_windows_confounds_full <- confounds_pheno %>%
  semi_join(good_trs_full, by = c("subject", "TR")) %>%
  arrange(subject, TR)

#extract windows pre age exclusion
best_windows_pre_full           <- best_windows_full
kept_windows_confounds_pre_full <- kept_windows_confounds_full



###--- Sliding window summary ---###
n_windows_kept_full  <- nrow(best_windows_full)
n_subjects_kept_full <- dplyr::n_distinct(best_windows_full$subject)
cat(sprintf("Sliding window full: %d windows kept across %d subjects\n",
            n_windows_kept_full, n_subjects_kept_full))



###--- Exclude participants aged 16+ for use as "adult" sample ---###

#create list of people 16+ who passed the full sliding window
passed_participants_16_plus_full <- confounds_pheno %>%
  filter(subject %in% unique(best_windows_full$subject)) %>%
  distinct(subject, age = .data[[age_col]]) %>%
  filter(age >= adult_age_min) %>%
  arrange(subject)

readr::write_csv(passed_participants_16_plus_full, file.path(output_dir_s2, "subjects_pass_window_full_age16plus.csv"))



###--- Select best windows for child sample ---###

#remove excluded subjects from best_windows and kept_windows_confounds
best_windows_dev_full <- best_windows_full %>%
  anti_join(passed_participants_16_plus_full, by = "subject")

kept_windows_confounds_dev_full <- kept_windows_confounds_full %>%
  anti_join(passed_participants_16_plus_full, by = "subject")



###--- Select best windows for adult sample ---###

#only include 16+ subjects in best_windows_adult and kept_windows_confounds
best_windows_adult_full <- best_windows_pre_full %>%
  semi_join(passed_participants_16_plus_full, by = "subject")

kept_windows_confounds_adult_full <- kept_windows_confounds_pre_full %>%
  semi_join(passed_participants_16_plus_full, by = "subject")



###--- Save stage 2 outputs ---###
saveRDS(best_windows,            file.path(output_dir_s2, "best_windows_kids.rds"))
saveRDS(kept_windows_confounds,  file.path(output_dir_s2, "kept_windows_confounds_kids.rds"))
saveRDS(best_windows_adult,           file.path(output_dir_s2, "best_windows_adults.rds"))
saveRDS(kept_windows_confounds_adult, file.path(output_dir_s2, "kept_windows_confounds_adults.rds"))
saveRDS(best_windows_dev_full,             file.path(output_dir_s2, "best_windows_kids_full.rds"))
saveRDS(kept_windows_confounds_dev_full,   file.path(output_dir_s2, "kept_windows_confounds_kids_full.rds"))
saveRDS(best_windows_adult_full,           file.path(output_dir_s2, "best_windows_adults_full.rds"))
saveRDS(kept_windows_confounds_adult_full, file.path(output_dir_s2, "kept_windows_confounds_adults_full.rds"))
