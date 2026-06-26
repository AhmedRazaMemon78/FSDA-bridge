"""Agreement check: FSDA `mahalFS` through matlab.engine vs a numpy reference.

Run with the project venv (the script's own dir is put on sys.path so
`import bridge` works):

    C:\\Users\\LucaI\\fsda_dev_env\\Scripts\\python.exe code\\mahalFS\\check_mahalFS.py [FSDA_ROOT]

FSDA_ROOT is optional — pass the FSDA install dir only if `mahalFS` is not already
on the MATLAB path (FSDA is normally an Add-On). Prints PASS/FAIL, both distance
vectors, the max abs diff, and the Python / MATLAB / engine version triple; writes
inputs+outputs to reference/. This is the spec-001 agreement gate.
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


def numpy_mahal(Y: np.ndarray, MU: np.ndarray, SIGMA: np.ndarray) -> np.ndarray:
    """Reference squared Mahalanobis distances, mirroring FSDA's formula."""
    diff = Y - MU.reshape(1, -1)
    return np.sum((diff @ np.linalg.inv(SIGMA)) * diff, axis=1)


def engine_pkg_version() -> str:
    try:
        return metadata.version("matlabengine")
    except Exception:
        return "n/a"


def main() -> int:
    # fixed tiny input: n = 5, v = 2
    Y = np.array(
        [[1.0, 2.0],
         [2.0, 0.0],
         [3.0, 5.0],
         [0.0, -1.0],
         [4.0, 4.0]]
    )
    MU = np.array([2.0, 2.0])
    SIGMA = np.array([[2.0, 0.5],
                      [0.5, 1.0]])

    fsda_root = sys.argv[1] if len(sys.argv) > 1 else None

    eng = bridge.start_engine(fsda_root=fsda_root)
    matlab_version = eng.version()
    where = eng.which("mahalFS")
    d_fsda = bridge.mahal_fs(eng, Y, MU, SIGMA)
    bridge.stop_engine(eng)

    d_ref = numpy_mahal(Y, MU, SIGMA)
    max_abs_diff = float(np.max(np.abs(d_fsda - d_ref)))
    ok = bool(np.allclose(d_fsda, d_ref, rtol=0.0, atol=TOL))

    print("=== spec 001: mahalFS bridge agreement check ===")
    print(f"Python       : {platform.python_version()}")
    print(f"MATLAB       : {matlab_version}")
    print(f"engine pkg   : {engine_pkg_version()}")
    print(f"mahalFS path : {where}")
    print(f"FSDA mahalFS : {np.array2string(d_fsda, precision=10)}")
    print(f"numpy ref    : {np.array2string(d_ref, precision=10)}")
    print(f"max abs diff : {max_abs_diff:.3e}  (tol {TOL:.0e})")
    print(f"RESULT       : {'PASS' if ok else 'FAIL'}")

    out = Path(__file__).resolve().parent / "reference"
    out.mkdir(exist_ok=True)
    with open(out / "mahalFS_check.csv", "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["i", "y1", "y2", "d_fsda", "d_numpy", "abs_diff"])
        for i in range(Y.shape[0]):
            w.writerow([i + 1, Y[i, 0], Y[i, 1], d_fsda[i], d_ref[i], abs(d_fsda[i] - d_ref[i])])

    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
