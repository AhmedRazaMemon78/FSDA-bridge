"""Integration smoke test -- requires a running MATLAB with the FSDA Add-On.

Run locally with:  pytest -m integration
It is deselected by the default ``-m "not integration"`` and skips itself when MATLAB /
FSDA cannot be started.
"""
import numpy as np
import pytest

pytest.importorskip("matlab.engine")
from pyfsda import FsdaEngine


@pytest.mark.integration
def test_mahalfs_matches_numpy():
    """mahalFS(Y, MU, SIGMA) must equal the numpy Mahalanobis oracle to 1e-9."""
    try:
        eng = FsdaEngine.start("mahalFS", check_version=False)
    except Exception as exc:                      # no MATLAB / FSDA on this machine
        pytest.skip(f"MATLAB with FSDA not available: {exc}")
    try:
        Y = np.array([[1.0, 2.0], [2.0, 0.0], [3.0, 5.0], [0.0, -1.0], [4.0, 4.0]])
        MU = np.array([2.0, 2.0])
        SIGMA = np.array([[2.0, 0.5], [0.5, 1.0]])
        d = np.asarray(eng.call("mahalFS", Y, MU, SIGMA), dtype=float).reshape(-1)
        diff = Y - MU.reshape(1, -1)
        ref = np.sum((diff @ np.linalg.inv(SIGMA)) * diff, axis=1)
        np.testing.assert_allclose(d, ref, rtol=0.0, atol=1e-9)
    finally:
        eng.stop()
