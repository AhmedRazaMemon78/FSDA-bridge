#!/usr/bin/env python3
"""Call FSDA's `Score` from Python, the way you would in MATLAB.

`Score` (toolbox/regression/Score.m) is the Box-Cox score test: for a set of
transformation parameters `la`, it returns a score-test statistic per `la` (approx.
N(0,1)); the value nearest zero is the transformation best supported by the data.

This script is self-contained: it embeds the classic **wool** dataset (Box & Cox, 1964)
so it reproduces the example from MATLAB's own `Score` help — copy, paste, run.

Prerequisites
-------------
* MATLAB with the FSDA Add-On on the MATLAB path (verify `which Score` in MATLAB).
* `matlabengine` matching your MATLAB release, e.g.  pip install "matlabengine==26.1.*"
* pyfsda:  pip install pyfsda   (during team testing: from TestPyPI, see the README)

Run
---
    python score_example.py [FSDA_ROOT]     # FSDA_ROOT only if FSDA isn't on the path
"""
from __future__ import annotations

import os
import sys

import numpy as np

from pyfsda import FsdaEngine

# --- wool data (Box & Cox, 1964): 3^3 factorial, columns x1 x2 x3 (levels -1/0/1) and
#     y = number of cycles to failure. Same data as MATLAB's Score help example. ---------
WOOL = np.array([
    [-1, -1, -1,  674], [-1, -1, 0,  370], [-1, -1, 1,  292],
    [-1,  0, -1,  338], [-1,  0, 0,  266], [-1,  0, 1,  210],
    [-1,  1, -1,  170], [-1,  1, 0,  118], [-1,  1, 1,   90],
    [ 0, -1, -1, 1414], [ 0, -1, 0, 1198], [ 0, -1, 1,  634],
    [ 0,  0, -1, 1022], [ 0,  0, 0,  620], [ 0,  0, 1,  438],
    [ 0,  1, -1,  442], [ 0,  1, 0,  332], [ 0,  1, 1,  220],
    [ 1, -1, -1, 3636], [ 1, -1, 0, 3184], [ 1, -1, 1, 2000],
    [ 1,  0, -1, 1568], [ 1,  0, 0, 1070], [ 1,  0, 1,  566],
    [ 1,  1, -1, 1140], [ 1,  1, 0,  884], [ 1,  1, 1,  360],
], dtype=float)

LA = [-1.0, -0.5, 0.0, 0.5, 1.0]     # the five common Box-Cox lambdas (Score's default)


def main() -> int:
    fsda_root = (sys.argv[1] if len(sys.argv) > 1 else os.environ.get("PYFSDA_FSDA_ROOT")) or None

    y = WOOL[:, -1].reshape(-1, 1)   # response as an (n, 1) COLUMN (pyfsda: 1-D -> MATLAB row)
    X = WOOL[:, :3]                  # the three explanatory factors

    print("Starting MATLAB (slow the first time) ...")
    try:
        eng = FsdaEngine.start("Score", fsda_root=fsda_root, check_version=False)
    except Exception as exc:
        print("\nCould not start MATLAB with FSDA:")
        print("  * is MATLAB installed and matlabengine matching its release?")
        print("  * is FSDA on the MATLAB path?  (else: python score_example.py <FSDA_ROOT>)")
        print(f"\nunderlying error: {exc}")
        return 1

    try:
        print(f"MATLAB {eng.version()} ready.\n")

        # Call Score the MATLAB way: positional args first, then name/value options.
        # MATLAB:  outSC = Score(y, X, 'la', [-1 -0.5 0 0.5 1], 'intercept', true)
        out = eng.call("Score", y, X, la=LA, intercept=True)   # struct -> dict
        # (the bare default form is simply:  out = eng.call("Score", y, X) )
        #
        # Even simpler, with no explicit session (the shared engine starts on first use):
        #     import pyfsda
        #     out = pyfsda.Score(y, X, la=LA, intercept=True)

        score = np.asarray(out["Score"], dtype=float).reshape(-1)
        best = int(np.argmin(np.abs(score)))

        print("Box-Cox score test on the wool data (statistic ~ N(0,1)):\n")
        print(f"  {'lambda':>8}  {'score':>10}   transformation")
        names = {-1.0: "1/y", -0.5: "1/sqrt(y)", 0.0: "log(y)", 0.5: "sqrt(y)", 1.0: "y (none)"}
        for i, (lam, s) in enumerate(zip(LA, score)):
            mark = "  <-- best (|score| smallest)" if i == best else ""
            print(f"  {lam:>8.2f}  {s:>10.4f}   {names[lam]:<10}{mark}")

        print(f"\nBest-supported transformation: lambda = {LA[best]:.2f} ({names[LA[best]]}).")
        print(f"|score| = {abs(score[best]):.4f} "
              f"({'not rejected' if abs(score[best]) < 1.96 else 'REJECTED'} at the 5% level).")
        # ScoreT / Lik are only returned when their options are on; print if present & scalar.
        st = np.asarray(out["ScoreT"], dtype=float).reshape(-1) if "ScoreT" in out else np.array([])
        if st.size == 1 and np.isfinite(st[0]):
            print(f"\nScoreT (Tukey non-additivity) = {st[0]:.4f}")

        print("\nTip: options pass like a MATLAB name/value pair, e.g. "
              "eng.call('Score', y, X, la=[...], Lik=True).")
    finally:
        eng.stop()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
