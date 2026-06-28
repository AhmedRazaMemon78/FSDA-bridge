# Spec 014 — Julia PythonCall: call FSDA `getYahoo` through Python

> Layer-2 Julia surface for the `getYahoo` bridge (spec 013), completing the chain
> `Julia → PythonCall → Python (bridge.py) → matlab.engine → MATLAB + FSDA`. Read `CONSTITUTION.md`
> first. This is the `getYahoo` sibling of the spec-008 FSR Julia surface and mirrors its Layer-2
> conventions one-for-one; the Python Layer-1 bridge (`code/getYahoo/bridge.py`) is reused **verbatim**.

## Contract

- **Deliverable:** from Julia, call `code/getYahoo/bridge.py` through `PythonCall`, start/reuse a MATLAB
  engine, run the genuine FSDA `getYahoo({'G.MI','ENEL.MI'}, ...)`, and return one NamedTuple per ticker
  (the struct-array crossing) plus the deterministic `timerange` window as Julia values.
- **Done when:** `code/getYahoo/check_getYahoo_jl.jl`, run with PythonCall bound to the project venv,
  prints `PASS`; **the fixed-window OHLCV for both tickers equals the spec-013 golden**
  (`reference/getYahoo_window.csv`) to `<= 1e-9`, and it writes a Julia artifact + reports the Julia /
  PythonCall / Python / MATLAB / `matlabengine` / `getYahoo`-path diagnostics.
- **Out of scope:** direct MATLAB calls from Julia; edits to FSDA or any `.m`; changes to the Python
  bridge contract except bug fixes; the R surface (015); plot sub-options; gating the full `TT` /
  `Indicators` body; routines other than `getYahoo`; packaging.

## Design

- **Files:**
  - `code/getYahoo/bridge.jl` — Layer-2 wrapper (`start_bridge` / `get_yahoo` / `timerange_window` /
    `render_figures` / `wait_for_figures` / `stop_bridge` / `bridge_diagnostics` over an opaque
    `GetYahooBridge` struct). Binds PythonCall to the venv, evicts any stale `bridge` module and forces
    `code/getYahoo` to the front of `sys.path` before `pyimport` (the cross-target fix from specs
    002/005/008), then `pyimport`s `bridge`.
  - `code/getYahoo/check_getYahoo_jl.jl` — agreement check; reads the shared `getYahoo_query.json` + the
    OHLCV golden, runs `get_yahoo` then `timerange_window`, compares both tickers' window OHLCV at
    `1e-9`, writes `reference/getYahoo_jl_check.csv`.
  - `code/getYahoo/Project.toml` — pins `PythonCall = "0.9"`.
- **Signatures / calls:**
  - `start_bridge(; python = get(ENV, "FSDA_DEV_VENV", ""), fsda_root = nothing)` → opaque handle.
  - `get_yahoo(bridge, tickers; plots=0, msg=0, last_period=nothing, interval=nothing)` →
    `Vector{NamedTuple}` (`Ticker`, `Success`, `intervalActual`, `TimeZone`, `Message`, `tt_height`,
    `n_indicators`). Julia keyword args cross as Python keyword args; `nothing → None`.
  - `timerange_window(bridge, idx, t0, t1)` → `(time::Vector{String}, ohlcv::Matrix{Float64})` (columns
    Open, High, Low, Close, Volume) — the deterministic gate oracle, run MATLAB-side.
  - `stop_bridge` / `render_figures` / `wait_for_figures` / `bridge_diagnostics` (MATLAB values via the
    Python helpers `bridge.matlab_version` / `bridge.which_getyahoo`).
  - `bridge.py` stays authoritative for the struct-array decomposition, the timetable → time+matrix
    conversion, the nested-Indicators read, and the `string`→`str` handling.
- **Environment:** identical to specs 002/005/008 — set `JULIA_CONDAPKG_BACKEND=Null` and
  `JULIA_PYTHONCALL_EXE` **before `using PythonCall`**; resolve `FSDA_DEV_VENV` → PATH → error. One-shot
  binding caveat applies (fresh `julia` process to switch interpreters).
- **Marshalling notes:**
  - PythonCall does **not** auto-convert: the Python `list[dict]` is **iterated** element-wise and each
    field `pyconvert`ed (`String` / `Bool` / `Int`); `timerange_window` `pyconvert`s the OHLCV columns to
    `Matrix{Float64}`. The struct-array / timetable / nested-struct decomposition all happen Python-side,
    so Julia only sees clean strings + numeric arrays.
  - **Tickers** cross as a Python list via `pylist`; `nothing → None` for `last_period` / `interval`.
  - **Determinism**: the fixed `timerange` window over a past bar; `plots`/`msg` default off (headless).
- **Reference oracle:** the spec-013 `reference/getYahoo_window.csv` golden (gate target) and
  `reference/getYahoo_query.json` (fixed input). If either is missing, fail telling the user to run
  `check_getYahoo.py` first.

**Run:**

```bash
export JULIA_CONDAPKG_BACKEND=Null
export FSDA_DEV_VENV="$(command -v python)"
julia --project=code/getYahoo -e 'import Pkg; Pkg.instantiate()'
julia --project=code/getYahoo code/getYahoo/check_getYahoo_jl.jl
```

## Tasks

- [ ] #p1 Write `code/getYahoo/bridge.jl` (`start_bridge` / `get_yahoo` / `timerange_window` /
  `stop_bridge` / `bridge_diagnostics`, opaque `GetYahooBridge`), with the cross-target
  `sys.modules`/`sys.path` fix baked in.
- [ ] #p1 Bind PythonCall to the venv before `using PythonCall`; no machine-specific path.
- [ ] #p1 Validate Julia-side inputs (non-empty ticker list) before crossing; rely on `bridge.py` guards.
- [ ] #p1 Write `code/getYahoo/check_getYahoo_jl.jl` reading the spec-013 fixture + golden; gate = both
  tickers' fixed-window OHLCV.
- [ ] #p1 Run the Julia check on the R2026a + FSDA box with network access; confirm `PASS`, save
  `reference/getYahoo_jl_check.csv`.
- [ ] #p2 Diagnostics via Python helpers (incl. resolved `getYahoo` path); commit `Project.toml`.
- [ ] #p3 Note PythonCall behaviour for list-of-dict-returning routines + nested timetable conversion.

### Done

(move checked items here with a date — verification requires the MATLAB engine + Yahoo network access,
not available in the authoring environment)
