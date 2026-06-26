# Spec 001 — MATLAB Engine: call an FSDA function from Python (`mahalFS`)

> First spec. Proves the Layer-1 bridge end-to-end on a real FSDA routine. Read `CONSTITUTION.md` first.

## Contract

- **Deliverable:** from Python, start a MATLAB engine session, call the genuine FSDA `mahalFS(Y, MU,
  SIGMA)`, and return the per-row **squared Mahalanobis distances** as a numpy array.
- **Done when:** `code/mahalFS/check_mahalFS.py`, run with the project venv, prints `PASS` — the FSDA
  output matches a pure-numpy reference to `< 1e-9` (the agreement gate, §5 of the constitution). The
  original PoC hit exact `0`.
- **Out of scope:** Julia and R surfaces (specs 002 / 003); any FSDA routine other than `mahalFS`;
  packaging.

## Design

**FSDA source** (`mahalFS.m`, verbatim — two lines, for reference only; we never edit it):

```matlab
function d = mahalFS(Y,MU,SIGMA)
Ytilde = bsxfun(@minus, Y, MU);
d = sum((Ytilde/SIGMA).*Ytilde, 2);   % d_i = (y_i - MU) * inv(SIGMA) * (y_i - MU)'
```

`Ytilde/SIGMA` is right matrix division (`Ytilde * inv(SIGMA)`), so `d` is the **squared** Mahalanobis
distance of each row of `Y` from `MU` under covariance `SIGMA`.

- **Files:**
  - `code/mahalFS/bridge.py` — Layer 1. `start_engine(fsda_root=None)` starts the engine and verifies
    `mahalFS` is on the MATLAB path (FSDA is installed as an Add-On, so normally already resolved;
    `fsda_root` is the fallback for `addpath(genpath(...))`). `mahal_fs(eng, Y, MU, SIGMA)` marshals
    numpy → `matlab.double` → numpy. `stop_engine(eng)` quits the session.
  - `code/mahalFS/check_mahalFS.py` — the agreement check. Fixed small input (`n=5, v=2`), numpy
    reference `((Y - MU) @ inv(SIGMA) * (Y - MU)).sum(axis=1)`, compare with `atol=1e-9`. Prints the
    version triple (Python / MATLAB / engine) and writes inputs+outputs to `reference/`.
- **Signatures / shapes:** `Y` is `(n, v)`, `MU` is `(v,)` or `(1, v)` (forced to `1×v`), `SIGMA` is
  `(v, v)`; output is `(n,)`.
- **Marshalling notes:** convert via `matlab.double(arr.tolist())`; validate `MU.shape == (1, v)` and
  `SIGMA.shape == (v, v)` before the call, and `d.shape == (n,)` after. No silent reshape.
- **Reference oracle:** the FSDA call itself; gold output saved to `code/mahalFS/reference/`.

## Tasks

- [x] #p1 Write `code/mahalFS/bridge.py` (start_engine / mahal_fs / stop_engine).
- [x] #p1 Write `code/mahalFS/check_mahalFS.py` (numpy reference + agreement gate + version triple).
- [x] #p1 Run the check in the venv; confirm `PASS` with max abs diff ≈ 0.
- [x] #p2 Note FSDA-path resolution (Add-On auto-resolves; `fsda_root` / env fallback documented).
- [ ] #p3 Jot follow-up specs: 002 Julia (PythonCall) surface, 003 R (reticulate) surface.

### Done

- 2026-06-26 — Bridge + agreement check written and run. **PASS, max abs diff `0.000e+00`** (tol 1e-9).
  Env: Python 3.12.10 · MATLAB R2026a Update 2 · `matlabengine==26.1.12` · FSDA Add-On at
  `...\MATLAB Add-Ons\Toolboxes\FSDA\utilities_stat\mahalFS.m`. Gold output in
  `code/mahalFS/reference/mahalFS_check.csv`.
- 2026-06-26 - Review tightened bridge boundary checks: explicit `ValueError`/`RuntimeError` instead of
  optimized-away assertions; `mahalFS` agreement check still **PASS**, max abs diff `0.000e+00`.
