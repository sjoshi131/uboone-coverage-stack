#!/bin/bash
# submit_throws.sh -- submit a coverage-study throw campaign with jobsub_lite.
# Run on a dunegpvm (host shell, NOT inside the container), with a valid token:
#   htgettoken -a htvaultprod.fnal.gov -i dune
#
#   grid/submit_throws.sh [-n max_events] <tarball> <card> <ghep_on_pnfs> <njobs> <throws_per_job> <tag>
#
#   -n N    process only the first N events of the input in every job (default:
#           all events). Use it for quick grid tests; every job must use the same N,
#           and the merged result then describes only those N events.
#   <card>  either a card name inside the tarball (e.g. coverage_all_dials_tier2.xml)
#           or a path to a local card template (it is shipped with the job).
# Example: 400 throws as 20 jobs x 20 throws
#   grid/submit_throws.sh /exp/dune/app/users/$USER/coverage-stack.tar.gz \
#       coverage_all_dials_tier2.xml /pnfs/dune/scratch/users/$USER/inputs/ghep_AR23.root 20 20 alldials
# Quick grid test: 2 jobs x 3 throws on the first 200 events
#   grid/submit_throws.sh -n 200 /exp/dune/app/users/$USER/coverage-stack.tar.gz \
#       cards/smoke_test_tier2.xml /pnfs/dune/scratch/users/$USER/inputs/ghep_AR23.root 2 3 gridtest
set -eo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MAXEV=0
while getopts "n:" opt; do
  case "${opt}" in
    n) MAXEV=${OPTARG} ;;
    *) sed -n '2,20p' "$0"; exit 1 ;;
  esac
done
shift $((OPTIND - 1))
[[ "${MAXEV}" =~ ^[0-9]+$ ]] || { echo "-n needs a non-negative integer (0 = all events)"; exit 1; }
[ $# -eq 6 ] || { sed -n '2,20p' "$0"; exit 1; }
TARBALL=$(readlink -f "$1"); CARD=$2; INPUT=$3; NJOBS=$4; NPER=$5; TAG=$6
[ -f "${TARBALL}" ] || { echo "no tarball ${TARBALL}"; exit 1; }
[ "${NPER}" -ge 2 ] || { echo "throws_per_job must be >= 2"; exit 1; }

OUTDIR="/pnfs/dune/scratch/users/${USER}/coverage/${TAG}_$(date +%Y%m%d_%H%M)"
mkdir -p "${OUTDIR}/logs"
{ # record how this campaign was made, next to its outputs
  echo "date            $(date -u +%FT%TZ)"
  echo "tarball         ${TARBALL}  md5 $(md5sum "${TARBALL}" | cut -d' ' -f1)"
  echo "card            ${CARD}"
  echo "input           ${INPUT}"
  echo "jobs            ${NJOBS}"
  echo "throws_per_job  ${NPER}"
  echo "max_events      ${MAXEV}   (0 = all)"
} > "${OUTDIR}/campaign.txt"

EXTRA=()
if [ -f "${CARD}" ]; then EXTRA+=(-f "dropbox://$(readlink -f "${CARD}")"); CARD=$(basename "${CARD}"); fi

jobsub_submit -G dune -N "${NJOBS}" \
  --memory=4000MB --disk=10GB --expected-lifetime=8h \
  --resource-provides=usage_model=DEDICATED,OPPORTUNISTIC \
  --singularity-image /cvmfs/singularity.opensciencegrid.org/fermilab/fnal-wn-sl7:latest \
  --tar_file_name "dropbox://${TARBALL}" \
  "${EXTRA[@]}" \
  "file://${REPO}/grid/run_throws.sh" "${CARD}" "${INPUT}" "${NPER}" "${OUTDIR}" "${TAG}" "${MAXEV}"

echo "[submit] ${NJOBS} jobs x ${NPER} throws, events per job: $([ "${MAXEV}" -gt 0 ] && echo "${MAXEV}" || echo all) -> ${OUTDIR}"
echo "[submit] when finished: grid/merge_throws.sh ${OUTDIR} <card> <local ghep file>"
