# Spec-005 agreement check: the Julia (PythonCall) surface must reproduce the
# Python/FSDA oracle artifact from spec 004 to TOL. Mirrors check_mahalFS_jl.jl.
#
# Run (PythonCall installed in the active Julia env, FSDA_DEV_VENV → the venv's
# python that has matlabengine):
#     export FSDA_DEV_VENV="/path/to/fsda_dev_env/bin/python"   # macOS / Linux
#     julia --project=code/Score code/Score/check_Score_jl.jl [FSDA_ROOT]
#
# bridge.jl pins PythonCall to the venv, so it is included BEFORE anything else
# touches Python. The fixed input (genuine FSDA `wool`) and the oracle are read
# from reference/ artifacts written by check_Score.py — run that first.

const SCRIPT_DIR = @__DIR__
include(joinpath(SCRIPT_DIR, "bridge.jl"))

using Printf

const TOL = 1e-9
const LA = Float64[-1.0, -0.5, 0.0, 0.5, 1.0]   # FSDA Score default

format_vec(x) = join((@sprintf("%.10g", v) for v in x), " ")

function load_wool(path)
    # Genuine FSDA wool fixture persisted by check_Score.py (last column = y).
    isfile(path) || error(
        "Missing fixture: ", path, ". Run code/Score/check_Score.py first.")
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

function load_oracle(path, la)
    # Spec 004 owns the genuine FSDA oracle artifact; this check only verifies
    # that the Julia wrapper reproduces it for the same fixed input.
    isfile(path) || error(
        "Missing spec-004 oracle artifact: ", path,
        ". Run code/Score/check_Score.py first.")
    lines = [strip(l) for l in readlines(path) if !isempty(strip(l))]
    length(lines) >= 2 || error("Spec-004 oracle has no data rows: ", path)
    header = strip.(split(lines[1], ","))
    for col in ("la", "Score_fsda")
        col in header || error("Spec-004 oracle is missing column: ", col)
    end
    ila = findfirst(==("la"), header)
    isf = findfirst(==("Score_fsda"), header)

    rows = [strip.(split(l, ",")) for l in lines[2:end]]
    length(rows) == length(la) ||
        error("Spec-004 oracle row count (", length(rows), ") does not match the ",
              "spec-005 fixed la (", length(la), ").")
    la_csv = [parse(Float64, r[ila]) for r in rows]
    sc = [parse(Float64, r[isf]) for r in rows]
    all(la_csv .== la) ||
        error("Spec-004 oracle la column does not match the spec-005 fixed la.")
    return sc
end

function write_artifact(path, la, sc, oracle, abs_diff)
    open(path, "w") do io
        println(io, "i,la,Score_surface,Score_oracle,abs_diff")
        for i in eachindex(la)
            println(io, join((i, la[i], sc[i], oracle[i], abs_diff[i]), ","))
        end
    end
end

function print_diagnostics(d)
    # Enough environment detail to make PythonCall/Python/MATLAB mismatches
    # visible when the check is run on another machine.
    println("Julia        : ", d.julia)
    println("PythonCall   : ", d.pythoncall)
    println("Python       : ", d.python_version)
    println("Python path  : ", d.python)
    println("MATLAB       : ", d.matlab)
    println("engine pkg   : ", d.matlabengine)
    println("Score path   : ", d.score_path)
end

function main()
    reference_dir = joinpath(SCRIPT_DIR, "reference")
    y, X = load_wool(joinpath(reference_dir, "wool.csv"))
    oracle_sc = load_oracle(joinpath(reference_dir, "Score_check.csv"), LA)

    fsda_root = length(ARGS) >= 1 && !isempty(ARGS[1]) ? ARGS[1] : nothing
    bridge = start_bridge(fsda_root = fsda_root)
    try
        diagnostics = bridge_diagnostics(bridge)
        sc = score(bridge, y, X; la = LA, intercept = true)

        abs_diff = abs.(sc .- oracle_sc)
        max_abs_diff = maximum(abs_diff)
        ok = length(sc) == length(oracle_sc) && all(abs_diff .<= TOL)

        isdir(reference_dir) || mkpath(reference_dir)
        write_artifact(joinpath(reference_dir, "Score_jl_check.csv"),
                       LA, sc, oracle_sc, abs_diff)

        println("=== spec 005: Julia PythonCall Score agreement check ===")
        print_diagnostics(diagnostics)
        println("lambda       : ", format_vec(LA))
        println("Julia surface: ", format_vec(sc))
        println("oracle       : ", format_vec(oracle_sc))
        println("max abs diff : ", @sprintf("%.3e", max_abs_diff), "  (tol 1e-09)")
        println("RESULT       : ", ok ? "PASS" : "FAIL")

        return ok ? 0 : 1
    finally
        # Always ask MATLAB to quit, including on failed comparisons / write errors.
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
