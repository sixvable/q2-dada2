#!/usr/bin/env Rscript

###################################################
# This R script takes an input two directories of
# .fastq.gz files, corresponding to matched forward
# and reverse sequence files,
# and outputs a tsv file of the dada2 processed sequence
# table. It is intended for use with the QIIME2 plugin
# for DADA2.
#
# Rscript run_dada_paired.R input_dirF input_dirR output.tsv track.tsv filtered_dirF filtered_dirR 240 160 0 0 2.0 2 pooled 1.0 0 100000
####################################################

####################################################
#             DESCRIPTION OF ARGUMENTS             #
####################################################
# NOTE: All numeric arguments should be zero or positive.
# NOTE: All numeric arguments save maxEEF/R are expected to be integers.
# NOTE: Currently the filterered_dirF/R must already exist.
# NOTE: ALL ARGUMENTS ARE POSITIONAL!
#
### FILE SYSTEM ARGUMENTS ###
#
# 1) File path to directory with the FORWARD .fastq.gz files to be processed.
#    Ex: path/to/dir/with/FWD_fastqgzs
#
# 2) File path to directory with the REVERSE .fastq.gz files to be processed.
#    Ex: path/to/dir/with/REV_fastqgzs
#
# 3) File path to output tsv file. If already exists, will be overwritten.
#    Ex: path/to/output_file.tsv
#
# 4) File path to tracking tsv file. If already exists, will be overwritte.
#    Ex: path/to/tracking_stats.tsv
#
# 5) File path to directory to write the filtered FORWARD .fastq.gz files. These files are intermediate
#               for the full workflow. Currently they remain after the script finishes. Directory must
#               already exist.
#    Ex: path/to/dir/with/FWD_fastqgzs/filtered
#
# 6) File path to directory to write the filtered REVERSE .fastq.gz files. These files are intermediate
#               for the full workflow. Currently they remain after the script finishes. Directory must
#               already exist.
#    Ex: path/to/dir/with/REV_fastqgzs/filtered
#
### FILTERING ARGUMENTS ###
#
# 7) truncLenF - The position at which to truncate forward reads. Forward reads shorter
#               than truncLenF will be discarded.
#               Special values: 0 - no truncation or length filtering.
#    Ex: 240
#
# 8) truncLenR - The position at which to truncate reverse reads. Reverse reads shorter
#               than truncLenR will be discarded.
#               Special values: 0 - no truncation or length filtering.
#    Ex: 160
#
# 9) trimLeftF - The number of nucleotides to remove from the start of
#               each forward read. Should be less than truncLenF.
#    Ex: 0
#
# 10) trimLeftR - The number of nucleotides to remove from the start of
#               each reverse read. Should be less than truncLenR.
#    Ex: 0
#
# 11) maxEEF - Forward reads with expected errors higher than maxEEF are discarded.
#               Both forward and reverse reads are independently tested.
#    Ex: 2.0
#
# 12) maxEER - Reverse reads with expected errors higher than maxEER are discarded.
#               Both forward and reverse reads are independently tested.
#    Ex: 2.0
#
# 13) truncQ - Reads are truncated at the first instance of quality score truncQ.
#                If the read is then shorter than truncLen, it is discarded.
#    Ex: 2
#
### SENSITIVITY ARGUMENTS ###
#
# 14) poolMethod - The method used to pool (or not) samples during denoising.
#             Valid options are:
#               independent: (Default) No pooling, samples are denoised indpendently.
#               pseudo: Samples are "pseudo-pooled" for denoising.
#    Ex: independent
#
#
### CHIMERA ARGUMENTS ###
#
# 15) chimeraMethod - The method used to remove chimeras. Valid options are:
#               none: No chimera removal is performed.
#               pooled: All reads are pooled prior to chimera detection.
#               consensus: Chimeras are detect in samples individually, and a consensus decision
#                           is made for each sequence variant.
#    Ex: consensus
#
# 16) minParentFold - The minimum abundance of potential "parents" of a sequence being
#               tested as chimeric, expressed as a fold-change versus the abundance of the sequence being
#               tested. Values should be greater than or equal to 1 (i.e. parents should be more
#               abundant than the sequence being tested).
#    Ex: 1.0
#
### SPEED ARGUMENTS ###
#
# 17) nthreads - The number of threads to use.
#                 Special values: 0 - detect available and use all.
#    Ex: 1
#
# 18) nreads_learn - The minimum number of reads to learn the error model from.
#                 Special values: 0 - Use all input reads.
#    Ex: 1000000
#

cat(R.version$version.string, "\n")
errQuit <- function(mesg, status=1) { message("Error: ", mesg); q(status=status) }
getN <- function(x) sum(getUniques(x))
args <- commandArgs(TRUE)

# Assign each of the arguments, in positional order, to an appropriately named R variable
inp.dirF <- args[[1]]
inp.dirR <- args[[2]]
out.path <- args[[3]]
out.track <- args[[4]]
filtered.dirF <- args[[5]]
filtered.dirR <- args[[6]]
truncLenF <- as.integer(args[[7]])
truncLenR <- as.integer(args[[8]])
trimLeftF <- as.integer(args[[9]])
trimLeftR <- as.integer(args[[10]])
maxEEF <- as.numeric(args[[11]])
maxEER <- as.numeric(args[[12]])
truncQ <- as.integer(args[[13]])
minOverlap <- as.integer(args[14])
poolMethod <- args[[15]]
chimeraMethod <- args[[16]]
minParentFold <- as.numeric(args[[17]])
nthreads <- as.integer(args[[18]])
nreads.learn <- as.integer(args[[19]])

### VALIDATE ARGUMENTS ###

# Input directory is expected to contain .fastq.gz file(s)
# that have not yet been filtered and globally trimmed
# to the same length.
if(!(dir.exists(inp.dirF) && dir.exists(inp.dirR))) {
  errQuit("Input directory does not exist.")
} else {
  unfiltsF <- list.files(inp.dirF, pattern=".fastq.gz$", full.names=TRUE)
  unfiltsR <- list.files(inp.dirR, pattern=".fastq.gz$", full.names=TRUE)
  if(length(unfiltsF) == 0) {
    errQuit("No input forward files with the expected filename format found.")
  }
  if(length(unfiltsR) == 0) {
    errQuit("No input reverse files with the expected filename format found.")
  }
  if(length(unfiltsF) != length(unfiltsR)) {
    errQuit("Different numbers of forward and reverse .fastq.gz files.")
  }
}

# Output files are to be filenames (not directories) and are to be
# removed and replaced if already present.
for(fn in c(out.path, out.track)) {
  if(dir.exists(fn)) {
    errQuit("Output filename ", fn, " is a directory.")
  } else if(file.exists(fn)) {
    invisible(file.remove(fn))
  }
}

# Convert nthreads to the logical/numeric expected by dada2
if(nthreads < 0) {
  errQuit("nthreads must be non-negative.")
} else if(nthreads == 0) {
  multithread <- TRUE # detect and use all
} else if(nthreads == 1) {
  multithread <- FALSE
} else {
  multithread <- nthreads
}

### LOAD LIBRARIES ###
suppressWarnings(library(methods))
suppressWarnings(library(dada2))
cat("DADA2:", as.character(packageVersion("dada2")), "/",
    "Rcpp:", as.character(packageVersion("Rcpp")), "/",
    "RcppParallel:", as.character(packageVersion("RcppParallel")), "\n")

### TRIM AND FILTER ###
cat("1) Filtering ")
filtsF <- file.path(filtered.dirF, basename(unfiltsF))
filtsR <- file.path(filtered.dirR, basename(unfiltsR))
out <- suppressWarnings(filterAndTrim(unfiltsF, filtsF, unfiltsR, filtsR,
                                      truncLen=c(truncLenF, truncLenR), trimLeft=c(trimLeftF, trimLeftR),
                                      maxEE=c(maxEEF, maxEER), truncQ=truncQ, rm.phix=TRUE,
                                      multithread=multithread))
cat(ifelse(file.exists(filtsF), ".", "x"), sep="")
filtsF <- list.files(filtered.dirF, pattern=".fastq.gz$", full.names=TRUE)
filtsR <- list.files(filtered.dirR, pattern=".fastq.gz$", full.names=TRUE)
cat("\n")
if(length(filtsF) == 0) { # All reads were filtered out
  errQuit("No reads passed the filter (were truncLenF/R longer than the read lengths?)", status=2)
}

### LEARN ERROR RATES ###
# Dereplicate enough samples to get nreads.learn total reads
cat("2) Learning Error Rates\n")
errF <- suppressWarnings(learnErrors(filtsF, nreads=nreads.learn, multithread=multithread))
errR <- suppressWarnings(learnErrors(filtsR, nreads=nreads.learn, multithread=multithread))

### PROCESS ALL SAMPLES ###
# Loop over rest in streaming fashion with learned error rates
denoisedF <- rep(0, length(filtsF))
ddsF <- vector("list", length(filtsF))
ddsR <- vector("list", length(filtsF))
mergers <- vector("list", length(filtsF))
cat("3) Denoise samples ")

for(j in seq(length(filtsF))) {
  drpF <- derepFastq(filtsF[[j]])
  ddsF[[j]] <- dada(drpF, err=errF, multithread=multithread, verbose=FALSE)
  drpR <- derepFastq(filtsR[[j]])
  ddsR[[j]] <- dada(drpR, err=errR, multithread=multithread, verbose=FALSE)
  cat(".")
}
cat("\n")
if(poolMethod == "pseudo") {
  cat("  Pseudo-pool step ")
  ### TEMPORARY, to be removed once 1.12 makes its way to Q2
  ### Needed for now to manage pseudo-pooling memory, as 1.10 didn't do this appropriately.
  ### pseudo_priors code copied from dada2.R
  stF <- makeSequenceTable(ddsF)
  pseudo_priorsF <- colnames(stF)[colSums(stF>0) >= 2 | colSums(stF) >= Inf]
  rm(stF)
  stR <- makeSequenceTable(ddsR)
  pseudo_priorsR <- colnames(stR)[colSums(stR>0) >= 2 | colSums(stR) >= Inf]
  rm(stR)
  ### \pseudo_priors code copied from dada2.R
  ### code copied from previous loop through samples in this script
  for(j in seq(length(filtsF))) {
    drpF <- derepFastq(filtsF[[j]])
    ddsF[[j]] <- dada(drpF, err=errF, priors=pseudo_priorsF,
                      multithread=multithread, verbose=FALSE)
    drpR <- derepFastq(filtsR[[j]])
    ddsR[[j]] <- dada(drpR, err=errR, priors=pseudo_priorsR,
                      multithread=multithread, verbose=FALSE)
    cat(".")
  }
  cat("\n")
  ### \code copied from previous loop through samples in this script
}

### Now loop through and do merging
for(j in seq(length(filtsF))) {
  drpF <- derepFastq(filtsF[[j]])
  drpR <- derepFastq(filtsR[[j]])
  mergers[[j]] <- mergePairs(ddsF[[j]], drpF, ddsR[[j]], drpR, minOverlap=minOverlap)
  denoisedF[[j]] <- getN(ddsF[[j]])
  cat(".")
}
cat("\n")

# Make sequence table
seqtab <- makeSequenceTable(mergers)

# Remove chimeras
cat("4) Remove chimeras (method = ", chimeraMethod, ")\n", sep="")
if(chimeraMethod %in% c("pooled", "consensus")) {
  seqtab.nochim <- removeBimeraDenovo(seqtab, method=chimeraMethod, minFoldParentOverAbundance=minParentFold, multithread=multithread)
} else { # No chimera removal, copy seqtab to seqtab.nochim
  seqtab.nochim <- seqtab
}

### REPORT READ COUNTS AT EACH PROCESSING STEP ###
# Handle edge cases: Samples lost in filtering; One sample
track <- cbind(out, matrix(0, nrow=nrow(out), ncol=3))
colnames(track) <- c("input", "filtered", "denoised", "merged", "non-chimeric")
passed.filtering <- track[,"filtered"] > 0
track[passed.filtering,"denoised"] <- denoisedF
track[passed.filtering,"merged"] <- rowSums(seqtab)
track[passed.filtering,"non-chimeric"] <- rowSums(seqtab.nochim)
write.table(track, out.track, sep="\t", row.names=TRUE, col.names=NA,
	    quote=FALSE)

### WRITE OUTPUT AND QUIT ###
# Formatting as tsv plain-text sequence table table
cat("6) Write output\n")
seqtab.nochim <- t(seqtab.nochim) # QIIME has OTUs as rows
col.names <- basename(filtsF)
col.names[[1]] <- paste0("#OTU ID\t", col.names[[1]])
write.table(seqtab.nochim, out.path, sep="\t",
            row.names=TRUE, col.names=col.names, quote=FALSE)
saveRDS(seqtab.nochim, gsub("tsv", "rds", out.path)) ### TESTING

q(status=0)
