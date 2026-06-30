"""Agreement gate for the generic FSDA engine (spec 016), Python only.

One reusable `FsdaEngine.start()` session exercises every well-behaved crossing
case through the *same* generic `call` / `eval` -- proving one shared engine
replaces the per-routine plumbing without a wrapper per routine:

    1. numeric array         mahalFS  -> ndarray            vs inline numpy oracle
    2. struct -> dict        Score    -> dict, out["Score"] vs inline numpy oracle
    3. nested struct         constructed struct of structs of arrays  -> exact
    4. char/string scalar    FSR      -> out["class"] == "FSR"
    (+) routine-agnostic     FSRaddt  -> out["Tdel"] tail   vs committed gold
    5. table -> dict         constructed array2table         -> exact (the path
                             that lets avasms / univariatems cross)
    6. real table fn         univariatems(y,X) -> Tsel table -> dict (STRUCTURAL:
                             robust cols are stochastic, so shape not value)
    7. /multivariate         corrNominal(N) -> struct (w/ table fields) -> chi2 &
                             CramerV vs numpy oracle
    8. /multivariate FS      FSM(Y) -> struct -> out.mmd tail vs bootstrapped gold
    9. /multivariate 2-out   [RAW,REW]=mcd(Y) -> tuple of dicts (nargout=2; structural)
   10. /multivariate PCA     pcaFS(Y) -> struct -> explained eigenvalues vs numpy corr
   11. /multivariate divrg   [PD,pval]=CressieRead(N) -> PD vs numpy oracle (lambda=2/3)
   12. /utilities_stat       logfactorial(n) -> float vs numpy
   13. /utilities_stat       tabulateFS(x) -> [value,count,percent] matrix vs numpy
   14. /utilities_stat       TBwei(u,c) -> Tukey biweight weights vs closed-form numpy

Cases 2/4/(+) also gate a real struct field against committed gold read **only**
from the existing per-target `reference/` folders -- nothing existing is written
or moved. `getYahoo` (struct-array) remains out of scope.

Run with the project venv's Python (engine boot is slow -- one session is reused):

    "$FSDA_DEV_VENV" code/fsda_engine/check_engine.py [FSDA_ROOT]    # macOS / Linux
    %FSDA_DEV_VENV% code\\fsda_engine\\check_engine.py [FSDA_ROOT]   # Windows

Prints per-case PASS/FAIL + max abs diff and an overall result; writes a
transparency summary to code/fsda_engine/reference/engine_check.csv. Gate
tolerance is atol=1e-9 (CONSTITUTION sec 5).
"""
from __future__ import annotations

import csv
import platform
import sys
from importlib import metadata
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
from engine import FsdaEngine

TOL = 1e-9
TAIL = 5                       # FSR mdr gate: last TAIL rows
ADDT_TAIL = 3                  # FSRaddt Tdel gate: last ADDT_TAIL rows
LA = np.array([-1.0, -0.5, 0.0, 0.5, 1.0])

CODE = Path(__file__).resolve().parent.parent           # .../code
REFERENCE = Path(__file__).resolve().parent / "reference"


# --- inline numpy oracles (self-contained; mirror the per-target checks) ------
def numpy_mahal(Y: np.ndarray, MU: np.ndarray, SIGMA: np.ndarray) -> np.ndarray:
    """Reference squared Mahalanobis distances, mirroring FSDA's formula."""
    diff = Y - MU.reshape(1, -1)
    return np.sum((diff @ np.linalg.inv(SIGMA)) * diff, axis=1)


def numpy_score(y: np.ndarray, X: np.ndarray, la: np.ndarray, intercept: bool = True) -> np.ndarray:
    """Reference Box-Cox score-test statistics, mirroring FSDA Score.m
    (copied from code/Score/check_Score.py so this gate stays self-contained)."""
    y = np.asarray(y, dtype=float).reshape(-1)
    X = np.asarray(X, dtype=float)
    n = y.shape[0]
    logy = np.log(y)
    G = np.exp(np.sum(logy) / n)
    logG = np.log(G)
    Xb = np.hstack([np.ones((n, 1)), X]) if intercept else X
    out = np.empty(len(la), dtype=float)
    for i, lai in enumerate(la):
        if abs(lai) < 1e-8:
            z = G * logy
            w = G * logy * (logy / 2.0 - logG)
        else:
            laiGlaim1 = lai * np.exp((lai - 1.0) * logG)
            ylai = np.exp(lai * logy)
            ylaim1 = ylai - 1.0
            z = ylaim1 / laiGlaim1
            w = (ylai * logy - ylaim1 * (1.0 / lai + logG)) / laiGlaim1
        Xw = np.hstack([Xb, w.reshape(-1, 1)])
        k = Xw.shape[1]
        Q, R = np.linalg.qr(Xw)
        beta = np.linalg.solve(R, Q.T @ z)
        resid = z - Xw @ beta
        sse = float(resid @ resid)
        Ri = np.linalg.solve(R, np.eye(k))
        xtxi = Ri @ Ri.T
        se = np.sqrt(np.diag(xtxi) * sse / (n - k))
        out[i] = -beta[-1] / se[-1]
    return out


# --- helpers -----------------------------------------------------------------
def read_csv_matrix(path: Path) -> np.ndarray:
    """Read a header+numeric CSV into a 2-D float array."""
    rows = []
    with open(path, newline="") as f:
        reader = csv.reader(f)
        next(reader)  # header
        for line in reader:
            rows.append([float(v) for v in line])
    return np.asarray(rows, dtype=float)


def require_fixture(path: Path, hint: str) -> np.ndarray:
    """Read a committed fixture/gold CSV (read-only); explain how to make it if absent."""
    if not path.exists():
        raise FileNotFoundError(
            f"required fixture not found: {path}\n  -> run {hint} first to materialize it."
        )
    return read_csv_matrix(path)


def load_or_write_golden(path: Path, matrix: np.ndarray, header: list):
    """Return (golden, bootstrapped?). Write `matrix` as the golden on first run (the
    inputs are deterministic), else read it back to compare against — the FSR pattern
    for routines that have no cheap independent oracle (forward searches)."""
    if path.exists():
        return read_csv_matrix(path), False
    path.parent.mkdir(exist_ok=True)
    with open(path, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(header)
        for row in matrix:
            w.writerow(list(row))
    return matrix.copy(), True


def engine_pkg_version() -> str:
    try:
        return metadata.version("matlabengine")
    except Exception:
        return "n/a"


def gate(name: str, ok: bool, diff: float, note: str = "") -> dict:
    """Pack one case result for the summary table."""
    return {"case": name, "ok": bool(ok), "max_abs_diff": float(diff), "note": note}


# --- the four (+1) cases, all through the same generic engine -----------------
def case_numeric(eng: FsdaEngine) -> dict:
    """1. numeric array: mahalFS -> ndarray."""
    Y = np.array([[1.0, 2.0], [2.0, 0.0], [3.0, 5.0], [0.0, -1.0], [4.0, 4.0]])
    MU = np.array([2.0, 2.0])                       # 1-D -> crosses as 1 x v row
    SIGMA = np.array([[2.0, 0.5], [0.5, 1.0]])
    d = np.asarray(eng.call("mahalFS", Y, MU, SIGMA), dtype=float).reshape(-1)
    ref = numpy_mahal(Y, MU, SIGMA)
    diff = float(np.max(np.abs(d - ref)))
    return gate("1 numeric array (mahalFS)", np.allclose(d, ref, rtol=0.0, atol=TOL),
                diff, "matlab.double -> ndarray")


def case_struct(eng: FsdaEngine) -> dict:
    """2. struct -> dict: Score, read out["Score"]."""
    wool = require_fixture(CODE / "Score" / "reference" / "wool.csv",
                           "code/Score/check_Score.py")
    y = wool[:, -1].reshape(-1, 1)                  # (n, 1) column -> crosses as column
    X = wool[:, :-1]
    out = eng.call("Score", y, X, la=LA, intercept=True)
    if not isinstance(out, dict):
        return gate("2 struct -> dict (Score)", False, float("inf"),
                    f"expected dict, got {type(out).__name__}")
    sc = np.asarray(out["Score"], dtype=float).reshape(-1)
    ref = numpy_score(y, X, LA, intercept=True)
    diff = float(np.max(np.abs(sc - ref)))
    return gate("2 struct -> dict (Score)", np.allclose(sc, ref, rtol=0.0, atol=TOL),
                diff, "struct -> dict, out['Score']")


def case_nested(eng: FsdaEngine) -> dict:
    """3. nested struct of arrays: constructed struct of structs of arrays."""
    s = eng.eval("struct('a',[1 2 3],'b',struct('c',[4 5 6],'d',[7 8 9]))")
    try:
        a = np.asarray(s["a"], dtype=float).reshape(-1)
        c = np.asarray(s["b"]["c"], dtype=float).reshape(-1)
        d = np.asarray(s["b"]["d"], dtype=float).reshape(-1)
    except (TypeError, KeyError) as exc:
        return gate("3 nested struct of arrays", False, float("inf"),
                    f"did not recurse to dict-of-dict-of-arrays: {exc}")
    want_a, want_c, want_d = np.array([1, 2, 3.]), np.array([4, 5, 6.]), np.array([7, 8, 9.])
    diff = float(max(np.max(np.abs(a - want_a)),
                     np.max(np.abs(c - want_c)),
                     np.max(np.abs(d - want_d))))
    ok = (isinstance(s, dict) and isinstance(s["b"], dict) and diff <= TOL)
    return gate("3 nested struct of arrays", ok, diff, "dict of dict of ndarrays")


def case_fsr(eng: FsdaEngine) -> dict:
    """4. char/string scalar (+ struct of arrays): FSR out['class'] and mdr tail."""
    stars = require_fixture(CODE / "FSR" / "reference" / "stars.csv",
                            "code/FSR/check_FSR.py")
    gold = require_fixture(CODE / "FSR" / "reference" / "FSR_mdr.csv",
                           "code/FSR/check_FSR.py")
    y = stars[:, -1].reshape(-1, 1)
    X = stars[:, :-1]
    # FSDA's own 'msg' defaults ON; silence it by forwarding msg=0. Both 'msg' and
    # 'plots' are ordinary FSDA name/value options -- they pass straight through as
    # kwargs (the bridge's own stdout tee is the separate `echo_output` flag).
    out = eng.call("FSR", y, X, nsamp=0, intercept=True, plots=1, msg=0)
    cls = out.get("class")
    mdr = np.asarray(out["mdr"], dtype=float)
    tail = mdr[-TAIL:]
    gtail = gold[-TAIL:]
    same = tail.shape == gtail.shape
    diff = float(np.max(np.abs(tail - gtail))) if same else float("inf")
    ok = (cls == "FSR") and same and np.allclose(tail, gtail, rtol=0.0, atol=TOL)
    return gate("4 char scalar + struct (FSR)", ok, diff,
                f"out['class']={cls!r}; mdr tail vs gold")


def case_fsraddt(eng: FsdaEngine) -> dict:
    """(+) routine-agnostic second struct routine: FSRaddt Tdel tail vs gold."""
    wool = require_fixture(CODE / "FSRaddt" / "reference" / "wool.csv",
                           "code/FSRaddt/check_FSRaddt.py")
    gold = require_fixture(CODE / "FSRaddt" / "reference" / "FSRaddt_Tdel.csv",
                           "code/FSRaddt/check_FSRaddt.py")
    y = wool[:, -1].reshape(-1, 1)
    X = wool[:, :-1]
    out = eng.call("FSRaddt", y, X, nsamp=0, intercept=True, plots=0, msg=0)
    tdel = np.asarray(out["Tdel"], dtype=float)
    tail = tdel[-ADDT_TAIL:]
    gtail = gold[-ADDT_TAIL:]
    same = tail.shape == gtail.shape
    diff = float(np.max(np.abs(tail - gtail))) if same else float("inf")
    ok = same and np.allclose(tail, gtail, rtol=0.0, atol=TOL)
    return gate("+ routine-agnostic (FSRaddt)", ok, diff, "out['Tdel'] tail vs gold")


def case_table(eng: FsdaEngine) -> dict:
    """5. MATLAB table -> dict: the mechanism that lets avasms / univariatems cross.

    A table cannot be returned to Python directly, so the engine decomposes it
    MATLAB-side. Build two known tables and check the round-trip exactly: column
    data by VariableNames, plus RowNames."""
    try:
        t = eng.eval("array2table([1 2 3;4 5 6],'VariableNames',{'aa','bb','cc'})")
        r = eng.eval("array2table([10;20],'VariableNames',{'v'},'RowNames',{'r1','r2'})")
        names_ok = (t["VariableNames"] == ["aa", "bb", "cc"]) and (t["RowNames"] == [])
        cols = {k: np.asarray(v, dtype=float).reshape(-1) for k, v in t["data"].items()}
        rownames_ok = (r["RowNames"] == ["r1", "r2"])
        want = {"aa": [1, 4.], "bb": [2, 5.], "cc": [3, 6.], "v": [10, 20.]}
        diff = float(max(
            np.max(np.abs(cols["aa"] - want["aa"])),
            np.max(np.abs(cols["bb"] - want["bb"])),
            np.max(np.abs(cols["cc"] - want["cc"])),
            np.max(np.abs(np.asarray(r["data"]["v"], dtype=float).reshape(-1) - want["v"])),
        ))
    except (TypeError, KeyError) as exc:
        return gate("5 table -> dict", False, float("inf"),
                    f"did not decompose table to dict: {exc}")
    ok = names_ok and rownames_ok and diff <= TOL
    return gate("5 table -> dict", ok, diff, "VariableNames + data + RowNames")


def case_univariatems(eng: FsdaEngine) -> dict:
    """6. real table-returning FSDA fn: univariatems(y, X) -> Tsel (table) -> dict.

    Unlike case 5 (a constructed array2table), this calls a genuine FSDA routine whose
    output is a MATLAB table. Its robust columns use random subsampling, so the values
    are not reproducible at 1e-9 -- this is a STRUCTURAL gate (the table decomposed into
    a well-formed dict), while case 5 stays the exact 1e-9 mechanism proof."""
    rng = np.random.default_rng(0)
    n, p = 60, 5
    X = rng.standard_normal((n, p))
    # strong signal on cols 0 and 2 -> some variables are reliably selected
    y = (3.0 * X[:, 0] - 2.0 * X[:, 2] + 0.3 * rng.standard_normal(n)).reshape(-1, 1)
    try:
        Tsel = eng.call("univariatems", y, X)        # y as (n,1) column; X (n,p)
        h = int(Tsel["height"])
        names, rownames = Tsel["VariableNames"], Tsel["RowNames"]
        cols_ok = all(isinstance(v, np.ndarray) and v.reshape(-1).shape[0] == h
                      for v in Tsel["data"].values())
        ok = (isinstance(Tsel, dict) and isinstance(names, list) and len(names) >= 1
              and isinstance(rownames, list) and len(rownames) == h and h >= 1 and cols_ok)
    except (TypeError, KeyError) as exc:
        return gate("6 real table fn (univariatems)", False, float("inf"),
                    f"univariatems table did not cross: {exc}")
    return gate("6 real table fn (univariatems)", ok, 0.0,
                f"structural: Tsel -> dict, {len(names)} cols x {h} rows")


def case_corrnominal(eng: FsdaEngine) -> dict:
    """7. /multivariate spot-check: corrNominal(N) on a contingency matrix -> struct.

    Confirms a multivariate routine crosses end-to-end and gates chi2 & Cramer's V vs an
    inline numpy oracle. corrNominal's out struct also holds *table* fields (Ntable,
    ConfLimtable, ...); the R2026a engine returns those as numeric arrays, so the whole
    struct marshals without special handling -- no engine change was needed. dispresults
    is off to keep the gate quiet."""
    N = np.array([[10., 20., 30.], [40., 50., 60.], [70., 80., 90.]])
    out = eng.call("corrNominal", N, dispresults=False)
    if not isinstance(out, dict):
        return gate("7 multivariate (corrNominal)", False, float("inf"),
                    f"expected dict, got {type(out).__name__}")
    # numpy oracle: chi-square and Cramer's V for a contingency table
    rt = N.sum(1, keepdims=True); ct = N.sum(0, keepdims=True); tot = N.sum()
    E = rt @ ct / tot
    chi2_ref = float(((N - E) ** 2 / E).sum())
    I, J = N.shape
    cramer_ref = float(np.sqrt(chi2_ref / (tot * (min(I, J) - 1))))
    chi2 = float(np.asarray(out["Chi2"]))
    cramer = float(np.asarray(out["CramerV"]).reshape(-1)[0])
    diff = max(abs(chi2 - chi2_ref), abs(cramer - cramer_ref))
    return gate("7 multivariate (corrNominal)", diff <= TOL, diff,
                f"chi2={chi2:.4f}, CramerV={cramer:.4f} vs numpy oracle")


def _fsm_dataset() -> np.ndarray:
    """Fixed multivariate dataset, persisted so all three language gates read an
    identical Y (the FSM gold is FSDA-RNG-specific, not numpy-specific). Seeded numpy
    generates it on first run and writes reference/FSM_Y.csv (round-trippable floats);
    later runs — and the Julia/R gates — read that committed fixture."""
    path = REFERENCE / "FSM_Y.csv"
    if path.exists():
        return read_csv_matrix(path)
    rng = np.random.default_rng(0)
    Y = rng.standard_normal((40, 3))
    Y[-3:] += 6.0
    REFERENCE.mkdir(exist_ok=True)
    with open(path, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow([f"v{j + 1}" for j in range(Y.shape[1])])
        for row in Y:
            w.writerow(list(row))
    return Y


def case_fsm(eng: FsdaEngine) -> dict:
    """8. /multivariate forward search: FSM(Y) -> struct (out.mmd ~ FSR's out.mdr).

    No cheap independent oracle (a forward search over FSDA internals), so — like FSR —
    the gate is the mmd tail vs a bootstrapped gold. Deterministic: the dataset is seeded
    and `rng(0)` fixes FSM's random initial subset; plots/msg off for a quiet run."""
    Y = _fsm_dataset()
    eng.eval("rng(0)", nargout=0)
    out = eng.call("FSM", Y, plots=0, msg=0)
    cls = out.get("class") if isinstance(out, dict) else type(out).__name__
    if cls != "FSM":
        return gate("8 FSM (multivariate FS)", False, float("inf"), f"expected FSM struct, got {cls!r}")
    mmd = np.asarray(out["mmd"], dtype=float)
    if mmd.ndim != 2 or mmd.shape[1] != 2:
        return gate("8 FSM (multivariate FS)", False, float("inf"), f"mmd shape {mmd.shape}")
    gold, boot = load_or_write_golden(REFERENCE / "FSM_mmd.csv", mmd, ["step", "mmd"])
    tail, gtail = mmd[-TAIL:], gold[-TAIL:]
    same = tail.shape == gtail.shape
    diff = float(np.max(np.abs(tail - gtail))) if same else float("inf")
    note = "mmd tail vs gold" + (" (bootstrapped)" if boot else "")
    return gate("8 FSM (multivariate FS)", same and diff <= TOL, diff, note)


def case_mcd(eng: FsdaEngine) -> dict:
    """9. /multivariate two-output routine: [RAW, REW] = mcd(Y) -> tuple of dicts.

    Validates the nargout=2 marshalling (a Python tuple of two structs). mcd is a
    resampling estimator; `rng(0)` stabilizes the run and the gate is STRUCTURAL — both
    structs present with the right class and shapes (loc v-vector, cov v x v)."""
    Y = _fsm_dataset()
    v = Y.shape[1]
    eng.eval("rng(0)", nargout=0)
    res = eng.call("mcd", Y, nargout=2, plots=0, msg=0)
    if not (isinstance(res, tuple) and len(res) == 2):
        return gate("9 mcd (nargout=2 tuple)", False, float("inf"),
                    f"expected 2-tuple, got {type(res).__name__}")
    RAW, REW = res
    ok = (isinstance(RAW, dict) and isinstance(REW, dict)
          and RAW.get("class") == "mcd" and REW.get("class") == "mcdr"
          and np.asarray(RAW["loc"]).reshape(-1).shape[0] == v
          and np.asarray(RAW["cov"]).shape == (v, v))
    return gate("9 mcd (nargout=2 tuple)", ok, 0.0,
                f"RAW.class={RAW.get('class')!r}, REW.class={REW.get('class')!r}, "
                f"cov{np.asarray(RAW['cov']).shape}")


def case_pcafs(eng: FsdaEngine) -> dict:
    """10. /multivariate PCA: pcaFS(Y) -> struct. `out.explained[:,0]` are the eigenvalues
    of the *correlation* matrix (standardize defaults true) -> gated vs numpy at 1e-9.
    Deterministic (no subsampling); reuses the committed FSM_Y fixture."""
    Y = _fsm_dataset()
    out = eng.call("pcaFS", Y, plots=0)
    if not isinstance(out, dict):
        return gate("10 multivariate (pcaFS)", False, float("inf"), f"expected dict, got {type(out).__name__}")
    expl = np.asarray(out["explained"], dtype=float)
    eig_ref = np.sort(np.linalg.eigvalsh(np.corrcoef(Y, rowvar=False)))[::-1]
    diff = float(np.max(np.abs(expl[:, 0] - eig_ref)))
    return gate("10 multivariate (pcaFS)", diff <= TOL, diff, "explained eigenvalues vs numpy corr")


def case_cressieread(eng: FsdaEngine) -> dict:
    """11. /multivariate power-divergence: [PD,pval]=CressieRead(N) -> tuple. Gate PD
    (default family parameter lambda=2/3) vs a numpy oracle at 1e-9. CressieRead has no
    'plots' option, so none is passed."""
    N = np.array([[10., 20., 30.], [40., 50., 60.], [70., 80., 90.]])
    res = eng.call("CressieRead", N, nargout=2)
    if not (isinstance(res, tuple) and len(res) == 2):
        return gate("11 multivariate (CressieRead)", False, float("inf"),
                    f"expected 2-tuple, got {type(res).__name__}")
    PD = float(np.asarray(res[0]))
    rt = N.sum(1, keepdims=True); ct = N.sum(0, keepdims=True); tot = N.sum()
    E = rt @ ct / tot
    la = 2.0 / 3.0
    PD_ref = float((2.0 / (la * (la + 1.0))) * np.sum(N * ((N / E) ** la - 1.0)))
    diff = abs(PD - PD_ref)
    return gate("11 multivariate (CressieRead)", diff <= TOL, diff, f"PD={PD:.4f} vs numpy oracle")


def case_logfactorial(eng: FsdaEngine) -> dict:
    """12. /utilities_stat scalar: logfactorial(n) = log(n!) -> float, vs numpy oracle."""
    n = 10
    lf = float(np.asarray(eng.call("logfactorial", float(n))))
    ref = float(np.sum(np.log(np.arange(1, n + 1))))
    diff = abs(lf - ref)
    return gate("12 utilities_stat (logfactorial)", diff <= TOL, diff, f"log({n}!) vs numpy")


def case_tabulatefs(eng: FsdaEngine) -> dict:
    """13. /utilities_stat frequency: tabulateFS(x) -> [value, count, percent] matrix,
    vs numpy.unique counts."""
    x = np.array([1., 1, 2, 3, 3, 3])
    tb = np.asarray(eng.call("tabulateFS", x), dtype=float)
    vals, cnts = np.unique(x, return_counts=True)
    ref = np.column_stack([vals, cnts, cnts / x.size * 100.0])
    same = tb.shape == ref.shape
    diff = float(np.max(np.abs(tb - ref))) if same else float("inf")
    return gate("13 utilities_stat (tabulateFS)", same and diff <= TOL, diff, "value/count/percent vs numpy")


def case_tbwei(eng: FsdaEngine) -> dict:
    """14. /utilities_stat robust weight: TBwei(u,c) = Tukey biweight (1-(u/c)^2)^2 for
    |u|<=c else 0, vs a closed-form numpy oracle."""
    u = np.array([-3., -1, 0, 0.5, 2, 5]).reshape(-1, 1)
    c = 4.685
    w = np.asarray(eng.call("TBwei", u, c), dtype=float).reshape(-1)
    uu = u.reshape(-1)
    ref = np.where(np.abs(uu) <= c, (1 - (uu / c) ** 2) ** 2, 0.0)
    diff = float(np.max(np.abs(w - ref)))
    return gate("14 utilities_stat (TBwei)", diff <= TOL, diff, "Tukey biweight vs numpy")


def main() -> int:
    fsda_root = sys.argv[1] if len(sys.argv) > 1 else None
    eng = FsdaEngine.start(fsda_root=fsda_root)
    try:
        matlab_version = eng.version()
        results = [
            case_numeric(eng),
            case_struct(eng),
            case_nested(eng),
            case_fsr(eng),
            case_fsraddt(eng),
            case_table(eng),
            case_univariatems(eng),
            case_corrnominal(eng),
            case_fsm(eng),
            case_mcd(eng),
            case_pcafs(eng),
            case_cressieread(eng),
            case_logfactorial(eng),
            case_tabulatefs(eng),
            case_tbwei(eng),
        ]
    finally:
        eng.stop()

    overall = all(r["ok"] for r in results)

    print("=== spec 016: generic FSDA engine agreement check ===")
    print(f"Python       : {platform.python_version()}")
    print(f"MATLAB       : {matlab_version}")
    print(f"engine pkg   : {engine_pkg_version()}")
    print(f"tolerance    : atol {TOL:.0e}")
    print("cases (one shared FsdaEngine.call / .eval):")
    for r in results:
        print(f"  [{'PASS' if r['ok'] else 'FAIL'}]  {r['case']:<30}  "
              f"max abs diff {r['max_abs_diff']:.3e}   {r['note']}")
    print(f"RESULT       : {'PASS' if overall else 'FAIL'}")

    REFERENCE.mkdir(exist_ok=True)
    with open(REFERENCE / "engine_check.csv", "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["case", "result", "max_abs_diff", "note"])
        for r in results:
            w.writerow([r["case"], "PASS" if r["ok"] else "FAIL",
                        f"{r['max_abs_diff']:.6e}", r["note"]])

    return 0 if overall else 1


if __name__ == "__main__":
    raise SystemExit(main())
