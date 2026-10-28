#!/bin/bash
# run_throws.sh -- grid job: generate one slice of throws (strategy ThrowErrors).
# Arguments (passed by submit_throws.sh):
#   $1 card       card template file name (in $CONDOR_DIR_INPUT if shipped with -f,
#                 otherwise in the tarball's cards/ directory)
#   $2 input      GENIE ghep file on /pnfs (copied to the worker with ifdh)
#   $3 nper       throws per job (>= 2)
#   $4 outdir     /pnfs output directory
#   $5 tag        name prefix for the output files
#   $6 maxevents  only the first N input events (0 or absent = all events)
#
# Job k (=$PROCESS) writes throws so that the union over jobs is 1..N*nper with
# no duplicates; only job 0 writes the "nominal" directory that MergeErrors needs.
#   k = 0 : -s 0         error_throws = nper     -> throw_1 .. throw_nper (+ nominal)
#   k > 0 : -s k*nper+1  error_throws = nper-1   -> throw_(k*nper+1) .. throw_((k+1)*nper)

set -o pipefail
CARD=$1; INPUT=$2; NPER=$3; OUTDIR=$4; TAG=$5; MAXEV=${6:-0}
K=${PROCESS:-0}
NOPT=(); [ "${MAXEV}" -gt 0 ] 2>/dev/null && NOPT=(-n "${MAXEV}")
echo "[job] host=$(hostname) process=${K} card=${CARD} input=${INPUT} nper=${NPER} outdir=${OUTDIR} maxevents=${MAXEV}"

STACKDIR=$(ls -d "${INPUT_TAR_DIR_LOCAL}"/*/ | head -1)
source "${STACKDIR}/setup.sh" || exit 10

WD="${_CONDOR_SCRATCH_DIR:-$PWD}/work"; mkdir -p "${WD}" && cd "${WD}" || exit 9
ifdh cp "${INPUT}" ./input.ghep.root || exit 11

if [ -f "${CONDOR_DIR_INPUT}/${CARD}" ]; then TMPL="${CONDOR_DIR_INPUT}/${CARD}"; else TMPL="${COVERAGE_CARDS}/${CARD}"; fi
"${STACK}/prepare_card.sh" "${TMPL}" "${PWD}/input.ghep.root" card.xml || exit 12

if [ "${K}" -eq 0 ]; then START=0; NT=${NPER}; else START=$(( K*NPER + 1 )); NT=$(( NPER - 1 )); fi
OUT="${TAG}_$(printf %04d "${K}").root"
echo "[job] start=${START} error_throws=${NT} -> ${OUT}.throws.root"

nuissyst -c card.xml -o "${OUT}" -f ThrowErrors -s "${START}" -q "error_throws=${NT}" "${NOPT[@]}" > nuissyst.log 2>&1
RC=$?
tail -30 nuissyst.log
# Always ship the log (compressed), so failed jobs can be diagnosed from /pnfs
gzip -c nuissyst.log > "${OUT}.log.gz" && ifdh cp "${OUT}.log.gz" "${OUTDIR}/logs/${OUT}.log.gz"

# NUISANCE writes an output file even when it aborts: check rc and FATAL lines,
# and never copy a bad file where merge_throws.sh would pick it up.
if [ "${RC}" -ne 0 ] || grep -q "ERR FATAL" nuissyst.log; then
  grep -m5 "ERR FATAL" nuissyst.log
  echo "[job] nuissyst FAILED (rc=${RC}); output not copied"; exit 13
fi
[ -s "${OUT}.throws.root" ] || { echo "[job] no ${OUT}.throws.root"; exit 13; }

ifdh cp "${OUT}.throws.root" "${OUTDIR}/${OUT}.throws.root" || exit 14
echo "[job] done"
