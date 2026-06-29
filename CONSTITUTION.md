# CONSTITUTION

The project-wide contract: rules common to **every** spec in this repo. Individual specs may add detail
but must not contradict this file. Changes here require the author's explicit sign-off.

## 1. What this project is

Prototype calling **FSDA** (MATLAB robust-statistics toolbox) from other languages, using the **MATLAB
Engine API for Python** (`matlab.engine`) as the bridge. The port chain grows one surface at a time:

```
Python  → matlab.engine → MATLAB + FSDA          ← spec 001 (now)
Julia   → PythonCall → Python → … → FSDA          ← later spec
R       → reticulate → Python → … → FSDA          ← later spec
```

The Python bridge plays two roles: a **reference oracle** that runs the genuine FSDA routine to produce
gold outputs, and (optionally) a **live backend** that a Julia/R wrapper calls at runtime. This is a
local prototype — **no package is produced, no CI is required.**

## 2. Toolchain (pinned)

| Component | Pin |
|-----------|-----|
| MATLAB | **R2026a**, with the **FSDA Add-On** installed (routines on the MATLAB path; verify `which mahalFS`) |
| FSDA install | per-user MATLAB Add-On dir (`...\MATLAB Add-Ons\Toolboxes\FSDA`; auto on path) |
| Python venv | machine-specific — set `FSDA_DEV_VENV` to the venv's **python executable** (`...\Scripts\python.exe` on Windows, `.../bin/python` on macOS); Python **3.12.10**, `numpy`, `matlabengine==26.1.*` |
| engine install | from **PyPI** (`pip install "matlabengine==26.1.*"`) — the matlabroot build fails on read-only Program Files |

The interpreter is selected by an activated venv, else **`FSDA_DEV_VENV`** (the venv's python
executable), else `python` / `python3` on `PATH`. `matlab.engine` is locked to the installed MATLAB
release — keep the MATLAB ↔ engine-package versions paired.

## 3. Bridge architecture

- **Layer 0 — MATLAB / FSDA:** unmodified. We call it, we never edit it.
- **Layer 1 — Python bridge:** starts one MATLAB engine session (startup is slow — reuse it), marshals
  inputs in, calls the FSDA function, marshals outputs back, and shuts down explicitly. Two forms coexist:
  - the **shared generic engine** `code/fsda_engine/engine.py` (`FsdaEngine`, spec 016) — a routine-agnostic
    `call(name, *args, **nv)` / `eval` that most routines use with **no per-routine wrapper**; and
  - the original per-target `code/<target>/bridge.py` modules (mahalFS, Score, FSR, FSRaddt, getYahoo),
    kept for routines that need bespoke handling.
- **Layer 2 — language surfaces (later):** Julia (PythonCall) and R (reticulate) each call into Layer 1.

## 4. Type marshalling (where ports break)

Values cross the MATLAB ↔ Python boundary and lose information silently if unguarded:

- MATLAB matrices ↔ `matlab.double` / `matlab.logical`; **column-major** storage; **1-based** indexing.
- MATLAB `struct` ↔ `dict`; cell ↔ list; char/string ↔ `str`; `NaN`/`Inf` preserved; empty `[]` / `0×0`
  need explicit handling.
- A MATLAB **`table` / `timetable`** cannot be returned to Python directly — the generic engine runs in
  the MATLAB workspace and decomposes it into a dict `{VariableNames, RowNames / RowTimes, data}`.
  **Struct-arrays / datetime** still do not marshal generically (handled bespoke, e.g. `getYahoo`).
- **Rule:** shape/dtype-check every marshalled value at the boundary — no silent reshape (the generic
  engine returns MATLAB's natural shape; a 1-D input crosses as a MATLAB **row**, so pass `(n, 1)` for a
  column). An index returned from MATLAB stays 1-based until the language surface converts it; never hand
  a MATLAB index to Python as if it were 0-based.

## 5. Agreement gate (definition of done)

For a fixed set of inputs, the port output must match the FSDA **reference oracle** to a stated tolerance
(**default `1e-9`**): same values, same flagged units, same structure — accounting for legitimate
equivalent-optimum / ordering ambiguity. Gold outputs are saved under the target's folder
(`code/<target>/reference/`). Randomized FSDA steps (subsampling) must be seed-controlled across the
bridge. A port not checked against the oracle is **not done**.

## 6. Layout & discipline

- Code is organized **by target**: `code/<target>/` (one folder per FSDA routine), holding `bridge.py`,
  a `check_<target>.py` agreement check, and `reference/` gold outputs — **plus** shared cross-target
  modules where justified: the generic engine `code/fsda_engine/` (spec 016) holds `engine.py`,
  `check_engine.py`, and `reference/`.
- Prototype rules: no package, no CI, no new heavy dependencies.
- Commits are scoped and reference the spec number. Closing a task is recorded in its spec file.
