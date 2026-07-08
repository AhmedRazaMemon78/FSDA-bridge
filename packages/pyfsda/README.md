# pyfsda

Call [**FSDA**](https://github.com/UniprJRC/FSDA) — the MATLAB *Flexible Statistics and Data
Analysis* toolbox for robust statistics — from **Python**, using the MATLAB Engine as the
computational backend. FSDA runs unmodified in MATLAB; `pyfsda` is a thin, routine-agnostic bridge
that marshals data across the boundary.

```python
from pyfsda import FsdaEngine

eng = FsdaEngine.start("mahalFS")                      # boot MATLAB, check the routine is on the path
d   = eng.call("mahalFS", Y, MU, SIGMA)                # numeric array  -> numpy ndarray
out = eng.call("Score", y, X, la=la, intercept=True)  # struct         -> dict
eng.stop()                                             # shut the (slow-to-start) session down
```

## Requirements

`pyfsda` does not bundle MATLAB or FSDA — it drives your local install. You need:

1. **MATLAB** with the **FSDA Add-On** installed and on the MATLAB path (verify `which mahalFS`
   inside MATLAB).
2. **`matlabengine`** matching your MATLAB release. This is the one version constraint that matters:
   the `matlabengine` package on PyPI is release-locked, so install the one that pairs with your
   MATLAB — e.g. `pip install "matlabengine==26.1.*"` for **R2026a**. `pyfsda` lists `matlabengine`
   as a dependency but deliberately does **not** pin it, so it will not clobber a matching version you
   already have.
3. **Python 3.9–3.13** (whatever your MATLAB release's engine supports).

## Install

```bash
pip install pyfsda
# then, if not already present, the matlabengine that matches YOUR MATLAB:
pip install "matlabengine==26.1.*"     # example: MATLAB R2026a
```

## Verify your install

Run [`examples/smoke_test.py`](examples/smoke_test.py) — it starts MATLAB and checks a few real FSDA
routines against numpy oracles, printing `RESULT: PASS` when your MATLAB + FSDA + `matlabengine` setup
is good:

```bash
python smoke_test.py                 # or:  python smoke_test.py /path/to/FSDA
```

## What crosses the boundary

`call(name, *args, nargout=1, echo_output=False, options=None, **kwargs)` marshals positional
arguments in order and keyword arguments (and any `options` dict) as MATLAB name/value pairs. It runs
through the MATLAB workspace so outputs the engine cannot return directly (tables, 2-D cells) are
decoded MATLAB-side.

| MATLAB value | crosses as |
|---|---|
| numeric / logical array | `numpy.ndarray` (natural shape, `NaN`/`Inf` preserved) |
| `struct` | `dict` (recursed) |
| `char` / `string` scalar | `str` |
| `cell` | `list` |
| `table` / `timetable` | `dict` `{VariableNames, RowNames`/`RowTimes, data, height}` |
| 2-D `cell` | nested `list` |
| `nargout > 1` | `tuple` of the above |
| graphics handle (`matlab.graphics.*`) | **not marshalled** — request only data outputs |

Conventions: a 1-D input crosses as a MATLAB **row** (pass an `(n, 1)` array for a column); outputs
keep MATLAB's natural shape (no silent reshape); MATLAB indices stay **1-based**.

Reserved keywords consumed by the bridge are only `nargout`, `echo_output`, and `options`; every other
keyword is forwarded to MATLAB (so FSDA's own `msg` option passes straight through). `echo_output=True`
tees MATLAB's stdout/stderr to your terminal.

`FsdaEngine.start()` also runs a best-effort FSDA up-to-date check via FSDA's `tuna` utility (quiet
unless an update is available); disable it with `FsdaEngine.start(check_version=False)`.

## Notes

- **MATLAB engine startup is slow** — start one `FsdaEngine` and reuse it; always `stop()` explicitly.
- Struct-arrays and `datetime`/`duration` scalars are out of scope for the generic converters.

## License

[EUPL-1.2](LICENSE) — consistent with FSDA's own licensing.
