"""Tests for the functional façade -- pyfsda.<name>(...) over a shared engine.

Unit tests need no MATLAB (they only check attribute wiring). The integration test
starts MATLAB and is skipped when it is unavailable.
"""
import numpy as np
import pytest

pytest.importorskip("matlab")
import pyfsda


# --- unit: attribute wiring (no MATLAB started) ------------------------------
def test_dynamic_attr_returns_callable():
    fn = pyfsda.Score
    assert callable(fn) and fn.__name__ == "Score"


def test_same_wrapper_is_cached():
    assert pyfsda.mahalFS is pyfsda.mahalFS          # cached, stable identity


def test_from_import_works():
    from pyfsda import mahalFS                        # import triggers __getattr__
    assert callable(mahalFS)


def test_underscore_names_raise():
    with pytest.raises(AttributeError):
        _ = pyfsda.__something_private__
    with pytest.raises(AttributeError):
        _ = pyfsda._notafunction


def test_public_api_present():
    for name in ("FsdaEngine", "start", "stop", "engine", "to_matlab", "from_matlab"):
        assert hasattr(pyfsda, name)
    assert "Score" in dir(pyfsda)                     # advertised for discoverability


# --- integration: real MATLAB + FSDA -----------------------------------------
@pytest.mark.integration
def test_functional_calls_match_engine():
    """pyfsda.mahalFS / pyfsda.Score behave exactly like the explicit engine calls."""
    try:
        pyfsda.start(check_version=False)
    except Exception as exc:                          # no MATLAB / FSDA here
        pytest.skip(f"MATLAB with FSDA not available: {exc}")
    try:
        Y = np.array([[1.0, 2.0], [2.0, 0.0], [3.0, 5.0], [0.0, -1.0], [4.0, 4.0]])
        MU = np.array([2.0, 2.0])
        SIGMA = np.array([[2.0, 0.5], [0.5, 1.0]])
        d = np.asarray(pyfsda.mahalFS(Y, MU, SIGMA), dtype=float).reshape(-1)
        diff = Y - MU.reshape(1, -1)
        ref = np.sum((diff @ np.linalg.inv(SIGMA)) * diff, axis=1)
        np.testing.assert_allclose(d, ref, rtol=0.0, atol=1e-9)

        # struct -> dict, name/value options (small valid regression; y must be positive)
        rng = np.random.default_rng(0)
        Xf = rng.normal(size=(20, 2))
        yf = np.abs(rng.normal(loc=5.0, size=(20, 1))) + 1.0     # (n,1) positive column
        out = pyfsda.Score(yf, Xf, intercept=True)
        assert isinstance(out, dict) and "Score" in out

        # typo -> friendly AttributeError, not a raw MATLAB error
        with pytest.raises(AttributeError):
            pyfsda.NoSuchFsdaFunction123(Y)
    finally:
        pyfsda.stop()
