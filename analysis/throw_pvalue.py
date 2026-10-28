#!/usr/bin/env python3
"""throw_pvalue.py merged.root [--sample NAME] [--rcond 1e-10] [--plot PREFIX] [--csv PREFIX]

Prior-predictive p-value of the data against the nominal prediction, using the
nuissyst throws as the reference ensemble.

  throws      chi2_k   = (m_nom - m_k)^T C^-1 (m_nom - m_k),  k = 1..N
  reference   chi2_obs = (d - m_nom)^T C^-1 (d - m_nom)
  p-value     p = (#{k: chi2_k >= chi2_obs} + 1) / (N + 1)

C is the data covariance NUISANCE uses for the sample (nominal/<sample>_COV),
the same matrix in both chi2s, inverted once with an eigenvalue cut: modes with
lambda <= rcond * lambda_max are dropped (pseudo-inverse).

Inputs, all from the merged nuissyst output (merge_throws.sh / fast_merge.py):
  d      nominal/<sample>_data
  m_nom  error_bands/<sample>_nominal_vec   (checked against nominal/<sample>_MC)
  m_k    error_bands/<sample>_MC_tree       (one entry per throw, content_<i>)
  C      nominal/<sample>_COV               (units of (1e-38 cm^2)^2, NUISANCE convention)

Needs only ROOT with PyROOT (the stack's setup.sh provides it).
"""
import argparse
import math
import sys

import ROOT

ROOT.gROOT.SetBatch(True)
ROOT.gErrorIgnoreLevel = ROOT.kWarning
UNIT = 1e38  # NUISANCE stores the covariance for data/MC scaled by 1e38


def die(msg):
    sys.exit("[pvalue] ERROR: " + msg)


def find_samples(f):
    eb = f.Get("error_bands")
    if not eb:
        die("no error_bands/ directory: is this a merged nuissyst output?")
    out = []
    for k in eb.GetListOfKeys():
        n = k.GetName()
        if n.endswith("_MC_tree"):
            s = n[: -len("_MC_tree")]
            if f.Get(f"nominal/{s}_data") and f.Get(f"nominal/{s}_COV"):
                out.append(s)
    return out


class PseudoInverse:
    """Eigen-decomposition of the symmetric C with an rcond cut on eigenvalues."""

    def __init__(self, cov_hist, n, rcond):
        m = ROOT.TMatrixDSym(n)
        for i in range(n):
            for j in range(n):
                m[i][j] = 0.5 * (cov_hist.GetBinContent(i + 1, j + 1) + cov_hist.GetBinContent(j + 1, i + 1))
        eig = ROOT.TMatrixDSymEigen(m)
        vals, vecs = eig.GetEigenValues(), eig.GetEigenVectors()
        lam = [vals[i] for i in range(n)]
        self.lmax = max(lam)
        self.lmin = min(lam)
        cut = rcond * self.lmax
        self.modes = []  # (1/lambda, eigenvector)
        for j in range(n):
            if lam[j] > cut:
                self.modes.append((1.0 / lam[j], [vecs[i][j] for i in range(n)]))
        self.n = n
        self.kept = len(self.modes)
        self.dropped = n - self.kept
        self.negative = sum(1 for x in lam if x <= 0)

    def chi2(self, r):
        tot = 0.0
        for inv, u in self.modes:
            proj = sum(ui * ri for ui, ri in zip(u, r))
            tot += inv * proj * proj
        return tot


def quantile(sorted_x, q):
    if not sorted_x:
        return float("nan")
    pos = q * (len(sorted_x) - 1)
    lo = int(math.floor(pos))
    hi = min(lo + 1, len(sorted_x) - 1)
    return sorted_x[lo] + (pos - lo) * (sorted_x[hi] - sorted_x[lo])


def analyse(f, s, rcond, plot, csv):
    D = f.Get(f"nominal/{s}_data")
    M = f.Get(f"nominal/{s}_MC")
    C = f.Get(f"nominal/{s}_COV")
    V = f.Get(f"error_bands/{s}_nominal_vec")
    T = f.Get(f"error_bands/{s}_MC_tree")
    n = D.GetNbinsX()
    if C.GetNbinsX() != n or C.GetNbinsY() != n:
        die(f"{s}: covariance is {C.GetNbinsX()}x{C.GetNbinsY()}, data has {n} bins")
    if T.GetNbranches() != n:
        die(f"{s}: throw tree has {T.GetNbranches()} branches, data has {n} bins")

    d = [D.GetBinContent(i + 1) * UNIT for i in range(n)]
    if V:
        mnom = [V[i] * UNIT for i in range(n)]
        dev = max(abs(V[i] - M.GetBinContent(i + 1)) / max(abs(V[i]), 1e-300) for i in range(n))
        if dev > 1e-9:
            print(f"[pvalue] WARNING: {s}: nominal_vec and nominal/_MC differ (max rel {dev:.1e})")
    else:
        mnom = [M.GetBinContent(i + 1) * UNIT for i in range(n)]

    P = PseudoInverse(C, n, rcond)

    chi2_obs = P.chi2([a - b for a, b in zip(d, mnom)])

    chi2k, skipped = [], 0
    for e in range(T.GetEntries()):
        T.GetEntry(e)
        mk = [getattr(T, f"content_{i}") * UNIT for i in range(n)]
        if not all(math.isfinite(x) for x in mk):
            skipped += 1
            continue
        chi2k.append(P.chi2([a - b for a, b in zip(mnom, mk)]))
    N = len(chi2k)
    if N == 0:
        die(f"{s}: no usable throws")

    nge = sum(1 for x in chi2k if x >= chi2_obs)
    p = (nge + 1.0) / (N + 1.0)
    p_err = math.sqrt(p * (1.0 - p) / (N + 1.0))
    xs = sorted(chi2k)

    # Cross-check against NUISANCE's own chi2 of data vs nominal MC
    L = f.Get("nominal/likelihood_hist")
    nuis = L.GetBinContent(1) if L else None

    print(f"\n=== {s}")
    print(f"bins                    {n}")
    print(f"covariance C            data covariance (nominal/_COV), eigenvalues {P.lmin:.3g} .. {P.lmax:.3g},"
          f" condition number {P.lmax / P.lmin if P.lmin > 0 else float('inf'):.3g}")
    print(f"inverse                 rcond = {rcond:g}: {P.kept} modes kept, {P.dropped} dropped"
          + (f" ({P.negative} non-positive eigenvalues!)" if P.negative else ""))
    print(f"throws N                {N}" + (f"   ({skipped} with non-finite bins skipped)" if skipped else ""))
    print(f"chi2_obs (data vs nom)  {chi2_obs:.4g}   (chi2/ndof = {chi2_obs / P.kept:.3g}, ndof = modes kept)")
    if nuis is not None:
        print(f"  NUISANCE chi2         {nuis:.4g}   ({'agrees' if abs(nuis - chi2_obs) <= 1e-4 * max(1, nuis) else 'DIFFERS, see notes'})")
    print(f"throw chi2_k            min {xs[0]:.4g}  16% {quantile(xs, .16):.4g}  median {quantile(xs, .5):.4g}"
          f"  84% {quantile(xs, .84):.4g}  95% {quantile(xs, .95):.4g}  max {xs[-1]:.4g}")
    print(f"throws with chi2_k >= chi2_obs   {nge} of {N}")
    print(f"p-value                 {p:.4g} +- {p_err:.2g}  (smallest possible with N throws: {1.0 / (N + 1):.2g})")
    print(f"for comparison only:    chi2 distribution p = {ROOT.TMath.Prob(chi2_obs, P.kept):.3g}"
          f"  (assumes the data scatter, not the model spread, sets the width)")
    if N < 100:
        print(f"[pvalue] NOTE: only {N} throws; p is known to about +-{p_err:.2g}. Use hundreds of throws.")

    if csv:
        with open(f"{csv}{s}.csv", "w") as o:
            o.write("k,chi2_k\n")
            for k, x in enumerate(chi2k, 1):
                o.write(f"{k},{x:.10g}\n")
            o.write(f"obs,{chi2_obs:.10g}\n")
        print(f"[pvalue] wrote {csv}{s}.csv")
    if plot:
        draw(s, chi2k, chi2_obs, p, N, f"{plot}{s}.png")
    return dict(sample=s, n=n, kept=P.kept, N=N, chi2_obs=chi2_obs, nge=nge, p=p)


def draw(s, chi2k, chi2_obs, p, N, out):
    hi = max(max(chi2k), chi2_obs) * 1.1
    nb = max(10, min(100, int(math.sqrt(N)) * 2))
    h = ROOT.TH1D("h", f"{s};#chi^{{2}};throws", nb, 0, hi)
    hr = ROOT.TH1D("hr", "", nb, 0, hi)
    for x in chi2k:
        h.Fill(x)
        if x >= chi2_obs:
            hr.Fill(x)
    c = ROOT.TCanvas("c", "", 900, 650)
    ROOT.gStyle.SetOptStat(0)
    h.SetLineColor(ROOT.kBlue + 1)
    h.SetLineWidth(2)
    h.Draw("hist")
    hr.SetFillColorAlpha(ROOT.kRed, 0.35)
    hr.SetLineColor(ROOT.kRed)
    hr.Draw("hist same")
    ymax = h.GetMaximum() * 1.05
    ln = ROOT.TLine(chi2_obs, 0, chi2_obs, ymax)
    ln.SetLineColor(ROOT.kBlack)
    ln.SetLineWidth(3)
    ln.SetLineStyle(2)
    ln.Draw()
    leg = ROOT.TLegend(0.50, 0.70, 0.88, 0.88)
    leg.AddEntry(h, f"throws #chi^{{2}}_{{k}}(m_{{nom}}, m_{{k}}), N = {N}", "l")
    leg.AddEntry(ln, f"data #chi^{{2}}_{{obs}} = {chi2_obs:.3g}", "l")
    leg.AddEntry(hr, f"p = {p:.3g}", "f")
    leg.Draw()
    c.SaveAs(out)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("file", help="merged nuissyst output (error_bands/, nominal/)")
    ap.add_argument("--sample", action="append", help="sample name (default: every sample with throws)")
    ap.add_argument("--rcond", type=float, default=1e-10,
                    help="drop covariance modes with lambda <= rcond*lambda_max (default 1e-10)")
    ap.add_argument("--plot", nargs="?", const="pvalue_", metavar="PREFIX",
                    help="write <PREFIX><sample>.png (default prefix pvalue_)")
    ap.add_argument("--csv", nargs="?", const="pvalue_", metavar="PREFIX",
                    help="write <PREFIX><sample>.csv with chi2_k and chi2_obs")
    a = ap.parse_args()

    f = ROOT.TFile.Open(a.file)
    if not f or f.IsZombie():
        die(f"cannot open {a.file}")
    samples = a.sample or find_samples(f)
    if not samples:
        die("no sample with error_bands/<sample>_MC_tree and nominal/<sample>_COV found")
    res = [analyse(f, s, a.rcond, a.plot, a.csv) for s in samples]
    if len(res) > 1:
        print("\nsample                                                     bins  N      chi2_obs   p")
        for r in res:
            print(f"{r['sample']:58s} {r['n']:4d}  {r['N']:5d}  {r['chi2_obs']:9.4g}  {r['p']:.4g}")


if __name__ == "__main__":
    main()
