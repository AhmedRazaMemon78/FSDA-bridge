"""pyfsda — call FSDA (MATLAB robust-statistics toolbox) routines from Python.

One reusable MATLAB Engine session, a routine-agnostic ``call`` / ``eval`` surface,
and generic numpy <-> MATLAB marshalling::

    from pyfsda import FsdaEngine

    eng = FsdaEngine.start("mahalFS")
    d   = eng.call("mahalFS", Y, MU, SIGMA)               # numeric array -> ndarray
    out = eng.call("Score", y, X, la=la, intercept=True)  # struct        -> dict
    eng.stop()

Requires MATLAB with the FSDA Add-On and a ``matlabengine`` release matching that
MATLAB (see the README).
"""
from __future__ import annotations

from .engine import FsdaEngine, from_matlab, to_matlab

__version__ = "0.1.0"

__all__ = ["FsdaEngine", "to_matlab", "from_matlab", "__version__"]
