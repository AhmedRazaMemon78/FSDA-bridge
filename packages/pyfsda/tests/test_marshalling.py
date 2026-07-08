"""Unit tests for the pure marshalling helpers -- no running MATLAB required.

Only the `matlab` *client* module (from the `matlabengine` package) is needed to build
`matlab.double` values; the MATLAB engine itself is never started here. The whole module
is skipped when `matlabengine` is not installed.
"""
import numpy as np
import pytest

matlab = pytest.importorskip("matlab")
pytest.importorskip("pyfsda")
from pyfsda import from_matlab, to_matlab


def test_to_matlab_0d_ndarray_becomes_float():
    r = to_matlab(np.array(3.0))
    assert isinstance(r, float) and r == 3.0


def test_to_matlab_1d_becomes_matlab_row():
    m = to_matlab(np.array([1.0, 2.0, 3.0]))
    assert isinstance(m, matlab.double)
    assert m.size == (1, 3)                      # documented: 1-D -> MATLAB row


def test_to_matlab_2d_shape_preserved():
    m = to_matlab(np.array([[1.0, 2.0], [3.0, 4.0]]))
    assert isinstance(m, matlab.double)
    assert m.size == (2, 2)


def test_to_matlab_bool_checked_before_int():
    r = to_matlab(True)
    assert r is True and isinstance(r, bool)     # NOT coerced to 1.0


def test_to_matlab_int_float_str_list():
    assert to_matlab(5) == 5.0 and isinstance(to_matlab(5), float)
    assert to_matlab("hi") == "hi"
    m = to_matlab([1.0, 2.0, 3.0])
    assert isinstance(m, matlab.double) and m.size == (1, 3)


def test_from_matlab_passthrough():
    assert from_matlab(None) is None
    assert from_matlab("x") == "x"
    assert from_matlab(3.0) == 3.0
    assert from_matlab(True) is True


def test_from_matlab_double_to_ndarray():
    arr = from_matlab(matlab.double([[1.0, 2.0, 3.0]]))
    assert isinstance(arr, np.ndarray)
    np.testing.assert_allclose(np.asarray(arr, dtype=float).reshape(-1), [1.0, 2.0, 3.0])


def test_from_matlab_dict_and_list_recursed():
    d = from_matlab({"a": matlab.double([[1.0, 2.0]]), "s": "txt"})
    assert isinstance(d, dict) and isinstance(d["a"], np.ndarray) and d["s"] == "txt"
    lst = from_matlab([matlab.double([[1.0]]), "y", 2.0])
    assert isinstance(lst, list) and lst[1] == "y" and lst[2] == 2.0


def test_roundtrip_matrix():
    a = np.array([[1.0, 2.0, 3.0], [4.0, 5.0, 6.0]])
    back = np.asarray(from_matlab(to_matlab(a)), dtype=float)
    np.testing.assert_allclose(back, a)
