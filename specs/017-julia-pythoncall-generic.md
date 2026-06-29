# Spec 017 — Generic FSDA engine, Julia (PythonCall) surface

> Read `CONSTITUTION.md` first. Layer-2 Julia sibling of the Python generic engine
> (spec 016). Lives under the shared `code/fsda_engine/` module (the §6 deviation
> recorded in spec 016).

## Contract

*What this spec must deliver, and how we know it's done.*

- **Deliverable:** `code/fsda_engine/engine.jl` — a routine-agnostic Julia surface over
  the Python `FsdaEngine` (spec 016) via PythonCall: `start_engine`, `call(h, name,
  args...; nargout, echo_output, options, kwargs...)`, `eval_expr`, `stop_engine`,
  `render_figures`, `wait_for_figures`, `diagnostics`. ANY FSDA routine is callable with
  **no per-routine wrapper** (contrast the per-target `code/<target>/bridge.jl`).
- **Done when:** `code/fsda_engine/check_engine.jl` prints overall `PASS` — the same 7
  cases as `check_engine.py` (numeric `mahalFS`, struct `Score`, nested struct, `FSR`,
  `FSRaddt`, constructed `table`, live `univariatems`) reproduced through the generic
  Julia engine at `atol=1e-9` (univariatems structural). **Met 2026-06-29** (all 7 PASS).
- **Out of scope:** per-routine Julia wrappers; building MATLAB tables as *inputs* from
  Julia (numeric inputs already work); any change to `engine.py`.

## Design

- **Files:** `code/fsda_engine/engine.jl`, `check_engine.jl`, and `Project.toml` +
  `Manifest.toml` (PythonCall, copied from `code/FSR/`).
- **Plumbing (reused from `code/FSR/bridge.jl`):** `_resolve_python` + ENV pinning
  (`JULIA_CONDAPKG_BACKEND=Null`, `JULIA_PYTHONCALL_EXE`) **before** `using PythonCall`;
  `_ENGINE_DIR` locates `engine.py`; opaque `FsdaEngineHandle`. `engine.py` imports under
  the unique module name `engine`, so the per-target `bridge` cache-eviction is moot.
- **The two converters (the genuinely new part — PythonCall does not auto-convert):**
  - `_to_py(a)` — Julia `AbstractArray` → `numpy.asarray` (so `engine.to_matlab` marshals
    it); scalars/strings/bools via PythonCall. Applied to positionals **and** kwarg values.
  - `_py2jl(x)` — recurse: Python `dict`→`Dict{String,Any}`, `numpy.ndarray`→`Array`,
    `list`/`tuple`→`Vector`, `str`→`String`, `bool`→`Bool`, else `pyconvert(Any, x)`.
- **Marshalling notes:** pass `y` as an `(n,1)` matrix when a routine wants a column
  (1-D → MATLAB row convention from spec 016). Table/timetable results arrive as the
  `engine.py` dict `{VariableNames, RowNames/RowTimes, data, height}`.
- **Gate oracle:** committed language-neutral golds read **read-only**
  (`mahalFS_check.csv` col `d_fsda`, `Score_check.csv` col `Score_fsda`, `FSR_mdr.csv`,
  `FSRaddt_Tdel.csv`); FSDA-vs-FSDA so most cases are exact (0.0).

## Tasks

### Done
- [x] #p1 `engine.jl` (generic surface + `_to_py`/`_py2jl`) — 2026-06-29
- [x] #p1 `check_engine.jl` mirroring the Python gate; overall `PASS` (7 cases,
  Julia 1.12.6 / PythonCall 0.9.35 / MATLAB R2026a) — 2026-06-29
- [x] #p2 `Project.toml`/`Manifest.toml` for the engine env (PythonCall) — 2026-06-29

### Learnings (2026-06-29)
- The generic Julia surface is *smaller* than a per-target `bridge.jl` (no per-routine
  validation) but needs the recursive `_py2jl` because PythonCall never auto-converts; R
  (spec 018) gets this free from reticulate `convert=TRUE`.
