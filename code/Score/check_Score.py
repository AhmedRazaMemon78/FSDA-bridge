"""Agreement check: FSDA `Score` through matlab.engine vs a numpy reference.

Run with the project venv's Python (the script's own dir is put on sys.path so
`import bridge` works). With an activated venv just `python check_Score.py`; or
point FSDA_DEV_VENV at the venv's python executable and run it directly:

    %FSDA_DEV_VENV% code\\Score\\check_Score.py [FSDA_ROOT]   # Windows
    "$FSDA_DEV_VENV" code/Score/check_Score.py [FSDA_ROOT]    # macOS / Linux

FSDA_ROOT is optional — pass the FSDA install dir only if `Score` is not already
on the MATLAB path (FSDA is normally an Add-On). Prints PASS/FAIL, both Score
vectors, the max abs diff, and the Python / MATLAB / engine version triple. The
fixed input is the genuine FSDA `wool` dataset: it is read from the committed
reference/wool.csv when present, otherwise loaded once from MATLAB's wool.txt
and persisted there (so the R/Julia surfaces read the same input). Also writes
the per-lambda oracle to reference/Score_check.csv. This is the spec-004
agreement gate.
"""
from __future__ import annotations

import csv
import platform
import sys
from importlib import metadata
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import bridge

TOL = 1e-9
LA = np.array([-1.0, -0.5, 0.0, 0.5, 1.0])


def numpy_score(y: np.ndarray, X: np.ndarray, la: np.ndarray, intercept: bool = True) -> np.ndarray:
    """Reference Box-Cox score-test statistics, mirroring FSDA Score.m.

    For each lambda: form the geometric-mean-normalized power transformation z
    and the constructed variable w = dz/dlambda; regress z on [X w] (X already
    carrying the intercept column when intercept=True) via QR; the score
    statistic is the *negated* t-ratio of w's coefficient (FSDA: -beta(end)/se(end)).
    """
    y = np.asarray(y, dtype=float).reshape(-1)
    X = np.asarray(X, dtype=float)
    n = y.shape[0]
    logy = np.log(y)
    G = np.exp(np.sum(logy) / n)            # geometric mean
    logG = np.log(G)
    # FSDA's aux.chkinputR prepends the intercept column to X before the loop.
    Xb = np.hstack([np.ones((n, 1)), X]) if intercept else X

    out = np.empty(len(la), dtype=float)
    for i, lai in enumerate(la):
        if abs(lai) < 1e-8:                 # lambda == 0
            z = G * logy
            w = G * logy * (logy / 2.0 - logG)
        else:
            laiGlaim1 = lai * np.exp((lai - 1.0) * logG)
            ylai = np.exp(lai * logy)       # y .^ lambda
            ylaim1 = ylai - 1.0
            z = ylaim1 / laiGlaim1
            w = (ylai * logy - ylaim1 * (1.0 / lai + logG)) / laiGlaim1
        Xw = np.hstack([Xb, w.reshape(-1, 1)])
        k = Xw.shape[1]
        Q, R = np.linalg.qr(Xw)             # reduced QR == MATLAB qr(Xw, 0)
        beta = np.linalg.solve(R, Q.T @ z)
        resid = z - Xw @ beta
        sse = float(resid @ resid)
        Ri = np.linalg.solve(R, np.eye(k))
        xtxi = Ri @ Ri.T
        se = np.sqrt(np.diag(xtxi) * sse / (n - k))   # df = n - ncol(Xw)
        out[i] = -beta[-1] / se[-1]
    return out


def engine_pkg_version() -> str:
    try:
        return metadata.version("matlabengine")
    except Exception:
        return "n/a"


def load_wool_fixture(eng, reference_dir: Path) -> np.ndarray:
    """Return the fixed wool dataset (27 x 4: 3 factors + positive response).

    Read it from the committed reference/wool.csv when present; otherwise load
    the genuine FSDA `wool.txt` once through MATLAB and persist it as the
    portable fixture, so the R/Julia surfaces can read the same input without
    wool.txt being on their machine's MATLAB path.
    """
    wool_csv = reference_dir / "wool.csv"
    if wool_csv.exists():
        rows = []
        with open(wool_csv, newline="") as f:
            reader = csv.reader(f)
            next(reader)  # header
            for line in reader:
                rows.append([float(v) for v in line])
        return np.asarray(rows, dtype=float)

    eng.eval("XX = load('wool.txt');", nargout=0)
    XX = np.asarray(eng.workspace["XX"], dtype=float)
    reference_dir.mkdir(exist_ok=True)
    with open(wool_csv, "w", newline="") as f:
        w = csv.writer(f)
        ncol = XX.shape[1]
        w.writerow([f"x{j + 1}" for j in range(ncol - 1)] + ["y"])
        for row in XX:
            w.writerow(list(row))
    return XX


def main() -> int:
    reference_dir = Path(__file__).resolve().parent / "reference"
    fsda_root = sys.argv[1] if len(sys.argv) > 1 else None

    eng = bridge.start_engine(fsda_root=fsda_root)
    matlab_version = eng.version()
    where = eng.which("Score")

    XX = load_wool_fixture(eng, reference_dir)
    y = XX[:, -1]
    X = XX[:, :-1]

    sc_fsda = bridge.score(eng, y, X, la=LA, intercept=True)
    bridge.stop_engine(eng)

    sc_ref = numpy_score(y, X, LA, intercept=True)
    max_abs_diff = float(np.max(np.abs(sc_fsda - sc_ref)))
    ok = bool(np.allclose(sc_fsda, sc_ref, rtol=0.0, atol=TOL))

    print("=== spec 004: Score bridge agreement check ===")
    print(f"Python       : {platform.python_version()}")
    print(f"MATLAB       : {matlab_version}")
    print(f"engine pkg   : {engine_pkg_version()}")
    print(f"Score path   : {where}")
    print(f"lambda       : {np.array2string(LA, precision=4)}")
    print(f"FSDA Score   : {np.array2string(sc_fsda, precision=10)}")
    print(f"numpy ref    : {np.array2string(sc_ref, precision=10)}")
    print(f"max abs diff : {max_abs_diff:.3e}  (tol {TOL:.0e})")
    print(f"RESULT       : {'PASS' if ok else 'FAIL'}")

    reference_dir.mkdir(exist_ok=True)
    with open(reference_dir / "Score_check.csv", "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["i", "la", "Score_fsda", "Score_numpy", "abs_diff"])
        for i in range(LA.size):
            w.writerow([i + 1, LA[i], sc_fsda[i], sc_ref[i], abs(sc_fsda[i] - sc_ref[i])])

    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
