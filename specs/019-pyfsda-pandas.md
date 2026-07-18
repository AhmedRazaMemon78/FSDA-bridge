# Spec 019 — Optional pandas at the pyfsda (Python) boundary

> Read `CONSTITUTION.md` first. This spec adds a Python-only, opt-in pandas view over the
> existing `table`/`timetable` → dict contract. The dict stays the default and remains the
> cross-language interchange format; R and Julia are untouched.

## Contract

- **Deliverable:** in the **pyfsda package only**, (a) an opt-in `frames=True` that returns
  MATLAB `table`/`timetable` outputs as a `pandas.DataFrame`, plus a public
  `pyfsda.to_dataframe(table_dict)` helper; and (b) unconditional marshalling of a
  `pandas.DataFrame` **input** into a MATLAB table. pandas is an **optional, lazily
  imported** dependency (`pip install pyfsda[pandas]`).
- **Done when:**
  - `python -m pytest packages/pyfsda/tests/test_frames.py` passes with **no** MATLAB.
  - With MATLAB: `univariatems(y, X, frames=True)` returns a `DataFrame` equal to the
    `frames=False` dict within `1e-9`; a numeric `DataFrame` passed in is seen MATLAB-side
    as a `table` (`istable`) with matching `VariableNames`/values (round-trip `1e-9`).
  - `import pyfsda` still works with pandas absent; `frames=True` / DataFrame input then
    raises a clear `pip install pyfsda[pandas]` error.
  - `python code/fsda_engine/check_engine.py` still PASSes (repo engine untouched).
- **Out of scope:** any change to the repo engine, `engine.R`, `engine.jl`, or the three
  `check_engine.*` gates; `datetime`/`categorical`/MultiIndex DataFrame columns; string
  columns as table **inputs** (v1 input path is numeric/bool only); timetable inputs;
  making DataFrame the pyfsda default; collapsing the two `engine.py` copies.

## Design

- **Files (all under `packages/pyfsda/`):**
  - `src/pyfsda/frames.py` — NEW: `is_table_dict`, `to_dataframe`, `apply_frames`,
    `is_dataframe` (duck-typed, no pandas import).
  - `src/pyfsda/engine.py` — add `frames: bool = False` to `FsdaEngine.call`; convert
    table-dict outputs via `apply_frames` when set; detect DataFrame args and route to a
    new `_df_to_table_var`; guard `to_matlab` against DataFrames.
  - `src/pyfsda/__init__.py` — `__version__ = "0.4.0"`; export `to_dataframe`,
    `is_table_dict`.
  - `pyproject.toml` — `[project.optional-dependencies] pandas = ["pandas>=1.5"]`.
  - `README.md`, `CHANGELOG.md` — document the optional pandas view.
  - `tests/test_frames.py` (new, CI-safe) and `tests/test_integration.py` (extended).
- **Signatures / calls:**
  - `to_dataframe(table_dict) -> pandas.DataFrame` (index from `RowTimes`/`RowNames`).
  - `FsdaEngine.call(..., frames=False)`; `pyfsda.univariatems(y, X, frames=True)`.
  - `_df_to_table_var(df, vn)` → `array2table(fe_block,'VariableNames',fe_varnames)`
    MATLAB-side; column names cross as a workspace cell (never string-interpolated).
- **Marshalling notes:** dict is still produced first, then optionally viewed as a
  DataFrame — the `1e-9` gate is against the dict. Input numeric block crosses as
  `matlab.double`; a non-default `df.index` becomes `RowNames`.
- **Isolation:** R/Julia import the **repo** `engine.py`; pyfsda uses its **own** copy, so
  the two copies diverge by design (pyfsda = Python-enriched superset).

## Tasks

- [ ] #p3 Follow-up: string-column DataFrame inputs; unify the two `engine.py` copies.

### Done  (2026-07-18)

- [x] #p1 `frames.py` — `is_table_dict`, `to_dataframe`, `apply_frames`, `is_dataframe`
      (lazy pandas, duck-typed input detection).
- [x] #p1 `call(frames=...)` output path + `_df_to_table_var` / `_cellstr_to_var` input path
      in the **package** engine; repo engine, `engine.R`, `engine.jl`, `check_engine.*` left
      untouched.
- [x] #p1 `test_frames.py` (7 tests) + version bump to 0.4.0 + `pyfsda[pandas]` optional dep.
- [x] #p2 Integration `test_dataframe_table_roundtrip` (istable + sortrows/frames, base-MATLAB
      only); README pandas section + CHANGELOG 0.4.0.
- [x] #p2 Live Python↔MATLAB round-trip **PASSED** (`pytest -m integration ...`, 28.6 s).

### Verification (2026-07-18)

- `pytest tests/test_frames.py tests/test_marshalling.py -m "not integration"` → **16 passed**
  (no MATLAB engine started).
- No-MATLAB guard paths confirmed: pandas-absent → `import pyfsda` OK and `to_dataframe`
  raises the `pip install pyfsda[pandas]` hint; non-numeric column → `NotImplementedError`;
  `to_matlab(DataFrame)` → `TypeError`.
- **MATLAB-side marshalling validated via MATLAB MCP** — caught & fixed a bug: `array2table`
  rejects `'VariableNamingRule'`; removed it (explicit `VariableNames` are preserved verbatim,
  incl. names with spaces). `array2table` / `RowNames` / `sortrows` / `table2array` confirmed.
- **Live engine round-trip PASSED** (2026-07-18): `test_dataframe_table_roundtrip` on a
  booted `matlab.engine` session — DataFrame in → MATLAB `table` (`istable`), `sortrows` +
  `frames=True` back to a DataFrame with columns preserved and values equal within `1e-9`;
  the default (no `frames`) still returns the neutral dict. 1 passed in 28.6 s.
