#!/bin/bash
# merge_throws.sh <outdir> <card template> <ghep input> [merged.root]
# Merges all *.throws.root files from a campaign into one NUISANCE output with
# error_bands/, nominal_throw/, nominal/ and nominal_band/.
# Run inside the SL7 container after: source <stack>/setup.sh
set -eo pipefail
[ $# -ge 3 ] || { sed -n '2,6p' "$0"; exit 1; }
OUTDIR=$1; CARD=$2; INPUT=$3; MERGED=${4:-${OUTDIR%/}/merged.root}
command -v nuissyst >/dev/null || { echo "source the stack setup.sh first"; exit 1; }
if [ -f "${CARD}" ]; then CARD=$(readlink -f "${CARD}"); else CARD="${COVERAGE_CARDS}/${CARD}"; fi
INPUT=$(readlink -f "${INPUT}")

FILES=$(ls "${OUTDIR}"/*.throws.root)
N=$(echo "${FILES}" | wc -l)
NOM=$(ls "${OUTDIR}"/*_0000.root.throws.root 2>/dev/null || true)
[ -n "${NOM}" ] || { echo "job 0 output (holds 'nominal') is missing -- resubmit job 0"; exit 1; }
echo "[merge] ${N} throw files in ${OUTDIR}"

W=$(mktemp -d); cd "${W}"
"${STACK}/prepare_card.sh" "${CARD}" "${INPUT}" card.xml
nuissyst -c card.xml -o merged.root -n 1000 -f MergeErrors -p "$(echo ${FILES} | tr ' ' ',')" 2>&1 | tee merge.log
cp merged.root "${MERGED}"
echo "[merge] -> ${MERGED}"
