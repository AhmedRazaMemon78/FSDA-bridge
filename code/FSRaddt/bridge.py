"""Layer-1 bridge for FSDA `FSRaddt` (Forward Search added-variable deletion t-test).

Python -> matlab.engine -> MATLAB + FSDA

Start a MATLAB engine session, marshal numpy arrays to/from matlab.double, and
call the genuine FSDA `FSRaddt`. FSRaddt runs a forward search (robust LXS initial
subset, then grows a clean subset one unit at a time) and, at every step, monitors
the **deletion t statistic** of each explanatory variable -- the added-variable
t-test that asks whether dropping that variable matters as the subset grows. It
returns a MATLAB **struct**; the fields of interest here:

    out.Tdel    (m, k+1)  [step, deletion t-stat per tested variable] per search step
    out.S2del   (m, k+1)  [step, deletion sigma^2 estimate per tested variable]
    out.bs      (p, k)     1-based initial-subset unit indices (one column per variable)
    out.Un      cell{k}    units entering at each step (one monitoring matrix per variable)
    out.la      (k,)       1-based column indices of the variables the t-stats are for
    out.class   'FSRaddt'

where k = number of tested variables (= length(la), all of X by default) and m =
n - init + 1 forward-search steps.

Three things make FSRaddt a richer crossing than FSR (see CONSTITUTION sec 4):
  * struct output -> Python dict (nargout=1), like FSR;
  * **cell array** out.Un -> Python list of numpy arrays (the engine maps a MATLAB
    cell to a list); FSR put Un out of scope, so cell<->list is exercised here for
    the first time (`_normalize_un`);
  * **variable-width** monitoring matrices: Tdel/S2del have k+1 columns (k depends
    on X / DataVars), not the fixed 2 of FSR's mdr -- shape checks key off `la`, not
    a hardcoded 2. out.bs / out.la are **1-based** MATLAB indices, kept 1-based here.

Randomness comes only from `nsamp` subsampling; `nsamp=0` enumerates ALL C(n,p)
subsets, making the run deterministic with no RNG seeding. `plots`/`msg` default to
off (headless gate); set them to view FSRaddt's deletion-t figure as a live MATLAB
window and route its messages to the terminal (see `fsraddt` and `render_figures`).

See spec 010 (specs/010-matlab-engine-FSRaddt.md) and CONSTITUTION.md.
"""
from __future__ import annotations

import io
import sys

import numpy as np
import matlab
import matlab.engine


def start_engine(fsda_root: str | None = None):
    """Start a MATLAB engine and make sure FSDA `FSRaddt` resolves.

    FSDA is normally installed as a MATLAB Add-On, so `FSRaddt` is already on the
    path and `fsda_root` can be left as None. Pass the FSDA install dir only as a
    fallback; it is added with addpath(genpath(...)). Raises RuntimeError if
    `FSRaddt` still cannot be found.
    """
    eng = matlab.engine.start_matlab()
    if fsda_root is not None:
        eng.addpath(eng.genpath(fsda_root), nargout=0)
    if not eng.which("FSRaddt"):
        eng.quit()
        raise RuntimeError(
            "FSDA `FSRaddt` not found on the MATLAB path. Install the FSDA Add-On "
            "in MATLAB, or pass fsda_root=<FSDA install dir>."
        )
    return eng


def _to_int_array(raw) -> np.ndarray:
    """Flatten a MATLAB index value (scalar / vector / empty) to a 1-based 1D int
    array, dropping any NaN. Used for `out.la` (and any 1-D index field)."""
    arr = np.atleast_1d(np.asarray(raw, dtype=float)).reshape(-1)
    arr = arr[~np.isnan(arr)]
    return arr.astype(int)


def _to_int_matrix(raw) -> np.ndarray:
    """Coerce a MATLAB index matrix (e.g. `out.bs`, p x k) to a 2D 1-based int
    array. A scalar/vector is promoted to 2D so the shape is always (rows, cols)."""
    arr = np.atleast_2d(np.asarray(raw, dtype=float))
    return arr.astype(int)


def _normalize_un(raw) -> list[np.ndarray]:
    """Normalize FSRaddt `out.Un` (a MATLAB **cell**) to a list of numpy arrays.

    The engine maps a MATLAB cell array to a Python list, so the common case is a
    list whose elements are matlab.double monitoring matrices. Tolerate the two
    degenerate shapes too: a bare array (single tested variable returned uncelled)
    becomes a one-element list, and an empty value becomes []. Each element is left
    as-is numerically (it holds 1-based unit indices in column >= 2); no reshape.
    """
    if raw is None:
        return []
    if isinstance(raw, (list, tuple)):
        return [np.asarray(el, dtype=float) for el in raw]
    arr = np.asarray(raw, dtype=float)
    if arr.size == 0:
        return []
    return [arr]


def fsraddt(
    eng,
    y: np.ndarray,
    X: np.ndarray,
    nsamp: int = 0,
    intercept: bool = True,
    plots: int = 0,
    msg: int = 0,
    DataVars=None,
    h: int | None = None,
    init: int | None = None,
    lms: int = 1,
) -> dict:
    """Call FSDA `FSRaddt(y, X, ...)` through the engine and return the key fields.

    y         : (n,) or (n, 1) response
    X         : (n, p-1) predictor matrix (intercept added by FSDA when intercept=True)
    nsamp     : subsamples for the LXS initial subset; 0 = ALL subsets (deterministic)
    intercept : include a constant term (default True)
    plots     : FSRaddt plot level (0 none, 1 deletion-t plot with envelopes); default 0
    msg       : FSRaddt message level; when truthy, MATLAB's text output is routed to
                the terminal (engine stdout/stderr). Default 0.
    DataVars  : 1-based columns of X to run the deletion test on (None = all)
    h/init    : optional FSRaddt knobs (passed through only when not None)
    lms       : initial estimator criterion (1 = LMS, else LTS); default 1
    returns   : dict with Tdel (m, k+1), S2del (m, k+1), bs (p, k, 1-based int),
                Un (list of k arrays, from the MATLAB cell), la (k, 1-based int),
                class (str). k = number of tested variables.

    `plots`/`msg` default to 0 so the agreement gate stays headless. When `plots`
    is on, FSRaddt opens a live MATLAB figure window -- it closes when the engine
    quits, so don't `stop_engine` until you have viewed it (see `render_figures`).
    Every value is shape-checked at the boundary; no silent reshape.
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
            "lms", float(lms),
            "plots", float(plots),
            "msg", float(msg)]
    if DataVars is not None:
        dv = np.atleast_1d(np.asarray(DataVars, dtype=float)).reshape(1, -1)
        args += ["DataVars", matlab.double(dv.tolist())]
    if h is not None:
        args += ["h", float(h)]
    if init is not None:
        args += ["init", float(init)]

    if msg:
        # Surface FSRaddt's MATLAB-side messages. The engine requires io.StringIO
        # buffers (not sys.stdout directly), so capture then echo to the terminal.
        out_buf, err_buf = io.StringIO(), io.StringIO()
        out = eng.FSRaddt(*args, nargout=1, stdout=out_buf, stderr=err_buf)
        if out_buf.getvalue():
            sys.stdout.write(out_buf.getvalue())
            sys.stdout.flush()   # so embedded interpreters (reticulate/PythonCall) surface it
        if err_buf.getvalue():
            sys.stderr.write(err_buf.getvalue())
            sys.stderr.flush()
    else:
        out = eng.FSRaddt(*args, nargout=1)   # MATLAB struct -> Python dict

    la = _to_int_array(out["la"])

    Tdel = np.asarray(out["Tdel"], dtype=float)
    if Tdel.ndim != 2 or Tdel.shape[1] != 1 + la.size:
        raise RuntimeError(
            f"expected FSRaddt Tdel shape (m, 1+{la.size}), got {Tdel.shape}"
        )

    return {
        "Tdel": Tdel,
        "S2del": np.asarray(out["S2del"], dtype=float),
        "bs": _to_int_matrix(out["bs"]),
        "Un": _normalize_un(out["Un"]),
        "la": la,
        "class": str(out["class"]),
    }


def render_figures(eng) -> None:
    """Force any open MATLAB figures (e.g. from fsraddt(plots=...)) to paint."""
    eng.eval("drawnow", nargout=0)


def wait_for_figures(eng) -> None:
    """Block until the user closes all open MATLAB figures.

    fsraddt(plots=...) opens a figure window that lives in the engine and would
    vanish when it quits. This holds the engine (and the window) open until the
    user dismisses it by *closing the window(s)*. It is driven entirely MATLAB-side
    (uiwait), so it is immune to the terminal-stdin interference seen when the
    engine is embedded via reticulate / PythonCall (there, reading a key from R or
    Julia does not work). Returns immediately if no figures are open.
    """
    eng.eval(
        "drawnow; "
        "fh = findall(groot, 'Type', 'figure'); "
        "while ~isempty(fh); uiwait(fh(1)); "
        "fh = findall(groot, 'Type', 'figure'); end",
        nargout=0,
    )


def stop_engine(eng) -> None:
    """Shut the engine session down."""
    eng.quit()


def matlab_version(eng) -> str:
    """Return the MATLAB version string for diagnostics."""
    return str(eng.version())


def which_fsraddt(eng) -> str:
    """Return the resolved `FSRaddt` path for diagnostics."""
    return str(eng.which("FSRaddt"))
