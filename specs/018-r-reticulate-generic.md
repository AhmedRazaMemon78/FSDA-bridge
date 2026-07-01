# Spec 018 — Generic FSDA engine, R (reticulate) surface

> Read `CONSTITUTION.md` first. Layer-2 R sibling of the Python generic engine
> (spec 016) and the Julia surface (spec 017). Lives under the shared
> `code/fsda_engine/` module.

## Contract

*What this spec must deliver, and how we know it's done.*

- **Deliverable:** `code/fsda_engine/engine.R` — a routine-agnostic R surface over the
  Python `FsdaEngine` (spec 016) via reticulate: `start_engine`, `fsda_call(handle, name,
  ..., nargout, echo_output, options)`, `eval_m`, `stop_engine`, `render_figures`,
  `wait_for_figures`, `diagnostics`. ANY FSDA routine is callable with **no per-routine
  wrapper** (contrast the per-target `code/<target>/bridge.R`).
- **Done when:** `code/fsda_engine/check_engine.R` prints overall `PASS` — the same 7
  cases as `check_engine.py` reproduced through the generic R engine at `atol=1e-9`
  (univariatems structural). **Met 2026-06-29** (all 7 PASS; FSRaddt 4.4e-16 fp noise).
- **Out of scope:** per-routine R wrappers; building MATLAB tables as *inputs* from R
  (numeric inputs already work); any change to `engine.py`.

## Design

- **Files:** `code/fsda_engine/engine.R`, `check_engine.R`.
- **Plumbing (reused from `code/FSR/bridge.R`):** `.resolve_python` / `.configure_python`
  / `.engine_dir`; classed handle (`fsda_engine`). `import_from_path("engine",
  .engine_dir, convert = TRUE)`; `module$FsdaEngine$start(...)`.
- **No manual converter:** reticulate with `convert = TRUE` auto-converts both directions
  (R matrix ↔ numpy, Python dict ↔ R named list, str ↔ character), so `fsda_call` just
  splits `...` into positional (unnamed) and name/value (named) args and forwards to the
  Python `engine$call`; the returned dict comes back as a nested named list.
- **Naming:** the call surface is `fsda_call` (not `call`, which would mask `base::call`).
  Result fields are accessed `out$mdr`, `out$Score`, `out$data$<col>`, etc.; `unlist()`
  collapses VariableNames/RowNames to character vectors.
- **Marshalling notes:** pass `y` as an `(n,1)` matrix for a column. Use `on.exit()` for
  engine cleanup — a `tryCatch(..., finally=)` with `<<-` walks past the local into the
  locked `base::diag` binding (the bug fixed during this spec).
- **Gate oracle:** same committed language-neutral golds as spec 017, read **read-only**.

## Tasks

### Done
- [x] #p1 `engine.R` (generic surface, reticulate auto-convert) — 2026-06-29
- [x] #p1 `check_engine.R` mirroring the Python gate; overall `PASS` (7 cases,
  R 4.4.1 / reticulate 1.45.0 / MATLAB R2026a) — 2026-06-29
- [x] #p1 Mirror cases through **25** into `check_engine.R`. Latest **22–25**: 22 `publishFS`
  (nested named-list access `r[[1]]` over the 3×8 `InpArgs`, empty `laste`), 23 `distribspec`
  (base-R `pnorm(1.96)-pnorm(-1.96)` oracle; fresh `figure` via `eval_m`), 24 `histFS` (base-R
  `hist(y, breaks=edges, plot=FALSE)$counts`), 25 `boxplotb` (structural named-list). **`engine.R`
  unchanged** — reticulate delegates to `engine.py` and inherits its marshalling. All **25**
  PASS — 2026-07-01

### Learnings (2026-06-29, +2026-07-01)
- R is the lightest of the three surfaces: reticulate `convert=TRUE` removes the need for
  any recursive py→R converter (Julia's `_py2jl`). Watch two R-isms: `call`/`diag` are
  base bindings (avoid as names / `<<-` targets).
- **Adapter, not reimplementation.** `engine.R` never re-does marshalling — it delegates to the
  Python `FsdaEngine.call`, so it stays current with `engine.py` for free (cases 15–16 use the
  /clustering 2-D-cell fix with no `engine.R` edit). Sync is a *check-file* task only.
- **Graphics handles are never requested** (CONSTITUTION §4); every graphics case takes data
  outputs only. `distribspec` grabs the ambient `gcf`/`gca`, so open a fresh `figure` first.
