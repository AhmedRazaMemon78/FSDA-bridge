# Layer-2 Julia surface for spec 005. The actual MATLAB/FSDA call stays in the
# Python bridge (code/Score/bridge.py); this file owns PythonCall setup and
# Julia-side shape checks. It mirrors bridge.R (spec 006) one-for-one:
# start_bridge / score / stop_bridge / bridge_diagnostics over an opaque handle
# that bundles the imported Python `bridge` module and the live engine. It is the
# `Score` sibling of the spec-002 `mahalFS` Julia surface.
#
# CRITICAL: PythonCall binds its interpreter at load time (`using PythonCall`),
# so the interpreter is resolved and exported via ENV *before* that line — there
# is no second chance. One-shot caveat: if PythonCall was already initialised in
# this Julia session against a different interpreter it cannot be rebound; start
# a fresh `julia` process to switch interpreters.

# --- Locate this file's directory (bridge.py must sit next to it) ------------
const _BRIDGE_DIR = let
    here = @__DIR__
    if isfile(joinpath(here, "bridge.py"))
        abspath(here)
    else
        # Fall back to common working dirs (repo root or the target folder).
        wd = pwd()
        candidates = [wd, joinpath(wd, "code", "Score")]
        idx = findfirst(c -> isfile(joinpath(c, "bridge.py")), candidates)
        idx === nothing && error(
            "Cannot locate code/Score/bridge.py next to bridge.jl or under the " *
            "working directory; run from the repo or the target directory.")
        abspath(candidates[idx])
    end
end

# --- Interpreter resolution (no machine-specific path committed) -------------
function _resolve_python(python::AbstractString)
    # Mirror bridge.R's precedence: an explicit value (FSDA_DEV_VENV) wins, else
    # the active python/python3 on PATH (so macOS works too), else a clear error.
    # An explicit value may be a python executable, a virtualenv root, or a
    # conda-style root; turn whatever we are given into a concrete executable.
    p = String(python)
    if isempty(p)
        found = Sys.which("python")
        found === nothing && (found = Sys.which("python3"))
        found === nothing && error(
            "No Python interpreter found. Set FSDA_DEV_VENV to your venv's python " *
            "executable (Scripts\\python.exe on Windows, bin/python on macOS) that " *
            "has matlabengine installed.")
        return abspath(found)
    end
    isfile(p) && return abspath(p)               # direct executable
    if isdir(p)                                  # venv / conda root
        nested = [
            joinpath(p, "python.exe"),            # conda root (Windows)
            joinpath(p, "Scripts", "python.exe"), # venv (Windows)
            joinpath(p, "bin", "python"),         # venv / conda (POSIX)
            joinpath(p, "bin", "python3"),
        ]
        idx = findfirst(isfile, nested)
        idx !== nothing && return abspath(nested[idx])
    end
    error("Python venv or executable not found: ", p,
          ". Set FSDA_DEV_VENV to the project venv or a Python executable with matlabengine.")
end

# Resolve the interpreter and pin PythonCall to it BEFORE `using PythonCall`.
const _PYTHON_EXE = _resolve_python(get(ENV, "FSDA_DEV_VENV", ""))
ENV["JULIA_CONDAPKG_BACKEND"] = "Null"   # do not let CondaPkg manage a Python
ENV["JULIA_PYTHONCALL_EXE"] = _PYTHON_EXE

using PythonCall

const _PYTHONCALL_VERSION = try
    string(pkgversion(PythonCall))
catch
    "n/a"
end

# FSDA Score default transformation parameters (mirrors bridge.py DEFAULT_LA).
const _DEFAULT_LA = Float64[-1.0, -0.5, 0.0, 0.5, 1.0]

# --- Opaque handle (the bridge.R `fsda_score_bridge` list, as a struct) -------
struct ScoreBridge
    module_::Py     # imported Python `bridge` module
    engine::Py      # live matlab.engine session
    python::String  # interpreter PythonCall is bound to
    bridge_dir::String
end

# --- Julia-side input validation (fail before crossing into Python) ----------
function _validate_inputs(y, X, la)
    # bridge.py performs the matching authoritative checks before calling MATLAB;
    # these guards just give a Julia-side error before the boundary crossing.
    yv = if y isa AbstractVector
        Vector{Float64}(y)
    elseif y isa AbstractMatrix && size(y, 2) == 1
        Vector{Float64}(vec(y))
    else
        error("y must be a numeric vector or n x 1 matrix.")
    end
    n = length(yv)
    n >= 1 || error("y must have at least one element.")
    all(yv .> 0) || error("y must be strictly positive (Box-Cox transform).")

    (X isa AbstractMatrix) || error("X must be a 2D numeric matrix.")
    Xm = Matrix{Float64}(X)
    size(Xm, 1) == n ||
        error("X must have ", n, " rows to match y, got ", size(Xm, 1), ".")

    lav = if la === nothing
        copy(_DEFAULT_LA)
    elseif la isa AbstractVector
        Vector{Float64}(la)
    else
        error("la must be a numeric vector.")
    end
    length(lav) >= 1 || error("la must be a non-empty numeric vector.")

    return (y = yv, X = Xm, la = lav)
end

function _validate_bridge(bridge)
    (bridge isa ScoreBridge) ||
        error("bridge must be a handle returned by start_bridge().")
end

# --- Lifecycle ---------------------------------------------------------------
"""
    start_bridge(; python = get(ENV, "FSDA_DEV_VENV", ""), fsda_root = nothing)

Import the local Python `bridge` and start a reusable MATLAB engine session,
returning an opaque `ScoreBridge` handle. PythonCall is already bound to the
interpreter resolved at load time; passing a different `python` here cannot
rebind it, so it only warns and records what was actually used.
"""
function start_bridge(; python::AbstractString = get(ENV, "FSDA_DEV_VENV", ""),
                       fsda_root = nothing)
    requested = isempty(String(python)) ? _PYTHON_EXE : _resolve_python(python)
    if requested != _PYTHON_EXE
        @warn("PythonCall is already bound to a different interpreter; the " *
              "`python` argument cannot rebind it in this session. Start a fresh " *
              "`julia` process to switch interpreters.",
              bound = _PYTHON_EXE, requested = requested)
    end

    sys = pyimport("sys")
    on_path = any(==(_BRIDGE_DIR), (pyconvert(String, p) for p in sys.path))
    on_path || sys.path.insert(0, _BRIDGE_DIR)   # local bridge.py wins
    module_ = pyimport("bridge")

    engine = if fsda_root === nothing || isempty(String(fsda_root))
        module_.start_engine()
    else
        module_.start_engine(fsda_root = String(fsda_root))
    end

    return ScoreBridge(module_, engine, _PYTHON_EXE, _BRIDGE_DIR)
end

"""
    score(bridge, y, X; la = nothing, intercept = true) -> Vector{Float64}

Return the FSDA Box-Cox score-test t-statistics as a plain Julia vector of length
`length(la)` (default la = [-1, -0.5, 0, 0.5, 1]).
"""
function score(bridge, y, X; la = nothing, intercept::Bool = true)
    _validate_bridge(bridge)
    inp = _validate_inputs(y, X, la)
    # PythonCall passes the Julia vector/matrix to Python keeping their logical
    # shape; bridge.py's guards (y>0, X rows, struct field read) are authoritative.
    # Keyword args cross as Python keyword args.
    sc_py = bridge.module_.score(bridge.engine, inp.y, inp.X;
                                 la = inp.la, intercept = intercept)
    # PythonCall does NOT auto-convert the return; convert the numpy (len(la),)
    # explicitly and verify length. No silent reshape.
    sc = pyconvert(Vector{Float64}, sc_py)
    length(sc) == length(inp.la) ||
        error("expected FSDA Score length ", length(inp.la), ", got ", length(sc), ".")
    return sc
end

"""
    stop_bridge(bridge)

Quit the MATLAB engine (startup is expensive, so callers control shutdown).
"""
function stop_bridge(bridge)
    _validate_bridge(bridge)
    bridge.module_.stop_engine(bridge.engine)
    return nothing
end

"""
    bridge_diagnostics(bridge) -> NamedTuple

Julia / PythonCall / Python / MATLAB / matlabengine / Score-path details.
MATLAB-specific values go through the Python helpers `bridge.matlab_version(eng)`
and `bridge.which_score(eng)` so PythonCall never probes engine method
signatures directly.
"""
function bridge_diagnostics(bridge)
    _validate_bridge(bridge)
    sys = pyimport("sys")
    metadata = pyimport("importlib.metadata")
    engine_pkg = try
        pyconvert(String, metadata.version("matlabengine"))
    catch
        "n/a"
    end
    return (
        julia = string(VERSION),
        pythoncall = _PYTHONCALL_VERSION,
        python = pyconvert(String, sys.executable),
        python_version = pyconvert(String, pyimport("platform").python_version()),
        matlab = pyconvert(String, bridge.module_.matlab_version(bridge.engine)),
        matlabengine = engine_pkg,
        score_path = pyconvert(String, bridge.module_.which_score(bridge.engine)),
        bridge_dir = bridge.bridge_dir,
        requested_python = bridge.python,
    )
end
