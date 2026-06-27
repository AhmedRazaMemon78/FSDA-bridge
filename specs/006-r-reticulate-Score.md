# Spec 006 - R reticulate: call FSDA `Score` through Python

> Layer-2 R surface for the `Score` bridge (spec 004), completing the chain
> `R → reticulate → Python (bridge.py) → matlab.engine → MATLAB + FSDA`. Read `CONSTITUTION.md` first;
> it defines the MATLAB/Python toolchain, bridge layering, marshalling rules, and agreement gate. This
> is the `Score` sibling of the spec-003 `mahalFS` R surface; the Python Layer-1 bridge
> (`code/Score/bridge.py`) is reused **verbatim**.

## Contract

- **Deliverable:** from R, call the existing Python Layer-1 bridge in `code/Score/bridge.py` through
  `reticulate`, start or reuse a MATLAB engine session, call the genuine FSDA
  `Score(y, X, 'la', la, 'intercept', intercept)`, and return the per-lambda **score-test t-statistics**
  as an R numeric vector.
- **Done when:** `code/Score/check_Score_r.R`, run with R configured to use the project Python venv,
  prints `PASS`; the R surface output matches the FSDA/Python oracle to `<= 1e-9`, writes an R-specific
  reference artifact under `code/Score/reference/`, and reports the R / reticulate / Python / MATLAB /
  `matlabengine` version details plus the resolved `Score` path.
- **Out of scope:** direct MATLAB calls from R; edits to FSDA or any `.m` source; changes to the Python
  bridge contract except bug fixes required by this spec; Julia (spec 005); the optional `out.Lik` /
  `out.ScoreT` outputs; FSDA routines other than `Score`; packaging, CI, or a CRAN-style R package.

## Design

- **Files:**
  - `code/Score/bridge.R` - Layer 2 wrapper. Loads `reticulate`, pins it to the project Python venv,
    imports `code/Score/bridge.py`, and exposes R functions mirroring the Python bridge lifecycle
    (`start_bridge` / `score` / `stop_bridge` / `bridge_diagnostics` over an opaque
    `fsda_score_bridge` handle).
  - `code/Score/check_Score_r.R` - R agreement check using the genuine `wool` fixture
    (`reference/wool.csv`) and default `la = [-1, -0.5, 0, 0.5, 1]`, comparing the R surface output
    against the spec-004 Python/FSDA oracle (`reference/Score_check.csv`) at `1e-9`.
  - `code/Score/reference/Score_r_check.csv` - R check artifact: per-lambda surface vs oracle.
- **Signatures / calls:**
  - `start_bridge(python = Sys.getenv("FSDA_DEV_VENV"), fsda_root = NULL)` returns an opaque bridge
    handle containing the imported Python module and the live MATLAB engine object.
  - `score(bridge, y, X, la = NULL, intercept = TRUE)` accepts a numeric vector or one-column matrix
    `y` (strictly positive), a numeric matrix `X` (`n × p`), and an optional `la` vector; it returns a
    numeric vector of length `length(la)` (default 5). R named args map to Python keyword args.
  - `stop_bridge(bridge)` explicitly quits the MATLAB engine by delegating to `bridge.py::stop_engine`.
  - The R wrapper calls Python only; the Python bridge remains responsible for `matlab.double`
    conversion, the `out$Score` **struct-field** read, and the actual `eng.Score(...)` call.
- **Marshalling notes:**
  - R matrices are column-major; the wrapper passes matrix-shaped objects through `reticulate` without
    flattening or transposing them. `y` crosses as a numeric vector, `X` as an `n × p` array, `la` as a
    numeric vector, `intercept` as a logical.
  - Validate on the R side before calling Python: `y` is a numeric vector / `n × 1` matrix and strictly
    positive, `X` is `n × p` with rows matching `y`, `la` is a non-empty numeric vector. Python boundary
    checks from spec 004 remain authoritative.
  - *Struct return is Python-side:* `Score` returns a MATLAB struct, but `bridge.py` reads `out['Score']`,
    so reticulate only ever converts a numpy vector — no struct/list handling in R.
  - Convert the returned Python/numpy value to an R numeric vector and verify `length(sc) == length(la)`.
  - R code uses `=` for assignment, matching `AGENTS.md`.
- **Reference oracle:** load `code/Score/reference/Score_check.csv` from spec 004 and compare the R
  surface output to its `Score_fsda` column for the same fixed `la`; load `y`/`X` from
  `reference/wool.csv`. If either file is missing, the R check fails with a message telling the user to
  run the spec-004 Python agreement check first. The R check writes its own artifact, tolerance `1e-9`.

## Tasks

- [x] #p1 Write `code/Score/bridge.R` with `start_bridge`, `score`, `stop_bridge`, `bridge_diagnostics`.
- [x] #p1 In `bridge.R`, configure `reticulate` to use `FSDA_DEV_VENV` when set, otherwise the active
  `python` on PATH; if neither resolves, stop with a clear message (no machine-specific path baked in).
- [x] #p1 Validate R-side input shapes/types before crossing into Python (y vector/n×1 & strictly
  positive, X `n×p`, la vector).
- [x] #p1 Write `code/Score/check_Score_r.R` using the spec-004 `wool` fixture + oracle, tolerance `1e-9`.
- [x] #p1 Run the R agreement check; confirm `PASS` and save `reference/Score_r_check.csv`.
- [x] #p2 Print useful version/path diagnostics: R, `reticulate`, Python, MATLAB, `matlabengine`,
  resolved `Score` path.
- [x] #p2 Document the exact command used to run the R check in this spec's Done section.
- [x] #p3 Note any reticulate conversion surprises for `Score` (keyword args, struct-returning routines).

### Done

- 2026-06-27 - R reticulate layer written and agreement check run. **PASS, max abs diff `0.000e+00`**
  (tol 1e-9). R artifact in `code/Score/reference/Score_r_check.csv`. `bridge.py` reused **verbatim**.

  Command used (macOS):

  ```bash
  export FSDA_DEV_VENV="$(command -v python)"
  export PYTHONDONTWRITEBYTECODE=1
  Rscript code/Score/check_Score_r.R
  ```

  Env: R 4.4.1; `reticulate` 1.45.0 (installed from CRAN into `/Users/aldocorbellini/Rpackages`);
  Python 3.11.5 at `/Users/aldocorbellini/miniconda3/bin/python3.11`; MATLAB
  `26.1.0.3234472 (R2026a) Update 1`; `matlabengine` 26.1.12; `Score` resolved to
  `/Users/aldocorbellini/FSDA/toolbox/regression/Score.m`. Fixture: genuine FSDA `wool` (27×4); default
  `la`. R surface = `[17.7059, 7.4927, -0.9122, -9.5511, -18.5576]`, reproducing the spec-004 oracle.

- 2026-06-27 - reticulate notes for `Score` (vs the spec-003 `mahalFS` surface):
  - **Named args → keyword args.** `bridge$module$score(eng, y, X, la = ..., intercept = ...)` passes R
    named args as Python keyword args; the optional `la`/`intercept` defaults stay in `bridge.py`.
  - **Struct returns never reach R.** `Score` returns a MATLAB struct, but `bridge.py` extracts
    `out['Score']` Python-side, so reticulate converts only a numpy vector — no struct handling in R.
  - **Two reference files.** Inputs (27 wool rows) and outputs (5 lambdas) differ in cardinality, so the
    fixture (`wool.csv`) and oracle (`Score_check.csv`) are separate; the R check reads both.
  - As in spec 003, MATLAB diagnostics go through Python helpers (`bridge.matlab_version`,
    `bridge.which_score`) to avoid reticulate probing engine method signatures.
  - **One-time setup:** this machine had no `reticulate`; installed the CRAN binary
    (`install.packages("reticulate", lib="/Users/aldocorbellini/Rpackages")`) before the run.

- 2026-06-27 - Cross-target import fix (shared with spec 003). All targets' Layer-1 files are named
  `bridge.py`; Python caches modules by bare name, so loading `mahalFS` and `Score` in one R session
  returned the first-imported module and raised
  `AttributeError: module 'bridge' has no attribute 'which_score'` until R restart. Both `bridge.R`
  files now call `sys.modules.pop('bridge', None)` just before `import_from_path`, loading each target's
  own `code/<target>/bridge.py` fresh (no restart, either order). Verified at the import level without
  MATLAB. **Note (Julia):** the spec-002/005 PythonCall surfaces have the same latent `bridge` name, but
  Julia is already single-target-per-session by design (the one-shot PythonCall binding + `const
  _BRIDGE_DIR`), so the documented workflow is a fresh `julia` process per target; making Julia
  multi-target in one session would require wrapping each `bridge.jl` in its own `module`.
