# Spec-011 agreement check: the Julia (PythonCall) surface must reproduce the
# last 5 rows of the Python/FSDA out.Tdel golden from spec 010. Mirrors
# check_FSR_jl.jl (spec 008).
#
# Run (PythonCall installed in the active Julia env, FSDA_DEV_VENV → the venv's
# python that has matlabengine):
#     export FSDA_DEV_VENV="/path/to/fsda_dev_env/bin/python"   # macOS / Linux
#     julia --project=code/FSRaddt code/FSRaddt/check_FSRaddt_jl.jl [FSDA_ROOT]
#
# bridge.jl pins PythonCall to the venv, so it is included BEFORE anything else
# touches Python. The fixed input (genuine FSDA `wool`) and the Tdel golden are
# read from reference/ artifacts written by check_FSRaddt.py — run that first.

const SCRIPT_DIR = @__DIR__
include(joinpath(SCRIPT_DIR, "bridge.jl"))

using Printf

const TOL = 1e-9
const TAIL = 5   # the gate compares the last TAIL rows of out.Tdel
const PLOTS = 1  # FSRaddt plot level (0 headless; 1 shows the deletion-t figure)
const MSG = 1    # FSRaddt message level (1 routes MATLAB's progress messages here)

function load_wool(path)
    # Genuine FSDA wool fixture persisted by check_FSRaddt.py (last column = y).
    isfile(path) || error(
        "Missing fixture: ", path, ". Run code/FSRaddt/check_FSRaddt.py first.")
    lines = [strip(l) for l in readlines(path) if !isempty(strip(l))]
    length(lines) >= 2 || error("wool fixture has no data rows: ", path)
    rows = [parse.(Float64, strip.(split(l, ","))) for l in lines[2:end]]
    n = length(rows)
    ncol = length(rows[1])
    ncol >= 2 || error("wool fixture must have at least one predictor plus y.")
    M = Matrix{Float64}(undef, n, ncol)
    for i in 1:n
        M[i, :] = rows[i]
    end
    return M[:, end], M[:, 1:end-1]   # y, X
end

function load_golden_tdel(path)
    # Spec 010 owns the FSDA golden; this check reproduces its last TAIL rows.
    # The golden is variable-width: header step,t1,t2,... (one t per tested var).
    isfile(path) || error(
        "Missing spec-010 golden artifact: ", path,
        ". Run code/FSRaddt/check_FSRaddt.py first.")
    lines = [strip(l) for l in readlines(path) if !isempty(strip(l))]
    length(lines) >= 2 || error("Spec-010 golden has no data rows: ", path)
    header = strip.(split(lines[1], ","))
    header[1] == "step" ||
        error("Spec-010 golden header must start with step; got ", header)
    rows = [parse.(Float64, strip.(split(l, ","))) for l in lines[2:end]]
    m = length(rows)
    k1 = length(rows[1])
    M = Matrix{Float64}(undef, m, k1)
    for i in 1:m
        M[i, :] = rows[i]
    end
    return M
end

function write_artifact(path, tail, gtail, abs_diff)
    open(path, "w") do io
        ncol = size(tail, 2)
        cols = ["t$(j)_surface,t$(j)_golden" for j in 1:(ncol - 1)]
        println(io, "step,", join(cols, ","), ",max_abs_diff")
        for i in 1:size(tail, 1)
            vals = Any[Int(tail[i, 1])]
            for j in 2:ncol
                push!(vals, tail[i, j]); push!(vals, gtail[i, j])
            end
            push!(vals, abs_diff[i])
            println(io, join(vals, ","))
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
    println("FSRaddt path : ", d.fsraddt_path)
end

function main()
    reference_dir = joinpath(SCRIPT_DIR, "reference")
    y, X = load_wool(joinpath(reference_dir, "wool.csv"))
    golden = load_golden_tdel(joinpath(reference_dir, "FSRaddt_Tdel.csv"))

    fsda_root = length(ARGS) >= 1 && !isempty(ARGS[1]) ? ARGS[1] : nothing
    bridge = start_bridge(fsda_root = fsda_root)
    try
        diagnostics = bridge_diagnostics(bridge)
        res = fsraddt(bridge, y, X; nsamp = 0, intercept = true, plots = PLOTS, msg = MSG)

        Tdel = res.Tdel
        (size(Tdel, 1) >= TAIL && size(golden, 1) >= TAIL) ||
            error("need at least ", TAIL, " Tdel rows on both sides.")
        size(Tdel, 2) == size(golden, 2) ||
            error("Tdel width ", size(Tdel, 2), " != golden width ", size(golden, 2))
        tail = Tdel[end-TAIL+1:end, :]
        gtail = golden[end-TAIL+1:end, :]
        abs_diff = vec(maximum(abs.(tail .- gtail), dims = 2))
        max_abs_diff = maximum(abs_diff)
        ok = size(tail) == size(gtail) && all(abs_diff .<= TOL)

        isdir(reference_dir) || mkpath(reference_dir)
        write_artifact(joinpath(reference_dir, "FSRaddt_jl_check.csv"), tail, gtail, abs_diff)

        println("=== spec 011: Julia PythonCall FSRaddt agreement check ===")
        print_diagnostics(diagnostics)
        println("tested vars  : la(1-b)=", res.la, "  (k=", length(res.la), ")")
        println("Un cells     : ", length(res.Un), " (cell->list); shapes ",
                [size(u) for u in res.Un])
        println("Tdel last ", TAIL, " rows (step, deletion t-stats):")
        for i in 1:TAIL
            cells = join([@sprintf("%.6f", tail[i, j]) for j in 2:size(tail, 2)], "  ")
            @printf("   %3d  %s\n", Int(tail[i, 1]), cells)
        end
        println("max abs diff : ", @sprintf("%.3e", max_abs_diff), "  (tol 1e-09)")
        println("RESULT       : ", ok ? "PASS" : "FAIL")

        # Keep the engine (and the figure window) alive until the user closes it:
        # blocking is driven MATLAB-side (uiwait), since reading a key from Julia
        # cannot work once the engine is embedded via PythonCall. Gated on an
        # interactive terminal so piped / CI runs never hang.
        if PLOTS != 0 && stdin isa Base.TTY
            println("Close the FSRaddt figure window(s) to stop the engine and finish...")
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
