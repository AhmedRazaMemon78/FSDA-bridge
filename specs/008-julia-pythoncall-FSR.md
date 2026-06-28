# Spec 008 — Julia PythonCall: call FSDA `FSR` through Python

> Layer-2 Julia surface for the `FSR` bridge (spec 007), completing the chain
> `Julia → PythonCall → Python (bridge.py) → matlab.engine → MATLAB + FSDA`. Read `CONSTITUTION.md`
> first. This is the `FSR` sibling of the spec-002/005 Julia surfaces and mirrors their Layer-2
> conventions one-for-one; the Python Layer-1 bridge (`code/FSR/bridge.py`) is reused **verbatim**.

## Contract

- **Deliverable:** from Julia, call `code/FSR/bridge.py` through `PythonCall`, start/reuse a MATLAB
  engine, run the genuine FSDA `FSR(y, X, ...)`, and return its key fields (`mdr`, 1-based `outliers`,
  `beta`, `scale`) as Julia values.
- **Done when:** `code/FSR/check_FSR_jl.jl`, run with PythonCall bound to the project venv, prints
  `PASS`; **the last five rows of `out.mdr` equal the spec-007 golden** (`reference/FSR_mdr.csv`) to
  `<= 1e-9` on the `stars` fixture, and it writes a Julia artifact + reports the Julia / PythonCall /
  Python / MATLAB / `matlabengine` / `FSR`-path diagnostics.
- **Out of scope:** direct MATLAB calls from Julia; edits to FSDA or any `.m`; changes to the Python
  bridge contract except bug fixes; the R surface (009); `out.Un`/`out.nout`/`weak`/plot options;
  routines other than `FSR`; packaging.

## Design

- **Files:**
  - `code/FSR/bridge.jl` — Layer-2 wrapper (`start_bridge` / `fsr` / `stop_bridge` /
    `bridge_diagnostics` over an opaque `FSRBridge` struct). Binds PythonCall to the venv, evicts any
    stale `bridge` module and forces `code/FSR` to the front of `sys.path` before `pyimport` (the
    cross-target fix from specs 002/005), then `pyimport`s `bridge`.
  - `code/FSR/check_FSR_jl.jl` — agreement check; reads the `stars` fixture + golden, runs `fsr(nsamp=0)`,
    compares the last 5 rows of `mdr` at `1e-9`, writes `reference/FSR_jl_check.csv`.
  - `code/FSR/Project.toml` — pins `PythonCall = "0.9"`.
- **Signatures / calls:**
  - `start_bridge(; python = get(ENV, "FSDA_DEV_VENV", ""), fsda_root = nothing)` → opaque handle.
  - `fsr(bridge, y, X; nsamp=0, intercept=true, h=nothing, init=nothing, bonflev=nothing)` → NamedTuple
    `(mdr::Matrix{Float64} (m,2), outliers::Vector{Int} 1-based, beta::Vector{Float64}, scale::Float64)`.
    Julia keyword args cross as Python keyword args; `nothing → None`.
  - `stop_bridge` / `bridge_diagnostics` (MATLAB values via Python helpers `bridge.matlab_version` /
    `bridge.which_fsr`).
  - `bridge.py` stays authoritative for `matlab.double` conversion, forcing `plots=0,msg=0`, the
    struct-field reads, and the scalar/array/empty **outlier normalization**.
- **Environment:** identical to specs 002/005 — set `JULIA_CONDAPKG_BACKEND=Null` and
  `JULIA_PYTHONCALL_EXE` **before `using PythonCall`**; resolve `FSDA_DEV_VENV` → PATH → error. One-shot
  binding caveat applies (fresh `julia` process to switch interpreters).
- **Marshalling notes:**
  - PythonCall does **not** auto-convert: `pyconvert(Matrix{Float64}, res["mdr"])`,
    `pyconvert(Vector{Int}, res["outliers"])`, etc. The struct→dict + outlier-shape normalization happen
    Python-side, so Julia only sees clean numpy arrays.
  - **1-based outliers**: Julia is natively 1-based, so the index list is already correct (no decrement).
  - **Determinism**: `nsamp=0`; `plots=0`/`msg=0` keep the engine headless.
- **Reference oracle:** the spec-007 `reference/FSR_mdr.csv` golden (gate = its last 5 rows) and
  `reference/stars.csv` (fixed input). If either is missing, fail telling the user to run `check_FSR.py`.

**Run:**

```bash
export JULIA_CONDAPKG_BACKEND=Null
export FSDA_DEV_VENV="$(command -v python)"
julia --project=code/FSR -e 'import Pkg; Pkg.instantiate()'
julia --project=code/FSR code/FSR/check_FSR_jl.jl
```

## Tasks

- [x] #p1 Write `code/FSR/bridge.jl` (`start_bridge` / `fsr` / `stop_bridge` / `bridge_diagnostics`,
  opaque `FSRBridge`), with the cross-target `sys.modules`/`sys.path` fix baked in.
- [x] #p1 Bind PythonCall to the venv before `using PythonCall`; no machine-specific path.
- [x] #p1 Validate Julia-side inputs (y vector/n×1, X n×p) before crossing; rely on `bridge.py` guards.
- [x] #p1 Write `code/FSR/check_FSR_jl.jl` reading the spec-007 fixture + golden; gate = last 5 mdr rows.
- [x] #p1 Run the Julia check; confirm `PASS`, save `reference/FSR_jl_check.csv`.
- [x] #p2 Diagnostics via Python helpers (incl. resolved `FSR` path); commit `Project.toml`.
- [x] #p3 Note PythonCall behaviour for dict-returning routines + Int-index conversion.

### Done

- 2026-06-27 — Julia PythonCall Layer-2 surface written and run. **Agreement gate (CONSTITUTION §5):
  PASS — max abs diff `0.000e+00`** (tol 1e-9) on the last 5 rows of `out.mdr`. `bridge.py` reused
  **verbatim**; outliers (1-based) **[11, 20, 30, 34]** reproduced. Run sequence:

  ```bash
  export JULIA_CONDAPKG_BACKEND=Null
  export FSDA_DEV_VENV="$(command -v python)"
  julia --project=code/FSR -e 'import Pkg; Pkg.instantiate()'
  julia --project=code/FSR code/FSR/check_FSR_jl.jl
  ```

  Diagnostics: Julia 1.12.6 · PythonCall 0.9.35 · Python 3.11.5 (`/Users/aldocorbellini/miniconda3`) ·
  MATLAB R2026a Update 1 · `matlabengine` 26.1.12 · `FSR` at
  `/Users/aldocorbellini/FSDA/toolbox/regression/FSR.m`. Artifact: `reference/FSR_jl_check.csv`. Note:
  `Pkg.instantiate()` writes `code/FSR/Manifest.toml` (generated, gitignored — ship only `Project.toml`).

- 2026-06-27 — PythonCall notes for `FSR` (vs the spec-005 `Score` surface):
  - **Dict-returning routine.** `bridge.py::fsr` returns a Python dict; in Julia, `res["mdr"]` /
    `res["outliers"]` are indexed off the `Py` and `pyconvert`ed explicitly (Matrix / Vector{Int}).
  - **Outlier-shape normalization stays Python-side** — Julia always receives a clean numpy array, so
    the scalar/array/empty inconsistency never reaches PythonCall.
  - **Cross-target fix baked in from the start** (FSR is the 4th `bridge.py`): `start_bridge` evicts the
    cached module and prepends `code/FSR` to `sys.path` before `pyimport`, so FSR coexists with mahalFS /
    Score in one Julia session.

- 2026-06-27 — Plots/messages enabled (parity with spec 007). `fsr(...; plots=0, msg=0)` now forwards
  both to `bridge.py`, and `render_figures(bridge)` (→ Python `bridge.render_figures`) was added.
  `check_FSR_jl.jl` sets `PLOTS=MSG=1`, and before `stop_bridge` (in `finally`) it renders + `readline()`
  pauses **only when `stdin isa Base.TTY`**, so piped/CI runs never hang. Messages: `bridge.py` writes the
  captured MATLAB output to Python `sys.stdout`, which PythonCall surfaces on the Julia terminal.
  Verified headless (piped stdin): FSDA's signal-detection messages print, **PASS** (max abs diff
  `0.000e+00`, outliers [11, 20, 30, 34]), exit 0, no hang.
