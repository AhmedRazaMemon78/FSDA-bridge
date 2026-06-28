"""Agreement check: FSDA `FSRaddt` through matlab.engine on the `wool` dataset.

Run with the project venv's Python (the script's own dir is put on sys.path so
`import bridge` works). With an activated venv just `python check_FSRaddt.py`; or
point FSDA_DEV_VENV at the venv's python executable and run it directly:

    %FSDA_DEV_VENV% code\\FSRaddt\\check_FSRaddt.py [FSDA_ROOT]   # Windows
    "$FSDA_DEV_VENV" code/FSRaddt/check_FSRaddt.py [FSDA_ROOT]    # macOS / Linux

FSRaddt cannot be reproduced by an independent numpy oracle (it is a forward search
over FSDA internals), so the agreement gate is: **the last five rows of out.Tdel
must be equal** to the committed golden (reference/FSRaddt_Tdel.csv) at atol=1e-9.
out.Tdel is (m, k+1) = [step, deletion t-stat per tested variable]; its tail is the
decisive added-variable-significance region near the full sample. nsamp=0 makes the
run deterministic.

Fixed input: the genuine FSDA `wool` dataset (3^3 factorial, n=27, 3 predictors +
response), a classic multiple-regression example. It is read from the committed
reference/wool.csv when present, otherwise loaded once from MATLAB and persisted
there (so the R/Julia surfaces read the same input). This is the spec-010 gate.
"""
from __future__ import annotations

import csv
import platform
import sys
from importlib import metadata
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import bridge

TOL = 1e-9
TAIL = 5   # the gate compares the last TAIL rows of out.Tdel
PLOTS = 1  # FSRaddt plot level (0 headless; 1 shows the deletion-t figure window)
MSG = 1    # FSRaddt message level (1 routes MATLAB's progress messages to the terminal)

# Load the genuine FSDA wool data, accepting either wool.txt (ASCII matrix) or
# wool.mat (a variable / table), leaving the result in MATLAB variable XX.
LOAD_WOOL = (
    "if ~isempty(which('wool.txt'))\n"
    "  XX = load('wool.txt');\n"
    "elseif ~isempty(which('wool.mat'))\n"
    "  tmp = load('wool.mat'); fn = fieldnames(tmp); v = tmp.(fn{1});\n"
    "  if istable(v); XX = table2array(v); else; XX = v; end\n"
    "else\n"
    "  error('wool dataset not found on the MATLAB path');\n"
    "end"
)


def engine_pkg_version() -> str:
    try:
        return metadata.version("matlabengine")
    except Exception:
        return "n/a"


def load_wool_fixture(eng, reference_dir: Path) -> np.ndarray:
    """Return the fixed `wool` dataset (last column = response y).

    Read it from the committed reference/wool.csv when present; otherwise load the
    genuine FSDA dataset once through MATLAB and persist it as the portable fixture,
    so the R/Julia surfaces read identical inputs.
    """
    wool_csv = reference_dir / "wool.csv"
    if wool_csv.exists():
        rows = []
        with open(wool_csv, newline="") as f:
            reader = csv.reader(f)
            next(reader)  # header
            for line in reader:
                rows.append([float(v) for v in line])
        return np.asarray(rows, dtype=float)

    eng.eval(LOAD_WOOL, nargout=0)
    XX = np.asarray(eng.workspace["XX"], dtype=float)
    reference_dir.mkdir(exist_ok=True)
    with open(wool_csv, "w", newline="") as f:
        w = csv.writer(f)
        ncol = XX.shape[1]
        w.writerow([f"x{j + 1}" for j in range(ncol - 1)] + ["y"])
        for row in XX:
            w.writerow(list(row))
    return XX


def load_or_write_golden(reference_dir: Path, Tdel: np.ndarray):
    """Return (golden Tdel, bootstrapped?). The golden is the full Tdel trajectory;
    its last TAIL rows are the gate. Bootstrapped from this run when absent. The
    header is step,t1,t2,... (one t column per tested variable)."""
    golden_csv = reference_dir / "FSRaddt_Tdel.csv"
    if golden_csv.exists():
        rows = []
        with open(golden_csv, newline="") as f:
            reader = csv.reader(f)
            next(reader)  # header
            for line in reader:
                rows.append([float(v) for v in line])
        return np.asarray(rows, dtype=float), False

    reference_dir.mkdir(exist_ok=True)
    ncol = Tdel.shape[1]
    with open(golden_csv, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["step"] + [f"t{j}" for j in range(1, ncol)])
        for row in Tdel:
            w.writerow(list(row))
    return Tdel.copy(), True


def main() -> int:
    reference_dir = Path(__file__).resolve().parent / "reference"
    fsda_root = sys.argv[1] if len(sys.argv) > 1 else None

    eng = bridge.start_engine(fsda_root=fsda_root)
    try:
        matlab_version = eng.version()
        where = eng.which("FSRaddt")

        XX = load_wool_fixture(eng, reference_dir)
        y = XX[:, -1]
        X = XX[:, :-1]

        # plots/msg are driven by the module constants; with MSG on, FSRaddt's
        # progress messages are routed to this terminal, and with PLOTS on it opens
        # a live MATLAB figure window (kept open by the pause below).
        res = bridge.fsraddt(eng, y, X, nsamp=0, intercept=True, plots=PLOTS, msg=MSG)

        Tdel = res["Tdel"]
        golden, bootstrapped = load_or_write_golden(reference_dir, Tdel)

        tail = Tdel[-TAIL:]
        gtail = golden[-TAIL:]
        same_shape = tail.shape == gtail.shape
        max_abs_diff = float(np.max(np.abs(tail - gtail))) if same_shape else float("inf")
        ok = same_shape and bool(np.allclose(tail, gtail, rtol=0.0, atol=TOL))

        print("=== spec 010: FSRaddt bridge agreement check ===")
        print(f"Python       : {platform.python_version()}")
        print(f"MATLAB       : {matlab_version}")
        print(f"engine pkg   : {engine_pkg_version()}")
        print(f"FSRaddt path : {where}")
        print(f"fixture      : wool (n={XX.shape[0]}, p={XX.shape[1] - 1}+intercept), nsamp=0")
        print(f"tested vars  : la(1-b)={res['la'].tolist()}  (k={res['la'].size})")
        print(f"Un cells     : {len(res['Un'])} (cell->list); shapes "
              f"{[tuple(u.shape) for u in res['Un']]}")
        print(f"bs (1-based) : {res['bs'].tolist()}")
        print(f"Tdel last {TAIL} rows (step, deletion t-stats):")
        for row in tail:
            cells = "  ".join(f"{v:.6f}" for v in row[1:])
            print(f"   {int(row[0]):3d}  {cells}")
        if bootstrapped:
            print("golden       : bootstrapped reference/FSRaddt_Tdel.csv (first run)")
        print(f"max abs diff : {max_abs_diff:.3e}  (tol {TOL:.0e})")
        print(f"RESULT       : {'PASS' if ok else 'FAIL'}")

        # transparency artifact: la + bs + Un shapes (long format, language-neutral)
        with open(reference_dir / "FSRaddt_check.csv", "w", newline="") as f:
            w = csv.writer(f)
            w.writerow(["field", "index", "value"])
            for i, v in enumerate(res["la"]):
                w.writerow(["la", i, int(v)])
            for (r, c), v in np.ndenumerate(res["bs"]):
                w.writerow(["bs", f"{r}_{c}", int(v)])
            for i, u in enumerate(res["Un"]):
                w.writerow(["Un_shape", i, f"{u.shape[0]}x{u.shape[1]}"])

        # Keep the engine (and the figure window) alive until the user closes it:
        # blocking is driven MATLAB-side (uiwait), uniform with R/Julia where reading
        # a key cannot work (the embedded engine hijacks stdin). Gated on an
        # interactive terminal so piped / CI runs never hang.
        if PLOTS and sys.stdin.isatty():
            print("Close the FSRaddt figure window(s) to stop the engine and finish...")
            bridge.wait_for_figures(eng)

        return 0 if ok else 1
    finally:
        bridge.stop_engine(eng)


if __name__ == "__main__":
    raise SystemExit(main())
