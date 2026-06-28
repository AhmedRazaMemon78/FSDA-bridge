# Spec 015 - R reticulate: call FSDA `getYahoo` through Python

> Layer-2 R surface for the `getYahoo` bridge (spec 013), completing the chain
> `R → reticulate → Python (bridge.py) → matlab.engine → MATLAB + FSDA`. Read `CONSTITUTION.md` first.
> This is the `getYahoo` sibling of the spec-009 FSR R surface; the Python Layer-1 bridge
> (`code/getYahoo/bridge.py`) is reused **verbatim**.

## Contract

- **Deliverable:** from R, call `code/getYahoo/bridge.py` through `reticulate`, start/reuse a MATLAB
  engine, run the genuine FSDA `getYahoo({'G.MI','ENEL.MI'}, ...)`, and return one R list per ticker
  (the struct-array crossing) plus the deterministic `timerange` window as plain R.
- **Done when:** `code/getYahoo/check_getYahoo_r.R`, run with R configured to use the project venv,
  prints `PASS`; **the fixed-window OHLCV for both tickers equals the spec-013 golden**
  (`reference/getYahoo_window.csv`) to `<= 1e-9`, it writes an R artifact, and it reports the R /
  reticulate / Python / MATLAB / `matlabengine` / `getYahoo`-path diagnostics.
- **Out of scope:** direct MATLAB calls from R; edits to FSDA or any `.m`; changes to the Python bridge
  contract except bug fixes; Julia (014); plot sub-options; gating the full `TT` / `Indicators` body;
  routines other than `getYahoo`; packaging.

## Design

- **Files:**
  - `code/getYahoo/bridge.R` - Layer 2 wrapper (`start_bridge` / `get_yahoo` / `timerange_window` /
    `render_figures` / `wait_for_figures` / `stop_bridge` / `bridge_diagnostics` over an opaque
    `fsda_getyahoo_bridge` handle). Pins reticulate to the venv, evicts any stale `bridge` module from
    `sys.modules` before importing (the cross-target fix from specs 003/006/009), and imports
    `code/getYahoo/bridge.py`.
  - `code/getYahoo/check_getYahoo_r.R` - agreement check; reads the shared `getYahoo_query.json`
    (parsed via Python's `json`, so no extra R dependency) + the OHLCV golden, runs `get_yahoo` then
    `timerange_window`, compares both tickers' window OHLCV at `1e-9`, writes
    `reference/getYahoo_r_check.csv`.
- **Signatures / calls:**
  - `start_bridge(python = Sys.getenv("FSDA_DEV_VENV"), fsda_root = NULL)` → opaque handle.
  - `get_yahoo(bridge, tickers, plots = 0, msg = 0, last_period = NULL, interval = NULL)` → R list of
    named lists (`Ticker`, `Success`, `intervalActual`, `TimeZone`, `Message`, `TT`, `Indicators`, ...).
    R named args map to Python keyword args; `NULL → None`.
  - `timerange_window(bridge, idx, t0, t1)` → R named list (`time`, `Open`, `High`, `Low`, `Close`,
    `Volume`) — the deterministic gate oracle, run MATLAB-side.
  - `stop_bridge` / `render_figures` / `wait_for_figures` / `bridge_diagnostics` (MATLAB values via the
    Python helpers `bridge.matlab_version` / `bridge.which_getyahoo`).
  - `bridge.py` stays authoritative for the struct-array decomposition, the timetable → time+matrix
    conversion, the nested-Indicators read, and the `string`→`str` handling.
- **Marshalling notes:**
  - With `convert = TRUE`, reticulate turns the returned Python `list[dict]` into an R list of named
    lists, the nested `TT` / `Indicators` dicts into nested R lists, and their numpy values into numeric
    vectors / the time list into a character vector. The struct-array / timetable handling all stays
    Python-side, so R only sees clean lists + vectors.
  - **Tickers** cross as a Python list (`as.list(tickers)`); `NULL → None` for `last_period` / `interval`.
  - **Determinism**: the fixed `timerange` window over a past bar; `plots`/`msg` default off (headless).
  - R code uses `=` for assignment, matching `AGENTS.md`.
- **Reference oracle:** the spec-013 `reference/getYahoo_window.csv` golden (gate target) and
  `reference/getYahoo_query.json` (fixed input). If either is missing, the R check fails telling the user
  to run `check_getYahoo.py` first.

## Tasks

- [ ] #p1 Write `code/getYahoo/bridge.R` (`start_bridge` / `get_yahoo` / `timerange_window` /
  `stop_bridge` / `bridge_diagnostics`), with the cross-target `sys.modules.pop('bridge', None)`
  eviction baked in.
- [ ] #p1 Configure reticulate to use `FSDA_DEV_VENV` (else PATH; else stop) — no machine-specific path.
- [ ] #p1 Validate R-side inputs (non-empty character ticker vector) before crossing into Python.
- [ ] #p1 Write `code/getYahoo/check_getYahoo_r.R` using the spec-013 fixture + golden; gate = both
  tickers' fixed-window OHLCV.
- [ ] #p1 Run the R check on the R2026a + FSDA box with network access; confirm `PASS` and save
  `reference/getYahoo_r_check.csv`.
- [ ] #p2 Diagnostics via Python helpers (incl. resolved `getYahoo` path); document the run command here.
- [ ] #p3 Note reticulate behaviour for list-of-dict-returning routines + nested timetable conversion.

### Done

(move checked items here with a date — verification requires the MATLAB engine + Yahoo network access,
not available in the authoring environment)

**Run command (macOS):**

```bash
export FSDA_DEV_VENV="$(command -v python)"
export PYTHONDONTWRITEBYTECODE=1
Rscript code/getYahoo/check_getYahoo_r.R
```
