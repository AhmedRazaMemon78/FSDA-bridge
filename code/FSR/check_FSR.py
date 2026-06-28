"""Agreement check: FSDA `FSR` through matlab.engine on the `stars` dataset.

Run with the project venv's Python (the script's own dir is put on sys.path so
`import bridge` works). With an activated venv just `python check_FSR.py`; or
point FSDA_DEV_VENV at the venv's python executable and run it directly:

    %FSDA_DEV_VENV% code\\FSR\\check_FSR.py [FSDA_ROOT]   # Windows
    "$FSDA_DEV_VENV" code/FSR/check_FSR.py [FSDA_ROOT]    # macOS / Linux

FSR cannot be reproduced by an independent numpy oracle (it is a forward search
over FSDA internals), so the agreement gate is: **the last five rows of out.mdr
must be equal** to the committed golden (reference/FSR_mdr.csv) at atol=1e-9.
out.mdr is (n-init, 2) = [step, minimum deletion residual]; its tail is the
decisive outlier-signal region. nsamp=0 makes the run deterministic.

Fixed input: the genuine FSDA `stars` dataset (Hertzsprung-Russell star data, a
classic multi-outlier regression example). It is read from the committed
reference/stars.csv when present, otherwise loaded once from MATLAB and persisted
there (so the R/Julia surfaces read the same input). This is the spec-007 gate.
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
TAIL = 5   # the gate compares the last TAIL rows of out.mdr
PLOTS = 1  # FSR plot level (0 headless; 1 shows the mdr figure window)
MSG = 1    # FSR message level (1 routes MATLAB's progress messages to the terminal)

# Load the genuine FSDA stars data, accepting either stars.txt (ASCII matrix) or
# stars.mat (a variable / table), leaving the result in MATLAB variable XX.
LOAD_STARS = (
    "if ~isempty(which('stars.txt'))\n"
    "  XX = load('stars.txt');\n"
    "elseif ~isempty(which('stars.mat'))\n"
    "  tmp = load('stars.mat'); fn = fieldnames(tmp); v = tmp.(fn{1});\n"
    "  if istable(v); XX = table2array(v); else; XX = v; end\n"
    "else\n"
    "  error('stars dataset not found on the MATLAB path');\n"
    "end"
)


def engine_pkg_version() -> str:
    try:
        return metadata.version("matlabengine")
    except Exception:
        return "n/a"


def load_stars_fixture(eng, reference_dir: Path) -> np.ndarray:
    """Return the fixed `stars` dataset (last column = response y).

    Read it from the committed reference/stars.csv when present; otherwise load
    the genuine FSDA dataset once through MATLAB and persist it as the portable
    fixture, so the R/Julia surfaces read identical inputs.
    """
    stars_csv = reference_dir / "stars.csv"
    if stars_csv.exists():
        rows = []
        with open(stars_csv, newline="") as f:
            reader = csv.reader(f)
            next(reader)  # header
            for line in reader:
                rows.append([float(v) for v in line])
        return np.asarray(rows, dtype=float)

    eng.eval(LOAD_STARS, nargout=0)
    XX = np.asarray(eng.workspace["XX"], dtype=float)
    reference_dir.mkdir(exist_ok=True)
    with open(stars_csv, "w", newline="") as f:
        w = csv.writer(f)
        ncol = XX.shape[1]
        w.writerow([f"x{j + 1}" for j in range(ncol - 1)] + ["y"])
        for row in XX:
            w.writerow(list(row))
    return XX


def load_or_write_golden(reference_dir: Path, mdr: np.ndarray):
    """Return (golden mdr, bootstrapped?). The golden is the full mdr trajectory;
    its last TAIL rows are the gate. Bootstrapped from this run when absent."""
    golden_csv = reference_dir / "FSR_mdr.csv"
    if golden_csv.exists():
        rows = []
        with open(golden_csv, newline="") as f:
            reader = csv.reader(f)
            next(reader)  # header
            for line in reader:
                rows.append([float(v) for v in line])
        return np.asarray(rows, dtype=float), False

    reference_dir.mkdir(exist_ok=True)
    with open(golden_csv, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["step", "mdr"])
        for step, val in mdr:
            w.writerow([step, val])
    return mdr.copy(), True


def main() -> int:
    reference_dir = Path(__file__).resolve().parent / "reference"
    fsda_root = sys.argv[1] if len(sys.argv) > 1 else None

    eng = bridge.start_engine(fsda_root=fsda_root)
    try:
        matlab_version = eng.version()
        where = eng.which("FSR")

        XX = load_stars_fixture(eng, reference_dir)
        y = XX[:, -1]
        X = XX[:, :-1]

        # plots/msg are driven by the module constants; with MSG on, FSR's progress
        # messages are routed to this terminal, and with PLOTS on it opens a live
        # MATLAB figure window (kept open by the pause below).
        res = bridge.fsr(eng, y, X, nsamp=0, intercept=True, plots=PLOTS, msg=MSG)

        mdr = res["mdr"]
        golden, bootstrapped = load_or_write_golden(reference_dir, mdr)

        tail = mdr[-TAIL:]
        gtail = golden[-TAIL:]
        same_shape = tail.shape == gtail.shape
        max_abs_diff = float(np.max(np.abs(tail - gtail))) if same_shape else float("inf")
        ok = same_shape and bool(np.allclose(tail, gtail, rtol=0.0, atol=TOL))

        print("=== spec 007: FSR bridge agreement check ===")
        print(f"Python       : {platform.python_version()}")
        print(f"MATLAB       : {matlab_version}")
        print(f"engine pkg   : {engine_pkg_version()}")
        print(f"FSR path     : {where}")
        print(f"fixture      : stars (n={XX.shape[0]}, p={XX.shape[1] - 1}+intercept), nsamp=0")
        print(f"outliers(1-b): {res['outliers'].tolist()}")
        print(f"mdr last {TAIL} rows (step, mdr):")
        for step, val in tail:
            print(f"   {int(step):3d}  {val:.10f}")
        if bootstrapped:
            print("golden       : bootstrapped reference/FSR_mdr.csv (first run)")
        print(f"max abs diff : {max_abs_diff:.3e}  (tol {TOL:.0e})")
        print(f"RESULT       : {'PASS' if ok else 'FAIL'}")

        # transparency artifact: outliers + beta + scale (long format, language-neutral)
        with open(reference_dir / "FSR_check.csv", "w", newline="") as f:
            w = csv.writer(f)
            w.writerow(["field", "index", "value"])
            for i, b in enumerate(res["beta"]):
                w.writerow(["beta", i, b])
            w.writerow(["scale", 0, res["scale"]])
            for i, o in enumerate(res["outliers"]):
                w.writerow(["outlier", i, int(o)])

        # Keep the engine (and the figure windows) alive until the user closes
        # them: blocking is driven MATLAB-side (uiwait), uniform with R/Julia where
        # reading a key cannot work (the embedded engine hijacks stdin). Gated on
        # an interactive terminal so piped / CI runs never hang.
        if PLOTS and sys.stdin.isatty():
            print("Close the FSR figure window(s) to stop the engine and finish...")
            bridge.wait_for_figures(eng)

        return 0 if ok else 1
    finally:
        bridge.stop_engine(eng)


if __name__ == "__main__":
    raise SystemExit(main())
