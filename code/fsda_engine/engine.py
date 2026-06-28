"""Generic Layer-1 engine for FSDA — one shared bridge for many routines.

Python -> matlab.engine -> MATLAB + FSDA

Every per-routine `code/<target>/bridge.py` repeats the same engine/plumbing:
start the engine, check the routine is on the path, marshal numpy <-> matlab.double,
route MATLAB messages, handle figures, shut down. This module factors that plumbing
into ONE place so a new FSDA routine usually needs no wrapper at all -- you call

    eng = FsdaEngine.start("mahalFS")
    d   = eng.call("mahalFS", Y, MU, SIGMA)            # numeric array  -> ndarray
    out = eng.call("Score", y, X, la=la, intercept=True)  # struct      -> dict

and the generic converters handle the crossing. It covers the four *well-behaved*
MATLAB return shapes (see spec 016):

    numeric array            matlab.double      -> ndarray
    struct                   dict               -> dict (recursed)
    nested struct of arrays  dict of dicts      -> dict of dicts of ndarrays
    char/string scalar       char               -> str

OUT OF SCOPE (handled by its own bespoke bridge): `getYahoo` and anything returning
a MATLAB timetable / table / struct-array / datetime -- those do not marshal
generically (see code/getYahoo/bridge.py).

Marshalling rules (CONSTITUTION sec 4):
  * Output is returned in MATLAB's natural shape -- NO silent reshape. A column
    vector stays (n, 1); callers squeeze if they want (n,).
  * Input has ONE documented convention: a 1-D ndarray/list crosses as a MATLAB
    *row* (1 x n). Pass an (n, 1) array when a routine wants a column (e.g. y).
  * NaN / Inf are preserved; MATLAB indices stay 1-based -- interpretation is the
    caller's.

Dependencies: numpy + matlab + matlab.engine + stdlib only.

See spec 016 (specs/016-matlab-engine-generic.md) and CONSTITUTION.md.
"""
from __future__ import annotations

import io
import sys

import numpy as np
import matlab
import matlab.engine

# call() reserves these keyword names for its own control; every OTHER keyword is
# forwarded to MATLAB as a name/value pair. Notably `msg` is NOT reserved -- it
# passes straight through to FSDA (FSR/FSRaddt/getYahoo each have their own `msg`
# option). The bridge's stdout/stderr tee is `echo_output`, deliberately named so
# it cannot collide with an FSDA option. The rare case where an FSDA option's name
# does collide with one of these reserved words is handled via the `options` dict:
#     eng.call("FSR", y, X, options={"nargout": ...})
_RESERVED_CALL_KWARGS = ("nargout", "echo_output", "options")


def to_matlab(x):
    """Marshal a Python value to a MATLAB-engine input type.

    ndarray : 0-D -> float; 1-D -> MATLAB row (1 x n); 2-D -> matlab.double as-is.
              (1-D -> row is a *convention*; pass an (n, 1) array for a column.)
    bool    -> bool (MATLAB logical) -- checked before int (bool is an int subclass).
    int/float -> float.   str -> str (char).   list/tuple of numbers -> row matlab.double.
    Anything else is passed through untouched (already a matlab.* type, etc.).
    """
    if isinstance(x, np.ndarray):
        a = np.asarray(x, dtype=float)
        if a.ndim == 0:
            return float(a)
        if a.ndim == 1:
            a = a.reshape(1, -1)            # documented: 1-D -> MATLAB row
        return matlab.double(a.tolist())
    if isinstance(x, bool):
        return x
    if isinstance(x, (int, float)):
        return float(x)
    if isinstance(x, str):
        return x
    if isinstance(x, (list, tuple)):
        return matlab.double([float(v) for v in x])
    return x


def from_matlab(x):
    """Marshal a MATLAB-engine return value to plain Python, recursively.

    None        -> None (e.g. an nargout=0 call).
    dict        -> {k: from_matlab(v)}                 (struct / nested struct).
    str/bool/int/float -> passed through                (char scalar, logical scalar).
    list/tuple  -> [from_matlab(v) ...]                 (cell array / nargout > 1).
    matlab.*    -> np.asarray(x)  (numeric/logical array; shape & NaN/Inf preserved,
                  NO reshape).
    """
    if x is None:
        return None
    if isinstance(x, dict):
        return {k: from_matlab(v) for k, v in x.items()}
    if isinstance(x, str):
        return x
    if isinstance(x, (bool, int, float)):
        return x
    if isinstance(x, (list, tuple)):
        return [from_matlab(v) for v in x]
    # matlab.double / matlab.logical / matlab.int* and anything array-like.
    try:
        return np.asarray(x)
    except Exception:
        return x


class FsdaEngine:
    """A reusable MATLAB engine session with a generic, routine-agnostic `call`."""

    def __init__(self, eng):
        self.eng = eng

    # --- lifecycle -----------------------------------------------------------
    @classmethod
    def start(cls, routine: str | None = None, fsda_root: str | None = None) -> "FsdaEngine":
        """Start a MATLAB engine; optionally verify one FSDA `routine` resolves.

        FSDA is normally a MATLAB Add-On (already on the path), so `fsda_root` can
        be None; pass the FSDA install dir only as a fallback (added with
        addpath(genpath(...))). When `routine` is given and cannot be found, the
        engine is closed and RuntimeError is raised.
        """
        eng = matlab.engine.start_matlab()
        if fsda_root:
            eng.addpath(eng.genpath(fsda_root), nargout=0)
        if routine and not eng.which(routine):
            eng.quit()
            raise RuntimeError(
                f"FSDA `{routine}` not found on the MATLAB path. Install the FSDA "
                f"Add-On in MATLAB, or pass fsda_root=<FSDA install dir>."
            )
        return cls(eng)

    def stop(self) -> None:
        """Shut the engine session down (startup is slow -- callers control this)."""
        self.eng.quit()

    # --- the generic call ----------------------------------------------------
    def call(self, name: str, *args, nargout: int = 1, echo_output: bool = False,
             options: dict | None = None, **kwargs):
        """Call FSDA function `name` generically and return plain Python.

        Positional `args` are marshalled with `to_matlab` and passed in order.
        Keyword args (and any `options` dict) become MATLAB name/value pairs, in
        the given order -- e.g. ``call("Score", y, X, la=la, intercept=True)``
        sends ``Score(y, X, 'la', la, 'intercept', true)``. FSDA's own ``msg``
        option is just such a kwarg -- ``call("FSR", y, X, msg=0)`` forwards it to
        MATLAB (it is NOT consumed by the bridge).

        nargout     : number of outputs to request (default 1).
        echo_output : when True, route MATLAB's stdout/stderr to this terminal (the
                      engine needs io.StringIO buffers, so capture then echo). This
                      is the bridge's OWN tee, named so it cannot clash with an FSDA
                      option; it does not change what FSDA prints, only whether an
                      embedded host (reticulate / PythonCall) surfaces it.
        """
        margs = [to_matlab(a) for a in args]
        pairs = dict(options or {})
        pairs.update(kwargs)
        for key, value in pairs.items():
            margs.append(key)               # option name crosses as a char literal
            margs.append(to_matlab(value))

        fn = getattr(self.eng, name)
        if echo_output:
            out_buf, err_buf = io.StringIO(), io.StringIO()
            raw = fn(*margs, nargout=nargout, stdout=out_buf, stderr=err_buf)
            if out_buf.getvalue():
                sys.stdout.write(out_buf.getvalue())
                sys.stdout.flush()          # surface under reticulate / PythonCall too
            if err_buf.getvalue():
                sys.stderr.write(err_buf.getvalue())
                sys.stderr.flush()
        else:
            raw = fn(*margs, nargout=nargout)
        return from_matlab(raw)

    def eval(self, expr: str, nargout: int = 1):
        """Evaluate a MATLAB expression and marshal the result back generically.

        Handy for building/reading values the function `call` surface does not
        cover (e.g. a constructed nested struct). nargout=0 returns None.
        """
        if nargout == 0:
            self.eng.eval(expr, nargout=0)
            return None
        return from_matlab(self.eng.eval(expr, nargout=nargout))

    # --- diagnostics ---------------------------------------------------------
    def which(self, name: str) -> str:
        """Resolved path of FSDA function `name` (empty str if not found)."""
        return str(self.eng.which(name))

    def version(self) -> str:
        """MATLAB version string."""
        return str(self.eng.version())

    # --- figures (parity with the per-routine bridges) -----------------------
    def render_figures(self) -> None:
        """Force any open MATLAB figures to paint."""
        self.eng.eval("drawnow", nargout=0)

    def wait_for_figures(self) -> None:
        """Block until the user closes all open MATLAB figures.

        Driven entirely MATLAB-side (uiwait), so it is immune to the terminal-stdin
        interference seen when the engine is embedded via reticulate / PythonCall.
        Returns immediately if no figures are open.
        """
        self.eng.eval(
            "drawnow; "
            "fh = findall(groot, 'Type', 'figure'); "
            "while ~isempty(fh); uiwait(fh(1)); "
            "fh = findall(groot, 'Type', 'figure'); end",
            nargout=0,
        )
