# Spec 003 - R reticulate: call FSDA `mahalFS` through Python

> Layer-2 R surface for the existing `mahalFS` bridge. Read `CONSTITUTION.md` first; it defines the
> MATLAB/Python toolchain, bridge layering, marshalling rules, and agreement gate.

## Contract

*What this spec must deliver, and how we know it's done.*

- **Deliverable:** from R, call the existing Python Layer-1 bridge in `code/mahalFS/bridge.py` through
  `reticulate`, start or reuse a MATLAB engine session, call the genuine FSDA `mahalFS(Y, MU, SIGMA)`,
  and return the per-row **squared Mahalanobis distances** as an R numeric vector.
- **Done when:** `code/mahalFS/check_mahalFS_r.R`, run with R configured to use the project Python venv,
  prints `PASS`; the R surface output matches the FSDA/Python oracle to `<= 1e-9`, writes an R-specific
  reference artifact under `code/mahalFS/reference/`, and reports the R / reticulate / Python / MATLAB /
  `matlabengine` version details.
- **Out of scope:** direct MATLAB calls from R; edits to FSDA or any `.m` source; changes to the Python
  bridge contract except bug fixes required by this spec; Julia; FSDA routines other than `mahalFS`;
  packaging, CI, or a CRAN-style R package.

## Design

*How the contract is realised.*

- **Files:**
  - `code/mahalFS/bridge.R` - Layer 2 wrapper. Loads `reticulate`, pins it to the project Python venv,
    imports `code/mahalFS/bridge.py`, and exposes R functions mirroring the Python bridge lifecycle.
  - `code/mahalFS/check_mahalFS_r.R` - R agreement check using the same fixed `n = 5, v = 2` input as
    spec 001, comparing the R surface output against the Python/FSDA oracle at `1e-9`.
  - `code/mahalFS/reference/mahalFS_r_check.csv` - R check artifact containing inputs, FSDA distances,
    oracle distances, and absolute differences.
- **Signatures / calls:**
  - `start_bridge(python = Sys.getenv("FSDA_DEV_VENV"), fsda_root = NULL)` returns an opaque bridge
    handle containing the imported Python module and the live MATLAB engine object.
  - `mahal_fs(bridge, Y, MU, SIGMA)` accepts an R numeric matrix `Y`, numeric vector or one-row matrix
    `MU`, and numeric matrix `SIGMA`; it returns a numeric vector of length `nrow(Y)`.
  - `stop_bridge(bridge)` explicitly quits the MATLAB engine by delegating to `bridge.py::stop_engine`.
  - The R wrapper calls Python only; the Python bridge remains responsible for `matlab.double`
    conversion and the actual `eng.mahalFS(...)` call.
- **Marshalling notes:**
  - R matrices are column-major; the wrapper must pass matrix-shaped objects through `reticulate`
    without flattening or transposing them.
  - Validate on the R side before calling Python: `Y` is a 2D numeric matrix, `MU` is length `v` or
    shape `1 x v`, and `SIGMA` is `v x v`. Python boundary checks from spec 001 remain authoritative.
  - Convert the returned Python/numpy value to an R numeric vector and verify `length(d) == nrow(Y)`.
    No silent reshape; no conversion of MATLAB 1-based indexes is needed for `mahalFS`.
  - R code uses `=` for assignment, matching `AGENTS.md`.
- **Reference oracle:** load `code/mahalFS/reference/mahalFS_check.csv` from spec 001 and compare the R
  surface output to its saved FSDA distance column for the same fixed inputs. If that file is missing,
  the R check should fail with a message telling the user to run the spec-001 Python agreement check
  first. The R check writes its own artifact under `code/mahalFS/reference/`, and the agreement
  tolerance is `1e-9`.

## Tasks

*Ordered checklist. Priorities: `#p1` blocking, `#p2` this round, `#p3` nice-to-have.*

- [x] #p1 Write `code/mahalFS/bridge.R` with `start_bridge`, `mahal_fs`, and `stop_bridge`.
- [x] #p1 In `bridge.R`, configure `reticulate` to use `FSDA_DEV_VENV` when set, otherwise the pinned
  default venv `C:\Users\LucaI\fsda_dev_env`.
- [x] #p1 Validate R-side input shapes and numeric types before crossing into Python.
- [x] #p1 Write `code/mahalFS/check_mahalFS_r.R` using the same fixed input as spec 001 and tolerance
  `1e-9`.
- [x] #p1 Run the R agreement check; confirm `PASS` and save `reference/mahalFS_r_check.csv`.
- [x] #p2 Print useful version/path diagnostics: R, `reticulate`, Python, MATLAB, `matlabengine`, and
  resolved `mahalFS` path.
- [x] #p2 Document the exact command used to run the R check in this spec's Done section.
- [x] #p3 Note any reticulate conversion surprises that matter for later R wrappers.

### Done

- 2026-06-26 - R reticulate layer written and agreement check run. **PASS, max abs diff `0.000e+00`**
  (tol 1e-9). R artifact in `code/mahalFS/reference/mahalFS_r_check.csv`.

  Command used:

  ```powershell
  $env:R_LIBS_USER = 'D:\tmp\Rlib-4.5.2'
  $env:FSDA_DEV_VENV = (Get-Command python).Source
  $env:PYTHONDONTWRITEBYTECODE = '1'
  & 'C:\Program Files\R\R-4.5.2\bin\Rscript.exe' code\mahalFS\check_mahalFS_r.R
  ```

  Env: R 4.5.2; `reticulate` 1.46.0 from `D:\tmp\Rlib-4.5.2`; Python 3.12.10 at
  `C:/Users/mrian/AppData/Local/Programs/Python/Python312/python.exe`; MATLAB
  `26.1.0.3251617 (R2026a) Update 2`; `matlabengine` 26.1.12; `mahalFS` resolved to
  `D:\MATLAB\FSDAgit\FSDA\toolbox\utilities_stat\mahalFS.m`.
- 2026-06-26 - Reticulate notes for later R wrappers: R matrices passed through as shaped arrays for
  this fixture, so no transpose was needed. Direct calls like `bridge$engine$version()` can trigger
  reticulate signature probing on MATLAB engine methods; diagnostics now go through tiny Python helper
  functions instead.

- 2026-06-26 - Follow-up fix: `FSDA_DEV_VENV` / `DEFAULT_PYTHON_ENV` may point at a conda root such as
  `C:\Users\mrian\miniconda3`, which is not a Python virtualenv. `bridge.R` now detects real venvs via
  `pyvenv.cfg` and otherwise uses an available `python.exe` with `reticulate::use_python()`. The R check
  is also source-friendly: `source(".../check_mahalFS_r.R")` runs the check and returns to R, while
  `Rscript` still exits with the check status. Verified **PASS**, max abs diff `0.000e+00`, using
  `C:/Users/mrian/miniconda3/python.exe`.