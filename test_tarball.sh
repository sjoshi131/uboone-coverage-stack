#!/bin/bash
# test_tarball.sh <tarball> [ghep_input.root]
# Unpacks the tarball somewhere else and checks, in a clean environment, that it
# runs WITHOUT touching the original stack or build area -- i.e. as a grid job sees it.
# Run inside the SL7 container.
set -eo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${REPO}/config.sh"
TARBALL=$(readlink -f "$1"); INPUT=${2:+$(readlink -f "$2")}
[ -z "${INPUT}" ] || [ -f "${INPUT}" ] || { echo "smoke-test input not found: $2"; exit 1; }
[ -f "${TARBALL}" ] || { echo "usage: $0 <tarball> [ghep_input.root]"; exit 1; }

T="/exp/dune/data/users/${USER}/tartest/$(date +%Y%m%d_%H%M%S)"
mkdir -p "${T}" && cd "${T}"
tar xzf "${TARBALL}"
echo "[test] unpacked to ${T} ($(du -sh . | cut -f1))"

env -i HOME="${HOME}" USER="${USER}" PATH=/usr/bin:/bin TERM="${TERM}" \
    UNPACKED="${T}/$(basename "${STACK}")" ORIG_STACK="${STACK}" ORIG_WORK="${WORK}" INPUT="${INPUT}" \
    bash --noprofile --norc -c '
  set -e
  fail() { echo "[test] FAIL: $*"; exit 1; }
  source "${UNPACKED}/setup.sh"
  [ "${STACK}" = "${UNPACKED}" ] || fail "setup.sh resolved STACK=${STACK}"
  L=$(ldd "$(command -v nuissyst)")
  echo "${L}" | grep "not found" && fail "unresolved libraries"
  echo "${L}" | grep -E "${ORIG_STACK}|${ORIG_WORK}" && fail "binary still points at the original stack/build area"
  echo "${L}" | grep -E "libGRw|libGFwGHEP|nusystematics|systematicstools" | grep -v "${UNPACKED}" && fail "custom libs resolved outside the tarball"
  echo "[test] library resolution OK (custom libs from tarball, the rest from /cvmfs)"
  if [ -n "${INPUT}" ]; then
    "${STACK}/prepare_card.sh" "${COVERAGE_CARDS}/smoke_test_tier2.xml" "${INPUT}" smoke.xml
    set +e; nuissyst -c smoke.xml -o smoke.root -n 2000 > smoke.log 2>&1; rc=$?; set -e
    tail -15 smoke.log
    "${STACK}/check_output.sh" "${rc}" smoke.log smoke.root || fail "smoke run failed (log: $(pwd)/smoke.log)"
    echo "[test] smoke run OK: $(pwd)/smoke.root"
  fi
  echo "[test] TARBALL OK"
'
echo "[test] remove ${T} when done."
