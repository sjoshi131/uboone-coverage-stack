#!/bin/bash
# submit_throws.sh -- submit a coverage-study throw campaign with jobsub_lite.
# Run on a dunegpvm (host shell, NOT inside the container), with a valid token:
#   htgettoken -a htvaultprod.fnal.gov -i dune
#
#   grid/submit_throws.sh <tarball> <card> <ghep_on_pnfs> <njobs> <throws_per_job> <tag>
#
#   <card>  either a card name inside the tarball (e.g. coverage_all_dials_tier2.xml)
#           or a path to a local card template (it is shipped with the job).
# Example: 400 throws as 20 jobs x 20 throws
#   grid/submit_throws.sh /exp/dune/app/users/$USER/coverage-stack.tar.gz \
#       coverage_all_dials_tier2.xml /pnfs/dune/scratch/users/$USER/inputs/ghep_AR23.root 20 20 alldials
set -eo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[ $# -eq 6 ] || { sed -n '2,15p' "$0"; exit 1; }
TARBALL=$(readlink -f "$1"); CARD=$2; INPUT=$3; NJOBS=$4; NPER=$5; TAG=$6
[ -f "${TARBALL}" ] || { echo "no tarball ${TARBALL}"; exit 1; }
[ "${NPER}" -ge 2 ] || { echo "throws_per_job must be >= 2"; exit 1; }

OUTDIR="/pnfs/dune/scratch/users/${USER}/coverage/${TAG}_$(date +%Y%m%d_%H%M)"
mkdir -p "${OUTDIR}/logs"

EXTRA=()
if [ -f "${CARD}" ]; then EXTRA+=(-f "dropbox://$(readlink -f "${CARD}")"); CARD=$(basename "${CARD}"); fi

jobsub_submit -G dune -N "${NJOBS}" \
  --memory=4000MB --disk=10GB --expected-lifetime=8h \
  --resource-provides=usage_model=DEDICATED,OPPORTUNISTIC \
  --singularity-image /cvmfs/singularity.opensciencegrid.org/fermilab/fnal-wn-sl7:latest \
  --tar_file_name "dropbox://${TARBALL}" \
  "${EXTRA[@]}" \
  "file://${REPO}/grid/run_throws.sh" "${CARD}" "${INPUT}" "${NPER}" "${OUTDIR}" "${TAG}"

echo "[submit] ${NJOBS} jobs x ${NPER} throws -> ${OUTDIR}"
echo "[submit] when finished: grid/merge_throws.sh ${OUTDIR} <card> <local ghep file>"
