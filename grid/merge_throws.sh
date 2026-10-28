#!/bin/bash
# merge_throws.sh <outdir> [merged.root]
# merge_throws.sh --nuissyst <outdir> <card template> <ghep input> [merged.root]
# Merges all *.throws.root files from a campaign into one NUISANCE output with
# error_bands/, nominal_throw/, nominal/ and nominal_band/.
# Default: grid/fast_merge.py (reads only the throw files; seconds, no events).
# --nuissyst: the original 'nuissyst -f MergeErrors' (loads card, FHiCL and events;
#             slow with the production FHiCL). Both give bit-identical results.
# Run inside the SL7 container (started with /pnfs bound!) after: source <stack>/setup.sh
set -eo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
die() { echo "[merge] ERROR: $*" >&2; exit 1; }
usage() { sed -n '2,9p' "$0"; exit 1; }
USE_NUISSYST=0
[ "$1" = "--nuissyst" ] && { USE_NUISSYST=1; shift; }
if [ ${USE_NUISSYST} -eq 1 ]; then
  [ $# -ge 3 ] || usage
  OUTDIR=${1%/}; CARD=$2; INPUT=$3; MERGED=${4:-${OUTDIR}/merged.root}
else
  [ $# -ge 1 ] && [ $# -le 2 ] || usage
  OUTDIR=${1%/}; MERGED=${2:-${OUTDIR}/merged.root}
fi

[ -n "${STACK}" ] || die "stack environment not set: source the stack setup.sh first"
case "${OUTDIR}${INPUT}${MERGED}" in
  */pnfs/*) [ -d /pnfs/dune ] || die "/pnfs is not visible here: start the container with -B /cvmfs,/exp,/nashome,/pnfs" ;;
esac
[ -d "${OUTDIR}" ] || die "campaign directory not found: ${OUTDIR}"
OUTDIR=$(readlink -f "${OUTDIR}")
[ -d "$(dirname "${MERGED}")" ] || die "output directory does not exist: $(dirname "${MERGED}") (mkdir -p it first)"
MERGED="$(readlink -f "$(dirname "${MERGED}")")/$(basename "${MERGED}")"

shopt -s nullglob
FILES=( "${OUTDIR}"/*_0000.root.throws.root )
[ ${#FILES[@]} -gt 0 ] || die "job 0 output (*_0000.root.throws.root, holds 'nominal') is missing -- resubmit job 0"
for f in "${OUTDIR}"/*.throws.root; do [ "${f}" = "${FILES[0]}" ] || FILES+=( "${f}" ); done   # job 0 first
shopt -u nullglob
[ ${#FILES[@]} -gt 0 ] || die "no *.throws.root files in ${OUTDIR} -- are the jobs finished? (jobsub_q -G dune --user ${USER})"
echo "[merge] ${#FILES[@]} throw files in ${OUTDIR}"
[ -f "${OUTDIR}/campaign.txt" ] && sed 's/^/[merge]   /' "${OUTDIR}/campaign.txt"

W=$(mktemp -d); cd "${W}"
echo "[merge] working directory (merge.log): ${W}"
set +e
if [ ${USE_NUISSYST} -eq 1 ]; then
  command -v nuissyst >/dev/null || die "nuissyst not found"
  if [ -f "${CARD}" ]; then CARD=$(readlink -f "${CARD}"); else CARD="${COVERAGE_CARDS}/${CARD}"; fi
  [ -f "${CARD}" ] || die "card not found: ${CARD}"
  [ -f "${INPUT}" ] || die "input file not found: ${INPUT}"
  "${STACK}/prepare_card.sh" "${CARD}" "$(readlink -f "${INPUT}")" card.xml || die "prepare_card failed"
  LIST=$(IFS=,; echo "${FILES[*]}")
  nuissyst -c card.xml -o merged.root -n 1000 -f MergeErrors -p "${LIST}" > merge.log 2>&1
  RC=$?
  grep -v "DEBUG CalcWeightZExp" merge.log | tail -5
else
  python3 -c "import ROOT" >/dev/null 2>&1 || die "python3 cannot import ROOT in this environment; use --nuissyst"
  python3 "${HERE}/fast_merge.py" -o merged.root "${FILES[@]}" 2>&1 | tee merge.log
  RC=${PIPESTATUS[0]}
fi
set -e
"${STACK}/check_output.sh" "${RC}" merge.log merged.root || die "merge failed (log: ${W}/merge.log)"
cp merged.root "${MERGED}"
[ -f "${OUTDIR}/campaign.txt" ] && [ "$(dirname "${MERGED}")" != "${OUTDIR}" ] && cp "${OUTDIR}/campaign.txt" "${MERGED%.root}.campaign.txt"
echo "[merge] -> ${MERGED}"
