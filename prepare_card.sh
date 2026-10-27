#!/bin/bash
# prepare_card.sh <template card> <GENIE ghep input file> <output card>
# Fills the @INPUT_GHEP@ placeholder in a card template.
set -eo pipefail
[ $# -eq 3 ] || { echo "usage: $0 <template.xml> <ghep_input.root> <out.xml>"; exit 1; }
tmpl=$1; input=$2; out=$3
[ -f "${tmpl}" ]  || { echo "no such card: ${tmpl}"; exit 1; }
[ -f "${input}" ] || echo "[prepare_card] warning: ${input} does not exist (yet)"
grep -q "@INPUT_GHEP@" "${tmpl}" || { echo "[prepare_card] ${tmpl} has no @INPUT_GHEP@ placeholder"; exit 1; }
sed "s#@INPUT_GHEP@#${input}#g" "${tmpl}" > "${out}"
echo "[prepare_card] ${out} <- ${tmpl} with input ${input}"
