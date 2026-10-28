#!/usr/bin/env python3
"""fast_merge.py -o merged.root throws_0000.root.throws.root [more.throws.root ...]

Merges nuissyst throw files WITHOUT starting nuissyst (no card, no FHiCL, no
events, no reweighting). Reproduces SystematicRoutines::MergeThrows (incl. the
nominal patch) exactly:

  error_bands/<plot>              throw mean, error = throw spread (TProfile "S")
  error_bands/<plot>_prof         the TProfile
  error_bands/<plot>_tree         one entry per throw, branches content_<i>
  error_bands/<plot>_nominal      nominal prediction
  error_bands/<plot>_nominal_vec  nominal bin contents (TVectorD)
  nominal_throw/<plot>            throw mean, error = stat (+) spread
  nominal/<plot>                  nominal prediction, stat errors
  nominal_band/<plot>             nominal, error = stat (+) RMS of throws about nominal

<plot> = every TH1D/TH2D in the 'nominal' directory of the file that has one
(job 0). Throws are read in the order the files are given, and in key order
inside each file, as nuissyst does. Needs only ROOT with PyROOT (the stack's
setup.sh provides it).
"""
import argparse
import math
import re
import sys
from array import array

import ROOT

ROOT.gROOT.SetBatch(True)
ROOT.TH1.AddDirectory(False)


def die(msg):
    sys.exit("[fast_merge] ERROR: " + msg)


def open_throw_file(path):
    """Same lookup as nuissyst: <path>, else <path>.throws.root. None if unreadable."""
    for p in (path, path + ".throws.root"):
        f = ROOT.TFile.Open(p, "READ")
        if f and not f.IsZombie():
            return p, f
    return None, None


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("-o", "--output", required=True, help="merged output file (overwritten)")
    ap.add_argument("files", nargs="+", help="throw files (*.throws.root), job 0 first")
    a = ap.parse_args()

    # --- check inputs and find the file with 'nominal' ---
    good, nominalfile = [], None
    for path in a.files:
        p, f = open_throw_file(path)
        if f is None:
            print(f"[fast_merge] WARNING: cannot read {path}, skipped", file=sys.stderr)
            continue
        good.append(p)
        if f.Get("nominal"):
            nominalfile = p  # nuissyst keeps the LAST file holding 'nominal'
        f.Close()
    if not good:
        die("no readable throw files")
    if len(a.files) - len(good) > 0.25 * len(a.files):
        print("[fast_merge] WARNING: over 25% of the throw files are unreadable", file=sys.stderr)
    if nominalfile is None:
        die("no file contains a 'nominal' directory (job 0 output missing?)")
    print(f"[fast_merge] {len(good)} throw files; nominal from {nominalfile}")

    # --- plots to merge: TH1D/TH2D keys of nominal/, in key order ---
    nf = ROOT.TFile.Open(nominalfile, "READ")
    nomdir = nf.Get("nominal")
    plots = []
    for key in nomdir.GetListOfKeys():
        cl = ROOT.gROOT.GetClass(key.GetClassName())
        if not (cl.InheritsFrom("TH1D") or cl.InheritsFrom("TH2D")):
            continue
        h = key.ReadObj()
        h.SetDirectory(0)
        name = h.GetName()
        nbins = h.GetNbinsX() if cl.InheritsFrom("TH1D") else h.GetNbinsX() * h.GetNbinsY()
        plots.append(dict(name=name, base=h, nbins=nbins,
                          nom=[h.GetBinContent(j + 1) for j in range(nbins)]))
    nf.Close()
    if not plots:
        die("no TH1D/TH2D in nominal/")

    out = ROOT.TFile(a.output, "RECREATE")
    d_err = out.mkdir("error_bands")
    d_nt = out.mkdir("nominal_throw")
    d_cv = out.mkdir("nominal")
    d_band = out.mkdir("nominal_band")

    d_err.cd()
    for p in plots:
        n, nb = p["name"], p["nbins"]
        p["prof"] = ROOT.TProfile(n + "_prof", n + "_prof", nb, 0, nb, "S")
        p["prof"].SetDirectory(d_err)
        p["tree"] = ROOT.TTree(n + "_tree", n + "_tree")
        p["buf"] = [array("d", [0.0]) for _ in range(nb)]
        for i in range(nb):
            p["tree"].Branch(f"content_{i}", p["buf"][i], f"content_{i}/D")
        p["sumsq"] = [0.0] * nb
        p["nused"] = 0

    # --- one pass over the throw files (nuissyst re-reads every file per plot) ---
    seen = {}
    for path in good:
        f = ROOT.TFile.Open(path, "READ")
        nthr = 0
        for key in f.GetListOfKeys():
            kname = key.GetName()
            if "throw_" not in kname:
                continue
            m = re.fullmatch(r"throw_(\d+)", kname)
            if m:
                seen.setdefault(int(m.group(1)), []).append(path)
            tdir = key.ReadObj()
            nthr += 1
            for p in plots:
                h = tdir.Get(p["name"])
                if not h:
                    continue
                prof, buf, nom, ss = p["prof"], p["buf"], p["nom"], p["sumsq"]
                for j in range(p["nbins"]):
                    c = h.GetBinContent(j + 1)
                    prof.Fill(j + 0.5, c)
                    buf[j][0] = c
                    ss[j] += (c - nom[j]) ** 2
                p["nused"] += 1
                p["tree"].Fill()
        f.Close()
        print(f"[fast_merge]   {path}: {nthr} throws")

    dups = {k: v for k, v in seen.items() if len(v) > 1}
    if dups:
        k = sorted(dups)[0]
        print(f"[fast_merge] WARNING: {len(dups)} throw numbers appear in more than one file "
              f"(e.g. throw_{k} in {dups[k]}); were jobs resubmitted with the same start?", file=sys.stderr)
    if seen:
        lo, hi = min(seen), max(seen)
        missing = (hi - lo + 1) - len(seen)
        nread = sum(len(v) for v in seen.values())
        print(f"[fast_merge] {nread} throws read, {len(seen)} distinct numbers (throw_{lo}..throw_{hi}"
              + (f", {missing} missing)" if missing else ", none missing)"))

    # --- write, in the same order as nuissyst ---
    for p in plots:
        n, nb, base, prof = p["name"], p["nbins"], p["base"], p["prof"]
        nomplot = base.Clone(n + "_nominal_tmp")
        nomplot.SetDirectory(0)
        stat = [base.GetBinError(j + 1) for j in range(nb)]
        for j in range(nb):
            base.SetBinContent(j + 1, prof.GetBinContent(j + 1))
            base.SetBinError(j + 1, prof.GetBinError(j + 1))
        base.SetTitle("Profiled throws")
        d_err.cd()
        base.Write()
        prof.Write()
        p["tree"].Write()

        d_nt.cd()
        for j in range(nb):
            base.SetBinError(j + 1, math.sqrt(stat[j] ** 2 + base.GetBinError(j + 1) ** 2))
        base.Write()

        d_cv.cd()
        nomplot.SetName(n)
        nomplot.SetTitle("Nominal prediction")
        nomplot.Write()

        d_band.cd()
        band = nomplot.Clone(n)
        band.SetDirectory(0)
        band.SetTitle("Nominal prediction, stat+syst (throws about nominal)")
        N = p["nused"]
        for j in range(nb):
            syst = math.sqrt(p["sumsq"][j] / N) if N > 0 else 0.0
            band.SetBinError(j + 1, math.sqrt(nomplot.GetBinError(j + 1) ** 2 + syst ** 2))
        band.Write()

        d_err.cd()
        nomplot.Write(n + "_nominal")
        vec = ROOT.TVectorD(nb)
        for j in range(nb):
            vec[j] = p["nom"][j]
        vec.Write(n + "_nominal_vec")

    out.Close()
    print(f"[fast_merge] {len(plots)} plots -> {a.output}")


if __name__ == "__main__":
    main()
