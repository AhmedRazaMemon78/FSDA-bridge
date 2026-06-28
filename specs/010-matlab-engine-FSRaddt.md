# Spec 010 — MATLAB Engine: call FSDA `FSRaddt` from Python (added-variable deletion t-test)

> Fourth function ported through the Layer-1 bridge, after `mahalFS` (001), `Score` (004) and
> `FSR` (007). `FSRaddt` is a forward search (random LXS initial subset, then grows a clean subset)
> that, at every step, monitors the **deletion t statistic** of each explanatory variable — the
> added-variable t-test. It returns a **struct** including a **cell array** (`out.Un`) and
> **variable-width** monitoring matrices. Read `CONSTITUTION.md` first. Python surface only; Julia
> (011) and R (012) are siblings.

## Contract

- **Deliverable:** from Python, start a MATLAB engine session, call the genuine FSDA
  `FSRaddt(y, X, ...)`, and return the key outputs (the `out.Tdel` deletion-t trajectory, the
  `out.S2del` deletion-variance trajectory, the 1-based `out.bs` initial subset, the `out.Un`
  cell→list of entering-unit matrices, and `out.la`) as numpy.
- **Done when:** `code/FSRaddt/check_FSRaddt.py`, run with the project venv, prints `PASS` — **the
  last five rows of `out.Tdel` equal the committed golden** (`reference/FSRaddt_Tdel.csv`) to
  `< 1e-9`, on the genuine FSDA `wool` dataset with `nsamp=0` (deterministic).
- **Out of scope:** Julia and R surfaces (011 / 012); an independent numpy oracle (infeasible for
  FSRaddt — see below); the `out.S2del` tail as a gate, the `quant`/`DataVars`/plot-styling options
  beyond what the gate needs; FSDA routines other than `FSRaddt`; packaging.

## Design

**Why the gate is the Tdel tail, not a numpy oracle.** `mahalFS`/`Score` had clean pure-numpy
oracles. `FSRaddt` does not — it is a forward-search loop over FSDA internals (`FSRaddt`→`FSRmdr`/
`LXS`) run once per tested variable, not reproducible in numpy to 1e-9. `out.Tdel` is `(m, k+1)` —
`[step, deletion t-stat per tested variable]`, with `m = n-init+1` and `k` = number of tested
variables — and its **tail** (near the full sample) is the decisive added-variable-significance
region. Comparing the **last five rows** is robust to any minor mid-search ties yet proves the
surfaces converge to the same signal. (Mirrors the spec-007 mdr-tail gate, per the project owner.)

**Determinism.** FSRaddt randomness comes only from `nsamp` subsampling; **`nsamp=0` enumerates all
C(n,p) subsets**, so the run is deterministic with no RNG seeding. The fixture is small enough
(wool: n=27, p=4 → C(27,4)=17550) for that to be instant. FSRaddt defaults to `plots=0` and
`msg=true`; the bridge forces `plots=0` and `msg=0` for the gate so nothing pops a figure or writes
stdout through the headless engine.

- **Files:**
  - `code/FSRaddt/bridge.py` — Layer 1. `start_engine(fsda_root=None)` (verify `which('FSRaddt')`),
    `fsraddt(eng, y, X, nsamp=0, intercept=True, plots=0, msg=0, DataVars=None, h=None, init=None,
    lms=1)` (marshals numpy → `matlab.double`, forces `plots=0,msg=0`, parses the struct→dict),
    `stop_engine`, plus `render_figures`/`wait_for_figures` and diagnostics helpers `matlab_version`
    / `which_fsraddt` for the Layer-2 surfaces.
  - `code/FSRaddt/check_FSRaddt.py` — the agreement check. Fixed input = genuine FSDA `wool` (27×4).
    Gate = last 5 rows of `out.Tdel` vs golden at `atol=1e-9`. Bootstraps `reference/wool.csv`
    (portable fixture) + `reference/FSRaddt_Tdel.csv` (golden, header `step,t1,…,tk`) on first run;
    also writes `reference/FSRaddt_check.csv` (la / bs / Un-shapes, for transparency).
- **Signatures / shapes:** `y` is `(n,)`/`(n,1)`; `X` is `(n, p-1)` raw predictors (FSDA adds the
  intercept when `intercept=True`); returns a dict — `Tdel (m, k+1)`, `S2del (m, k+1)`,
  `bs (p, k)` 1-based int, `Un` list of `k` arrays (from the MATLAB cell), `la (k,)` 1-based int,
  `class`.
- **Marshalling notes (where FSRaddt breaks ports — different wrinkles from FSR):**
  - *Struct return:* `eng.FSRaddt(...)` returns a MATLAB **struct → Python dict** (needs `nargout=1`).
  - *Cell array (new):* `out.Un` is a MATLAB **cell** → Python **list** of numpy arrays. FSR put `Un`
    out of scope, so cell↔list is exercised here for the first time (`_normalize_un`, tolerant of a
    bare array or empty).
  - *Variable-width matrices:* `Tdel`/`S2del` have `k+1` columns (`k` depends on X / `DataVars`), not
    FSR's fixed 2. The Tdel shape check keys off `len(la)` (`shape[1] == 1 + la.size`) — no hardcoded
    width, no silent reshape.
  - *1-based indices:* `out.bs` / `out.la` are MATLAB **1-based** indices, kept 1-based here.
  - *Headless / determinism:* `plots=0`, `msg=0` forced; `nsamp=0` (all subsets) removes RNG.
- **Reference oracle:** the deterministic FSDA run itself; golden Tdel saved to
  `code/FSRaddt/reference/FSRaddt_Tdel.csv`, fixture to `reference/wool.csv`.

## Tasks

- [x] #p1 Write `code/FSRaddt/bridge.py` (start_engine / fsraddt with plots=0,msg=0,nsamp=0 /
  stop_engine + diagnostics; struct→dict parse; cell→list `Un` + 1-based `bs`/`la`; Tdel width check).
- [x] #p1 Write `code/FSRaddt/check_FSRaddt.py` (wool fixture bootstrap; gate = last 5 Tdel rows vs
  golden).
- [x] #p1 Run the check; confirm `PASS` with max abs diff < 1e-9, and that re-running is deterministic.
- [x] #p2 Persist `reference/wool.csv`, `reference/FSRaddt_Tdel.csv`, `reference/FSRaddt_check.csv`
  for the Layer-2 surfaces.
- [x] #p3 Note the cell-array + variable-width + 1-based-index learnings for specs 011 / 012.

### Done

- 2026-06-28 — Bridge + agreement check written and run. **PASS, max abs diff `0.000e+00`** (tol
  1e-9), deterministic across two runs (golden bootstrapped on run 1, matched on run 2). Env: Python
  3.11.5 · MATLAB R2026a Update 1 · `matlabengine==26.1.12` · `FSRaddt` at
  `/Users/aldocorbellini/FSDA/toolbox/regression/FSRaddt.m`. Fixture: genuine FSDA `wool` (3³
  factorial, n=27, 3 predictors + intercept), `nsamp=0`, `intercept=true`, `lms=1`. FSRaddt tested
  the three predictors (`la=[2,3,4]`, k=3; the intercept, column 1, is not tested), so `out.Tdel` is
  `(23, 4)` (steps 5–27); the last 5 rows (steps 23–27) are the gate. Golden in
  `reference/FSRaddt_Tdel.csv` (header `step,t1,t2,t3`); fixture in `reference/wool.csv`; transparency
  in `reference/FSRaddt_check.csv`. Note: LMS prints a benign "subsets without full rank ≈ 28%"
  warning for this factorial design — expected, and with `nsamp=0` (all 17 550 subsets) the run is
  still fully deterministic.
- 2026-06-28 — Learnings for the Layer-2 siblings (011 Julia, 012 R):
  - **`FSRaddt` returns a struct** → Python `dict`; the bridge reads `out['Tdel']`, `out['bs']`, etc.
    R/Julia reuse `bridge.py` verbatim, so all struct/dict handling stays Python-side.
  - **`out.Un` is a MATLAB cell** → Python `list` of numpy arrays (here 3 cells, each `(22, 11)`).
    `_normalize_un` collapses the cell / a bare array / empty to a list. This is the first cell↔list
    crossing (FSR put `Un` out of scope); it stays Python-side so the surfaces see clean arrays.
  - **Variable-width monitoring matrices**: `Tdel`/`S2del` are `(m, k+1)` with `k=len(la)` (not FSR's
    fixed 2). The width check is `Tdel.shape[1] == 1 + la.size`; the golden header is `step,t1,…,tk`.
  - **1-based indices preserved** (`out.bs` 4×3, `out.la`); R and Julia are natively 1-based, so they
    are already correct with no decrement.
  - **Two reference files of different cardinality**: `wool.csv` (27-row fixture) and
    `FSRaddt_Tdel.csv` (23-row trajectory); the gate is the last 5 rows of the latter. `nsamp=0` keeps
    the run deterministic.
