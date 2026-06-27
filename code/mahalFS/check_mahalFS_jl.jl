# Spec-002 agreement check: the Julia (PythonCall) surface must reproduce the
# Python/FSDA oracle artifact from spec 001 to TOL. Mirrors check_mahalFS_r.R.
#
# Run (PythonCall installed in the active Julia env, FSDA_DEV_VENV → the venv's
# python that has matlabengine):
#     export FSDA_DEV_VENV="/path/to/fsda_dev_env/bin/python"   # macOS / Linux
#     julia code/mahalFS/check_mahalFS_jl.jl [FSDA_ROOT]
#
# bridge.jl pins PythonCall to the venv, so it is included BEFORE anything else
# touches Python.

const SCRIPT_DIR = @__DIR__
include(joinpath(SCRIPT_DIR, "bridge.jl"))

using Printf

const TOL = 1e-9

format_vec(x) = join((@sprintf("%.10g", v) for v in x), " ")

function load_oracle(path, Y)
    # Spec 001 owns the genuine FSDA oracle artifact; this check only verifies
    # that the Julia wrapper reproduces it for the same fixed input.
    isfile(path) || error(
        "Missing spec-001 oracle artifact: ", path,
        ". Run code/mahalFS/check_mahalFS.py first.")

    lines = [strip(l) for l in readlines(path) if !isempty(strip(l))]
    length(lines) >= 2 || error("Spec-001 oracle has no data rows: ", path)
    header = strip.(split(lines[1], ","))
    for col in ("y1", "y2", "d_fsda")
        col in header || error("Spec-001 oracle is missing column: ", col)
    end
    iy1 = findfirst(==("y1"), header)
    iy2 = findfirst(==("y2"), header)
    idf = findfirst(==("d_fsda"), header)

    rows = [strip.(split(l, ",")) for l in lines[2:end]]
    length(rows) == size(Y, 1) ||
        error("Spec-001 oracle row count (", length(rows), ") does not match the ",
              "spec-002 fixed input (", size(Y, 1), ").")
    y1 = [parse(Float64, r[iy1]) for r in rows]
    y2 = [parse(Float64, r[iy2]) for r in rows]
    d_fsda = [parse(Float64, r[idf]) for r in rows]
    (all(y1 .== Y[:, 1]) && all(y2 .== Y[:, 2])) ||
        error("Spec-001 oracle inputs do not match the spec-002 fixed input.")
    return d_fsda
end

function write_artifact(path, Y, d_fsda, d_oracle, abs_diff)
    open(path, "w") do io
        println(io, "i,y1,y2,d_fsda,d_oracle,abs_diff")
        for i in 1:size(Y, 1)
            println(io, join((i, Y[i, 1], Y[i, 2], d_fsda[i], d_oracle[i], abs_diff[i]), ","))
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
    println("mahalFS path : ", d.mahalfs_path)
end

function main()
    # Fixed fixture shared with spec 001 (n = 5, v = 2; non-square on purpose).
    Y = [1.0  2.0;
         2.0  0.0;
         3.0  5.0;
         0.0 -1.0;
         4.0  4.0]
    MU = [2.0, 2.0]
    SIGMA = [2.0 0.5;
             0.5 1.0]

    reference_dir = joinpath(SCRIPT_DIR, "reference")
    oracle_path = joinpath(reference_dir, "mahalFS_check.csv")
    oracle_d = load_oracle(oracle_path, Y)

    fsda_root = length(ARGS) >= 1 && !isempty(ARGS[1]) ? ARGS[1] : nothing
    bridge = start_bridge(fsda_root = fsda_root)
    try
        diagnostics = bridge_diagnostics(bridge)
        d_fsda = mahal_fs(bridge, Y, MU, SIGMA)

        abs_diff = abs.(d_fsda .- oracle_d)
        max_abs_diff = maximum(abs_diff)
        ok = length(d_fsda) == length(oracle_d) && all(abs_diff .<= TOL)

        isdir(reference_dir) || mkpath(reference_dir)
        write_artifact(joinpath(reference_dir, "mahalFS_jl_check.csv"),
                       Y, d_fsda, oracle_d, abs_diff)

        println("=== spec 002: Julia PythonCall mahalFS agreement check ===")
        print_diagnostics(diagnostics)
        println("Julia surface: ", format_vec(d_fsda))
        println("oracle       : ", format_vec(oracle_d))
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
