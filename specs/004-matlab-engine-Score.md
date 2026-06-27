# Spec 004 — MATLAB Engine: call FSDA `Score` from Python (Box-Cox score test)

> Second function ported through the Layer-1 bridge, after `mahalFS` (spec 001). `Score` is richer: it
> takes name/value options (`la`, `intercept`), runs an internal regression per lambda, and returns a
> **struct**. This spec proves the bridge handles struct outputs and a non-trivial numeric routine.
> Read `CONSTITUTION.md` first. Python surface only; Julia (005) and R (006) are siblings.

## Contract

- **Deliverable:** from Python, start a MATLAB engine session, call the genuine FSDA
  `Score(y, X, 'la', la, 'intercept', intercept)`, and return the per-lambda **score-test
  t-statistics** (`out.Score`) as a numpy array.
- **Done when:** `code/Score/check_Score.py`, run with the project venv, prints `PASS` — the FSDA
  output matches a pure-numpy reference to `< 1e-9` (the agreement gate, §5 of the constitution) on the
  genuine FSDA `wool` dataset with the default `la = [-1, -0.5, 0, 0.5, 1]`.
- **Out of scope:** Julia and R surfaces (specs 005 / 006); the optional `out.Lik` / `out.ScoreT`
  (`'Lik'`, `'tukey1df'`) outputs; FSDA routines other than `Score`; packaging.

## Design

**FSDA source** (`Score.m` computational core, verbatim — for reference only; we never edit it). With
`intercept=true` (default), `aux.chkinputR` **prepends a column of ones to `X`** before this loop:

```matlab
logy=log(y); G=exp(sum(logy)/n); logG=log(G);
% per lambda lai:
%   lai==0 :  z=G*logy;                 w=G*logy.*(logy/2-logG);
%   else   :  laiGlaim1=lai*exp((lai-1)*logG);  ylai=exp(lai*logy);  ylaim1=ylai-1;
%             z=ylaim1/laiGlaim1;        w=(ylai.*logy-ylaim1*(1/lai+logG))/laiGlaim1;
Xw=[X w]; [Q,R]=qr(Xw,0); beta=R\(Q'*z);
residuals=z-Xw*beta; sse=norm(residuals)^2;
ri=R\eyepplus1; xtxi=ri*ri';
se=sqrt(diag(xtxi*sse/(n-p-1)));        % df = n - ncol(Xw)
tstatw=-beta(end)/se(end);              % NOTE the leading minus sign
```

`z` is the geometric-mean-normalized power transformation of `y`; `w = dz/dlambda` is the constructed
variable; `out.Score(i)` is the (negated) t-ratio of `w`'s coefficient when `w` is added to the
regression of `z` on `X`. A statistic near 0 supports that lambda.

- **Files:**
  - `code/Score/bridge.py` — Layer 1. `start_engine(fsda_root=None)` starts the engine and verifies
    `Score` resolves. `score(eng, y, X, la=None, intercept=True)` marshals numpy → `matlab.double` →
    numpy and reads `out['Score']`. `stop_engine(eng)` quits. `matlab_version(eng)` / `which_score(eng)`
    are diagnostics helpers for the Layer-2 surfaces.
  - `code/Score/check_Score.py` — the agreement check. Fixed input = genuine FSDA `wool` (27×4); numpy
    reference replicates the core above; compare with `atol=1e-9`. Prints the version triple and writes
    `reference/wool.csv` (the portable fixture) + `reference/Score_check.csv` (per-lambda oracle).
- **Signatures / shapes:** `y` is `(n,)` or `(n,1)` and **strictly positive** (Box-Cox); `X` is `(n, p)`
  raw predictors (FSDA adds the intercept column when `intercept=True`); `la` is 1D (default length 5);
  output is `(len(la),)`.
- **Marshalling notes (where this port can break):**
  - *Struct return:* `eng.Score(...)` returns a MATLAB **struct → Python dict** (needs `nargout=1`); read
    `out['Score']` then `np.asarray(...).reshape(-1)`. New vs `mahalFS`, which returned a bare array.
  - *Intercept column:* FSDA prepends the ones column **internally**; pass raw `X`. The numpy oracle must
    add the ones column itself so `Xw = [ones, X, w]` and residual `df = n - ncol(Xw)`.
  - *Sign:* the statistic is `-beta(end)/se(end)` — keep the minus in the oracle.
  - *Shapes:* `y` → `n×1` column `matlab.double`; `la` → `1×len(la)` row; validate `y > 0`, `X` rows
    match `y`, and output length `== len(la)`. No silent reshape.
  - *Fixture:* `wool.txt` ships with FSDA (`toolbox/datasets/regression/wool.txt`); the check loads it
    once via MATLAB and persists `reference/wool.csv` so R/Julia read identical inputs.
- **Reference oracle:** the FSDA call itself; gold per-lambda output saved to
  `code/Score/reference/Score_check.csv`, fixture to `code/Score/reference/wool.csv`.

## Tasks

- [x] #p1 Write `code/Score/bridge.py` (start_engine / score / stop_engine + diagnostics helpers).
- [x] #p1 Write `code/Score/check_Score.py` (numpy reference + agreement gate + version triple + wool
  fixture bootstrap).
- [x] #p1 Run the check in the venv; confirm `PASS` with max abs diff < 1e-9.
- [x] #p2 Persist the genuine `wool` fixture (`reference/wool.csv`) and the per-lambda oracle
  (`reference/Score_check.csv`) for the Layer-2 surfaces.
- [x] #p3 Note the struct-return + internal-intercept learnings for specs 005 / 006.

### Done

- 2026-06-27 — Bridge + agreement check written and run. **PASS, max abs diff `6.324e-13`** (tol 1e-9).
  Env: Python 3.11.5 · MATLAB R2026a Update 1 · `matlabengine==26.1.12` · `Score` resolved at
  `/Users/aldocorbellini/FSDA/toolbox/regression/Score.m`. Fixture: genuine FSDA `wool` (27×4,
  `toolbox/datasets/regression/wool.txt`), default `la = [-1 -0.5 0 0.5 1]`, `intercept=true`.
  Score = `[17.7059, 7.4927, -0.9122, -9.5511, -18.5576]` — the classic Box-Cox wool result: the
  statistic crosses zero near `lambda=0`, so the **log transform** is supported and `lambda=1` (no
  transform) is firmly rejected. A good sanity signal the port is meaningful, not just self-consistent.
  Gold output in `code/Score/reference/Score_check.csv`; fixture in `code/Score/reference/wool.csv`.
- 2026-06-27 — Learnings for the Layer-2 siblings (005 Julia, 006 R):
  - **`Score` returns a struct** → marshalled as a Python `dict`; the bridge reads `out['Score']`. R/Julia
    reuse `bridge.py` verbatim, so the dict access stays Python-side — no struct handling needed in R/Julia.
  - **The intercept column is FSDA's responsibility** (added in `aux.chkinputR`); the *oracle* must mirror it.
  - **Diagnostics helper renamed** `which_mahalfs` → `which_score`; otherwise the Layer-1 surface matches
    spec 001 one-for-one.
  - **Oracle artifact shape changed**: inputs (27 rows) and outputs (5 lambdas) have different cardinality,
    so unlike `mahalFS` they live in *two* files — `wool.csv` (fixture) and `Score_check.csv` (per-lambda
    oracle the R/Julia checks compare against).
