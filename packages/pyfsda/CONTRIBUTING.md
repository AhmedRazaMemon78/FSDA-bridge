# Contributing to pyfsda

## Test layers

| Layer | Marker | Needs MATLAB? | Where it runs |
|---|---|---|---|
| Marshalling unit tests (`tests/test_marshalling.py`) | *(none)* | No — only the `matlabengine` client (for `matlab.double`) | GitHub-hosted `build` job + locally |
| Integration smoke (`tests/test_integration.py`) | `integration` | **Yes** — starts MATLAB via `matlab.engine` and calls FSDA | **Self-hosted runner only** + locally |

Run locally:

```bash
pytest -m "not integration"     # unit tests
pytest -m integration           # integration (needs MATLAB + FSDA)
pytest                          # everything
```

## Why the integration tests need a self-hosted runner

`pyfsda` drives MATLAB through the **MATLAB Engine API for Python**. MathWorks' hosted-runner
licensing (`matlab-actions/setup-matlab`) uses **batch licensing**, which — per MathWorks —
*does not support external language interfaces, including the MATLAB Engine APIs for Python, Java,
.NET, COM, C, C++, and Fortran*. An `MLM_LICENSE_TOKEN` does **not** lift this: batch licensing simply
cannot license the Engine API. The only supported path is a **self-hosted runner whose MATLAB is
licensed without a batch token** (a normal individual/network license). Do not spend time trying to
make the `matlab.engine` tests run on GitHub-hosted runners — it is not possible.

## Registering a self-hosted runner (one time)

On a machine that has a **normally-licensed MATLAB**, FSDA, a matching `matlabengine`, and Python:

1. GitHub → repo **Settings → Actions → Runners → New self-hosted runner**; follow the install steps.
2. Apply the labels the `integration` job targets: **`self-hosted`, `macOS`, `pyfsda-matlab`**
   (adjust `macOS` if your runner is Linux/Windows, and update `runs-on` in
   `.github/workflows/publish.yml` to match).
3. Run the runner **as the user who holds the MATLAB license** (so `matlab.engine` can start MATLAB
   non-interactively).

### Runner prerequisites
- **MATLAB** licensed **without** a batch token (individual or network license).
- **FSDA** on that MATLAB's path (verify `which mahalFS` in MATLAB). If it is *not* on the default
  path, set a repository variable **`PYFSDA_FSDA_ROOT`** to the FSDA install/checkout dir — the job
  forwards it to `FsdaEngine.start(fsda_root=...)`.
- A **`python3` on `PATH`** whose `matlabengine` matches the MATLAB release
  (e.g. `matlabengine==26.1.*` for R2026a). The job builds a `--system-site-packages` venv so it
  inherits that `matlabengine`.

## Security

A self-hosted runner executes workflow code **on your machine**. The `integration` job is therefore
gated `if: github.event_name != 'pull_request'` and runs only on `push` / `workflow_dispatch`. **Never**
enable it for `pull_request` events on a public repository — a fork's PR could run arbitrary code on
your runner. Keep the guard in place.
