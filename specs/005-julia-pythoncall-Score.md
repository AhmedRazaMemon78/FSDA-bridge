# Spec 005 — Julia PythonCall: call FSDA `Score` through Python

> Layer-2 Julia surface for the `Score` bridge (spec 004), completing the chain
> `Julia → PythonCall → Python (bridge.py) → matlab.engine → MATLAB + FSDA`. Read `CONSTITUTION.md`
> first (toolchain, bridge layering, marshalling, agreement gate). This is the `Score` sibling of the
> spec-002 `mahalFS` Julia surface and mirrors its Layer-2 conventions one-for-one; the Python Layer-1
> bridge (`code/Score/bridge.py`) is reused **verbatim**.

## Contract

- **Deliverable:** from Julia, call the existing Python Layer-1 bridge in `code/Score/bridge.py` through
  `PythonCall`, start or reuse a MATLAB engine session, call the genuine FSDA
  `Score(y, X, 'la', la, 'intercept', intercept)`, and return the per-lambda **score-test t-statistics**
  as a Julia `Vector{Float64}`.
- **Done when:** `code/Score/check_Score_jl.jl`, run with PythonCall bound to the project Python venv,
  prints `PASS`; the Julia surface output matches the FSDA/Python oracle to `<= 1e-9`, writes a
  Julia-specific reference artifact under `code/Score/reference/`, and reports the Julia / PythonCall /
  Python / MATLAB / `matlabengine` version details plus the resolved `Score` path.
- **Out of scope:** direct MATLAB calls from Julia; edits to FSDA or any `.m` source; changes to the
  Python bridge contract except bug fixes required by this spec; the R surface (spec 006); the optional
  `out.Lik` / `out.ScoreT` outputs; FSDA routines other than `Score`; packaging, CI, or registering a
  Julia package.

## Design

- **Files:**
  - `code/Score/bridge.jl` — Layer-2 wrapper. Loads `PythonCall`, binds it to the project Python venv,
    puts `code/Score/` on Python's `sys.path`, `pyimport`s `bridge`, and exposes Julia functions
    mirroring the Python/R bridge lifecycle (`start_bridge` / `score` / `stop_bridge` /
    `bridge_diagnostics` over an opaque `ScoreBridge` struct).
  - `code/Score/check_Score_jl.jl` — Julia agreement check using the genuine `wool` fixture
    (`reference/wool.csv`) and the default `la = [-1, -0.5, 0, 0.5, 1]`, comparing the Julia surface
    output against the spec-004 Python/FSDA oracle (`reference/Score_check.csv`) at `1e-9`.
  - `code/Score/reference/Score_jl_check.csv` — Julia check artifact: per-lambda surface vs oracle.
  - `code/Score/Project.toml` — environment manifest pinning `PythonCall = "0.9"`.
- **Signatures / calls** (mirroring `bridge.R`'s opaque-handle design):
  - `start_bridge(; python = get(ENV, "FSDA_DEV_VENV", ""), fsda_root = nothing)` returns an opaque
    handle bundling the imported Python `bridge` module and the live MATLAB engine object.
  - `score(bridge, y, X; la = nothing, intercept = true)` accepts a Julia numeric `Vector`/`n×1` `y`
    (strictly positive), an `n×p` `Matrix` `X`, and an optional `la` vector; returns a
    `Vector{Float64}` of length `length(la)` (default 5). Keyword args cross as Python keyword args.
  - `stop_bridge(bridge)` quits the MATLAB engine via `bridge.py::stop_engine`.
  - `bridge_diagnostics(bridge)` returns Julia/PythonCall/Python/MATLAB/`matlabengine`/`Score`-path
    details. Engine values go through the Python helpers **`bridge.matlab_version(eng)`** and
    **`bridge.which_score(eng)`** — never call engine methods across PythonCall directly.
  - The Julia wrapper calls Python only; `bridge.py` remains responsible for `matlab.double` conversion,
    the `out['Score']` **struct-field** read, and the actual `eng.Score(...)` call, and its
    shape/positivity guards stay authoritative.
- **Environment (the critical piece):** identical to spec 002. PythonCall must use the **project venv**
  (the one with `matlabengine`), **not** a CondaPkg-managed Python. PythonCall reads its interpreter at
  load time, so `bridge.jl` must, **before `using PythonCall`**, set `JULIA_CONDAPKG_BACKEND = "Null"`
  and `JULIA_PYTHONCALL_EXE` to the resolved interpreter. Resolve with the repo's standard precedence:
  `FSDA_DEV_VENV` → `python`/`python3` on `PATH` → clear error. One-shot caveat: a different interpreter
  cannot be rebound in the same Julia session — start a fresh `julia` process.
- **Marshalling notes:**
  - *Julia ↔ Python:* a Julia `Vector{Float64}` (`y`) and `Matrix{Float64}` (`X`) cross via PythonCall as
    numpy arrays of the same logical shape; pass them through without flattening or transposing —
    `bridge.py`'s guards are the safety net. PythonCall does **not** auto-convert the return: convert the
    numpy `(len(la),)` explicitly with `pyconvert(Vector{Float64}, sc)` and verify
    `length(sc) == length(la)`. No silent reshape.
  - *Struct return is Python-side:* `Score` returns a MATLAB struct, but `bridge.py` already reads
    `out['Score']`, so PythonCall only ever sees a numpy vector — no struct/dict handling in Julia.
  - *Intercept:* FSDA adds the intercept column internally; Julia passes raw `X`, exactly as Python does.
  - *Python ↔ MATLAB:* unchanged from spec 004 (already checked).
- **Reference oracle:** load `code/Score/reference/Score_check.csv` from spec 004 and compare the Julia
  surface output to its `Score_fsda` column for the same fixed `la`; load the fixed `y`/`X` from
  `reference/wool.csv`. If either file is missing, fail with a message telling the user to run the
  spec-004 Python agreement check (`check_Score.py`) first. The Julia check writes its own artifact;
  tolerance is `1e-9`.

**Run** (requires `PythonCall` in the active Julia environment and `FSDA_DEV_VENV` pointing at the
venv's python):

```bash
# macOS / Linux
export JULIA_CONDAPKG_BACKEND=Null
export FSDA_DEV_VENV="$(command -v python)"
julia --project=code/Score -e 'import Pkg; Pkg.instantiate()'
julia --project=code/Score code/Score/check_Score_jl.jl
```

```powershell
# Windows (PowerShell)
$env:JULIA_CONDAPKG_BACKEND = "Null"
$env:FSDA_DEV_VENV = (Get-Command python).Source
julia --project=code\Score -e 'import Pkg; Pkg.instantiate()'
julia --project=code\Score code\Score\check_Score_jl.jl
```

## Tasks

- [x] #p1 Write `code/Score/bridge.jl` with `start_bridge`, `score`, `stop_bridge`, and
  `bridge_diagnostics` (opaque `ScoreBridge` struct, mirroring `bridge.R`).
- [x] #p1 In `bridge.jl`, bind PythonCall to the venv **before `using PythonCall`** (resolve
  `FSDA_DEV_VENV` → PATH → error; set `JULIA_CONDAPKG_BACKEND=Null` and `JULIA_PYTHONCALL_EXE`). No
  machine-specific path baked in.
- [x] #p1 Validate Julia-side input shapes/types (y vector/n×1 & strictly positive, X `n×p`, la vector)
  before crossing into Python; rely on `bridge.py` guards as authoritative.
- [x] #p1 Write `code/Score/check_Score_jl.jl` reading the spec-004 `wool` fixture + oracle, comparing
  at tolerance `1e-9`.
- [x] #p1 Run the Julia agreement check; confirm `PASS`, and save `reference/Score_jl_check.csv`.
- [x] #p2 Print version/path diagnostics via the Python helpers (Julia, PythonCall, Python, MATLAB,
  `matlabengine`, resolved `Score` path).
- [x] #p2 Commit a minimal `Project.toml` pinning PythonCall; document the run command here.
- [x] #p3 Note PythonCall conversion behaviour for keyword args + struct-returning routines.

### Done

- 2026-06-27 — Julia PythonCall Layer-2 surface written: `code/Score/bridge.jl`
  (`start_bridge` / `score` / `stop_bridge` / `bridge_diagnostics` over an opaque `ScoreBridge` struct,
  mirroring `bridge.R`) and `code/Score/check_Score_jl.jl` (reads the genuine `wool` fixture
  `reference/wool.csv` + the spec-004 oracle `reference/Score_check.csv`, default `la`, compares
  `Score_fsda` at `1e-9`, writes `reference/Score_jl_check.csv`). `bridge.py` is reused **verbatim**.

  **Agreement gate (CONSTITUTION §5): PASS — run 2026-06-27.** Run sequence:

  ```bash
  export JULIA_CONDAPKG_BACKEND=Null
  export FSDA_DEV_VENV="$(command -v python)"
  julia --project=code/Score -e 'import Pkg; Pkg.instantiate()'
  julia --project=code/Score code/Score/check_Score_jl.jl
  ```

  Printed diagnostics from the passing run:

  ```
  Julia        : 1.12.6
  PythonCall   : 0.9.35
  Python       : 3.11.5
  Python path  : /Users/aldocorbellini/miniconda3/bin/python
  MATLAB       : 26.1.0.3234472 (R2026a) Update 1
  engine pkg   : 26.1.12
  Score path   : /Users/aldocorbellini/FSDA/toolbox/regression/Score.m
  lambda       : -1 -0.5 0 0.5 1
  Julia surface: 17.7059127 7.492685656 -0.9122373268 -9.551122451 -18.55755191
  oracle       : 17.7059127 7.492685656 -0.9122373268 -9.551122451 -18.55755191
  max abs diff : 0.000e+00  (tol 1e-09)
  RESULT       : PASS
  ```

  Note: `Pkg.instantiate()` writes `code/Score/Manifest.toml` (a generated lockfile, not committed —
  the spec ships only `Project.toml`); regenerate it with the instantiate step above.

- 2026-06-27 — PythonCall notes for `Score` (vs the spec-002 `mahalFS` surface):
  - **Keyword arguments cross cleanly.** `bridge.module_.score(eng, y, X; la=..., intercept=...)` maps
    Julia keyword args to Python keyword args; `nothing` would map to Python `None` (we resolve the
    default `la` Julia-side and pass it explicitly, so the length check is exact).
  - **Struct returns never reach Julia.** `Score` returns a MATLAB struct, but `bridge.py` extracts
    `out['Score']` Python-side, so PythonCall only converts a numpy vector — no dict handling in Julia.
  - **Two reference files.** Inputs (27 wool rows) and outputs (5 lambdas) differ in cardinality, so the
    fixture (`wool.csv`) and oracle (`Score_check.csv`) are separate; the Julia check reads both.
  - The max abs diff is **exactly 0**: the Julia surface drives the same `bridge.py`/FSDA call as the
    oracle, so it reproduces `Score_fsda` bit-for-bit (the numeric gap is the numpy-vs-FSDA gap, already
    `6e-13` and recorded in spec 004).

- 2026-06-27 - Cross-target import fix (shared with spec 002). All targets' Layer-1 files are named
  `bridge.py`; Python caches modules by bare name, so loading `mahalFS` and `Score` in one Julia session
  returned the first-imported module and raised
  `AttributeError: module 'bridge' has no attribute 'which_score'`. Both `bridge.jl` files now evict the
  cached module (`sys.modules.pop("bridge", nothing)`) and force `_BRIDGE_DIR` to the front of
  `sys.path` before `pyimport("bridge")`, so each target loads its own `code/<target>/bridge.py` fresh,
  in either order. The path step is the one thing Julia needs beyond the R fix, because `pyimport` does
  not restore `sys.path` the way reticulate's `import_from_path` does. Verified at the import level
  without MATLAB; agreement gate unchanged.
