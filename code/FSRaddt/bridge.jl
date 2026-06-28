# Layer-2 Julia surface for spec 011. The actual MATLAB/FSDA call stays in the
# Python bridge (code/FSRaddt/bridge.py); this file owns PythonCall setup and
# Julia-side shape checks. It mirrors bridge.R (spec 012) one-for-one:
# start_bridge / fsraddt / stop_bridge / bridge_diagnostics over an opaque handle
# that bundles the imported Python `bridge` module and the live engine. It is the
# `FSRaddt` sibling of the spec-008 FSR Julia surface.
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
        candidates = [wd, joinpath(wd, "code", "FSRaddt")]
        idx = findfirst(c -> isfile(joinpath(c, "bridge.py")), candidates)
        idx === nothing && error(
            "Cannot locate code/FSRaddt/bridge.py next to bridge.jl or under the " *
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

# --- Opaque handle (the bridge.R `fsda_fsraddt_bridge` list, as a struct) -----
struct FSRaddtBridge
    module_::Py     # imported Python `bridge` module
    engine::Py      # live matlab.engine session
    python::String  # interpreter PythonCall is bound to
    bridge_dir::String
end

# --- Julia-side input validation (fail before crossing into Python) ----------
function _validate_inputs(y, X)
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

    (X isa AbstractMatrix) || error("X must be a 2D numeric matrix.")
    Xm = Matrix{Float64}(X)
    size(Xm, 1) == n ||
        error("X must have ", n, " rows to match y, got ", size(Xm, 1), ".")

    return (y = yv, X = Xm)
end

function _validate_bridge(bridge)
    (bridge isa FSRaddtBridge) ||
        error("bridge must be a handle returned by start_bridge().")
end

# --- Lifecycle ---------------------------------------------------------------
"""
    start_bridge(; python = get(ENV, "FSDA_DEV_VENV", ""), fsda_root = nothing)

Import the local Python `bridge` and start a reusable MATLAB engine session,
returning an opaque `FSRaddtBridge` handle. PythonCall is already bound to the
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

    # Python caches imported modules by their bare name, and every FSDA target's
    # Layer-1 file is named bridge.py. Evict any 'bridge' cached by a different
    # target (e.g. FSR / Score) and force THIS target's dir to the front of
    # sys.path, so code/FSRaddt/bridge.py is (re)loaded fresh. Without this, using
    # two targets in one Julia session returns the first-imported module
    # (AttributeError on the other target's helpers) — the PythonCall analogue of
    # the reticulate fix. FSRaddt is the 5th bridge.py, so this matters.
    sys = pyimport("sys")
    sys.modules.pop("bridge", nothing)
    while pyconvert(Bool, sys.path.__contains__(_BRIDGE_DIR))
        sys.path.remove(_BRIDGE_DIR)   # drop stale duplicates of this dir
    end
    sys.path.insert(0, _BRIDGE_DIR)    # this target's bridge.py wins
    module_ = pyimport("bridge")

    engine = if fsda_root === nothing || isempty(String(fsda_root))
        module_.start_engine()
    else
        module_.start_engine(fsda_root = String(fsda_root))
    end

    return FSRaddtBridge(module_, engine, _PYTHON_EXE, _BRIDGE_DIR)
end

"""
    fsraddt(bridge, y, X; nsamp=0, intercept=true, plots=0, msg=0,
            DataVars=nothing, h=nothing, init=nothing, lms=1) -> NamedTuple

Run FSDA `FSRaddt` through the Python bridge and return the key fields converted to
Julia: `Tdel` (m×(k+1) `Matrix{Float64}` of [step, deletion t-stat per variable]),
`S2del` (m×(k+1) `Matrix{Float64}`), `bs` (p×k `Matrix{Int}`, 1-based initial
subset), `Un` (`Vector` of k `Matrix{Float64}` from the MATLAB cell), `la` (k-vector
of 1-based tested-column indices). `nsamp=0` enumerates all subsets (deterministic).
`plots`/`msg` default to off; set them to open a live MATLAB figure window (keep the
bridge alive — see `render_figures`) and route FSRaddt's messages to this terminal.
"""
function fsraddt(bridge, y, X; nsamp::Integer = 0, intercept::Bool = true,
                 plots::Integer = 0, msg::Integer = 0,
                 DataVars = nothing, h = nothing, init = nothing, lms::Integer = 1)
    _validate_bridge(bridge)
    inp = _validate_inputs(y, X)
    # PythonCall passes the Julia vector/matrix to Python keeping their logical
    # shape; bridge.py's guards (shapes, struct-field reads, cell->list Un
    # normalization, 1-based bs/la) and its plots/msg handling are authoritative.
    # nothing -> None.
    res = bridge.module_.fsraddt(bridge.engine, inp.y, inp.X;
                                 nsamp = nsamp, intercept = intercept,
                                 plots = plots, msg = msg,
                                 DataVars = DataVars, h = h, init = init, lms = lms)
    # PythonCall does NOT auto-convert; convert each field explicitly. No reshape.
    la = pyconvert(Vector{Int}, res["la"])
    Tdel = pyconvert(Matrix{Float64}, res["Tdel"])
    (ndims(Tdel) == 2 && size(Tdel, 2) == 1 + length(la)) ||
        error("expected FSRaddt Tdel to be (m, 1+", length(la), "), got ", size(Tdel))
    # out.Un crosses as a Python list of numpy arrays; iterate it in Julia
    # (PythonCall makes a Python list iterable) and convert each cell element.
    Un = Matrix{Float64}[pyconvert(Matrix{Float64}, u) for u in res["Un"]]
    return (
        Tdel = Tdel,
        S2del = pyconvert(Matrix{Float64}, res["S2del"]),
        bs = pyconvert(Matrix{Int}, res["bs"]),
        Un = Un,
        la = la,
    )
end

"""
    render_figures(bridge)

Force any open MATLAB figures (from `fsraddt(...; plots=…)`) to paint. Figures
close when the engine quits, so keep the bridge alive (don't `stop_bridge`) until
you have viewed them.
"""
function render_figures(bridge)
    _validate_bridge(bridge)
    bridge.module_.render_figures(bridge.engine)
    return nothing
end

"""
    wait_for_figures(bridge)

Block until the user closes all open MATLAB figures. Driven MATLAB-side (`uiwait`),
so it is immune to the terminal-stdin interference under PythonCall (reading a key
from Julia does not work once the engine is embedded). Returns at once if no
figures are open.
"""
function wait_for_figures(bridge)
    _validate_bridge(bridge)
    bridge.module_.wait_for_figures(bridge.engine)
    return nothing
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

Julia / PythonCall / Python / MATLAB / matlabengine / FSRaddt-path details. MATLAB
values go through the Python helpers `bridge.matlab_version(eng)` and
`bridge.which_fsraddt(eng)` so PythonCall never probes engine method signatures.
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
        fsraddt_path = pyconvert(String, bridge.module_.which_fsraddt(bridge.engine)),
        bridge_dir = bridge.bridge_dir,
        requested_python = bridge.python,
    )
end
