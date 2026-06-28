# Spec 011 — Julia PythonCall: call FSDA `FSRaddt` through Python

> Layer-2 Julia surface for the `FSRaddt` bridge (spec 010), completing the chain
> `Julia → PythonCall → Python (bridge.py) → matlab.engine → MATLAB + FSDA`. Read `CONSTITUTION.md`
> first. This is the `FSRaddt` sibling of the spec-008 FSR Julia surface and mirrors its Layer-2
> conventions one-for-one; the Python Layer-1 bridge (`code/FSRaddt/bridge.py`) is reused **verbatim**.

## Contract

- **Deliverable:** from Julia, call `code/FSRaddt/bridge.py` through `PythonCall`, start/reuse a
  MATLAB engine, run the genuine FSDA `FSRaddt(y, X, ...)`, and return its key fields (`Tdel`,
  `S2del`, 1-based `bs`, the `Un` cell→`Vector` of matrices, 1-based `la`) as Julia values.
- **Done when:** `code/FSRaddt/check_FSRaddt_jl.jl`, run with PythonCall bound to the project venv,
  prints `PASS`; **the last five rows of `out.Tdel` equal the spec-010 golden**
  (`reference/FSRaddt_Tdel.csv`) to `<= 1e-9` on the `wool` fixture, and it writes a Julia artifact +
  reports the Julia / PythonCall / Python / MATLAB / `matlabengine` / `FSRaddt`-path diagnostics.
- **Out of scope:** direct MATLAB calls from Julia; edits to FSDA or any `.m`; changes to the Python
  bridge contract except bug fixes; the R surface (012); the `S2del` tail as a gate; the
  `quant`/`DataVars`/plot options; routines other than `FSRaddt`; packaging.

## Design

- **Files:**
  - `code/FSRaddt/bridge.jl` — Layer-2 wrapper (`start_bridge` / `fsraddt` / `stop_bridge` /
    `bridge_diagnostics` over an opaque `FSRaddtBridge` struct). Binds PythonCall to the venv, evicts
    any stale `bridge` module and forces `code/FSRaddt` to the front of `sys.path` before `pyimport`
    (the cross-target fix from spec 008; FSRaddt is the 5th `bridge.py`), then `pyimport`s `bridge`.
  - `code/FSRaddt/check_FSRaddt_jl.jl` — agreement check; reads the `wool` fixture + golden, runs
    `fsraddt(nsamp=0)`, compares the last 5 rows of `Tdel` at `1e-9`, writes
    `reference/FSRaddt_jl_check.csv`.
  - `code/FSRaddt/Project.toml` — pins `PythonCall = "0.9"`.
- **Signatures / calls:**
  - `start_bridge(; python = get(ENV, "FSDA_DEV_VENV", ""), fsda_root = nothing)` → opaque handle.
  - `fsraddt(bridge, y, X; nsamp=0, intercept=true, plots=0, msg=0, DataVars=nothing, h=nothing,
    init=nothing, lms=1)` → NamedTuple `(Tdel::Matrix{Float64} (m,k+1), S2del::Matrix{Float64},
    bs::Matrix{Int} 1-based, Un::Vector{Matrix{Float64}}, la::Vector{Int} 1-based)`. Julia keyword
    args cross as Python keyword args; `nothing → None`.
  - `stop_bridge` / `render_figures` / `wait_for_figures` / `bridge_diagnostics` (MATLAB values via
    Python helpers `bridge.matlab_version` / `bridge.which_fsraddt`).
  - `bridge.py` stays authoritative for `matlab.double` conversion, forcing `plots=0,msg=0`, the
    struct-field reads, the **cell→list `Un`** normalization, and the 1-based `bs`/`la`.
- **Environment:** identical to spec 008 — set `JULIA_CONDAPKG_BACKEND=Null` and `JULIA_PYTHONCALL_EXE`
  **before `using PythonCall`**; resolve `FSDA_DEV_VENV` → PATH → error. One-shot binding caveat
  applies (fresh `julia` process to switch interpreters).
- **Marshalling notes:**
  - PythonCall does **not** auto-convert: `pyconvert(Matrix{Float64}, res["Tdel"])`,
    `pyconvert(Matrix{Int}, res["bs"])`, `pyconvert(Vector{Int}, res["la"])`, etc.
  - **Cell→list `Un`:** `res["Un"]` is a Python list of numpy arrays; iterate it in Julia (a Python
    list is iterable under PythonCall) and `pyconvert` each element to a `Matrix{Float64}`. The
    cell→list normalization itself happens Python-side, so Julia only sees clean arrays.
  - **Variable width:** the Tdel check keys off `length(la)` (`size(Tdel,2) == 1 + length(la)`), not a
    hardcoded 2.
  - **1-based indices:** Julia is natively 1-based, so `bs`/`la` are already correct (no decrement).
  - **Determinism:** `nsamp=0`; `plots=0`/`msg=0` keep the engine headless.
- **Reference oracle:** the spec-010 `reference/FSRaddt_Tdel.csv` golden (gate = its last 5 rows) and
  `reference/wool.csv` (fixed input). If either is missing, fail telling the user to run
  `check_FSRaddt.py`.

**Run:**

```bash
export JULIA_CONDAPKG_BACKEND=Null
export FSDA_DEV_VENV="$(command -v python)"
julia --project=code/FSRaddt -e 'import Pkg; Pkg.instantiate()'
julia --project=code/FSRaddt code/FSRaddt/check_FSRaddt_jl.jl
```

## Tasks

- [x] #p1 Write `code/FSRaddt/bridge.jl` (`start_bridge` / `fsraddt` / `stop_bridge` /
  `bridge_diagnostics`, opaque `FSRaddtBridge`), with the cross-target `sys.modules`/`sys.path` fix.
- [x] #p1 Bind PythonCall to the venv before `using PythonCall`; no machine-specific path.
- [x] #p1 Validate Julia-side inputs (y vector/n×1, X n×p) before crossing; rely on `bridge.py` guards.
- [x] #p1 Write `code/FSRaddt/check_FSRaddt_jl.jl` reading the spec-010 fixture + golden; gate = last 5
  Tdel rows.
- [x] #p1 Run the Julia check; confirm `PASS`, save `reference/FSRaddt_jl_check.csv`.
- [x] #p2 Diagnostics via Python helpers (incl. resolved `FSRaddt` path); commit `Project.toml`.
- [x] #p3 Note PythonCall behaviour for the cell→list `Un` + variable-width Tdel conversion.

### Done

- 2026-06-28 — Julia PythonCall Layer-2 surface written and run. **Agreement gate (CONSTITUTION §5):
  PASS — max abs diff `0.000e+00`** (tol 1e-9) on the last 5 rows of `out.Tdel`. `bridge.py` reused
  **verbatim**; `la=[2,3,4]` (k=3) and the 3-cell `Un` (each `(22,11)`) reproduced. Run sequence:

  ```bash
  export JULIA_CONDAPKG_BACKEND=Null
  export FSDA_DEV_VENV="$(command -v python)"
  julia --project=code/FSRaddt -e 'import Pkg; Pkg.instantiate()'
  julia --project=code/FSRaddt code/FSRaddt/check_FSRaddt_jl.jl
  ```

  Diagnostics: Julia 1.12.6 · PythonCall 0.9.35 · Python 3.11.5
  (`/Users/aldocorbellini/miniconda3/bin/python`) · MATLAB R2026a Update 1 · `matlabengine` 26.1.12 ·
  `FSRaddt` at `/Users/aldocorbellini/FSDA/toolbox/regression/FSRaddt.m`. Artifact:
  `reference/FSRaddt_jl_check.csv`. Note: `Pkg.instantiate()` writes `code/FSRaddt/Manifest.toml`
  (generated, gitignored — ship only `Project.toml`).

- 2026-06-28 — PythonCall notes for `FSRaddt` (vs the spec-008 `FSR` surface):
  - **Cell→list `Un`.** `bridge.py::fsraddt` returns the MATLAB cell as a Python list of numpy
    arrays; in Julia a Python list is iterable, so `Matrix{Float64}[pyconvert(Matrix{Float64}, u)
    for u in res["Un"]]` converts each element cleanly. The cell→list normalization stays Python-side
    — Julia never sees the raw cell.
  - **Variable-width Tdel.** The width check is `size(Tdel,2) == 1 + length(la)` (here 4), not FSR's
    fixed 2; the golden reader accepts any number of `t` columns.
  - **Cross-target fix carried over** (FSRaddt is the 5th `bridge.py`): `start_bridge` evicts the
    cached module and prepends `code/FSRaddt` to `sys.path` before `pyimport`, so FSRaddt coexists
    with FSR / Score / mahalFS in one Julia session.
