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

- **Done when:** `code/fsda_engine/check_engine.py` prints overall `PASS` — all
  four cases (plus a second struct routine, `FSRaddt`, for routine-agnosticism)
  agree at `atol=1e-9` through the *same* engine session, gated against inline
  numpy oracles (mahalFS, Score) and committed gold read-only (FSR, FSRaddt).

- **Out of scope:** `getYahoo` and any MATLAB **timetable / table / struct-array /
  datetime** return (does not marshal generically — keeps its bespoke bridge);
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
    struct in case 3).
- **Marshalling notes (CONSTITUTION sec 4):**
  - Output: MATLAB's natural shape, **no silent reshape** (column stays `(n,1)`).
  - Input: 1-D → MATLAB **row**; pass `(n,1)` for a column (e.g. `y` for Score /
    FSR / FSRaddt). NaN/Inf preserved; indices stay 1-based.
  - `call` reserves the keyword names `nargout` / `msg` / `options`. An FSDA option
    literally named `msg` (FSR/FSRaddt) must be passed via `options={"msg": ...}`,
    else it binds the call's own stdout-capture flag. The four-case gate runs
    headless, relying on FSR/FSRaddt `plots`/`msg` defaulting to off.
- **Reference oracle:** inline numpy for `mahalFS` and `Score`; committed gold
  `code/FSR/reference/FSR_mdr.csv` and `code/FSRaddt/reference/FSRaddt_Tdel.csv`
  read **read-only**. Fixtures (`stars.csv`, `wool.csv`) read from the existing
  per-target `reference/` folders. Case 3 (nested struct) is an exact constructed
  round-trip, no fixture.

## Tasks

- [ ] #p3 Later: port the same pattern to `engine.jl` / `engine.R`

### Done

- [x] #p1 Write `code/fsda_engine/engine.py` (generic engine + converters) — 2026-06-28
- [x] #p1 Write `code/fsda_engine/check_engine.py` (four-case + FSRaddt gate) — 2026-06-28
- [x] #p1 Run the gate; overall `PASS` at 1e-9 — 2026-06-28. All five cases pass
  through one shared session: mahalFS / nested-struct / FSR / FSRaddt exact,
  Score 2.5e-12. MATLAB R2026a, matlabengine 26.1.12, Python 3.11.5.
- [x] #p2 No regression — change is purely additive (`git status`: only
  `code/fsda_engine/` + this spec; no existing file modified) — 2026-06-28

### Learnings (2026-06-28)

- The four "well-behaved" crossings (numeric / struct / nested struct / char) need
  **zero per-routine code** — generic `to_matlab` / `from_matlab` + a name/value
  `call` cover them. mahalFS, Score, FSR, FSRaddt all run with no wrapper.
- **`msg` name collision is real:** FSDA's own `msg` option defaults ON and clashes
  with `call`'s stdout-capture flag. Passing it as a kwarg silences the wrong thing;
  it must go through `options={"msg": 0}`. The gate now does this (and runs quiet).
- The `1-D → MATLAB row` input convention means a column response must be passed as
  `(n,1)` (e.g. `y.reshape(-1,1)` for Score/FSR/FSRaddt) — the gate relies on it.
