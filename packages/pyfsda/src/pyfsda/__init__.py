"""pyfsda — call FSDA (MATLAB robust-statistics toolbox) routines from Python.

Two ways to call, over the same generic engine and numpy <-> MATLAB marshalling.

Functional (MATLAB-like) — call any FSDA routine as ``pyfsda.<name>(...)``; the shared
MATLAB session starts on first use and is reused::

    import pyfsda

    d   = pyfsda.mahalFS(Y, MU, SIGMA)               # numeric array -> ndarray
    out = pyfsda.Score(y, X, la=la, intercept=True)  # struct        -> dict
    RAW, REW = pyfsda.mcd(Y, nargout=2)              # two outputs   -> tuple
    pyfsda.stop()                                     # optional; also runs at exit

Explicit session (advanced) — manage the engine yourself::

    from pyfsda import FsdaEngine
    eng = FsdaEngine.start("mahalFS")
    d   = eng.call("mahalFS", Y, MU, SIGMA)
    eng.stop()

Requires MATLAB with the FSDA Add-On and a ``matlabengine`` release matching that
MATLAB (see the README).
"""
from __future__ import annotations

import atexit

from .engine import FsdaEngine, from_matlab, to_matlab

__version__ = "0.2.0"

__all__ = [
    "FsdaEngine", "to_matlab", "from_matlab",
    "start", "stop", "engine", "__version__",
]

# --- shared lazily-started engine (backs the functional pyfsda.<name>(...) surface) ----
_ENGINE: FsdaEngine | None = None
_WRAPPERS: dict = {}
_VALIDATED: set = set()          # FSDA names confirmed on-path for the current engine

# A few common FSDA routines advertised by __dir__ for REPL discoverability. The
# __getattr__ mechanism accepts ANY FSDA function name, not just these.
_COMMON = (
    "mahalFS", "Score", "FSR", "FSRaddt", "FSM", "mcd", "pcaFS",
    "corrNominal", "tabulateFS", "TBwei", "bc", "combsFS",
)


def start(routine: str | None = None, fsda_root: str | None = None,
          check_version: bool = True) -> FsdaEngine:
    """Start (once) and return the shared FSDA engine used by ``pyfsda.<name>(...)``.

    Idempotent: returns the already-running engine on later calls. Call this before the
    first routine only if you need to set ``fsda_root`` or disable ``check_version``.
    """
    global _ENGINE
    if _ENGINE is None:
        _ENGINE = FsdaEngine.start(routine=routine, fsda_root=fsda_root,
                                   check_version=check_version)
    return _ENGINE


def engine() -> FsdaEngine:
    """Return the shared engine, starting it with defaults if needed."""
    return start()


def stop() -> None:
    """Shut the shared engine down (safe to call when it was never started)."""
    global _ENGINE
    if _ENGINE is not None:
        try:
            _ENGINE.stop()
        finally:
            _ENGINE = None
            _VALIDATED.clear()


atexit.register(stop)


def _make_wrapper(name: str):
    """Build (and cache) a callable that runs FSDA `name` on the shared engine."""
    def _fsda_call(*args, **kwargs):
        eng = engine()
        if name not in _VALIDATED:                     # verify once per name (typo guard)
            if not eng.which(name):
                raise AttributeError(
                    f"FSDA function {name!r} not found on the MATLAB path."
                )
            _VALIDATED.add(name)
        return eng.call(name, *args, **kwargs)
    _fsda_call.__name__ = name
    _fsda_call.__qualname__ = name
    _fsda_call.__doc__ = (f"Call FSDA `{name}` on the shared pyfsda engine: "
                          f"pyfsda.{name}(*args, **name_value_options).")
    return _fsda_call


def __getattr__(name: str):                            # PEP 562 module-level hook
    """Expose any FSDA routine as ``pyfsda.<name>`` (e.g. ``pyfsda.Score``)."""
    if name.startswith("_"):                            # don't hijack dunders/privates
        raise AttributeError(f"module 'pyfsda' has no attribute {name!r}")
    wrapper = _WRAPPERS.get(name)
    if wrapper is None:
        wrapper = _WRAPPERS[name] = _make_wrapper(name)
    return wrapper


def __dir__() -> list:
    return sorted(set(__all__) | set(_COMMON))
