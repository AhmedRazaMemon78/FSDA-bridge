"""Layer-1 bridge for FSDA `mahalFS` (squared Mahalanobis distances).

Python -> matlab.engine -> MATLAB + FSDA

Start a MATLAB engine session, marshal numpy arrays to/from matlab.double, and
call the genuine FSDA `mahalFS`. FSDA `mahalFS(Y, MU, SIGMA)` returns, for each
row y_i of Y, the *squared* Mahalanobis distance
    d_i = (y_i - MU) * inv(SIGMA) * (y_i - MU)'     (MU is 1 x v).

See spec 001 (specs/001-matlab-engine-mahalFS.md) and CONSTITUTION.md.
"""
from __future__ import annotations

import numpy as np
import matlab
import matlab.engine


def start_engine(fsda_root: str | None = None):
    """Start a MATLAB engine and make sure FSDA `mahalFS` resolves.

    FSDA is normally installed as a MATLAB Add-On, so `mahalFS` is already on the
    path and `fsda_root` can be left as None. Pass the FSDA install dir only as a
    fallback; it is added with addpath(genpath(...)). Raises RuntimeError if
    `mahalFS` still cannot be found.
    """
    eng = matlab.engine.start_matlab()
    if fsda_root is not None:
        eng.addpath(eng.genpath(fsda_root), nargout=0)
    if not eng.which("mahalFS"):
        eng.quit()
        raise RuntimeError(
            "FSDA `mahalFS` not found on the MATLAB path. Install the FSDA Add-On "
            "in MATLAB, or pass fsda_root=<FSDA install dir>."
        )
    return eng


def mahal_fs(eng, Y: np.ndarray, MU: np.ndarray, SIGMA: np.ndarray) -> np.ndarray:
    """Call FSDA `mahalFS(Y, MU, SIGMA)` through the engine.

    Y     : (n, v) data matrix
    MU    : (v,) or (1, v) location vector (forced to 1 x v)
    SIGMA : (v, v) covariance matrix
    returns : (n,) squared Mahalanobis distances.

    Every value is shape/dtype-checked at the boundary; no silent reshape.
    """
    Y = np.asarray(Y, dtype=float)
    MU = np.asarray(MU, dtype=float)
    SIGMA = np.asarray(SIGMA, dtype=float)

    if Y.ndim != 2:
        raise ValueError(f"Y must be a 2D matrix, got shape {Y.shape}")
    n, v = Y.shape

    if MU.ndim == 1:
        MU = MU.reshape(1, -1)
    elif MU.ndim != 2 or MU.shape[0] != 1:
        raise ValueError(f"MU must be shape ({v},) or (1, {v}), got {MU.shape}")
    if MU.shape != (1, v):
        raise ValueError(f"MU must be shape ({v},) or (1, {v}), got {MU.shape}")

    if SIGMA.shape != (v, v):
        raise ValueError(f"SIGMA must be shape ({v}, {v}), got {SIGMA.shape}")

    Ym = matlab.double(Y.tolist())
    MUm = matlab.double(MU.tolist())
    SIGMAm = matlab.double(SIGMA.tolist())

    d = eng.mahalFS(Ym, MUm, SIGMAm)
    d = np.asarray(d, dtype=float).reshape(-1)
    if d.shape != (n,):
        raise RuntimeError(f"expected FSDA output shape ({n},), got {d.shape}")
    return d


def stop_engine(eng) -> None:
    """Shut the engine session down."""
    eng.quit()


def matlab_version(eng) -> str:
    """Return the MATLAB version string for diagnostics."""
    return str(eng.version())


def which_mahalfs(eng) -> str:
    """Return the resolved `mahalFS` path for diagnostics."""
    return str(eng.which("mahalFS"))
