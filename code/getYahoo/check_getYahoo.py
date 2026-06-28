"""Agreement check: FSDA `getYahoo` through matlab.engine on two Milan tickers.

Run with the project venv's Python (the script's own dir is put on sys.path so
`import bridge` works). With an activated venv just `python check_getYahoo.py`; or
point FSDA_DEV_VENV at the venv's python executable and run it directly:

    %FSDA_DEV_VENV% code\\getYahoo\\check_getYahoo.py [FSDA_ROOT]   # Windows
    "$FSDA_DEV_VENV" code/getYahoo/check_getYahoo.py [FSDA_ROOT]    # macOS / Linux

`getYahoo` downloads LIVE data, so its values change every call -- an FSR-style
frozen-golden gate would fail by construction. The fix (per the project owner): gate
on a fixed 1-second `timerange` window over a PAST bar, whose OHLCV is finalized and
no longer moves. The mandated MATLAB gate code is

    T1 = out(1).TT;  tr = timerange("23-Jun-2026 09:00:00","23-Jun-2026 09:00:01");
    T1(tr,:)                                         % and likewise for out(2).TT

run MATLAB-side by `bridge.timerange_window`. The extracted OHLCV row for both
tickers is compared to the committed golden (reference/getYahoo_window.csv) at
atol=1e-9 -- the same mechanism as FSR's mdr-tail gate, just on a fixed bar instead
of a deterministic search. The golden is bootstrapped from the first successful run;
the R/Julia surfaces reproduce it.

Fixed inputs (tickers + window endpoints) live in reference/getYahoo_query.json so
the three surfaces use identical inputs. This is the spec-013 gate.
"""
from __future__ import annotations

import csv
import json
import platform
import sys
from importlib import metadata
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import bridge

TOL = 1e-9
PLOTS = 1  # getYahoo plot level (0 headless; 1 shows a three-panel figure per ticker)
MSG = 1    # getYahoo message level (1 routes progress messages to the terminal)

# Shared fixed input, bootstrapped on first run (see load_or_write_query).
DEFAULT_QUERY = {
    "tickers": ["G.MI", "ENEL.MI"],
    "t0": "23-Jun-2026 09:00:00",
    "t1": "23-Jun-2026 09:00:01",
    "last_period": None,   # None -> getYahoo default
    "interval": None,      # None -> getYahoo default
}

OHLCV = ("Open", "High", "Low", "Close", "Volume")


def engine_pkg_version() -> str:
    try:
        return metadata.version("matlabengine")
    except Exception:
        return "n/a"


def load_or_write_query(reference_dir: Path) -> dict:
    """Return the shared fixed input (tickers + window), bootstrapping it on first
    run so the R/Julia surfaces read identical inputs."""
    query_json = reference_dir / "getYahoo_query.json"
    if query_json.exists():
        with open(query_json) as f:
            return json.load(f)
    reference_dir.mkdir(exist_ok=True)
    with open(query_json, "w") as f:
        json.dump(DEFAULT_QUERY, f, indent=2)
    return dict(DEFAULT_QUERY)


def window_rows(res: list[dict], query: dict, eng) -> list[tuple]:
    """Run the fixed `timerange` window over every ticker; return flat gate rows
    [(ticker, time, Open, High, Low, Close, Volume), ...]."""
    rows = []
    for idx, r in enumerate(res, start=1):  # MATLAB is 1-based
        win = bridge.timerange_window(eng, idx, query["t0"], query["t1"])
        for j, t in enumerate(win["time"]):
            rows.append((
                r["Ticker"], t,
                win["Open"][j], win["High"][j], win["Low"][j],
                win["Close"][j], win["Volume"][j],
            ))
    return rows


def load_or_write_golden(reference_dir: Path, rows: list[tuple]):
    """Return (golden rows, bootstrapped?). Golden = the fixed-window OHLCV rows;
    bootstrapped from this run when absent."""
    golden_csv = reference_dir / "getYahoo_window.csv"
    if golden_csv.exists():
        out = []
        with open(golden_csv, newline="") as f:
            reader = csv.reader(f)
            next(reader)  # header
            for line in reader:
                ticker, t = line[0], line[1]
                out.append((ticker, t, *[float(v) for v in line[2:7]]))
        return out, False

    reference_dir.mkdir(exist_ok=True)
    with open(golden_csv, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["ticker", "time", *OHLCV])
        for row in rows:
            w.writerow(list(row))
    return [tuple(r) for r in rows], True


def numeric(rows: list[tuple]) -> np.ndarray:
    """Stack the OHLCV columns of gate rows into an (m, 5) float matrix."""
    if not rows:
        return np.empty((0, 5), dtype=float)
    return np.asarray([[float(v) for v in r[2:7]] for r in rows], dtype=float)


def write_transparency(reference_dir: Path, res: list[dict]) -> None:
    """Per-ticker structural summary (proves the struct-array / timetable / nested
    Indicators crossing) -- language-neutral CSV."""
    with open(reference_dir / "getYahoo_check.csv", "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["ticker", "Success", "intervalActual", "TimeZone",
                    "TT_height", "n_indicators", "Message"])
        for r in res:
            w.writerow([
                r["Ticker"], r["Success"], r["intervalActual"], r["TimeZone"],
                len(r["TT"]["time"]), len(r["Indicators"]), r["Message"],
            ])


def main() -> int:
    reference_dir = Path(__file__).resolve().parent / "reference"
    fsda_root = sys.argv[1] if len(sys.argv) > 1 else None
    query = load_or_write_query(reference_dir)

    eng = bridge.start_engine(fsda_root=fsda_root)
    try:
        matlab_version = eng.version()
        where = eng.which("getYahoo")

        # plots/msg from the module constants; with MSG on, getYahoo's progress
        # messages reach this terminal, and with PLOTS on it opens one three-panel
        # figure per ticker (kept open by the pause below).
        res = bridge.get_yahoo(
            eng, query["tickers"], plots=PLOTS, msg=MSG,
            last_period=query.get("last_period"), interval=query.get("interval"),
        )
        write_transparency(reference_dir, res)

        print("=== spec 013: getYahoo bridge agreement check ===")
        print(f"Python       : {platform.python_version()}")
        print(f"MATLAB       : {matlab_version}")
        print(f"engine pkg   : {engine_pkg_version()}")
        print(f"getYahoo path: {where}")
        print(f"tickers      : {query['tickers']}  (nout={len(res)})")
        for r in res:
            print(f"  {r['Ticker']:8s} Success={r['Success']!s:5s} "
                  f"interval={r['intervalActual']:>4s} tz={r['TimeZone']} "
                  f"TT={len(r['TT']['time'])} rows  msg='{r['Message']}'")

        # Network / availability handling: if nothing downloaded, this is almost
        # certainly an unreachable Yahoo (or offline CI) -- SKIP rather than FAIL,
        # since a transient outage is not a code defect.
        if not any(r["Success"] for r in res):
            print("SKIP         : Yahoo returned no data for any ticker "
                  "(unreachable / offline?) -- deterministic gate not evaluated.")
            return 0

        rows = window_rows(res, query, eng)
        if not rows:
            print(f"window       : {query['t0']} .. {query['t1']}")
            print("RESULT       : FAIL -- no bar fell inside the fixed window. The "
                  "bar may have aged out of Yahoo's retention; refresh t0/t1 in "
                  "reference/getYahoo_query.json (and delete getYahoo_window.csv).")
            return 1

        golden, bootstrapped = load_or_write_golden(reference_dir, rows)

        labels = [(r[0], r[1]) for r in rows]
        glabels = [(g[0], g[1]) for g in golden]
        actual, gold = numeric(rows), numeric(golden)
        same_shape = actual.shape == gold.shape and labels == glabels
        max_abs_diff = (
            float(np.max(np.abs(actual - gold))) if same_shape else float("inf")
        )
        ok = same_shape and bool(np.allclose(actual, gold, rtol=0.0, atol=TOL))

        print(f"window       : {query['t0']} .. {query['t1']}")
        print("fixed-window OHLCV (ticker, time, O, H, L, C, V):")
        for (tk, t, o, h, lo, c, v) in rows:
            print(f"  {tk:8s} {t}  {o:.6f} {h:.6f} {lo:.6f} {c:.6f} {v:.0f}")
        if bootstrapped:
            print("golden       : bootstrapped reference/getYahoo_window.csv (first run)")
        print(f"max abs diff : {max_abs_diff:.3e}  (tol {TOL:.0e})")
        print(f"RESULT       : {'PASS' if ok else 'FAIL'}")

        # Keep the engine (and the figure windows) alive until the user closes them:
        # blocking is driven MATLAB-side (uiwait), uniform with R/Julia where reading
        # a key cannot work (the embedded engine hijacks stdin). Gated on an
        # interactive terminal so piped / CI runs never hang.
        if PLOTS and sys.stdin.isatty():
            print("Close the getYahoo figure window(s) to stop the engine and finish...")
            bridge.wait_for_figures(eng)

        return 0 if ok else 1
    finally:
        bridge.stop_engine(eng)


if __name__ == "__main__":
    raise SystemExit(main())
