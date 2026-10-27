#!/bin/bash
# package.sh -- turn the built stack into a grid tarball.
#   ./package.sh            -> <parent of $STACK>/coverage-stack.tar.gz
# Ships only what is needed at run time: installed libraries/binaries/headers,
# GENIE config/ + data/ (incl. Martini tensors), Reweight config/, NUISANCE,
# FHiCL, cards, sbndata, setup scripts. Sources, objects and the in-tree
# (duplicate) GENIE/Reweight libraries are excluded.
set -eo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${REPO}/config.sh"
[ -f "${STACK}/nuisance/bin/nuissyst" ] || { echo "stack not built: ${STACK}"; exit 1; }

PARENT=$(dirname "${STACK}"); TOP=$(basename "${STACK}")
OUT="${PARENT}/${TOP}.tar.gz"
cd "${PARENT}"
tar czf "${OUT}" \
  --exclude="${TOP}/local_install/GENIE-Generator/src" \
  --exclude="${TOP}/local_install/GENIE-Generator/lib" \
  --exclude="${TOP}/local_install/GENIE-Generator/bin" \
  --exclude="${TOP}/local_install/GENIE-Reweight/src" \
  --exclude="${TOP}/local_install/GENIE-Reweight/lib" \
  --exclude="${TOP}/local_install/GENIE-Reweight/bin" \
  --exclude='.git' --exclude='*.o' --exclude='*.d' \
  "${TOP}"
md5sum "${OUT}" > "${OUT}.md5"
echo "[package] $(ls -lh "${OUT}" | awk '{print $5}')  ${OUT}"
echo "[package] md5 $(cut -d' ' -f1 "${OUT}.md5")   stack version $(cat "${STACK}/STACK_VERSION")"
echo "[package] next: ./test_tarball.sh ${OUT} /path/to/ghep_input.root"
