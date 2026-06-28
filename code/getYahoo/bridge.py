"""Layer-1 bridge for FSDA `getYahoo` (download financial time series from Yahoo).

Python -> matlab.engine -> MATLAB + FSDA

Start a MATLAB engine session, call the genuine FSDA `getYahoo(ticker, ...)`, and
marshal the result back as plain Python. `getYahoo` is the richest crossing in this
repo so far: called with several tickers it returns a MATLAB **struct array** (one
element per ticker), and each element carries a MATLAB **timetable** (`out.TT`) and a
nested **Indicators** struct -- none of which the engine hands back cleanly. So the
bridge does NOT rely on a direct struct-array return; it keeps `out` in the MATLAB
base workspace and decomposes it field-by-field with `eng.eval`, marshalling each
value explicitly (CONSTITUTION §4).

Output (per ticker), as returned by `get_yahoo`:

    Ticker            str     ticker symbol
    LastPeriod        str     requested period
    intervalRequested str     requested interval (after validation)
    intervalActual    str     granularity Yahoo actually returned
    TimeZone          str     exchange timezone
    TT                dict    {time:[ISO str], Open, High, Low, Close, Volume}
    Indicators        dict    11 numeric arrays (RSI, StochK, ... maSlow)
    Success           bool    download + processing succeeded
    Message           str     human-readable status
    class             str     'getYahoo'

Five things make `getYahoo` a harder crossing than FSR/FSRaddt (see spec 013):
  * struct ARRAY return -> Python list of dicts (FSR/FSRaddt returned one struct);
  * timetable `out.TT` -> {time, OHLCV}, decomposed MATLAB-side (does not marshal);
  * timezone-aware datetime row-times -> ISO 8601 strings;
  * nested `Indicators` struct -> dict of numpy arrays (NaN-preserving);
  * `string` scalars -> str (wrapped with char() before crossing).

Because the live values change every call, the deterministic agreement gate is a
fixed 1-second `timerange` window on a PAST bar (its OHLCV is finalized and no longer
moves). `timerange_window` runs that exact MATLAB snippet and returns its OHLCV row.
`plots`/`msg` default to off (headless gate); set them to view getYahoo's three-panel
figures (one window per ticker) and route its messages to the terminal.

See spec 013 (specs/013-matlab-engine-getYahoo.md) and CONSTITUTION.md.
"""
from __future__ import annotations

import io
import re
import sys

import numpy as np
import matlab
import matlab.engine

# Fields of out.Indicators, in the order getYahoo.m builds them.
INDICATOR_FIELDS = (
    "RSI", "StochK", "StochD", "MACD", "MACDSignal", "MACDHist",
    "WilliamsR", "ROC", "maFast", "maMid", "maSlow",
)

# MATLAB-side datetime -> string format (ISO 8601 with zone offset).
_TIME_FMT = "yyyy-MM-dd HH:mm:ssZ"

# Conservative allow-lists: these strings are interpolated into MATLAB `eval`
# commands, so reject anything that is not a plain ticker / option token / datetime.
_TICKER_RE = re.compile(r"^[A-Za-z0-9.^=:+\-]+$")
_TOKEN_RE = re.compile(r"^[A-Za-z0-9]+$")
_DATETIME_RE = re.compile(r"^[A-Za-z0-9 :.\-]+$")


def start_engine(fsda_root: str | None = None):
    """Start a MATLAB engine and make sure FSDA `getYahoo` resolves.

    FSDA is normally installed as a MATLAB Add-On, so `getYahoo` is already on the
    path and `fsda_root` can be left as None. Pass the FSDA install dir only as a
    fallback; it is added with addpath(genpath(...)). Raises RuntimeError if
    `getYahoo` still cannot be found.
    """
    eng = matlab.engine.start_matlab()
    if fsda_root is not None:
        eng.addpath(eng.genpath(fsda_root), nargout=0)
    if not eng.which("getYahoo"):
        eng.quit()
        raise RuntimeError(
            "FSDA `getYahoo` not found on the MATLAB path. Install the FSDA Add-On "
            "in MATLAB, or pass fsda_root=<FSDA install dir>."
        )
    return eng


def _normalize_tickers(tickers) -> list[str]:
    """Accept a single str or an iterable of str; return a validated list[str]."""
    if isinstance(tickers, str):
        tickers = [tickers]
    out = []
    for t in tickers:
        t = str(t)
        if not _TICKER_RE.match(t):
            raise ValueError(f"unsafe / malformed ticker symbol: {t!r}")
        out.append(t)
    if not out:
        raise ValueError("at least one ticker is required")
    return out


def _ticker_cell_literal(tickers: list[str]) -> str:
    """Build a MATLAB cell-array literal {'G.MI','ENEL.MI'} from validated tickers."""
    return "{" + ",".join("'" + t + "'" for t in tickers) + "}"


def _check_token(value: str, name: str) -> str:
    if not _TOKEN_RE.match(value):
        raise ValueError(f"unsafe / malformed {name}: {value!r}")
    return value


def _cellstr_to_list(raw) -> list[str]:
    """MATLAB cellstr -> Python list[str]. The engine returns a 1-element cell as a
    bare str and a multi-element cell as a list; collapse both to a list[str]."""
    if raw is None:
        return []
    if isinstance(raw, str):
        return [raw]
    return [str(x) for x in raw]


def _times_and_values(eng, tt_var: str) -> tuple[list[str], np.ndarray]:
    """Decompose a MATLAB timetable variable into (ISO times, n x 5 OHLCV).

    `tt_var` must be the NAME of a MATLAB workspace variable bound to a timetable,
    not a compound expression: MATLAB forbids dot/property access on a parenthesized
    expression -- `(out(1).TT).Properties` raises "Invalid use of operator" -- so
    callers assign the timetable to a temp var first (e.g. `gyTT`, `gySub`; MATLAB
    identifiers must start with a letter, so no leading underscore). Done entirely
    MATLAB-side because a timetable does not marshal across the boundary.
    """
    h = int(eng.eval(f"height({tt_var})", nargout=1))
    if h == 0:
        return [], np.empty((0, 5), dtype=float)
    # Read row-times via Properties.RowTimes (name-independent: getYahoo's timetable
    # dimension may or may not be called 'Time'); format as ISO 8601 with zone.
    times = _cellstr_to_list(
        eng.eval(
            f"cellstr(string({tt_var}.Properties.RowTimes,'{_TIME_FMT}'))",
            nargout=1,
        )
    )
    vals = np.asarray(eng.eval(f"{tt_var}.Variables", nargout=1), dtype=float)
    if vals.ndim != 2 or vals.shape[1] != 5:
        raise RuntimeError(
            f"expected timetable to have 5 variables (OHLCV), got shape {vals.shape}"
        )
    if len(times) != vals.shape[0]:
        raise RuntimeError(
            f"timetable time/length mismatch: {len(times)} times vs {vals.shape[0]} rows"
        )
    return times, vals


def _tt_dict(times: list[str], vals: np.ndarray) -> dict:
    """Pack decomposed timetable pieces into the bridge's TT dict."""
    return {
        "time": times,
        "Open": vals[:, 0].copy(),
        "High": vals[:, 1].copy(),
        "Low": vals[:, 2].copy(),
        "Close": vals[:, 3].copy(),
        "Volume": vals[:, 4].copy(),
    }


def _read_struct_element(eng, ii: int) -> dict:
    """Marshal `out(ii)` (1-based) from the MATLAB workspace into a Python dict."""
    def s(field: str) -> str:
        # string/char scalar -> str (char() makes string scalars cross as str).
        return str(eng.eval(f"char(out({ii}).{field})", nargout=1))

    success = bool(eng.eval(f"logical(out({ii}).Success)", nargout=1))

    # Assign the timetable to a temp var first: _times_and_values reads its
    # .Properties.RowTimes / .Variables, and MATLAB rejects those on a parenthesized
    # expression like (out(ii).TT).Properties ("Invalid use of operator"). The temp
    # name starts with a letter -- MATLAB identifiers cannot begin with underscore.
    eng.eval(f"gyTT = out({ii}).TT;", nargout=0)
    try:
        times, vals = _times_and_values(eng, "gyTT")
    finally:
        eng.eval("clear gyTT", nargout=0)
    height = vals.shape[0]

    indicators = {}
    if height > 0:
        for name in INDICATOR_FIELDS:
            arr = np.asarray(
                eng.eval(f"out({ii}).Indicators.{name}", nargout=1), dtype=float
            ).reshape(-1)
            if arr.size != height:
                raise RuntimeError(
                    f"Indicators.{name} length {arr.size} != TT height {height} "
                    f"for ticker {ii}"
                )
            indicators[name] = arr

    return {
        "Ticker": s("Ticker"),
        "LastPeriod": s("LastPeriod"),
        "intervalRequested": s("intervalRequested"),
        "intervalActual": s("intervalActual"),
        "TimeZone": s("TimeZone"),
        "TT": _tt_dict(times, vals),
        "Indicators": indicators,
        "Success": success,
        "Message": s("Message"),
        "class": s("class"),
    }


def get_yahoo(
    eng,
    tickers,
    plots: int = 0,
    msg: int = 0,
    last_period: str | None = None,
    interval: str | None = None,
    auto_fix_interval: bool | None = None,
) -> list[dict]:
    """Call FSDA `getYahoo(ticker, ...)` and return one dict per ticker.

    tickers           : a single ticker str, or an iterable of ticker strs
                        (e.g. 'G.MI' or ['G.MI', 'ENEL.MI'])
    plots             : 1 -> a three-panel figure per ticker; 0 headless (default)
    msg               : 1 -> route getYahoo's progress messages to the terminal
    last_period       : LastPeriod token (e.g. '5d','1y'); None = getYahoo default
    interval          : interval token (e.g. '1m','1d'); None = getYahoo default
    auto_fix_interval : override autoFixInterval; None = getYahoo default (true)

    Returns a list of length numel(out) -- the struct-array crossing -- each element
    a dict (see module docstring). `out` is left in the MATLAB base workspace so
    `timerange_window` can run the deterministic gate snippet on it.

    `plots`/`msg` default to 0 so the agreement gate stays headless. When `plots` is
    on, getYahoo opens live MATLAB figure windows (one per ticker) -- they close when
    the engine quits, so don't `stop_engine` until you have viewed them (see
    `render_figures` / `wait_for_figures`). Every value is shape/type-checked at the
    boundary; no silent reshape.
    """
    tickers = _normalize_tickers(tickers)
    cell = _ticker_cell_literal(tickers)

    args = [cell, f"'plots',{int(bool(plots))}", f"'msg',{int(bool(msg))}"]
    if last_period is not None:
        args.append(f"'LastPeriod','{_check_token(str(last_period), 'LastPeriod')}'")
    if interval is not None:
        args.append(f"'interval','{_check_token(str(interval), 'interval')}'")
    if auto_fix_interval is not None:
        args.append(f"'autoFixInterval',{str(bool(auto_fix_interval)).lower()}")
    cmd = "out = getYahoo(" + ",".join(args) + ");"

    if msg:
        # Surface getYahoo's MATLAB-side messages. The engine requires io.StringIO
        # buffers (not sys.stdout directly), so capture then echo to the terminal.
        out_buf, err_buf = io.StringIO(), io.StringIO()
        eng.eval(cmd, nargout=0, stdout=out_buf, stderr=err_buf)
        if out_buf.getvalue():
            sys.stdout.write(out_buf.getvalue())
            sys.stdout.flush()   # so embedded interpreters (reticulate/PythonCall) surface it
        if err_buf.getvalue():
            sys.stderr.write(err_buf.getvalue())
            sys.stderr.flush()
    else:
        eng.eval(cmd, nargout=0)

    nout = int(eng.eval("numel(out)", nargout=1))
    return [_read_struct_element(eng, ii) for ii in range(1, nout + 1)]


def timerange_window(eng, idx: int, t0: str, t1: str) -> dict:
    """Deterministic gate oracle: run the owner's exact `timerange` snippet.

        Tk = out(idx).TT;
        tr = timerange("t0","t1");
        Tk(tr,:)

    on the struct-array element `idx` (1-based) left in the workspace by
    `get_yahoo`, and return the matched bar(s) as a TT dict
    {time, Open, High, Low, Close, Volume}. A fixed 1-second window on a past bar
    isolates a single, finalized OHLCV row, so the values are deterministic across
    runs and across the three language surfaces. Raises if `get_yahoo` was not
    called first (no `out` in the workspace).
    """
    if not int(eng.eval("exist('out','var')", nargout=1)):
        raise RuntimeError("call get_yahoo(...) before timerange_window(...)")
    t0 = t0 if _DATETIME_RE.match(t0) else None
    t1 = t1 if _DATETIME_RE.match(t1) else None
    if t0 is None or t1 is None:
        raise ValueError("unsafe / malformed timerange endpoint")
    # Temp names start with a letter (MATLAB identifiers cannot begin with underscore).
    eng.eval(
        f'gyTR = timerange("{t0}","{t1}"); gySub = out({int(idx)}).TT(gyTR,:);',
        nargout=0,
    )
    times, vals = _times_and_values(eng, "gySub")
    eng.eval("clear gyTR gySub", nargout=0)
    return _tt_dict(times, vals)


def render_figures(eng) -> None:
    """Force any open MATLAB figures (from get_yahoo(plots=1)) to paint."""
    eng.eval("drawnow", nargout=0)


def wait_for_figures(eng) -> None:
    """Block until the user closes all open MATLAB figures.

    get_yahoo(plots=1) opens one figure window per ticker; they live in the engine
    and would vanish when it quits. This holds the engine (and the windows) open
    until the user dismisses them by *closing the window(s)*. It is driven entirely
    MATLAB-side (uiwait), so it is immune to the terminal-stdin interference seen
    when the engine is embedded via reticulate / PythonCall. Returns immediately if
    no figures are open.
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


def which_getyahoo(eng) -> str:
    """Return the resolved `getYahoo` path for diagnostics."""
    return str(eng.which("getYahoo"))
