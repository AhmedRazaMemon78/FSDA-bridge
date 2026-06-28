# Spec 007 — MATLAB Engine: call FSDA `FSR` from Python (Forward Search Regression)

> Third function ported through the Layer-1 bridge, after `mahalFS` (001) and `Score` (004). `FSR` is
> the hardest yet: a robust forward search (random LXS initial subset, sequential outlier testing) that
> returns a **struct** including a **list of 1-based outlier unit indices**. Read `CONSTITUTION.md`
> first. Python surface only; Julia (008) and R (009) are siblings.

## Contract

- **Deliverable:** from Python, start a MATLAB engine session, call the genuine FSDA `FSR(y, X, ...)`,
  and return the key outputs (the `out.mdr` forward-search trajectory, the 1-based `out.outliers`,
  `beta`, `scale`, fitted/residuals) as numpy.
- **Done when:** `code/FSR/check_FSR.py`, run with the project venv, prints `PASS` — **the last five
  rows of `out.mdr` equal the committed golden** (`reference/FSR_mdr.csv`) to `< 1e-9`, on the genuine
  FSDA `stars` dataset with `nsamp=0` (deterministic).
- **Out of scope:** Julia and R surfaces (008 / 009); an independent numpy oracle (infeasible for FSR —
  see below); the `out.Un` / `out.nout` monitoring matrices and the `weak`/`bonflev`/plot options beyond
  what the gate needs; FSDA routines other than `FSR`; packaging.

## Design

**Why the gate is the mdr tail, not a numpy oracle.** `mahalFS`/`Score` had clean pure-numpy oracles.
`FSR` does not — it is a forward-search loop over FSDA internals (`FSRmdr`, `FSRcore`, `LXS`) with
repeated singular-subset handling, not reproducible in numpy to 1e-9. `out.mdr` is `(n-init, 2)` —
`[step, minimum deletion residual]` — and its **tail** is the decisive outlier-signal region. Comparing
the **last five rows** is robust to any minor mid-search ties yet proves the surfaces converge to the
same signal. (Per the project owner.)

**Determinism.** FSR randomness comes only from `nsamp` subsampling; **`nsamp=0` enumerates all C(n,p)
subsets**, so the run is deterministic with no RNG seeding. The fixture is small enough (stars: n=47,
p=2 → C(47,2)=1081) for that to be instant. FSR also defaults to `plots=1`; the bridge forces
`plots=0` and `msg=0` so nothing pops a figure or writes stdout through the headless engine.

- **Files:**
  - `code/FSR/bridge.py` — Layer 1. `start_engine(fsda_root=None)` (verify `which('FSR')`),
    `fsr(eng, y, X, nsamp=0, intercept=True, h=None, init=None, bonflev=None)` (marshals numpy →
    `matlab.double`, forces `plots=0,msg=0`, parses the struct→dict), `stop_engine`, plus diagnostics
    helpers `matlab_version` / `which_fsr` for the Layer-2 surfaces.
  - `code/FSR/check_FSR.py` — the agreement check. Fixed input = genuine FSDA `stars` (47×2). Gate =
    last 5 rows of `out.mdr` vs golden at `atol=1e-9`. Bootstraps `reference/stars.csv` (portable
    fixture) + `reference/FSR_mdr.csv` (golden) on first run; also writes `reference/FSR_check.csv`
    (outliers/beta/scale, for transparency).
- **Signatures / shapes:** `y` is `(n,)`/`(n,1)`; `X` is `(n, p-1)` raw predictors (FSDA adds the
  intercept when `intercept=True`); returns a dict — `mdr (m,2)`, `outliers` (1-based int, **empty if
  none**), `beta (p,)`, `scale` (float), `fittedvalues (n,)`, `residuals (n,)`, `class`.
- **Marshalling notes (where FSR breaks ports — richer than Score):**
  - *Struct return:* `eng.FSR(...)` returns a MATLAB **struct → Python dict** (needs `nargout=1`).
  - *1-based outlier indices:* `out.outliers`/`out.ListOut` are MATLAB **1-based** unit indices, kept
    1-based here (the language surface converts only if it ever needs 0-based). FSR is the first
    index-returning routine, so this is finally exercised.
  - *Inconsistent index shape:* MATLAB returns a **scalar** for one outlier, a **vector** for several,
    and **empty `[[]]`/NaN** for none. `_normalize_outliers` collapses all three to a 1D int array.
  - *Headless:* `plots=0`, `msg=0` forced in the bridge.
  - *Determinism:* `nsamp=0` (all subsets); document why it removes RNG.
  - Validate `y`/`X` shapes and that `mdr` is 2-column; no silent reshape.
- **Reference oracle:** the deterministic FSDA run itself; golden mdr saved to
  `code/FSR/reference/FSR_mdr.csv`, fixture to `reference/stars.csv`.

## Tasks

- [x] #p1 Write `code/FSR/bridge.py` (start_engine / fsr with plots=0,msg=0,nsamp=0 / stop_engine +
  diagnostics; struct→dict parse; scalar/array/empty outlier normalization).
- [x] #p1 Write `code/FSR/check_FSR.py` (stars fixture bootstrap; gate = last 5 mdr rows vs golden).
- [x] #p1 Run the check; confirm `PASS` with max abs diff < 1e-9, and that re-running is deterministic.
- [x] #p2 Persist `reference/stars.csv`, `reference/FSR_mdr.csv`, `reference/FSR_check.csv` for the
  Layer-2 surfaces.
- [x] #p3 Note the struct + 1-based-index + inconsistent-shape learnings for specs 008 / 009.

### Done

- 2026-06-27 — Bridge + agreement check written and run. **PASS, max abs diff `0.000e+00`** (tol 1e-9),
  deterministic across two runs. Env: Python 3.11.5 · MATLAB R2026a Update 1 · `matlabengine==26.1.12` ·
  `FSR` at `/Users/aldocorbellini/FSDA/toolbox/regression/FSR.m`. Fixture: genuine FSDA `stars`
  (Hertzsprung-Russell, 47×2), `nsamp=0`, `intercept=true`. FSR flagged outliers (1-based)
  **[11, 20, 30, 34]** — exactly the four giant stars off the main sequence, a textbook-correct result
  (so the port is meaningful, not just self-consistent). `out.mdr` is 40 rows (steps 7–46); the last 5
  rows (steps 42–46) are the gate. beta = `[-4.0565, 2.0467]`, scale = `0.4058`. Golden in
  `code/FSR/reference/FSR_mdr.csv`; fixture in `reference/stars.csv`.
- 2026-06-27 — Learnings for the Layer-2 siblings (008 Julia, 009 R):
  - **`FSR` returns a struct** → Python `dict`; the bridge reads `out['mdr']`, `out['outliers']`, etc.
    R/Julia reuse `bridge.py` verbatim, so all struct/dict handling stays Python-side.
  - **Outlier index shape is inconsistent** (scalar / vector / empty `[[]]`); `_normalize_outliers`
    handles all three. The stars fixture hits the *vector* (multi-outlier) path; `forbes` would hit the
    scalar path and `stack_loss` the empty path (both verified during the probe).
  - **1-based indices preserved** end-to-end; R and Julia are natively 1-based, so the outlier list is
    already correct there with no decrement.
  - **Two reference files of different cardinality**: `stars.csv` (47-row fixture) and `FSR_mdr.csv`
    (40-row trajectory); the gate is the last 5 rows of the latter. `nsamp=0` keeps the run
    deterministic.

- 2026-06-27 — Plots/messages made viewable. `plots`/`msg` are now real `fsr()` parameters (default
  **0**, so the gate and any library use stay headless and deterministic — they don't affect `mdr`).
  Two MATLAB-Engine gotchas handled: (1) figure windows close when the engine quits, so `check_FSR.py`
  now keeps the engine alive in a `try/finally` and, on an interactive TTY (`sys.stdin.isatty()`),
  renders (`bridge.render_figures`) and pauses (`input(...)`) before `stop_engine` — a piped/CI run skips
  the pause and never hangs; (2) the engine requires `stdout`/`stderr` to be `io.StringIO` (not
  `sys.stdout`), so `fsr(..., msg=1)` captures into a buffer and echoes it to the terminal. Verified:
  with `PLOTS=MSG=1` the check prints FSDA's signal-detection messages and (on a terminal) opens the mdr
  figure, while the agreement gate is unchanged (**PASS**, max abs diff `0.000e+00`, outliers
  [11, 20, 30, 34]). R/Julia surfaces are unchanged (their `fsr` wrappers don't forward `plots`/`msg`);
  wiring those through is a possible follow-up.

- 2026-06-28 — R/Julia parity + robust interactive pause. `plots`/`msg` are now forwarded by the Julia
  and R `fsr` wrappers too (specs 008 / 009). The keep-alive is now driven **MATLAB-side** via
  `bridge.wait_for_figures` (`uiwait` until the figure windows are closed) instead of a terminal
  keypress: when the engine is embedded (reticulate / PythonCall) it hijacks the host process's stdin,
  so `input()` / `readline()` cannot catch a key in R/Julia. The user now **closes the figure window(s)**
  to finish; still gated on an interactive terminal so piped / CI never hangs. Agreement gate unchanged.
