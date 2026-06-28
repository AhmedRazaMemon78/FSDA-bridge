# Layer-2 Julia surface for spec 014. The actual MATLAB/FSDA call stays in the
# Python bridge (code/getYahoo/bridge.py); this file owns PythonCall setup and
# Julia-side conversions. It mirrors bridge.R (spec 015) one-for-one:
# start_bridge / get_yahoo / timerange_window / stop_bridge / bridge_diagnostics
# over an opaque handle bundling the imported Python `bridge` module and the live
# engine. It is the `getYahoo` sibling of the spec-008 FSR Julia surface.
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
        candidates = [wd, joinpath(wd, "code", "getYahoo")]
        idx = findfirst(c -> isfile(joinpath(c, "bridge.py")), candidates)
        idx === nothing && error(
            "Cannot locate code/getYahoo/bridge.py next to bridge.jl or under the " *
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

# --- Opaque handle (the bridge.R `fsda_getyahoo_bridge` list, as a struct) ----
struct GetYahooBridge
    module_::Py     # imported Python `bridge` module
    engine::Py      # live matlab.engine session
    python::String  # interpreter PythonCall is bound to
    bridge_dir::String
end

# --- Julia-side input validation (fail before crossing into Python) ----------
function _validate_tickers(tickers)
    # bridge.py performs the matching authoritative checks (and the allow-list)
    # before calling MATLAB; this guard just gives a Julia-side error first.
    ts = tickers isa AbstractString ? [String(tickers)] : String.(collect(tickers))
    isempty(ts) && error("at least one ticker is required.")
    return ts
end

function _validate_bridge(bridge)
    (bridge isa GetYahooBridge) ||
        error("bridge must be a handle returned by start_bridge().")
end

# --- Lifecycle ---------------------------------------------------------------
"""
    start_bridge(; python = get(ENV, "FSDA_DEV_VENV", ""), fsda_root = nothing)

Import the local Python `bridge` and start a reusable MATLAB engine session,
returning an opaque `GetYahooBridge` handle. PythonCall is already bound to the
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
    # target (e.g. FSR / FSRaddt) and force THIS target's dir to the front of
    # sys.path, so code/getYahoo/bridge.py is (re)loaded fresh. Without this, using
    # two targets in one Julia session returns the first-imported module
    # (AttributeError on the other target's helpers) — the PythonCall analogue of
    # the reticulate fix.
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

    return GetYahooBridge(module_, engine, _PYTHON_EXE, _BRIDGE_DIR)
end

"""
    get_yahoo(bridge, tickers; plots=0, msg=0, last_period=nothing, interval=nothing)
        -> Vector{NamedTuple}

Run FSDA `getYahoo(ticker, ...)` through the Python bridge and return one
NamedTuple per ticker (the struct-array crossing): `Ticker`, `Success`,
`intervalActual`, `TimeZone`, `Message`, `tt_height`, `n_indicators`. The full
timetable / Indicators decomposition stays Python-side; the deterministic gate
value comes from `timerange_window`. `plots`/`msg` default to off; set them to open
one live three-panel figure per ticker (keep the bridge alive — see
`render_figures`) and route getYahoo's messages to this terminal.
"""
function get_yahoo(bridge, tickers; plots::Integer = 0, msg::Integer = 0,
                   last_period = nothing, interval = nothing)
    _validate_bridge(bridge)
    ts = _validate_tickers(tickers)
    res = bridge.module_.get_yahoo(bridge.engine, pylist(ts);
                                   plots = plots, msg = msg,
                                   last_period = last_period, interval = interval)
    out = NamedTuple[]
    for el in res   # PythonCall iterates the Python list element-wise
        tt = el["TT"]
        push!(out, (
            Ticker = pyconvert(String, el["Ticker"]),
            Success = pyconvert(Bool, el["Success"]),
            intervalActual = pyconvert(String, el["intervalActual"]),
            TimeZone = pyconvert(String, el["TimeZone"]),
            Message = pyconvert(String, el["Message"]),
            tt_height = pyconvert(Int, pybuiltins.len(tt["time"])),
            n_indicators = pyconvert(Int, pybuiltins.len(el["Indicators"])),
        ))
    end
    return out
end

"""
    timerange_window(bridge, idx, t0, t1) -> NamedTuple

Deterministic gate oracle: run the owner's exact `timerange` snippet MATLAB-side on
struct-array element `idx` (1-based) and return the matched bar(s) as
`(time::Vector{String}, ohlcv::Matrix{Float64})` (columns Open, High, Low, Close,
Volume). Call `get_yahoo` first so `out` is in the MATLAB workspace.
"""
function timerange_window(bridge, idx::Integer, t0::AbstractString, t1::AbstractString)
    _validate_bridge(bridge)
    win = bridge.module_.timerange_window(bridge.engine, idx, String(t0), String(t1))
    times = pyconvert(Vector{String}, win["time"])
    m = length(times)
    M = Matrix{Float64}(undef, m, 5)
    for (j, k) in enumerate(("Open", "High", "Low", "Close", "Volume"))
        col = pyconvert(Vector{Float64}, win[k])
        length(col) == m || error("window column ", k, " length mismatch")
        M[:, j] = col
    end
    return (time = times, ohlcv = M)
end

"""
    render_figures(bridge)

Force any open MATLAB figures (from `get_yahoo(...; plots=…)`) to paint. Figures
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

Julia / PythonCall / Python / MATLAB / matlabengine / getYahoo-path details. MATLAB
values go through the Python helpers `bridge.matlab_version(eng)` and
`bridge.which_getyahoo(eng)` so PythonCall never probes engine method signatures.
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
        getyahoo_path = pyconvert(String, bridge.module_.which_getyahoo(bridge.engine)),
        bridge_dir = bridge.bridge_dir,
        requested_python = bridge.python,
    )
end
