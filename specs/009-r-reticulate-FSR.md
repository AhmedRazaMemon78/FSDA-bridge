# Spec 009 - R reticulate: call FSDA `FSR` through Python

> Layer-2 R surface for the `FSR` bridge (spec 007), completing the chain
> `R → reticulate → Python (bridge.py) → matlab.engine → MATLAB + FSDA`. Read `CONSTITUTION.md` first.
> This is the `FSR` sibling of the spec-003/006 R surfaces; the Python Layer-1 bridge
> (`code/FSR/bridge.py`) is reused **verbatim**.

## Contract

- **Deliverable:** from R, call `code/FSR/bridge.py` through `reticulate`, start/reuse a MATLAB engine,
  run the genuine FSDA `FSR(y, X, ...)`, and return its key fields (`mdr`, 1-based `outliers`, `beta`,
  `scale`) as plain R.
- **Done when:** `code/FSR/check_FSR_r.R`, run with R configured to use the project venv, prints `PASS`;
  **the last five rows of `out.mdr` equal the spec-007 golden** (`reference/FSR_mdr.csv`) to `<= 1e-9`
  on the `stars` fixture, it writes an R artifact, and it reports the R / reticulate / Python / MATLAB /
  `matlabengine` / `FSR`-path diagnostics.
- **Out of scope:** direct MATLAB calls from R; edits to FSDA or any `.m`; changes to the Python bridge
  contract except bug fixes; Julia (008); `out.Un`/`out.nout`/`weak`/plot options; routines other than
  `FSR`; packaging.

## Design

- **Files:**
  - `code/FSR/bridge.R` - Layer 2 wrapper (`start_bridge` / `fsr` / `stop_bridge` /
    `bridge_diagnostics` over an opaque `fsda_fsr_bridge` handle). Pins reticulate to the venv, evicts
    any stale `bridge` module from `sys.modules` before importing (the cross-target fix from spec 003/006),
    and imports `code/FSR/bridge.py`.
  - `code/FSR/check_FSR_r.R` - agreement check; reads the `stars` fixture + golden, runs `fsr(nsamp=0)`,
    compares the last 5 rows of `mdr` at `1e-9`, writes `reference/FSR_r_check.csv`.
- **Signatures / calls:**
  - `start_bridge(python = Sys.getenv("FSDA_DEV_VENV"), fsda_root = NULL)` → opaque handle.
  - `fsr(bridge, y, X, nsamp = 0, intercept = TRUE, h = NULL, init = NULL, bonflev = NULL)` → R list
    `(mdr` 2-col matrix, `outliers` integer vector 1-based, `beta` numeric, `scale` numeric)`. R named
    args map to Python keyword args; `NULL → None`.
  - `stop_bridge` / `bridge_diagnostics` (MATLAB values via Python helpers `bridge.matlab_version` /
    `bridge.which_fsr`).
  - `bridge.py` stays authoritative for `matlab.double` conversion, forcing `plots=0,msg=0`, the
    struct-field reads, and the scalar/array/empty **outlier normalization**.
- **Marshalling notes:**
  - With `convert = TRUE`, reticulate turns the returned Python dict into an R list and its numpy values
    into an R matrix (`mdr`) / vectors (`outliers`, `beta`); the struct/dict + outlier-shape handling all
    stay Python-side, so R only sees clean arrays.
  - **1-based outliers**: R is natively 1-based, so the index list is already correct (no decrement).
  - **Determinism**: `nsamp=0`; `plots=0`/`msg=0` keep the engine headless.
  - R code uses `=` for assignment, matching `AGENTS.md`.
- **Reference oracle:** the spec-007 `reference/FSR_mdr.csv` golden (gate = its last 5 rows) and
  `reference/stars.csv` (fixed input). If either is missing, the R check fails telling the user to run
  `check_FSR.py` first.

## Tasks

- [x] #p1 Write `code/FSR/bridge.R` (`start_bridge` / `fsr` / `stop_bridge` / `bridge_diagnostics`),
  with the cross-target `sys.modules.pop('bridge', None)` eviction baked in.
- [x] #p1 Configure reticulate to use `FSDA_DEV_VENV` (else PATH; else stop) — no machine-specific path.
- [x] #p1 Validate R-side inputs (y vector/n×1, X n×p) before crossing into Python.
- [x] #p1 Write `code/FSR/check_FSR_r.R` using the spec-007 fixture + golden; gate = last 5 mdr rows.
- [x] #p1 Run the R check; confirm `PASS` and save `reference/FSR_r_check.csv`.
- [x] #p2 Diagnostics via Python helpers (incl. resolved `FSR` path); document the run command here.
- [x] #p3 Note reticulate behaviour for dict-returning routines + integer-index conversion.

### Done

- 2026-06-27 - R reticulate layer written and agreement check run. **PASS, max abs diff `0.000e+00`**
  (tol 1e-9) on the last 5 rows of `out.mdr`. `bridge.py` reused **verbatim**; outliers (1-based)
  **11 20 30 34** reproduced. R artifact in `code/FSR/reference/FSR_r_check.csv`.

  Command used (macOS):

  ```bash
  export FSDA_DEV_VENV="$(command -v python)"
  export PYTHONDONTWRITEBYTECODE=1
  Rscript code/FSR/check_FSR_r.R
  ```

  Env: R 4.4.1; `reticulate` 1.45.0 (`/Users/aldocorbellini/Rpackages`); Python 3.11.5 at
  `/Users/aldocorbellini/miniconda3/bin/python3.11`; MATLAB `26.1.0.3234472 (R2026a) Update 1`;
  `matlabengine` 26.1.12; `FSR` at `/Users/aldocorbellini/FSDA/toolbox/regression/FSR.m`. Fixture:
  genuine FSDA `stars` (47×2), `nsamp=0`.

- 2026-06-27 - reticulate notes for `FSR` (vs the spec-006 `Score` surface):
  - **Dict-returning routine.** With `convert=TRUE`, `bridge$module$fsr(...)` returns an R list; `res$mdr`
    is an R matrix, `res$outliers` an integer vector — no manual unpacking of a Python object.
  - **Outlier-shape normalization stays Python-side** — R always receives a clean vector (empty when no
    outliers), so the scalar/array/empty inconsistency never reaches R.
  - **Cross-target fix baked in from the start** (FSR is the 4th `bridge.py`): `start_bridge` runs
    `sys.modules.pop('bridge', None)` before `import_from_path`, so FSR coexists with mahalFS / Score in
    one R session without the `AttributeError` cache trap.

- 2026-06-27 — Plots/messages enabled (parity with spec 007). `fsr(..., plots=0, msg=0)` now forwards
  both to `bridge.py`, and `render_figures(bridge)` (→ Python `bridge.render_figures`) was added.
  `check_FSR_r.R` sets `PLOTS=MSG=1`, and before the engine is quit (via `on.exit`) it renders +
  `readline()` pauses **only when `isatty(stdin())`**, so piped/CI runs never hang. Messages: `bridge.py`
  writes the captured MATLAB output to Python `sys.stdout`, which reticulate forwards to the R console.
  Verified headless (piped stdin): FSDA's messages print, **PASS** (max abs diff `0.000e+00`, outliers
  11 20 30 34), exit 0, no hang.
