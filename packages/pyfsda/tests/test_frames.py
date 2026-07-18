"""Unit tests for the optional pandas view helpers (``pyfsda.frames``) -- no MATLAB engine.

Importing ``pyfsda`` pulls in the ``matlab`` client package, so the module skips when that
is absent (same guard as ``test_marshalling.py``); the MATLAB engine itself is never
started. The ``to_dataframe`` cases additionally skip when pandas is not installed.
"""
import pytest

pytest.importorskip("pyfsda")
from pyfsda import is_table_dict, to_dataframe
from pyfsda.frames import apply_frames, is_dataframe


def _table_dict():
    import numpy as np
    return {
        "VariableNames": ["a", "b"],
        "data": {"a": np.array([1.0, 2.0, 3.0]), "b": ["x", "y", "z"]},
        "height": 3,
        "RowNames": [],
    }


def test_is_table_dict_positive_and_negative():
    assert is_table_dict(_table_dict())
    assert not is_table_dict({"VariableNames": ["a"]})        # no data / rows key
    assert not is_table_dict({"data": {}, "RowNames": []})    # no VariableNames
    assert not is_table_dict(42)


def test_is_dataframe_false_for_non_dataframe():
    assert not is_dataframe(42)
    assert not is_dataframe({"VariableNames": []})
    assert not is_dataframe([1, 2, 3])


def test_to_dataframe_columns_values_default_index():
    pytest.importorskip("pandas")
    df = to_dataframe(_table_dict())
    assert is_dataframe(df)
    assert list(df.columns) == ["a", "b"]                    # VariableNames order
    assert df["a"].tolist() == [1.0, 2.0, 3.0]
    assert df["b"].tolist() == ["x", "y", "z"]
    assert list(df.index) == [0, 1, 2]                       # empty RowNames -> RangeIndex


def test_to_dataframe_rownames_become_index():
    pytest.importorskip("pandas")
    d = _table_dict()
    d["RowNames"] = ["r1", "r2", "r3"]
    df = to_dataframe(d)
    assert list(df.index) == ["r1", "r2", "r3"]


def test_to_dataframe_rowtimes_parsed_to_datetime():
    pd = pytest.importorskip("pandas")
    import numpy as np
    d = {
        "VariableNames": ["v"],
        "data": {"v": np.array([10.0, 20.0])},
        "height": 2,
        "RowTimes": ["2020-01-01", "2020-01-02"],
    }
    df = to_dataframe(d)
    assert isinstance(df.index, pd.DatetimeIndex)


def test_apply_frames_recurses_tuple_and_struct():
    pytest.importorskip("pandas")
    td = _table_dict()
    out = apply_frames((td, 3.0))                            # nargout>1 tuple
    assert is_dataframe(out[0]) and out[1] == 3.0
    out2 = apply_frames({"Tsel": td, "n": 3})               # struct holding a table field
    assert is_dataframe(out2["Tsel"]) and out2["n"] == 3
    assert apply_frames("hello") == "hello"                 # non-table passthrough


def test_to_dataframe_rejects_non_table_dict():
    with pytest.raises(TypeError):
        to_dataframe({"not": "a table"})
