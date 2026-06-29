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
