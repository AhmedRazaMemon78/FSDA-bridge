# Spec-014 agreement check: the Julia (PythonCall) surface must reproduce the
# fixed-window OHLCV golden from the Python/FSDA spec 013. Mirrors check_FSR_jl.jl.
#
# Run (PythonCall installed in the active Julia env, FSDA_DEV_VENV → the venv's
# python that has matlabengine):
#     export FSDA_DEV_VENV="/path/to/fsda_dev_env/bin/python"   # macOS / Linux
#     julia --project=code/getYahoo code/getYahoo/check_getYahoo_jl.jl [FSDA_ROOT]
#
# bridge.jl pins PythonCall to the venv, so it is included BEFORE anything else
# touches Python. The fixed input (tickers + window) and the OHLCV golden are read
# from reference/ artifacts written by check_getYahoo.py — run that first.

const SCRIPT_DIR = @__DIR__
include(joinpath(SCRIPT_DIR, "bridge.jl"))

using Printf

const TOL = 1e-9
const PLOTS = 1  # getYahoo plot level (0 headless; 1 shows a figure per ticker)
const MSG = 1    # getYahoo message level (1 routes progress messages here)

_optstr(x) = pyis(x, pybuiltins.None) ? nothing : pyconvert(String, x)

function load_query(path)
    # Shared fixed input persisted by check_getYahoo.py (parsed via Python's json,
    # so no Julia JSON dependency is added).
    isfile(path) || error("Missing fixture: ", path, ". Run check_getYahoo.py first.")
    json = pyimport("json")
    q = json.loads(read(path, String))
    return (
        tickers = pyconvert(Vector{String}, q["tickers"]),
        t0 = pyconvert(String, q["t0"]),
        t1 = pyconvert(String, q["t1"]),
        last_period = _optstr(q["last_period"]),
        interval = _optstr(q["interval"]),
    )
end

function load_golden(path)
    # Spec 013 owns the OHLCV golden; this check reproduces it. Columns:
    # ticker,time,Open,High,Low,Close,Volume.
    isfile(path) || error(
        "Missing spec-013 golden artifact: ", path, ". Run check_getYahoo.py first.")
    lines = [strip(l) for l in readlines(path) if !isempty(strip(l))]
    length(lines) >= 2 || error("Spec-013 golden has no data rows: ", path)
    header = strip.(split(lines[1], ","))
    (header == ["ticker", "time", "Open", "High", "Low", "Close", "Volume"]) ||
        error("Spec-013 golden header mismatch; got ", header)
    rows = Tuple{String,String,Vector{Float64}}[]
    for l in lines[2:end]
        f = strip.(split(l, ","))
        push!(rows, (String(f[1]), String(f[2]), parse.(Float64, f[3:7])))
    end
    return rows
end

function surface_rows(bridge, res, q)
    # Run the fixed timerange window over every ticker; flatten to gate rows.
    rows = Tuple{String,String,Vector{Float64}}[]
    for (idx, r) in enumerate(res)   # 1-based, matching MATLAB out(idx)
        win = timerange_window(bridge, idx, q.t0, q.t1)
        for j in 1:length(win.time)
            push!(rows, (r.Ticker, win.time[j], collect(win.ohlcv[j, :])))
        end
    end
    return rows
end

function write_artifact(path, rows, golden, diffs)
    open(path, "w") do io
        println(io, "ticker,time,Open,High,Low,Close,Volume,abs_diff")
        for i in 1:length(rows)
            tk, t, v = rows[i]
            println(io, join((tk, t, v..., diffs[i]), ","))
        end
    end
end

function print_diagnostics(d)
    println("Julia        : ", d.julia)
    println("PythonCall   : ", d.pythoncall)
    println("Python       : ", d.python_version)
    println("Python path  : ", d.python)
    println("MATLAB       : ", d.matlab)
    println("engine pkg   : ", d.matlabengine)
    println("getYahoo path: ", d.getyahoo_path)
end

function main()
    reference_dir = joinpath(SCRIPT_DIR, "reference")
    q = load_query(joinpath(reference_dir, "getYahoo_query.json"))
    golden = load_golden(joinpath(reference_dir, "getYahoo_window.csv"))

    fsda_root = length(ARGS) >= 1 && !isempty(ARGS[1]) ? ARGS[1] : nothing
    bridge = start_bridge(fsda_root = fsda_root)
    try
        diagnostics = bridge_diagnostics(bridge)
        res = get_yahoo(bridge, q.tickers; plots = PLOTS, msg = MSG,
                        last_period = q.last_period, interval = q.interval)

        println("=== spec 014: Julia PythonCall getYahoo agreement check ===")
        print_diagnostics(diagnostics)
        println("tickers      : ", q.tickers, "  (nout=", length(res), ")")
        for r in res
            println("  ", rpad(r.Ticker, 8), " Success=", r.Success,
                    " interval=", r.intervalActual, " tz=", r.TimeZone,
                    " TT=", r.tt_height, " rows  msg='", r.Message, "'")
        end

        if !any(r.Success for r in res)
            println("SKIP         : Yahoo returned no data for any ticker ",
                    "(unreachable / offline?) -- deterministic gate not evaluated.")
            return 0
        end

        rows = surface_rows(bridge, res, q)
        if isempty(rows)
            println("window       : ", q.t0, " .. ", q.t1)
            println("RESULT       : FAIL -- no bar fell inside the fixed window ",
                    "(bar aged out? refresh t0/t1 in getYahoo_query.json).")
            return 1
        end

        labels = [(r[1], r[2]) for r in rows]
        glabels = [(g[1], g[2]) for g in golden]
        diffs = Float64[]
        ok = length(rows) == length(golden) && labels == glabels
        if ok
            for i in 1:length(rows)
                d = maximum(abs.(rows[i][3] .- golden[i][3]))
                push!(diffs, d)
            end
        end
        max_abs_diff = isempty(diffs) ? Inf : maximum(diffs)
        ok = ok && all(diffs .<= TOL)

        isdir(reference_dir) || mkpath(reference_dir)
        if !isempty(diffs)
            write_artifact(joinpath(reference_dir, "getYahoo_jl_check.csv"),
                           rows, golden, diffs)
        end

        println("window       : ", q.t0, " .. ", q.t1)
        println("fixed-window OHLCV (ticker, time, O, H, L, C, V):")
        for (tk, t, v) in rows
            @printf("  %-8s %s  %.6f %.6f %.6f %.6f %.0f\n",
                    tk, t, v[1], v[2], v[3], v[4], v[5])
        end
        println("max abs diff : ", @sprintf("%.3e", max_abs_diff), "  (tol 1e-09)")
        println("RESULT       : ", ok ? "PASS" : "FAIL")

        # Keep the engine (and the figure windows) alive until the user closes them:
        # blocking is driven MATLAB-side (uiwait), since reading a key from Julia
        # cannot work once the engine is embedded via PythonCall. Gated on an
        # interactive terminal so piped / CI runs never hang.
        if PLOTS != 0 && stdin isa Base.TTY
            println("Close the getYahoo figure window(s) to stop the engine and finish...")
            wait_for_figures(bridge)
        end

        return ok ? 0 : 1
    finally
        try
            stop_bridge(bridge)
        catch
        end
    end
end

status = try
    main()
catch e
    println(stderr, "ERROR        : ", sprint(showerror, e))
    1
end

if !isempty(PROGRAM_FILE) && abspath(PROGRAM_FILE) == abspath(@__FILE__)
    exit(status)
end
