# Spec-008 agreement check: the Julia (PythonCall) surface must reproduce the
# last 5 rows of the Python/FSDA out.mdr golden from spec 007. Mirrors
# check_Score_jl.jl.
#
# Run (PythonCall installed in the active Julia env, FSDA_DEV_VENV → the venv's
# python that has matlabengine):
#     export FSDA_DEV_VENV="/path/to/fsda_dev_env/bin/python"   # macOS / Linux
#     julia --project=code/FSR code/FSR/check_FSR_jl.jl [FSDA_ROOT]
#
# bridge.jl pins PythonCall to the venv, so it is included BEFORE anything else
# touches Python. The fixed input (genuine FSDA `stars`) and the mdr golden are
# read from reference/ artifacts written by check_FSR.py — run that first.

const SCRIPT_DIR = @__DIR__
include(joinpath(SCRIPT_DIR, "bridge.jl"))

using Printf

const TOL = 1e-9
const TAIL = 5   # the gate compares the last TAIL rows of out.mdr
const PLOTS = 1  # FSR plot level (0 headless; 1 shows the mdr figure window)
const MSG = 1    # FSR message level (1 routes MATLAB's progress messages here)

function load_stars(path)
    # Genuine FSDA stars fixture persisted by check_FSR.py (last column = y).
    isfile(path) || error(
        "Missing fixture: ", path, ". Run code/FSR/check_FSR.py first.")
    lines = [strip(l) for l in readlines(path) if !isempty(strip(l))]
    length(lines) >= 2 || error("stars fixture has no data rows: ", path)
    rows = [parse.(Float64, strip.(split(l, ","))) for l in lines[2:end]]
    n = length(rows)
    ncol = length(rows[1])
    ncol >= 2 || error("stars fixture must have at least one predictor plus y.")
    M = Matrix{Float64}(undef, n, ncol)
    for i in 1:n
        M[i, :] = rows[i]
    end
    return M[:, end], M[:, 1:end-1]   # y, X
end

function load_golden_mdr(path)
    # Spec 007 owns the FSDA golden; this check reproduces its last TAIL rows.
    isfile(path) || error(
        "Missing spec-007 golden artifact: ", path,
        ". Run code/FSR/check_FSR.py first.")
    lines = [strip(l) for l in readlines(path) if !isempty(strip(l))]
    length(lines) >= 2 || error("Spec-007 golden has no data rows: ", path)
    header = strip.(split(lines[1], ","))
    (header == ["step", "mdr"]) ||
        error("Spec-007 golden header must be step,mdr; got ", header)
    rows = [parse.(Float64, strip.(split(l, ","))) for l in lines[2:end]]
    m = length(rows)
    M = Matrix{Float64}(undef, m, 2)
    for i in 1:m
        M[i, :] = rows[i]
    end
    return M
end

function write_artifact(path, tail, gtail, abs_diff)
    open(path, "w") do io
        println(io, "step,mdr_surface,mdr_golden,abs_diff")
        for i in 1:size(tail, 1)
            println(io, join((Int(tail[i, 1]), tail[i, 2], gtail[i, 2], abs_diff[i]), ","))
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
    println("FSR path     : ", d.fsr_path)
end

function main()
    reference_dir = joinpath(SCRIPT_DIR, "reference")
    y, X = load_stars(joinpath(reference_dir, "stars.csv"))
    golden = load_golden_mdr(joinpath(reference_dir, "FSR_mdr.csv"))

    fsda_root = length(ARGS) >= 1 && !isempty(ARGS[1]) ? ARGS[1] : nothing
    bridge = start_bridge(fsda_root = fsda_root)
    try
        diagnostics = bridge_diagnostics(bridge)
        res = fsr(bridge, y, X; nsamp = 0, intercept = true, plots = PLOTS, msg = MSG)

        mdr = res.mdr
        (size(mdr, 1) >= TAIL && size(golden, 1) >= TAIL) ||
            error("need at least ", TAIL, " mdr rows on both sides.")
        tail = mdr[end-TAIL+1:end, :]
        gtail = golden[end-TAIL+1:end, :]
        abs_diff = vec(maximum(abs.(tail .- gtail), dims = 2))
        max_abs_diff = maximum(abs_diff)
        ok = size(tail) == size(gtail) && all(abs_diff .<= TOL)

        isdir(reference_dir) || mkpath(reference_dir)
        write_artifact(joinpath(reference_dir, "FSR_jl_check.csv"), tail, gtail, abs_diff)

        println("=== spec 008: Julia PythonCall FSR agreement check ===")
        print_diagnostics(diagnostics)
        println("outliers(1-b): ", res.outliers)
        println("mdr last ", TAIL, " rows (step, surface, golden):")
        for i in 1:TAIL
            @printf("   %3d  %.10f  %.10f\n", Int(tail[i, 1]), tail[i, 2], gtail[i, 2])
        end
        println("max abs diff : ", @sprintf("%.3e", max_abs_diff), "  (tol 1e-09)")
        println("RESULT       : ", ok ? "PASS" : "FAIL")

        # Keep the engine alive so the figure window stays open; only block on an
        # interactive terminal so piped / CI runs never hang.
        if PLOTS != 0 && stdin isa Base.TTY
            render_figures(bridge)
            print("Press Enter to close the FSR figures and stop the engine...")
            readline()
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
