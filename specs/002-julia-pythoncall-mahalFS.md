# Spec 002 — Julia PythonCall: call FSDA `mahalFS` through Python

> Layer-2 Julia surface for the existing `mahalFS` bridge, completing the chain
> `Julia → PythonCall → Python (bridge.py) → matlab.engine → MATLAB + FSDA`. Read `CONSTITUTION.md`
> first (toolchain, bridge layering, marshalling, agreement gate). This is the Julia sibling of the
> already-delivered R surface (spec 003) and mirrors its Layer-2 conventions; the Python Layer-1 bridge
> (`code/mahalFS/bridge.py`) is reused **verbatim**.

## Contract

*What this spec must deliver, and how we know it's done.*

- **Deliverable:** from Julia, call the existing Python Layer-1 bridge in `code/mahalFS/bridge.py`
  through `PythonCall`, start or reuse a MATLAB engine session, call the genuine FSDA
  `mahalFS(Y, MU, SIGMA)`, and return the per-row **squared Mahalanobis distances** as a Julia
  `Vector{Float64}`.
- **Done when:** `code/mahalFS/check_mahalFS_jl.jl`, run with PythonCall bound to the project Python
  venv, prints `PASS`; the Julia surface output matches the FSDA/Python oracle to `<= 1e-9`, writes a
  Julia-specific reference artifact under `code/mahalFS/reference/`, and reports the Julia / PythonCall /
  Python / MATLAB / `matlabengine` version details plus the resolved `mahalFS` path.
- **Out of scope:** direct MATLAB calls from Julia; edits to FSDA or any `.m` source; changes to the
  Python bridge contract except bug fixes required by this spec; the R surface (spec 003); FSDA routines
  other than `mahalFS`; packaging, CI, or registering a Julia package.

## Design

*How the contract is realised.*

- **Files:**
  - `code/mahalFS/bridge.jl` — Layer-2 wrapper. Loads `PythonCall`, binds it to the project Python venv,
    puts `code/mahalFS/` on Python's `sys.path`, `pyimport`s `bridge`, and exposes Julia functions
    mirroring the Python/R bridge lifecycle.
  - `code/mahalFS/check_mahalFS_jl.jl` — Julia agreement check using the same fixed `n = 5, v = 2` input
    as spec 001, comparing the Julia surface output against the spec-001 Python/FSDA oracle at `1e-9`.
  - `code/mahalFS/reference/mahalFS_jl_check.csv` — Julia check artifact: inputs, FSDA distances, oracle
    distances, and absolute differences.
- **Signatures / calls** (mirroring `bridge.R`'s opaque-handle design):
  - `start_bridge(; python = get(ENV, "FSDA_DEV_VENV", ""), fsda_root = nothing)` returns an opaque
    handle bundling the imported Python `bridge` module and the live MATLAB engine object.
  - `mahal_fs(bridge, Y, MU, SIGMA)` accepts a Julia numeric `Matrix` `Y`, a length-`v` `Vector` or
    `1×v` matrix `MU`, and a `v×v` matrix `SIGMA`; returns a `Vector{Float64}` of length `size(Y, 1)`.
  - `stop_bridge(bridge)` quits the MATLAB engine by delegating to `bridge.py::stop_engine`.
  - `bridge_diagnostics(bridge)` returns Julia/PythonCall/Python/MATLAB/`matlabengine`/`mahalFS`-path
    details. Engine-specific values go through the Python helpers **`bridge.matlab_version(eng)`** and
    **`bridge.which_mahalfs(eng)`** (added in spec 001 for exactly this) — never call engine methods
    across PythonCall directly, to avoid PythonCall probing MATLAB engine method signatures.
  - The Julia wrapper calls Python only; `bridge.py` remains responsible for `matlab.double` conversion
    and the actual `eng.mahalFS(...)` call, and its shape/dtype guards stay authoritative.
- **Environment (the critical piece):** PythonCall must use the **project venv** — the one with
  `matlabengine` installed — **not** a CondaPkg-managed Python. PythonCall reads its interpreter at load
  time, so `bridge.jl` must, **before `using PythonCall`**, set `ENV["JULIA_CONDAPKG_BACKEND"] = "Null"`
  and `ENV["JULIA_PYTHONCALL_EXE"]` to the resolved interpreter. Resolve the interpreter with the repo's
  standard precedence (no machine-specific path committed): **`FSDA_DEV_VENV`** (the venv's python
  executable; accept a venv/conda root and append `Scripts/python.exe` or `bin/python`) → `python` /
  `python3` on `PATH` → clear error with guidance. Note the one-shot caveat: if PythonCall was already
  initialised earlier in the Julia session against a different interpreter, it cannot be rebound — start
  a fresh `julia` process.
- **Marshalling notes (two boundaries now):**
  - *Julia ↔ Python:* a Julia `Matrix{Float64}` crosses via PythonCall as a numpy array of the **same
    logical shape `(n, v)`** (column-major / F-contiguous; numpy handles contiguity), so pass
    matrix-shaped objects through without flattening or transposing — `bridge.py`'s shape checks are the
    safety net. The fixed input is non-square (`n=5, v=2`), which **deliberately surfaces any accidental
    transpose**. PythonCall does **not** auto-convert return values: convert the returned numpy `(n,)`
    explicitly with `pyconvert(Vector{Float64}, d)` and verify `length(d) == size(Y, 1)`. No silent
    reshape.
  - *1-based indexing:* Julia **and** MATLAB are both 1-based, so an index returned by FSDA is already
    correct in Julia — **no decrement** (and `bridge.py` must not have adjusted it Python-side, or Julia
    would double-adjust). `mahalFS` returns distances, not indices, so this is moot here but matters for
    later index-returning routines.
  - *Python ↔ MATLAB:* unchanged from spec 001 (already checked).
- **Reference oracle:** load `code/mahalFS/reference/mahalFS_check.csv` from spec 001 and compare the
  Julia surface output to its saved FSDA distance (`d_fsda`) column for the same fixed inputs. If that
  file is missing, fail with a message telling the user to run the spec-001 Python agreement check
  (`check_mahalFS.py`) first. The Julia check writes its own artifact under `code/mahalFS/reference/`;
  tolerance is `1e-9`.

**Run** (requires `PythonCall` installed in the active Julia environment, e.g.
`julia -e 'import Pkg; Pkg.add("PythonCall")'`, and `FSDA_DEV_VENV` pointing at the venv's python):

```powershell
# Windows (PowerShell)
$env:FSDA_DEV_VENV = "C:\path\to\your\fsda_dev_env\Scripts\python.exe"
julia code\mahalFS\check_mahalFS_jl.jl
```

```bash
# macOS / Linux
export FSDA_DEV_VENV="/path/to/your/fsda_dev_env/bin/python"
julia code/mahalFS/check_mahalFS_jl.jl
```

## Tasks

*Ordered checklist. Priorities: `#p1` blocking, `#p2` this round, `#p3` nice-to-have.*

- [x] #p1 Write `code/mahalFS/bridge.jl` with `start_bridge`, `mahal_fs`, `stop_bridge`, and
  `bridge_diagnostics` (opaque handle bundling module + engine, mirroring `bridge.R`).
- [x] #p1 In `bridge.jl`, bind PythonCall to the venv **before `using PythonCall`**: resolve
  `FSDA_DEV_VENV` → active `python`/`python3` on PATH → clear error; set `JULIA_CONDAPKG_BACKEND=Null`
  and `JULIA_PYTHONCALL_EXE`. No machine-specific path baked in.
- [x] #p1 Validate Julia-side input shapes/types (Y `n×v`, MU length `v` or `1×v`, SIGMA `v×v`) before
  crossing into Python; rely on `bridge.py` guards as authoritative.
- [x] #p1 Write `code/mahalFS/check_mahalFS_jl.jl` using the same fixed input as spec 001, loading the
  spec-001 oracle CSV, comparing at tolerance `1e-9`.
- [x] #p1 Run the Julia agreement check; confirm `PASS` with max abs diff ≈ 0, and save
  `reference/mahalFS_jl_check.csv`. **Done 2026-06-26 on macOS (Julia 1.12.6 + MATLAB R2026a Update 1 +
  FSDA + `matlabengine` 26.1.12): `RESULT : PASS`, max abs diff `0.000e+00`.**
- [x] #p2 Print version/path diagnostics via the Python helpers: Julia, PythonCall, Python, MATLAB,
  `matlabengine`, and the resolved `mahalFS` path.
- [x] #p2 Document the exact command used to run the Julia check in this spec's Done section.
- [x] #p3 Note any PythonCall conversion surprises (e.g. `Py` return values, array contiguity) that
  matter for later Julia wrappers; decide whether to commit a minimal `Project.toml` pinning PythonCall.

### Done

- 2026-06-26 - Julia PythonCall Layer-2 surface written: `code/mahalFS/bridge.jl`
  (`start_bridge` / `mahal_fs` / `stop_bridge` / `bridge_diagnostics` over an opaque `MahalFSBridge`
  struct, mirroring `bridge.R`) and `code/mahalFS/check_mahalFS_jl.jl` (same fixed `n=5, v=2` fixture,
  loads the spec-001 oracle `reference/mahalFS_check.csv`, compares `d_fsda` at `1e-9`, writes
  `reference/mahalFS_jl_check.csv`). `bridge.py` is reused **verbatim**.

  **Agreement gate (CONSTITUTION §5): PASS — run 2026-06-26.** The macOS box turned out to have the
  full toolchain (the `matlab` CLI is not on `PATH`, but `matlabengine` locates MATLAB R2026a anyway).
  Run sequence used (with the CondaPkg backend disabled so PythonCall binds the project venv, not a
  conda Python):

  ```bash
  # macOS / Linux (bash)
  export JULIA_CONDAPKG_BACKEND=Null
  export FSDA_DEV_VENV="$(command -v python)"   # python with matlabengine 26.1.*
  julia --project=code/mahalFS -e 'import Pkg; Pkg.instantiate()'
  julia --project=code/mahalFS code/mahalFS/check_mahalFS_jl.jl
  ```

  ```powershell
  # Windows (PowerShell)
  $env:JULIA_CONDAPKG_BACKEND = "Null"
  $env:FSDA_DEV_VENV = (Get-Command python).Source
  julia --project=code\mahalFS -e 'import Pkg; Pkg.instantiate()'
  julia --project=code\mahalFS code\mahalFS\check_mahalFS_jl.jl
  ```

  Printed diagnostics from the passing run:

  ```
  Julia        : 1.12.6
  PythonCall   : 0.9.35
  Python       : 3.11.5
  Python path  : /Users/aldocorbellini/miniconda3/bin/python
  MATLAB       : 26.1.0.3234472 (R2026a) Update 1
  engine pkg   : 26.1.12
  mahalFS path : /Users/aldocorbellini/FSDA/toolbox/utilities_stat/mahalFS.m
  Julia surface: 0.5714285714 4.571428571 9.142857143 9.142857143 4.571428571
  oracle       : 0.5714285714 4.571428571 9.142857143 9.142857143 4.571428571
  max abs diff : 0.000e+00  (tol 1e-09)
  RESULT       : PASS
  ```

  Note: `Pkg.instantiate()` writes `code/mahalFS/Manifest.toml` (a generated lockfile, not committed —
  the spec ships only `Project.toml`); regenerate it with the instantiate step above. With
  `JULIA_CONDAPKG_BACKEND` unset, a bare `using PythonCall` would let CondaPkg download a separate conda
  Python into `code/mahalFS/.CondaPkg/` — `bridge.jl` prevents this by setting the Null backend before
  `using PythonCall`, but the instantiate step above sets it explicitly too.

- 2026-06-26 - Design / PythonCall notes for later Julia wrappers:
  - **Interpreter binding is one-shot.** PythonCall reads `JULIA_PYTHONCALL_EXE` at `using PythonCall`,
    so `bridge.jl` resolves the interpreter and sets `JULIA_CONDAPKG_BACKEND=Null` +
    `JULIA_PYTHONCALL_EXE` *above* that line. `start_bridge(python=...)` can no longer rebind in the same
    session — it only `@warn`s and records what was actually bound. Switching interpreters needs a fresh
    `julia` process.
  - **Return values are not auto-converted.** PythonCall returns the numpy `(n,)` as a `Py`; converted
    explicitly with `pyconvert(Vector{Float64}, d)` and length-checked. Inputs (Julia `Matrix{Float64}`)
    cross as shaped numpy arrays of the same logical `(n, v)` (F-contiguous; numpy handles contiguity),
    so the non-square fixture needs no transpose — `bridge.py`'s guards stay authoritative.
  - **Engine diagnostics go through Python helpers** (`bridge.matlab_version`, `bridge.which_mahalfs`),
    never `bridge.engine.<method>()` across PythonCall, to avoid PythonCall probing MATLAB engine method
    signatures (same hazard reticulate hit in spec 003).
  - **Project.toml committed** (`code/mahalFS/Project.toml`) pinning `PythonCall = "0.9"` — an
    environment manifest only (no package/build), so the Julia side is reproducible with
    `--project=code/mahalFS`.
