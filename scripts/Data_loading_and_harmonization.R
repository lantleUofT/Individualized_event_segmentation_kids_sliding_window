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


#--- Create output directory ---#
output_dir_s1  <- cfg$paths$output_dir_s1
dir.create(output_dir_s1, showWarnings = FALSE, recursive = TRUE)


#--- Set all file directories ---#
confound_dir   <- cfg$paths$confound_dir
behavioral_dir <- cfg$paths$behavioral_dir
phenotype_file <- cfg$paths$phenotype_file


#--- Set all parameters ---#
TR            <- 1:cfg$harmonization$TR_max
hrf_shift_tr  <- cfg$harmonization$hrf_shift_tr
n_dummy_tr    <- cfg$harmonization$n_dummy_tr
n_trs_stim    <- cfg$harmonization$n_trs_stim
smooth_window <- cfg$harmonization$smooth_window



###--- Load all data ---###

#confound data
conf_files <- list.files(confound_dir, pattern = "^sub-NDAR.*_confounds\\.1D$", full.names = TRUE)
confounds <- rbindlist(lapply(conf_files, function(f) {
  subj <- sub("_confounds\\.1D$", "", basename(f))
  dt <- fread(f, header = FALSE)
  data.table(
    subject                = subj,
    TR                     = seq_len(nrow(dt)),   
    framewise_displacement = as.numeric(dt$V5),
    std_dvars              = as.numeric(dt$V4)
  )
}), use.names = TRUE)

#behavioral data
filenames <- list.files(behavioral_dir, full.names = TRUE)
keep <- c("Participant", "TR", "continuous")
clean_data <- function(f) {
  fread(f, select = keep, na.strings = c("", "NA"))
}
behavior_raw_df <- rbindlist(lapply(filenames, clean_data), use.names = TRUE)

#phenotype data
pheno_df <- read.csv(phenotype_file)




###--- Data Harmonization pt1 (phenotype and confounds)---###

#mutate EID so it matches properly with the confounds data.table
pheno_df <- pheno_df %>%
  mutate(EID = ifelse(startsWith(EID, "sub-"), EID, paste0("sub-", EID)))

# rename EID to subject so it matches the confounds data.table
setDT(pheno_df)
setnames(pheno_df, "EID", "subject")

pheno_df <- unique(pheno_df, by = "subject")
stopifnot(!anyDuplicated(pheno_df$subject))

#keyed left join: keeping confound rows and attaching phenotype columns 
setkey(pheno_df, subject)
setkey(confounds, subject)

confounds_pheno <- pheno_df[confounds]
stopifnot(nrow(confounds_pheno) == nrow(confounds))

#Identify subjects with missing phenotype columns (should be none)
pheno_cols <- setdiff(names(pheno_df), "subject")
matched <- confounds_pheno[, .(matched = !all(is.na(.SD))),
                           by = subject, .SDcols = pheno_cols]

unmatched_ids <- matched[matched == FALSE, subject]
stopifnot(length(unmatched_ids) < dplyr::n_distinct(confounds$subject))

#drop unmatched subjects if they exist
confounds_pheno <- confounds_pheno[!subject %in% unmatched_ids]
stopifnot(!any(confounds_pheno$subject %in% unmatched_ids))

#print quick summary
cat(sprintf("Harmonization: %d subjects in, %d dropped (no phenotype), %d remain\n",
            dplyr::n_distinct(confounds$subject),
            length(unmatched_ids),
            dplyr::n_distinct(confounds_pheno$subject)))


###--- Data Harmonization pt2 (behavioral) ---###

#Convert the behavioral dataframe from a row per boundary to a 750TR time series
#timeseries: 1 at each TR a rater marked a boundary, 0 elsewhere.
behavior_ts_all <- purrr::map_dfr(unique(behavior_raw_df$Participant), function(p) {
  pdat <- filter(behavior_raw_df, Participant == p)
  tibble(
    norm_t      = as.integer(seq_along(TR) %in% pdat$TR),
    Participant = p,
    TR          = TR
  )
})

#Smooth individual raters data to preserve binary data post downsampling
#(spreads each spike across neighbouring TRs so it survives decimation).
behavioral_bounds_all <- behavior_ts_all %>%
  group_by(Participant) %>%
  mutate(norm_gaus = smth(norm_t,window = smooth_window, method = "gaussian"), 
         norm_gaus = replace_na(norm_gaus,0)) %>%
  ungroup() 

#resample & crop behavioral timeseries to match neural timeseries 
#(hrf + downsampling and cropping)
behavioral_bounds_all <- behavioral_bounds_all %>% 
  mutate(TR = TR+hrf_shift_tr)

toDelete <- seq(1, nrow(behavioral_bounds_all), 2)
behavioral_bounds_all <- behavioral_bounds_all[ toDelete, ]

behavioral_bounds_resamp <- behavioral_bounds_all %>% 
  filter(TR > n_dummy_tr & TR < n_trs_stim)  

#convert all behavioral timeseries into one group average timeseries
behavioral_bounds_resamp <- behavioral_bounds_resamp %>% 
  group_by(TR) %>%
  summarise(boundary_density = mean(norm_gaus))  

behavioral_bounds_resamp <- behavioral_bounds_resamp %>%
  arrange(TR) %>%             
  mutate(TR = row_number())   

#Second smoothing pass on the group-average timeseries
behavioral_bounds_resamp_smoothed <- behavioral_bounds_resamp %>%
  mutate(
    norm_resamp_gaus = smth(boundary_density, window = smooth_window, method = "gaussian"),
    norm_resamp_gaus = replace_na(norm_resamp_gaus, 0)
  )  



#--- Save Harmonized Files ---#
saveRDS(confounds_pheno, file.path(output_dir_s1, "confounds_pheno.rds"))
saveRDS(behavioral_bounds_resamp_smoothed, file.path(output_dir_s1, "behavioral_bounds_resamp_smoothed.rds"))




