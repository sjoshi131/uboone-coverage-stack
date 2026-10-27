#!/bin/bash
# check_output.sh <nuissyst exit code> <nuissyst log> <output.root>
# Strict pass/fail check of a nuissyst ErrorBands run. NUISANCE writes an output
# file even when it aborts, so the file's existence alone proves nothing.
# Requires the stack environment (setup.sh) for ROOT.
rc=$1; log=$2; out=$3
fail() { echo "[check] FAIL: $*"; exit 1; }

[ "${rc}" -eq 0 ] || fail "nuissyst exited with code ${rc} (see ${log})"
if grep -q "ERR FATAL" "${log}"; then
  grep -m5 "ERR FATAL" "${log}"
  fail "nuissyst reported a FATAL error (see ${log})"
fi
[ -s "${out}" ] || fail "no output file ${out}"

mdir=$(mktemp -d); macro="${mdir}/check_dirs.C"   # ROOT calls the function named like the file
cat > "${macro}" <<'EOF'
#include "TFile.h"
#include "TDirectory.h"
#include "TKey.h"
#include "TH1.h"
#include "TString.h"
#include <cmath>
#include <cstdio>
int check_dirs(const char* fn) {
  // Values (bin contents) must be finite everywhere: FAIL otherwise.
  // Non-finite statistical ERRORS are reported as warnings: NUISANCE gives NaN
  // errors in bins with (almost) no MC events, which is expected in short smoke
  // tests but must not happen in a full-statistics production run.
  TFile f(fn);
  if (f.IsZombie()) { printf("[check] cannot open %s\n", fn); return 1; }
  int bad = 0, warn = 0;
  for (const char* d : {"nominal", "nominal_band", "nominal_throw", "error_bands"}) {
    TDirectory* D = (TDirectory*)f.Get(d);
    if (!D) { printf("[check] MISSING directory %s/\n", d); bad++; continue; }
    int nh = 0, nval = 0, nerr = 0;
    for (auto k : *D->GetListOfKeys()) {
      TH1* h = dynamic_cast<TH1*>(((TKey*)k)->ReadObj());
      if (!h) continue;
      nh++;
      int hv = 0, he = 0; TString cells;
      for (int i = 0; i < h->GetNcells(); i++) {
        bool v = !std::isfinite(h->GetBinContent(i)), e = !std::isfinite(h->GetBinError(i));
        if (v) hv++;
        if (e) he++;
        if (v || e) cells += TString::Format(" %d%s", i, v ? "(value)" : "");
      }
      if (hv || he) printf("[check]   %s %s/%s: non-finite cells%s\n", hv ? "BAD " : "warn", d, h->GetName(), cells.Data());
      nval += hv; nerr += he;
    }
    printf("[check] %-14s %3d histograms, %d non-finite values, %d non-finite errors\n", d, nh, nval, nerr);
    if (nh == 0 || nval > 0) bad++;
    if (nerr > 0) warn++;
  }
  printf("[check] RESULT bad=%d warn=%d\n", bad, warn);
  return bad;
}
EOF
res=$(root -l -b -q "${macro}(\"${out}\")" 2>&1 | grep "\[check\]")
rm -rf "${mdir}"
echo "${res}"
echo "${res}" | grep -q "RESULT bad=0" || fail "output incomplete: missing/empty directories or non-finite bin values"
if ! echo "${res}" | grep -q "warn=0"; then
  echo "[check] WARNING: some statistical errors are NaN/inf (cells listed above). Expected for"
  echo "[check]          bins with ~no MC events in short smoke tests; NOT acceptable in production."
fi
echo "[check] OK: ${out}"
