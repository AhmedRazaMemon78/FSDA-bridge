# Spec 012 - R reticulate: call FSDA `FSRaddt` through Python

> Layer-2 R surface for the `FSRaddt` bridge (spec 010), completing the chain
> `R → reticulate → Python (bridge.py) → matlab.engine → MATLAB + FSDA`. Read `CONSTITUTION.md` first.
> This is the `FSRaddt` sibling of the spec-009 FSR R surface; the Python Layer-1 bridge
> (`code/FSRaddt/bridge.py`) is reused **verbatim**.

## Contract

- **Deliverable:** from R, call `code/FSRaddt/bridge.py` through `reticulate`, start/reuse a MATLAB
  engine, run the genuine FSDA `FSRaddt(y, X, ...)`, and return its key fields (`Tdel`, `S2del`,
  1-based `bs`, the `Un` cell→list of matrices, 1-based `la`) as plain R.
- **Done when:** `code/FSRaddt/check_FSRaddt_r.R`, run with R configured to use the project venv,
  prints `PASS`; **the last five rows of `out.Tdel` equal the spec-010 golden**
  (`reference/FSRaddt_Tdel.csv`) to `<= 1e-9` on the `wool` fixture, it writes an R artifact, and it
  reports the R / reticulate / Python / MATLAB / `matlabengine` / `FSRaddt`-path diagnostics.
- **Out of scope:** direct MATLAB calls from R; edits to FSDA or any `.m`; changes to the Python
  bridge contract except bug fixes; Julia (011); the `S2del` tail as a gate; the `quant`/`DataVars`/
  plot options; routines other than `FSRaddt`; packaging.

## Design

- **Files:**
  - `code/FSRaddt/bridge.R` - Layer 2 wrapper (`start_bridge` / `fsraddt` / `stop_bridge` /
    `bridge_diagnostics` over an opaque `fsda_fsraddt_bridge` handle). Pins reticulate to the venv,
    evicts any stale `bridge` module from `sys.modules` before importing (the cross-target fix from
    spec 009; FSRaddt is the 5th `bridge.py`), and imports `code/FSRaddt/bridge.py`.
  - `code/FSRaddt/check_FSRaddt_r.R` - agreement check; reads the `wool` fixture + golden, runs
    `fsraddt(nsamp=0)`, compares the last 5 rows of `Tdel` at `1e-9`, writes
    `reference/FSRaddt_r_check.csv`.
- **Signatures / calls:**
  - `start_bridge(python = Sys.getenv("FSDA_DEV_VENV"), fsda_root = NULL)` → opaque handle.
  - `fsraddt(bridge, y, X, nsamp = 0, intercept = TRUE, plots = 0, msg = 0, DataVars = NULL,
    h = NULL, init = NULL, lms = 1)` → R list `(Tdel` (m, k+1) matrix, `S2del` matrix, `bs` integer
    matrix 1-based, `Un` list of matrices, `la` integer vector 1-based)`. R named args map to Python
    keyword args; `NULL → None`.
  - `stop_bridge` / `render_figures` / `wait_for_figures` / `bridge_diagnostics` (MATLAB values via
    Python helpers `bridge.matlab_version` / `bridge.which_fsraddt`).
  - `bridge.py` stays authoritative for `matlab.double` conversion, forcing `plots=0,msg=0`, the
    struct-field reads, the **cell→list `Un`** normalization, and the 1-based `bs`/`la`.
- **Marshalling notes:**
  - With `convert = TRUE`, reticulate turns the returned Python dict into an R list, its numpy values
    into an R matrix (`Tdel`/`S2del`/`bs`) / vector (`la`), and the **`Un` list of arrays into an R
    list of matrices** — the struct/dict + cell→list handling all stay Python-side, so R only sees
    clean arrays.
  - **Variable width:** the Tdel check keys off `length(la)` (`ncol(Tdel) == 1 + length(la)`), not a
    hardcoded 2; the golden reader accepts any number of `t` columns.
  - **1-based indices**: R is natively 1-based, so `bs`/`la` are already correct (no decrement).
  - **Determinism**: `nsamp=0`; `plots=0`/`msg=0` keep the engine headless.
  - R code uses `=` for assignment, matching `AGENTS.md`.
- **Reference oracle:** the spec-010 `reference/FSRaddt_Tdel.csv` golden (gate = its last 5 rows) and
  `reference/wool.csv` (fixed input). If either is missing, the R check fails telling the user to run
  `check_FSRaddt.py` first.

## Tasks

- [x] #p1 Write `code/FSRaddt/bridge.R` (`start_bridge` / `fsraddt` / `stop_bridge` /
  `bridge_diagnostics`), with the cross-target `sys.modules.pop('bridge', None)` eviction baked in.
- [x] #p1 Configure reticulate to use `FSDA_DEV_VENV` (else PATH; else stop) — no machine-specific path.
- [x] #p1 Validate R-side inputs (y vector/n×1, X n×p) before crossing into Python.
- [x] #p1 Write `code/FSRaddt/check_FSRaddt_r.R` using the spec-010 fixture + golden; gate = last 5
  Tdel rows.
- [x] #p1 Run the R check; confirm `PASS` and save `reference/FSRaddt_r_check.csv`.
- [x] #p2 Diagnostics via Python helpers (incl. resolved `FSRaddt` path); document the run command here.
- [x] #p3 Note reticulate behaviour for the cell→list `Un` + variable-width Tdel conversion.

### Done

- 2026-06-28 - R reticulate layer written and agreement check run. **PASS, max abs diff `4.441e-16`**
  (tol 1e-9, machine epsilon from the golden-CSV round-trip) on the last 5 rows of `out.Tdel`.
  `bridge.py` reused **verbatim**; `la=2 3 4` (k=3) and the 3-cell `Un` (each `22x11`) reproduced. R
  artifact in `code/FSRaddt/reference/FSRaddt_r_check.csv`.

  Command used (macOS):

  ```bash
  export FSDA_DEV_VENV="$(command -v python)"
  export PYTHONDONTWRITEBYTECODE=1
  Rscript code/FSRaddt/check_FSRaddt_r.R
  ```

  Env: R 4.4.1; `reticulate` 1.45.0; Python 3.11.5 at `/Users/aldocorbellini/miniconda3/bin/python3.11`;
  MATLAB `26.1.0.3234472 (R2026a) Update 1`; `matlabengine` 26.1.12; `FSRaddt` at
  `/Users/aldocorbellini/FSDA/toolbox/regression/FSRaddt.m`. Fixture: genuine FSDA `wool` (27×4),
  `nsamp=0`.

- 2026-06-28 - reticulate notes for `FSRaddt` (vs the spec-009 `FSR` surface):
  - **Cell→list `Un`.** With `convert=TRUE`, `bridge$module$fsraddt(...)` returns an R list; `res$Un`
    (the MATLAB cell, surfaced Python-side as a list of numpy arrays) becomes an **R list of
    matrices** with no manual unpacking — `lapply(res$Un, as.matrix)` is all that's needed.
  - **Variable width Tdel.** `res$Tdel` is an R matrix of `1 + length(la)` columns (here 4); the check
    keys off `length(la)` and the golden reader accepts any number of `t` columns — no hardcoded 2.
  - **Cross-target fix carried over** (FSRaddt is the 5th `bridge.py`): `start_bridge` runs
    `sys.modules.pop('bridge', None)` before `import_from_path`, so FSRaddt coexists with FSR / Score /
    mahalFS in one R session without the `AttributeError` cache trap.
