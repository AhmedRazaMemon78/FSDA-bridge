# Spec 016 — Generic FSDA engine (Python)

> Read `CONSTITUTION.md` first. This spec introduces a *shared* engine module — a
> deliberate, author-approved deviation from the "organized by target" layout in
> CONSTITUTION sec 6 (sign-off given in the originating session, 2026-06-28). The
> constitution is **not** edited; the deviation is recorded here.

## Contract

*What this spec must deliver, and how we know it's done.*

- **Deliverable:** a single generic Layer-1 engine, `code/fsda_engine/engine.py`,
  that any FSDA routine can call without a per-routine wrapper, via
  `FsdaEngine.start(...)` + a routine-agnostic `call(name, *args, **nv)` whose
  generic converters cover the four well-behaved crossing shapes:

  | MATLAB out | crosses as |
  |---|---|
  | numeric array (`mahalFS`) | `matlab.double` → ndarray |
  | `struct` (`Score`, `FSR`, `FSRaddt`) | → dict (recursed) |
  | nested struct of arrays | → dict of dicts of ndarrays |
  | char/string scalar | → str |
  | `table` / `timetable` (`avasms`, `univariatems`) | → dict `{VariableNames, RowNames/RowTimes, data}` (decomposed MATLAB-side) |

- **Done when:** `code/fsda_engine/check_engine.py` prints overall `PASS` — all
  cases (incl. a constructed `table`→dict round-trip, plus `FSRaddt` for
  routine-agnosticism) agree at `atol=1e-9` through the *same* engine session,
  gated against inline numpy oracles (mahalFS, Score) and committed gold read-only
  (FSR, FSRaddt).

- **Out of scope:** `getYahoo` and any MATLAB **struct-array / datetime** return
  (does not marshal generically — keeps its bespoke bridge);
  the Julia (`engine.jl`) and R (`engine.R`) surfaces (same pattern, later);
  migrating or deleting the existing `code/<target>/bridge.py` files; editing
  `CONSTITUTION.md` / `CLAUDE.md`. This step is purely additive.

## Design

*How the contract is realised.*

- **Files (all new):**
  - `code/fsda_engine/engine.py` — `FsdaEngine` (start/stop, `call`, `eval`,
    `which`, `version`, `render_figures`, `wait_for_figures`) + module-level
    `to_matlab` / `from_matlab` converters.
  - `code/fsda_engine/check_engine.py` — the four-case (+1) agreement gate.
  - `code/fsda_engine/reference/engine_check.csv` — transparency summary (written
    by the check).
- **Signatures / calls:**
  - `FsdaEngine.start(routine=None, fsda_root=None)` → handle; verifies one
    routine resolves when given.
  - `call(name, *args, nargout=1, msg=False, options=None, **kwargs)` — positional
    args marshalled in order; kwargs / `options` become MATLAB name/value pairs.
    `eng.call("mahalFS", Y, MU, SIGMA)` → ndarray;
    `eng.call("Score", y, X, la=LA, intercept=True)` → dict.
  - `eval(expr, nargout=1)` — evaluate + marshal back (used to build the nested
    struct in case 3 and the constructed table in case 5).
- **Workspace execution:** `call`/`eval` run through the MATLAB **workspace** (inputs
  bound to `fe_*` temp vars, `[fe_out…] = name(…)` via `eng.eval`, temps cleared).
  This is what lets a **table/timetable** output cross — the engine cannot return one
  directly, so `_table_to_dict` decomposes it MATLAB-side (columns read by **index**,
  never by interpolated name; func/option names validated against `^[A-Za-z]\w*$` as
  an eval-injection guard). Numeric/struct/char outputs are value-identical to the
  prior direct-call path (the 5 original gate cases still pass unchanged).
- **Marshalling notes (CONSTITUTION sec 4):**
  - Output: MATLAB's natural shape, **no silent reshape** (column stays `(n,1)`); a
    table column is flattened to 1-D in `data` (it is inherently a column).
  - Input: 1-D → MATLAB **row**; pass `(n,1)` for a column (e.g. `y` for Score /
    FSR / FSRaddt). NaN/Inf preserved; indices stay 1-based.
  - `call` reserves only `nargout` / `echo_output` / `options`. FSDA's own `msg`
    option is **not** reserved — `call("FSR", ..., msg=0)` forwards it to MATLAB
    like any other name/value pair (the bridge's stdout/stderr tee is the separate
    `echo_output` flag). The gate silences FSDA's default-on messaging with `msg=0`.
- **Reference oracle:** inline numpy for `mahalFS` and `Score`; committed gold
  `code/FSR/reference/FSR_mdr.csv` and `code/FSRaddt/reference/FSRaddt_Tdel.csv`
  read **read-only**. Fixtures (`stars.csv`, `wool.csv`) read from the existing
  per-target `reference/` folders. Case 3 (nested struct) is an exact constructed
  round-trip, no fixture.

## Tasks

(all complete — see Done)

### Done

- [x] #p3 Port the same pattern to `engine.jl` / `engine.R` — done in specs 017/018
  (Julia + R generic surfaces, both 7/7 PASS) — 2026-06-29
- [x] #p2 First `/multivariate` spot-check: `corrNominal(N)` crosses correctly (case 7,
  chi2 & CramerV vs numpy oracle, 1e-9). **No engine change needed** — see Learnings — 2026-06-29
- [x] #p2 More `/multivariate` checks: case 8 `FSM(Y)` (forward search; `out.mmd` tail vs a
  bootstrapped gold `reference/FSM_mmd.csv`, deterministic via seeded Y + `rng(0)`), case 9
  `[RAW,REW]=mcd(Y)` (validates the **nargout=2 → tuple of dicts** path; structural,
  `RAW.class='mcd'`/`REW.class='mcdr'`). All 10 cases PASS — 2026-06-29
- [x] #p1 **Full `/multivariate` sweep — engine needs NO change.** Ran every function
  (47) through the generic engine: **26/26 marshallable ones CROSS** — struct→dict,
  two-struct→`tuple` of dicts (`mcd`/`mcdeda`/`mve`/`mveeda`/`mcdCorAna`), mixed
  `tuple(ndarray,dict)` (`mdMARsimulate`), bare numeric (`unibiv`/`barnardtest`/
  `CressieRead`), big contingency structs with table fields (`CorAna` dict[45],
  `corrNominal`/`corrOrdinal`/`SparseTableTest`). The 14 "failures" were all
  `MatlabExecutionError` from *my* inputs ("Initial subset is missing", "Not enough input
  arguments", …) — **not** marshalling gaps. GUI/script (`biplotFS`/`geoplotFS`/
  `champagneCode`) + chained helpers (`FSMinvmmd`/`mdPartialMD2full`/`FSCorAnaenv`) out of
  scope. Added committed cases 10 `pcaFS` (eigenvalues vs numpy corr) and 11 `CressieRead`
  (PD, λ=2/3, vs numpy). All 12 cases PASS — 2026-06-30
- [x] #p1 **`/utilities_stat` sweep — engine needs NO change.** 157 functions; static
  buckets = 133 numeric (marshalled like `mahalFS`, which lives here) + 2 struct + 5 "table"
  + 1 cell + 1 plot. Focused sweep of every structural gap-candidate (tables/structs/cell/
  multi-output) + a numeric sample: **13/13 CROSS, 0 FAIL** — incl. `mdpattern` table→dict,
  `crosstab2datamatrix`→`tuple(ndarray,dict)`, `RhoPsiWei`→struct, and the weight/ρ/ψ fns.
  `grpstatsFS` needs a **table input** → out of scope (not an output gap). Added committed
  cases 12 `logfactorial` (vs numpy), 13 `tabulateFS` ([value,count,percent] vs numpy.unique),
  14 `TBwei` (Tukey biweight vs closed form). All 15 cases PASS — 2026-06-30
- [x] #p1 **`/clustering` sweep — found a REAL gap; engine FIXED.** 35 functions (struct-heavy:
  `tclust`/`tkmeans`/`tclustreg`/`MixSim`/`GowerIndex`/…). Sweep: `tclustIC` FAILED with a
  Python `ValueError: cell arrays returned from MATLAB must be 1-by-N or M-by-1` (NOT a
  `MatlabExecutionError`) — its `out.IDXCLA`/`IDXMIX` are **2-D cell arrays** the engine can't
  return. **First genuine marshalling gap in 4 folders.** Fix: `engine.py` now has
  `_marshal_cell2d` (M×N cell → nested list, element-by-index) + `_marshal_struct` (decompose
  a struct field-by-field when the engine can't eagerly convert it), wired into `_marshal_var`
  as a **fallback** (fast whole-value read tried first → no regression; all 15 prior cases
  still PASS). Added cases 15 `GowerIndex` (Gower S vs numpy + `Stable` table-dict) and 16
  `tclustIC` (2-D-cell regression guard: `IDXCLA` decomposes to a nested list). All 17 PASS — 2026-06-30
- [x] #p1 **`/utilities` sweep — engine needs NO change.** 60 files, mostly non-statistical
  (web/file/notebook/string utilities + the author's `esercizio_*` teaching scripts). Web/
  financial fns (`getYahoo*`/`getFundamentals`/`getTickers`) are network-bound timetable/
  struct-array returns → out of scope like `getYahoo`; table-input fns (`rows2varsFS`/
  `tabledisp`) out of scope. Focused sweep of the engine-relevant candidates: **5/5 CROSS** —
  incl. the **first positional STRING input → string output** (`removeExtraSpacesLF`,
  `wraptextFS`), `findFile` → `list[str]` (cell of strings), and numeric (`triu2vec`,
  `zscoreFS`). Added cases 17 `removeExtraSpacesLF` (str I/O) and 18 `triu2vec` (upper-triangle
  vs numpy). All 18 cases PASS — 2026-06-30
- [x] #p1 **`/combinatorial` sweep — engine needs NO change.** 7 routines (`bc`, `combsFS`,
  `lexunrank`, `nchoosekFS`, `randsampleFS`, `shuffling`, `subsets`) — **all numeric-only**
  (scalar/vector/matrix), no tables/structs/cells. Empirical sweep of all 7 (incl. the
  `nargout=2` pairs `lexunrank`/`subsets`): **8/8 CROSS**, every output `float`/`ndarray`/
  numeric-tuple. 3 are RNG-dependent (`randsampleFS`/`shuffling`/random `subsets`) → unusable
  as deterministic checks. Added cases 19 `bc` (scalar vs `math.comb`), 20 `combsFS` (matrix
  of m-combinations vs `itertools`, exercises the v→P value-mapping), and 21 `lexunrank`
  (**nargout=2 plain-numeric tuple** — first such; oracle = `bc(n,k)-N` lexicographic combo,
  compared as a sorted set since FSDA orders `kcomb` descending). All 21 cases PASS — 2026-06-30
- [x] #p1 **`/utilities_help` sweep — engine needs NO change.** 13 routines — the FSDA
  help-build tooling (`publishFS`, `mreadFS`, `xmlcreateFS`/`xmlreadFS`/`xmlwriteFS`,
  `makecontentsfileFS`, `publishFunctionAlpha`/`Cate`, `publishBibliography`,
  `setToolboxStartEnd`, `CreateFSDAhelpFiles`, `htmlwriteFS`). Mostly file-I/O / HTML-XML
  side-effecting build steps (out of scope like `getYahoo`); `mreadFS` is marked OBSOLETE.
  Engine-relevant probe: **`publishFS('mahalFS', write2file=false, evalCode=false)` fully
  marshals its 16-field output struct → dict** — strings + a **2-D-cell arg table**
  (`InpArgs` → 3×8 nested list via `_marshal_cell2d`) + a column-cell `OutArgs` + an (empty)
  **MException `laste`** field, all in one struct, no gap. First failure was a
  `MatlabExecutionError` ("cannot find doc file mahal.html") from See-Also validation, not a
  marshalling gap → silenced with `ErrWrngSeeAlso=false` (classify by exception origin).
  `xmlcreateFS` also crosses (`docNode`→ndarray, `docNodechr`→str; no disk write). Added case
  22 `publishFS` (struct → dict; oracle = mahalFS's signature `d=mahalFS(Y,MU,SIGMA)`:
  `titl=='mahalFS'`, `InpArgs` names `['Y','MU','SIGMA']`, `OutArgs[0]=='d'`, `laste==''`).
  One check is proportionate — `publishFS` is the lone clean engine-relevant routine in a
  tooling folder. All 22 cases PASS — 2026-06-30

- [x] #p1 **`/graphics` sweep — engine needs NO change.** 42 files, almost all *plotting*
  functions — different in kind from every prior (data-returning) folder. The new return
  type is the **graphics handle object** (`matlab.graphics.*`). **Design decision (now binding
  in CONSTITUTION §4): graphics handles are never marshalled — they are never requested.**
  Plot functions are called with **`nargout=0`** (draw for the side effect → `None`) or with
  `nargout` tuned to return only their **data** outputs, skipping the handle. Empirical sweep:
  `yXplot`/`spmplot`/`resindexplot`/`scatterboxplot`/`polarhistogramFS`/`funnelchart`/
  `balloonplot` all cross as `None` at `nargout=0`; `waterfallchart` erred only as a
  `MatlabExecutionError` (my matrix input; it wants a vector) — no gap. A handle riding
  *inside* a struct (`boxplotb.handles`) crosses harmlessly as an **empty array**, never a
  crash — so struct-embedded handles need no special handling either. Added 3 data-only checks
  (no handle requested): **23** `distribspec(makedist('Normal'),[-1.96 1.96],'inside')` → `p`
  vs `Phi(1.96)-Phi(-1.96)` (stdlib `math.erf`, 1.1e-16); **24** `histFS(y,edges,gy)` → `ng`
  (bins×groups) summed over groups vs `np.histogram` (exact); **25** `boxplotb(Y)` → struct
  (structural: `cent` has `v` coords, `Spl` 4 cols). Gotcha: `distribspec` grabs the *ambient*
  `gcf`/`gca` (it makes no figure of its own), so after 22 prior cases + pcaFS's parpool its
  `gca` was a deleted axes → `MatlabExecutionError` at `get(nspecaxes,'Xlim')`; fixed in the
  check by opening a fresh `figure` first (`p` is the true CDF mass, independent of the axes).
  All 25 cases PASS — 2026-07-01

- [x] #p1 Write `code/fsda_engine/engine.py` (generic engine + converters) — 2026-06-28
- [x] #p1 Write `code/fsda_engine/check_engine.py` (four-case + FSRaddt gate) — 2026-06-28
- [x] #p1 Run the gate; overall `PASS` at 1e-9 — 2026-06-28. All five cases pass
  through one shared session: mahalFS / nested-struct / FSR / FSRaddt exact,
  Score 2.5e-12. MATLAB R2026a, matlabengine 26.1.12, Python 3.11.5.
- [x] #p2 No regression — change is purely additive (`git status`: only
  `code/fsda_engine/` + this spec; no existing file modified) — 2026-06-28
- [x] #p1 Table/timetable support — `call`/`eval` route through the workspace and
  decompose tables → dict. Gate case 5 (constructed `array2table`) PASS at 1e-9;
  case 6 calls a **real** table-returning routine `univariatems(y,X)` → `Tsel` dict
  (8 cols × 3 rows, structural gate; robust cols are stochastic). All 7 cases PASS —
  the 2 hard exceptions (`avasms`/`univariatems`) now cross — 2026-06-29

### Learnings (2026-06-28, +2026-06-29)

- The four "well-behaved" crossings (numeric / struct / nested struct / char) need
  **zero per-routine code** — generic `to_matlab` / `from_matlab` + a name/value
  `call` cover them. mahalFS, Score, FSR, FSRaddt all run with no wrapper.
- **FSDA's `msg` option prevails as a plain kwarg.** It defaults ON; the bridge's
  own stdout-capture flag was originally also named `msg`, which shadowed it. Fixed
  by renaming that flag to `echo_output`, so `call("FSR", ..., msg=0)` forwards
  `msg` to FSDA directly (gate runs quiet). Only `nargout`/`echo_output`/`options`
  are reserved now.
- The `1-D → MATLAB row` input convention means a column response must be passed as
  `(n,1)` (e.g. `y.reshape(-1,1)` for Score/FSR/FSRaddt) — the gate relies on it.
- **A `table`/`timetable` cannot be returned to Python by the engine at all** — it
  errors at conversion. So coverage of table-output functions required moving `call`
  onto a workspace round-trip and decomposing the table MATLAB-side (same trick as
  `getYahoo`). A `toolbox/regression` audit found only `avasms`/`univariatems` return
  tables; this closed both. Remaining non-generic returns there: struct-arrays /
  datetime (none in regression) and table *inputs* (functions accept numeric too).
- **A struct that *contains* table fields marshals fine — no fix needed.** `corrNominal`
  returns `out` with table fields (`out.Ntable`, `out.ConfLimtable`, …); the R2026a engine
  auto-converts an **all-numeric** table to a numeric array on the way out, so the whole
  struct crosses via the fast `eng.workspace[var]` path. Only the table *labels* are
  dropped — and with matrix input those are auto-generated defaults, so it's immaterial.
  (A predicted "struct-with-table errors" fix was investigated and **not** built — the
  empirical check disproved the premise.) corrNominal's matrix-vs-table *input* makes no
  numeric difference (the table input only supplies labels).
- **Sweeping a folder: distinguish `MatlabExecutionError` from marshalling gaps.** The full
  `/multivariate` sweep had 14 "failures", but every one was a `MatlabExecutionError`
  raised *inside MATLAB* (wrong/missing inputs: "Initial subset is missing", "Not enough
  input arguments") — the engine ran the call and faithfully propagated MATLAB's error.
  A real marshalling gap looks different (a Python conversion error, or an opaque return).
  None occurred in /regression, /multivariate, /utilities_stat. Lesson: classify failures
  by exception origin before "fixing" the engine. **/clustering finally produced a real one:**
  `tclustIC` raised a Python `ValueError` (2-D cell can't be returned) — exactly the
  non-`MatlabExecutionError` signature — so the `_marshal_cell2d` + `_marshal_struct` fallback
  was built *then* (driven by evidence, not the earlier corrNominal prediction).
