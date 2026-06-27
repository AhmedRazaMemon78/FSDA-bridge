"""Layer-1 bridge for FSDA `Score` (Box-Cox score test for transforming y).

Python -> matlab.engine -> MATLAB + FSDA

Start a MATLAB engine session, marshal numpy arrays to/from matlab.double, and
call the genuine FSDA `Score`. For each lambda in `la`, FSDA
`Score(y, X, 'la', la, 'intercept', ic)` builds the Box-Cox normalized-power
transformed response and its constructed variable w = dz/dlambda, augments the
design with w, and returns the *score test t-statistic* of w (the field
`out.Score`, one value per lambda). A statistic near zero supports that lambda
as the transformation parameter.

`Score` returns a MATLAB struct (-> Python dict); we read `out['Score']`. This
is a richer marshalling boundary than `mahalFS` (spec 001), which returned a
bare array.

See spec 004 (specs/004-matlab-engine-Score.md) and CONSTITUTION.md.
"""
from __future__ import annotations

import numpy as np
import matlab
import matlab.engine

# FSDA Score default transformation parameters (la).
DEFAULT_LA = (-1.0, -0.5, 0.0, 0.5, 1.0)


def start_engine(fsda_root: str | None = None):
    """Start a MATLAB engine and make sure FSDA `Score` resolves.

    FSDA is normally installed as a MATLAB Add-On, so `Score` is already on the
    path and `fsda_root` can be left as None. Pass the FSDA install dir only as a
    fallback; it is added with addpath(genpath(...)). Raises RuntimeError if
    `Score` still cannot be found.
    """
    eng = matlab.engine.start_matlab()
    if fsda_root is not None:
        eng.addpath(eng.genpath(fsda_root), nargout=0)
    if not eng.which("Score"):
        eng.quit()
        raise RuntimeError(
            "FSDA `Score` not found on the MATLAB path. Install the FSDA Add-On "
            "in MATLAB, or pass fsda_root=<FSDA install dir>."
        )
    return eng


def score(
    eng,
    y: np.ndarray,
    X: np.ndarray,
    la: np.ndarray | None = None,
    intercept: bool = True,
) -> np.ndarray:
    """Call FSDA `Score(y, X, 'la', la, 'intercept', intercept)` through the engine.

    y         : (n,) or (n, 1) strictly-positive response (Box-Cox requires y > 0)
    X         : (n, p) predictor matrix; the intercept column is added *inside*
                FSDA when intercept=True, so pass the raw predictors here.
    la        : 1D transformation parameters (default [-1, -0.5, 0, 0.5, 1])
    intercept : include a constant term (default True)
    returns   : (len(la),) score-test t-statistics, one per lambda.

    Every value is shape/dtype-checked at the boundary; no silent reshape.
    """
    y = np.asarray(y, dtype=float)
    X = np.asarray(X, dtype=float)
    la = np.asarray(DEFAULT_LA if la is None else la, dtype=float)

    if y.ndim == 2 and y.shape[1] == 1:
        y = y.reshape(-1)
    if y.ndim != 1:
        raise ValueError(f"y must be shape (n,) or (n, 1), got {y.shape}")
    n = y.shape[0]
    if np.any(y <= 0):
        raise ValueError("y must be strictly positive (Box-Cox transform).")

    if X.ndim != 2:
        raise ValueError(f"X must be a 2D matrix, got shape {X.shape}")
    if X.shape[0] != n:
        raise ValueError(f"X must have {n} rows to match y, got {X.shape[0]}")

    if la.ndim != 1 or la.size < 1:
        raise ValueError(f"la must be a non-empty 1D sequence, got shape {la.shape}")

    ym = matlab.double(y.reshape(-1, 1).tolist())   # n x 1 column vector
    Xm = matlab.double(X.tolist())                  # n x p
    lam = matlab.double([la.tolist()])              # 1 x len(la) row vector

    out = eng.Score(ym, Xm, "la", lam, "intercept", bool(intercept), nargout=1)
    # `Score` returns a MATLAB struct -> Python dict; read the Score field.
    sc = np.asarray(out["Score"], dtype=float).reshape(-1)
    if sc.shape != (la.size,):
        raise RuntimeError(f"expected FSDA Score shape ({la.size},), got {sc.shape}")
    return sc


def stop_engine(eng) -> None:
    """Shut the engine session down."""
    eng.quit()


def matlab_version(eng) -> str:
    """Return the MATLAB version string for diagnostics."""
    return str(eng.version())


def which_score(eng) -> str:
    """Return the resolved `Score` path for diagnostics."""
    return str(eng.which("Score"))
