"""Layer-1 bridge for FSDA `FSR` (Forward Search Regression / outlier detection).

Python -> matlab.engine -> MATLAB + FSDA

Start a MATLAB engine session, marshal numpy arrays to/from matlab.double, and
call the genuine FSDA `FSR`. FSR runs a robust forward search (random LXS initial
subset, then grows a clean subset one unit at a time, monitoring the minimum
deletion residual) and declares outliers. It returns a MATLAB **struct**; the
fields of interest here:

    out.mdr          (m, 2)  [step, minimum deletion residual] per search step
    out.outliers     1-based unit indices declared outliers (ListOut is identical)
    out.beta         (p,)    regression coefficients at the final step
    out.scale        scalar  robust scale estimate
    out.fittedvalues (n,)    / out.residuals (n,)
    out.class        'FSR'

Three things make FSR a richer crossing than mahalFS/Score (see CONSTITUTION §4):
  * struct output -> Python dict (nargout=1);
  * `out.outliers` are **1-based** MATLAB unit indices, kept 1-based here (the
    language surface converts if it ever needs 0-based) and shaped inconsistently
    by MATLAB -- a scalar when one outlier, an array when several, empty when none;
  * randomness from `nsamp` subsampling -- `nsamp=0` enumerates ALL C(n,p) subsets,
    making the run deterministic with no RNG seeding. Plots/messages are forced off
    so nothing pops a figure or writes to stdout through the headless engine.

See spec 007 (specs/007-matlab-engine-FSR.md) and CONSTITUTION.md.
"""
from __future__ import annotations

import numpy as np
import matlab
import matlab.engine


def start_engine(fsda_root: str | None = None):
    """Start a MATLAB engine and make sure FSDA `FSR` resolves.

    FSDA is normally installed as a MATLAB Add-On, so `FSR` is already on the
    path and `fsda_root` can be left as None. Pass the FSDA install dir only as a
    fallback; it is added with addpath(genpath(...)). Raises RuntimeError if
    `FSR` still cannot be found.
    """
    eng = matlab.engine.start_matlab()
    if fsda_root is not None:
        eng.addpath(eng.genpath(fsda_root), nargout=0)
    if not eng.which("FSR"):
        eng.quit()
        raise RuntimeError(
            "FSDA `FSR` not found on the MATLAB path. Install the FSDA Add-On "
            "in MATLAB, or pass fsda_root=<FSDA install dir>."
        )
    return eng


def _normalize_outliers(raw) -> np.ndarray:
    """Normalize FSR `outliers`/`ListOut` to a 1-based int array.

    MATLAB returns a scalar when there is one outlier, a row/column vector when
    several, and an empty 0x0 (or NaN) when none. Collapse all of these to a 1D
    int array (empty when no outliers); the indices stay 1-based.
    """
    arr = np.atleast_1d(np.asarray(raw, dtype=float)).reshape(-1)
    arr = arr[~np.isnan(arr)]
    return arr.astype(int)


def fsr(
    eng,
    y: np.ndarray,
    X: np.ndarray,
    nsamp: int = 0,
    intercept: bool = True,
    h: int | None = None,
    init: int | None = None,
    bonflev: float | None = None,
) -> dict:
    """Call FSDA `FSR(y, X, ...)` through the engine and return the key fields.

    y         : (n,) or (n, 1) response
    X         : (n, p-1) predictor matrix (intercept added by FSDA when intercept=True)
    nsamp     : subsamples for the LXS initial subset; 0 = ALL subsets (deterministic)
    intercept : include a constant term (default True)
    h/init/bonflev : optional FSR knobs (passed through only when not None)
    returns   : dict with mdr (m,2), outliers (1-based int array, empty if none),
                beta (p,), scale (float), fittedvalues (n,), residuals (n,), class (str).

    `plots` and `msg` are always forced to 0 (headless engine). Every value is
    shape-checked at the boundary; no silent reshape.
    """
    y = np.asarray(y, dtype=float)
    X = np.asarray(X, dtype=float)

    if y.ndim == 2 and y.shape[1] == 1:
        y = y.reshape(-1)
    if y.ndim != 1:
        raise ValueError(f"y must be shape (n,) or (n, 1), got {y.shape}")
    n = y.shape[0]

    if X.ndim != 2:
        raise ValueError(f"X must be a 2D matrix, got shape {X.shape}")
    if X.shape[0] != n:
        raise ValueError(f"X must have {n} rows to match y, got {X.shape[0]}")

    ym = matlab.double(y.reshape(-1, 1).tolist())   # n x 1 column vector
    Xm = matlab.double(X.tolist())                  # n x (p-1)

    args = [ym, Xm,
            "nsamp", float(nsamp),
            "intercept", bool(intercept),
            "plots", 0.0,
            "msg", 0.0]
    if h is not None:
        args += ["h", float(h)]
    if init is not None:
        args += ["init", float(init)]
    if bonflev is not None:
        args += ["bonflev", float(bonflev)]

    out = eng.FSR(*args, nargout=1)   # MATLAB struct -> Python dict

    mdr = np.asarray(out["mdr"], dtype=float)
    if mdr.ndim != 2 or mdr.shape[1] != 2:
        raise RuntimeError(f"expected FSR mdr shape (m, 2), got {mdr.shape}")

    return {
        "mdr": mdr,
        "outliers": _normalize_outliers(out["outliers"]),
        "beta": np.asarray(out["beta"], dtype=float).reshape(-1),
        "scale": float(out["scale"]),
        "fittedvalues": np.asarray(out["fittedvalues"], dtype=float).reshape(-1),
        "residuals": np.asarray(out["residuals"], dtype=float).reshape(-1),
        "class": str(out["class"]),
    }


def stop_engine(eng) -> None:
    """Shut the engine session down."""
    eng.quit()


def matlab_version(eng) -> str:
    """Return the MATLAB version string for diagnostics."""
    return str(eng.version())


def which_fsr(eng) -> str:
    """Return the resolved `FSR` path for diagnostics."""
    return str(eng.which("FSR"))
