#!/bin/bash
set -x

# Environment variables
# Required by numpy (in sparcc) to avoid issues with oversubscribing resources and CPU thrashing
export OMP_NUM_THREADS=1

# Parameters
RNG_SEED=0
MID_SAMPLE_COUNT=500
MID_OTU_COUNT=1000
SML_SAMPLE_COUNT=200
SML_OTU_COUNT=50
ITERATIONS=50
XITERATIONS=10

DATA_DIR=data
OUTPUT_DIR=output
PROFILE_DIR=profile
SOFTWARE_DIR=software
TEMP_DIR=temp

# Functions
function run_software {
  DATA_FP=$1
  DATA_MOTHUR_FP=$2
  FULL_OUTPUT_DIR=$3
  FULL_PROFILE_DIR=$4
  ITERATIONS=$5
  XITERATIONS=$6
  SAMPLES=$7
  OTUS=$8

  echo 'Fastspar (single thread)'
  /usr/bin/time -v ./software/fastspar/fastspar -c "${DATA_FP}" -r "${FULL_OUTPUT_DIR}"/fastspar_cor.tsv -a "${FULL_OUTPUT_DIR}"/fastspar_cov.tsv -i "${ITERATIONS}" -x "${XITERATIONS}" -y 2>"${FULL_PROFILE_DIR}"/fastspar_"${SAMPLES}"_"${OTUS}".txt 1>/dev/null

  echo 'Fastspar (10 threads)'
  /usr/bin/time -v ./software/fastspar/fastspar -c "${DATA_FP}" -r "${FULL_OUTPUT_DIR}"/fastspar_cor_threaded.tsv -a "${FULL_OUTPUT_DIR}"/fastspar_cov_threaded.tsv -i "${ITERATIONS}" -x "${XITERATIONS}" -t 10 -y 2>"${FULL_PROFILE_DIR}"/fastspar_threaded_"${SAMPLES}"_"${OTUS}".txt 1>/dev/null

  echo 'SparCC'
  /usr/bin/time -v python2 ./software/sparcc/SparCC.py -c "${FULL_OUTPUT_DIR}"/sparcc_cor.tsv -v "${FULL_OUTPUT_DIR}"/sparcc_cov.tsv -i "${ITERATIONS}" -x "${XITERATIONS}" "${DATA_FP}" 2>"${FULL_PROFILE_DIR}"/sparcc_"${SAMPLES}"_"${OTUS}".txt 1>/dev/null

  echo 'SpiecEasi SparCC'
  /usr/bin/time -v ./scripts/run_spieceasi.R "${ITERATIONS}" "${XITERATIONS}" "${DATA_FP}" "${FULL_OUTPUT_DIR}"/spieceasi_cor.tsv 2>"${FULL_PROFILE_DIR}"/spieceasi_"${SAMPLES}"_"${OTUS}".txt 1>/dev/null
  sed -i '1s/^/#OTU ID\t/' "${FULL_OUTPUT_DIR}"/spieceasi_cor.tsv

  echo 'Mothur SparCC'
  DATA_MOTHUR_FN="${DATA_MOTHUR_FP##*/}"
  MOTHUR_BASE_FP="${DATA_MOTHUR_FP%/*}/${DATA_MOTHUR_FN/.tsv/}.1.sparcc_"
  /usr/bin/time -v timeout --foreground 6h ./software/mothur/mothur "#sparcc(shared=${DATA_MOTHUR_FP}, samplings=${ITERATIONS}, iterations=${XITERATIONS}, permutations=0, processors=1)" 2>"${FULL_PROFILE_DIR}"/mothur_"${SAMPLES}"_"${OTUS}".txt 1>/dev/null
  mv "${MOTHUR_BASE_FP}correlation" "${FULL_OUTPUT_DIR}"/mothur_cor.tsv
  rm "${MOTHUR_BASE_FP}relabund"
  rm mothur.*.logfile
  sed -i '1s/^/#OTU ID/' "${FULL_OUTPUT_DIR}"/mothur_cor.tsv
}

# Provision software
MOTHUR_URL=https://github.com/mothur/mothur/releases/download/v1.40.3/Mothur.linux_64.zip
FASTSPAR_URL=https://github.com/scwatts/fastspar.git
SPARCC_URL=https://bitbucket.org/yonatanf/sparcc

echo 'Provisioning software'
mkdir -p "${TEMP_DIR}" "${SOFTWARE_DIR}"
{ git clone "${FASTSPAR_URL}" "${TEMP_DIR}"/fastspar/;
(cd "${TEMP_DIR}"/fastspar/; ./autogen.sh; ./configure --prefix=$(pwd -P); make install -j); } 2>/dev/null 1>&2
mv "${TEMP_DIR}"/fastspar/bin "${SOFTWARE_DIR}"/fastspar

hg clone "${SPARCC_URL}" software/sparcc 2>/dev/null 1>&2
(cd software/sparcc; hg checkout 05f4d3f) 2>/dev/null 1>&2

{ wget -P "${TEMP_DIR}" "${MOTHUR_URL}"
unzip temp/Mothur.linux_64.zip -d temp/; } 2>/dev/null 1>&2
mv "${TEMP_DIR}"/mothur "${SOFTWARE_DIR}"

R -e "install.packages(c('devtools', 'ggplot2', 'GGally'), repos='http://cran.rstudio.com/'); library(devtools); install_github('zdk123/SpiecEasi', ref='dea8763');" 2>/dev/null 1>&2

yes | rm -r temp/

# Provision data
OTU_TABLE_FP_GZ="${DATA_DIR}"/otu_table_cluster_99_collapsed.tsv.gz
OTU_TABLE_FP="${OTU_TABLE_FP_GZ/.gz/}"
MID_DATA_FP="${DATA_DIR}"/otu_table_subset_"${MID_SAMPLE_COUNT}"_"${MID_OTU_COUNT}".tsv
MID_DATA_MOTHUR_FP="${MID_DATA_FP/.tsv/_mothur.tsv}"
SML_DATA_FP="${DATA_DIR}"/otu_table_subset_"${SML_SAMPLE_COUNT}"_"${SML_OTU_COUNT}".tsv
SML_DATA_MOTHUR_FP="${SML_DATA_FP/.tsv/_mothur.tsv}"

echo 'Generating data subset'
gzip -d "${OTU_TABLE_FP_GZ}"
./scripts/generate_random_subsets.py -c "${OTU_TABLE_FP}" -a "${SML_SAMPLE_COUNT}" -t "${SML_OTU_COUNT}" -s "${RNG_SEED}" > "${SML_DATA_FP}"
./scripts/biom_tsv_to_mothur.py --input_fp "${SML_DATA_FP}" > "${SML_DATA_MOTHUR_FP}"
./scripts/generate_random_subsets.py -c "${OTU_TABLE_FP}" -a "${MID_SAMPLE_COUNT}" -t "${MID_OTU_COUNT}" -s "${RNG_SEED}" > "${MID_DATA_FP}"
./scripts/biom_tsv_to_mothur.py --input_fp "${MID_DATA_FP}" > "${MID_DATA_MOTHUR_FP}"

# Run software
mkdir -p {"${OUTPUT_DIR}","${PROFILE_DIR}"}/{mid,small}
echo 'Small dataset, for results comparison'
run_software "${SML_DATA_FP}" "${SML_DATA_MOTHUR_FP}" "${OUTPUT_DIR}"/small "${PROFILE_DIR}"/small "${ITERATIONS}" "${XITERATIONS}" "${SML_SAMPLE_COUNT}" "${SML_OTU_COUNT}"

echo 'Mid-sized dataset, for profiling'
run_software "${MID_DATA_FP}" "${MID_DATA_MOTHUR_FP}" "${OUTPUT_DIR}"/mid "${PROFILE_DIR}"/mid "${ITERATIONS}" "${XITERATIONS}" "${MID_SAMPLE_COUNT}" "${MID_OTU_COUNT}"

# Collect data
./scripts/collect_profile_data.py --profile_log_fps "${PROFILE_DIR}"/mid/*txt --output "${OUTPUT_DIR}"/profiles.tsv

# Generate plots
./scripts/plot_correlation.R output/small/*cor.tsv
./scripts/plot_profile.R output/profiles.tsv
