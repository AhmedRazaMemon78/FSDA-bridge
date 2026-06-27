# Layer-2 Julia surface for spec 002. The actual MATLAB/FSDA call stays in the
# Python bridge (code/mahalFS/bridge.py); this file owns PythonCall setup and
# Julia-side shape checks. It mirrors bridge.R (spec 003) one-for-one:
# start_bridge / mahal_fs / stop_bridge / bridge_diagnostics over an opaque
# handle that bundles the imported Python `bridge` module and the live engine.
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
        candidates = [wd, joinpath(wd, "code", "mahalFS")]
        idx = findfirst(c -> isfile(joinpath(c, "bridge.py")), candidates)
        idx === nothing && error(
            "Cannot locate code/mahalFS/bridge.py next to bridge.jl or under the " *
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

# --- Opaque handle (the bridge.R `fsda_mahalfs_bridge` list, as a struct) -----
struct MahalFSBridge
    module_::Py     # imported Python `bridge` module
    engine::Py      # live matlab.engine session
    python::String  # interpreter PythonCall is bound to
    bridge_dir::String
end

# --- Julia-side input validation (fail before crossing into Python) ----------
function _as_float_matrix(x, name)
    (x isa AbstractMatrix) || error(name, " must be a 2D numeric matrix.")
    return Matrix{Float64}(x)
end

function _validate_inputs(Y, MU, SIGMA)
    # bridge.py performs the matching authoritative checks before calling MATLAB;
    # these guards just give a Julia-side error before the boundary crossing.
    Ym = _as_float_matrix(Y, "Y")
    n, v = size(Ym)
    (n >= 1 && v >= 1) || error("Y must have at least one row and one column.")

    local MUm
    if MU isa AbstractMatrix
        MUm = Matrix{Float64}(MU)
        (size(MUm, 1) == 1 && size(MUm, 2) == v) ||
            error("MU must be length ", v, " or a 1 x ", v, " numeric matrix.")
    elseif MU isa AbstractVector
        length(MU) == v ||
            error("MU must be length ", v, " or a 1 x ", v, " numeric matrix.")
        MUm = reshape(Vector{Float64}(MU), 1, v)
    else
        error("MU must be a numeric vector or one-row numeric matrix.")
    end

    SIGMAm = _as_float_matrix(SIGMA, "SIGMA")
    (size(SIGMAm, 1) == v && size(SIGMAm, 2) == v) ||
        error("SIGMA must be a ", v, " x ", v, " numeric matrix.")

    return (Y = Ym, MU = MUm, SIGMA = SIGMAm)
end

function _validate_bridge(bridge)
    (bridge isa MahalFSBridge) ||
        error("bridge must be a handle returned by start_bridge().")
end

# --- Lifecycle ---------------------------------------------------------------
"""
    start_bridge(; python = get(ENV, "FSDA_DEV_VENV", ""), fsda_root = nothing)

Import the local Python `bridge` and start a reusable MATLAB engine session,
returning an opaque `MahalFSBridge` handle. PythonCall is already bound to the
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
    # target (e.g. Score) and force THIS target's dir to the front of sys.path,
    # so code/mahalFS/bridge.py is (re)loaded fresh. Without this, using two targets
    # in one Julia session returns the first-imported module (AttributeError on the
    # other target's helpers) — the PythonCall analogue of the reticulate fix.
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

    return MahalFSBridge(module_, engine, _PYTHON_EXE, _BRIDGE_DIR)
end

"""
    mahal_fs(bridge, Y, MU, SIGMA) -> Vector{Float64}

Return the FSDA squared Mahalanobis distances as a plain Julia vector of length
`size(Y, 1)`.
"""
function mahal_fs(bridge, Y, MU, SIGMA)
    _validate_bridge(bridge)
    inp = _validate_inputs(Y, MU, SIGMA)
    # PythonCall passes the Julia matrices to Python keeping their logical shape
    # (n, v) (column-major / F-contiguous; numpy handles contiguity), so no
    # flatten/transpose here — bridge.py's shape guards are authoritative. The
    # non-square fixture (n=5, v=2) would surface any accidental transpose.
    d_py = bridge.module_.mahal_fs(bridge.engine, inp.Y, inp.MU, inp.SIGMA)
    # PythonCall does NOT auto-convert the return; convert the numpy (n,)
    # explicitly and verify length. No silent reshape.
    d = pyconvert(Vector{Float64}, d_py)
    length(d) == size(inp.Y, 1) ||
        error("expected FSDA output length ", size(inp.Y, 1), ", got ", length(d), ".")
    return d
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

Julia / PythonCall / Python / MATLAB / matlabengine / mahalFS-path details.
MATLAB-specific values go through the Python helpers `bridge.matlab_version(eng)`
and `bridge.which_mahalfs(eng)` so PythonCall never probes engine method
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
        mahalfs_path = pyconvert(String, bridge.module_.which_mahalfs(bridge.engine)),
        bridge_dir = bridge.bridge_dir,
        requested_python = bridge.python,
    )
end
