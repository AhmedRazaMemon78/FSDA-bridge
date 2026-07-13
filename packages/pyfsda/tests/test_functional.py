"""Tests for the functional façade -- pyfsda.<name>(...) over a shared engine.

Unit tests need no MATLAB (they only check attribute wiring). The integration test
starts MATLAB and is skipped when it is unavailable.
"""
import io
import json
from unittest import mock

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


# --- unit: first-call GitHub latest-version notice (network mocked) ----------
def _fake_urlopen(payload):
    """Return a stand-in for urllib.request.urlopen yielding `payload` as JSON."""
    def _urlopen(url, timeout=None):
        cm = mock.MagicMock()
        cm.__enter__.return_value = io.BytesIO(json.dumps(payload).encode())
        cm.__exit__.return_value = False
        return cm
    return _urlopen


def _reset_notice(check_version=True):
    pyfsda._LATEST_CHECKED = False
    pyfsda._CHECK_VERSION = check_version


def test_latest_notice_prints_once(capsys):
    _reset_notice()
    with mock.patch("urllib.request.urlopen", _fake_urlopen({"tag_name": "8.7.11.0"})):
        pyfsda._notify_latest_fsda()
        pyfsda._notify_latest_fsda()                  # latched -> no second message
    err = capsys.readouterr().err
    # the notice phrase appears once per print -> exactly one confirms the run-once latch
    assert err.count("latest FSDA release on GitHub") == 1 and "8.7.11.0" in err


def test_latest_notice_silent_on_error(capsys):
    _reset_notice()

    def _boom(url, timeout=None):
        raise OSError("network down")

    with mock.patch("urllib.request.urlopen", _boom):
        pyfsda._notify_latest_fsda()                  # must not raise
    assert capsys.readouterr().err == ""


def test_latest_notice_respects_check_version(capsys):
    _reset_notice(check_version=False)
    with mock.patch("urllib.request.urlopen", _fake_urlopen({"tag_name": "8.7.11.0"})):
        pyfsda._notify_latest_fsda()
    assert capsys.readouterr().err == ""


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
