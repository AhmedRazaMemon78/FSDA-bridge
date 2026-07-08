#!/usr/bin/env python3
"""pyfsda smoke test — verify the FSDA bridge works on your machine.

Runs a handful of real FSDA routines through one MATLAB Engine session and checks each
result against an independent numpy/stdlib oracle to 1e-9. If every check PASSes, your
pyfsda + MATLAB + FSDA + matlabengine setup is good.

Prerequisites
-------------
1. MATLAB with the FSDA Add-On on the MATLAB path (verify `which mahalFS` inside MATLAB).
2. `matlabengine` matching your MATLAB release, e.g. for R2026a:
       pip install "matlabengine==26.1.*"
3. pyfsda (during team testing, from TestPyPI):
       pip install -i https://test.pypi.org/simple/ pyfsda==0.1.0 --no-deps

Run
---
    python smoke_test.py [FSDA_ROOT]

`FSDA_ROOT` (optional) is the FSDA install/checkout dir; pass it (or set the env var
PYFSDA_FSDA_ROOT) only if FSDA is not already on your default MATLAB path. Exit code is 0
if all checks pass, 1 otherwise.
"""
from __future__ import annotations

import math
import os
import sys

try:
    import numpy as np
except ImportError:
    sys.exit("numpy is required: pip install numpy")

try:
    from pyfsda import FsdaEngine
except ImportError as exc:
    sys.exit(
        f"Could not import pyfsda ({exc}).\n"
        "  Install it, e.g.:  pip install -i https://test.pypi.org/simple/ pyfsda==0.1.0 --no-deps\n"
        "  It also needs `matlabengine` matching your MATLAB (e.g. matlabengine==26.1.* for R2026a)."
    )

TOL = 1e-9


def _result(name: str, ok: bool, diff: float, detail: str) -> bool:
    print(f"  [{'PASS' if ok else 'FAIL'}]  {name:<28}  max abs diff {diff:.2e}   {detail}")
    return ok


def check_mahalfs(eng: FsdaEngine) -> bool:
    """numeric array -> ndarray: squared Mahalanobis distances vs a numpy oracle."""
    Y = np.array([[1.0, 2.0], [2.0, 0.0], [3.0, 5.0], [0.0, -1.0], [4.0, 4.0]])
    MU = np.array([2.0, 2.0])
    SIGMA = np.array([[2.0, 0.5], [0.5, 1.0]])
    d = np.asarray(eng.call("mahalFS", Y, MU, SIGMA), dtype=float).reshape(-1)
    diff = Y - MU.reshape(1, -1)
    ref = np.sum((diff @ np.linalg.inv(SIGMA)) * diff, axis=1)
    err = float(np.max(np.abs(d - ref)))
    return _result("mahalFS (numeric->ndarray)", err <= TOL, err, "Mahalanobis vs numpy")


def check_corrnominal(eng: FsdaEngine) -> bool:
    """matrix -> struct(dict): chi-square and Cramer's V of a contingency table vs numpy."""
    N = np.array([[10.0, 20.0, 30.0], [40.0, 50.0, 60.0], [70.0, 80.0, 90.0]])
    out = eng.call("corrNominal", N, dispresults=False)
    if not isinstance(out, dict):
        return _result("corrNominal (struct->dict)", False, float("inf"),
                       f"expected dict, got {type(out).__name__}")
    rt = N.sum(1, keepdims=True); ct = N.sum(0, keepdims=True); tot = N.sum()
    E = rt @ ct / tot
    chi2_ref = float(((N - E) ** 2 / E).sum())
    I, J = N.shape
    cramer_ref = float(np.sqrt(chi2_ref / (tot * (min(I, J) - 1))))
    chi2 = float(np.asarray(out["Chi2"]).reshape(-1)[0])
    cramer = float(np.asarray(out["CramerV"]).reshape(-1)[0])
    err = max(abs(chi2 - chi2_ref), abs(cramer - cramer_ref))
    return _result("corrNominal (struct->dict)", err <= TOL, err,
                   f"chi2={chi2:.4f}, CramerV={cramer:.4f} vs numpy")


def check_tbwei(eng: FsdaEngine) -> bool:
    """vector -> vector: Tukey biweight weights vs the closed form."""
    u = np.array([-3.0, -1, 0, 0.5, 2, 5]).reshape(-1, 1)
    c = 4.685
    w = np.asarray(eng.call("TBwei", u, c), dtype=float).reshape(-1)
    uu = u.reshape(-1)
    ref = np.where(np.abs(uu) <= c, (1 - (uu / c) ** 2) ** 2, 0.0)
    err = float(np.max(np.abs(w - ref)))
    return _result("TBwei (vector->vector)", err <= TOL, err, "Tukey biweight vs numpy")


def check_bc(eng: FsdaEngine) -> bool:
    """scalars -> scalar: binomial coefficient vs math.comb."""
    n, k = 12, 5
    c = float(np.asarray(eng.call("bc", float(n), float(k))).reshape(-1)[0])
    ref = float(math.comb(n, k))
    err = abs(c - ref)
    return _result("bc (scalar->scalar)", err <= TOL, err, f"C({n},{k})={c:.0f} vs math.comb")


CHECKS = (check_mahalfs, check_corrnominal, check_tbwei, check_bc)


def main() -> int:
    fsda_root = (sys.argv[1] if len(sys.argv) > 1 else os.environ.get("PYFSDA_FSDA_ROOT")) or None

    print("pyfsda smoke test — starting MATLAB (this is slow the first time) ...")
    try:
        eng = FsdaEngine.start("mahalFS", fsda_root=fsda_root, check_version=False)
    except Exception as exc:
        print("\nCould not start MATLAB with FSDA. Common causes:")
        print("  * MATLAB not installed / not found by matlabengine.")
        print("  * matlabengine version does not match your MATLAB release.")
        print("  * FSDA not on the MATLAB path -> pass its folder: python smoke_test.py <FSDA_ROOT>")
        print(f"\nunderlying error: {exc}")
        return 1

    print(f"MATLAB {eng.version()} up. Running checks:")
    results = []
    try:
        for check in CHECKS:
            try:
                results.append(check(eng))
            except Exception as exc:                       # keep going on a single failure
                results.append(_result(check.__name__, False, float("inf"), f"error: {exc}"))
    finally:
        eng.stop()

    ok = all(results)
    print(f"\nRESULT: {'PASS' if ok else 'FAIL'}  ({sum(results)}/{len(results)} checks)")
    if ok:
        print("Your pyfsda + MATLAB + FSDA setup works. 🎉")
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
