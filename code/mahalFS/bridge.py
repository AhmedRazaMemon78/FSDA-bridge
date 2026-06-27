"""
Layer-1 bridge for FSDA `mahalFS` (squared Mahalanobis distances).

Python -> matlab.engine -> MATLAB + FSDA

This module starts a MATLAB engine session from Python, converts NumPy arrays
into MATLAB-compatible arrays, calls the real FSDA `mahalFS` function, and
converts the result back into a NumPy array.

FSDA `mahalFS(Y, MU, SIGMA)` returns the squared Mahalanobis distance for each
row of Y:

    d_i = (y_i - MU) * inv(SIGMA) * (y_i - MU)'

where:
- Y is an n x v data matrix
- MU is a 1 x v location vector
- SIGMA is a v x v covariance matrix

The returned values are squared distances, not ordinary distances.

See spec 001 (specs/001-matlab-engine-mahalFS.md) and CONSTITUTION.md.
"""

from __future__ import annotations

# NumPy is used for array handling, validation, and conversion.
import numpy as np

# matlab provides MATLAB-compatible data types such as matlab.double.
import matlab

# matlab.engine allows Python to start and communicate with MATLAB.
import matlab.engine


def start_engine(fsda_root: str | None = None):
    """
    Start a MATLAB engine session and check that FSDA `mahalFS` is available.

    Parameters
    ----------
    fsda_root : str or None, optional
        Path to the FSDA installation directory.

        If FSDA is already installed as a MATLAB Add-On, this can be None
        because MATLAB should already know where `mahalFS` is.

        If FSDA is not on the MATLAB path, pass the FSDA root directory here.
        The function will add it recursively using addpath(genpath(...)).

    Returns
    -------
    eng
        A running MATLAB engine object.

    Raises
    ------
    RuntimeError
        If MATLAB starts successfully but `mahalFS` cannot be found.
    """

    # Start a new MATLAB session from Python.
    eng = matlab.engine.start_matlab()

    # If the caller provided the FSDA installation directory, add it and all
    # its subfolders to the MATLAB path.
    if fsda_root is not None:
        eng.addpath(eng.genpath(fsda_root), nargout=0)

    # Check whether MATLAB can resolve the function `mahalFS`.
    # eng.which("mahalFS") returns the file path if found, otherwise empty.
    if not eng.which("mahalFS"):

        # Close MATLAB before raising the error, to avoid leaving an unused
        # MATLAB process running.
        eng.quit()

        raise RuntimeError(
            "FSDA `mahalFS` not found on the MATLAB path. Install the FSDA Add-On "
            "in MATLAB, or pass fsda_root=<FSDA install dir>."
        )

    # Return the active MATLAB engine session.
    return eng


def mahal_fs(eng, Y: np.ndarray, MU: np.ndarray, SIGMA: np.ndarray) -> np.ndarray:
    """
    Call FSDA `mahalFS(Y, MU, SIGMA)` through the MATLAB engine.

    Parameters
    ----------
    eng
        Active MATLAB engine object.

    Y : numpy.ndarray
        Data matrix with shape (n, v), where:
        - n is the number of observations
        - v is the number of variables

    MU : numpy.ndarray
        Location vector with shape (v,) or (1, v).

        If MU is passed as a one-dimensional array, it is reshaped to
        MATLAB-compatible shape (1, v).

    SIGMA : numpy.ndarray
        Covariance matrix with shape (v, v).

    Returns
    -------
    numpy.ndarray
        One-dimensional array with shape (n,) containing the squared
        Mahalanobis distances.

    Notes
    -----
    This function checks all shapes at the Python/MATLAB boundary.
    It does not silently reshape invalid inputs.
    """

    # Convert inputs to NumPy arrays of type float.
    # This ensures that values can be converted cleanly to matlab.double.
    Y = np.asarray(Y, dtype=float)
    MU = np.asarray(MU, dtype=float)
    SIGMA = np.asarray(SIGMA, dtype=float)

    # Y must be a two-dimensional matrix.
    if Y.ndim != 2:
        raise ValueError(f"Y must be a 2D matrix, got shape {Y.shape}")

    # Extract the number of observations and variables.
    n, v = Y.shape

    # MU may be passed as a one-dimensional vector of length v.
    # Convert it to a row vector with shape (1, v).
    if MU.ndim == 1:
        MU = MU.reshape(1, -1)

    # If MU is not one-dimensional, then it must already be a 2D row vector.
    elif MU.ndim != 2 or MU.shape[0] != 1:
        raise ValueError(f"MU must be shape ({v},) or (1, {v}), got {MU.shape}")

    # After normalization, MU must have exactly shape (1, v).
    if MU.shape != (1, v):
        raise ValueError(f"MU must be shape ({v},) or (1, {v}), got {MU.shape}")

    # SIGMA must be a square covariance matrix with dimensions v x v.
    if SIGMA.shape != (v, v):
        raise ValueError(f"SIGMA must be shape ({v}, {v}), got {SIGMA.shape}")

    # Convert NumPy arrays to nested Python lists, then to matlab.double.
    # matlab.double is the MATLAB Engine representation of a MATLAB double array.
    Ym = matlab.double(Y.tolist())
    MUm = matlab.double(MU.tolist())
    SIGMAm = matlab.double(SIGMA.tolist())

    # Call the actual FSDA MATLAB function.
    # This computes squared Mahalanobis distances.
    d = eng.mahalFS(Ym, MUm, SIGMAm)

    # Convert MATLAB output back to a NumPy array.
    # reshape(-1) flattens the result into a one-dimensional vector.
    d = np.asarray(d, dtype=float).reshape(-1)

    # FSDA should return one distance for each row of Y.
    # If not, something unexpected happened inside the MATLAB call.
    if d.shape != (n,):
        raise RuntimeError(f"expected FSDA output shape ({n},), got {d.shape}")

    # Return the squared Mahalanobis distances.
    return d


def stop_engine(eng) -> None:
    """
    Shut down the MATLAB engine session.

    Parameters
    ----------
    eng
        Active MATLAB engine object.
    """

    # Close the MATLAB process started by Python.
    eng.quit()


def matlab_version(eng) -> str:
    """
    Return the MATLAB version string for diagnostics.

    Parameters
    ----------
    eng
        Active MATLAB engine object.

    Returns
    -------
    str
        MATLAB version string.
    """

    # Ask MATLAB for its version and convert the result to a Python string.
    return str(eng.version())


def which_mahalfs(eng) -> str:
    """
    Return the resolved path of FSDA `mahalFS` for diagnostics.

    Parameters
    ----------
    eng
        Active MATLAB engine object.

    Returns
    -------
    str
        Full path to the `mahalFS` function, if MATLAB can find it.
    """

    # MATLAB `which` returns the file path of the function that will be called.
    return str(eng.which("mahalFS"))