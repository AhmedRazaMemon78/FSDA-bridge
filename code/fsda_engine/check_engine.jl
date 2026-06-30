# Agreement gate for the generic FSDA engine — Julia (PythonCall) surface (spec 017).
#
# Runs the same cases as check_engine.py through the *generic* Julia engine (engine.jl),
# proving the Julia surface reproduces the Python gate at atol=1e-9 (univariatems
# structural). Gates against the committed, language-neutral golds written by the Python
# per-target checks (read-only): mahalFS_check.csv, Score_check.csv, FSR_mdr.csv,
# FSRaddt_Tdel.csv — plus constructed struct/table round-trips and a live univariatems.
#
# Run (engine boot is slow; one session is reused):
#     export FSDA_DEV_VENV="/Users/aldocorbellini/miniconda3/bin/python"
#     julia --project=code/fsda_engine code/fsda_engine/check_engine.jl [FSDA_ROOT]

const SCRIPT_DIR = @__DIR__
include(joinpath(SCRIPT_DIR, "engine.jl"))

using Printf, Random, LinearAlgebra

const TOL = 1e-9
const CODE = abspath(joinpath(SCRIPT_DIR, ".."))          # .../code
const REFERENCE = joinpath(SCRIPT_DIR, "reference")        # engine's own golds/fixtures
const LA = [-1.0, -0.5, 0.0, 0.5, 1.0]

# --- helpers -----------------------------------------------------------------
function read_csv(path)
    isfile(path) || error("missing fixture/gold: ", path, " (run the Python per-target check first)")
    lines = [strip(l) for l in readlines(path) if !isempty(strip(l))]
    rows = [parse.(Float64, strip.(split(l, ","))) for l in lines[2:end]]
    M = Matrix{Float64}(undef, length(rows), length(rows[1]))
    for i in eachindex(rows)
        M[i, :] = rows[i]
    end
    return M
end

gate(name, ok, diff, note) = (name = name, ok = ok, diff = Float64(diff), note = note)

# --- cases (all through the same generic engine) -----------------------------
function case_numeric(h)
    Y = [1.0 2.0; 2.0 0.0; 3.0 5.0; 0.0 -1.0; 4.0 4.0]
    MU = [2.0, 2.0]                              # 1-D -> 1 x v row
    SIGMA = [2.0 0.5; 0.5 1.0]
    d = vec(call(h, "mahalFS", Y, MU, SIGMA))
    gold = read_csv(joinpath(CODE, "mahalFS", "reference", "mahalFS_check.csv"))[:, 4]  # d_fsda
    diff = maximum(abs.(d .- gold))
    gate("1 numeric array (mahalFS)", diff <= TOL, diff, "matlab.double -> Array")
end

function case_struct(h)
    wool = read_csv(joinpath(CODE, "Score", "reference", "wool.csv"))
    y = reshape(wool[:, end], :, 1)             # (n,1) column
    X = wool[:, 1:end-1]
    out = call(h, "Score", y, X; la = LA, intercept = true)
    (out isa Dict) || return gate("2 struct -> Dict (Score)", false, Inf, "expected Dict, got $(typeof(out))")
    sc = vec(out["Score"])
    gold = read_csv(joinpath(CODE, "Score", "reference", "Score_check.csv"))[:, 3]      # Score_fsda
    diff = maximum(abs.(sc .- gold))
    gate("2 struct -> Dict (Score)", diff <= TOL, diff, "struct -> Dict, out[\"Score\"]")
end

function case_nested(h)
    s = eval_expr(h, "struct('a',[1 2 3],'b',struct('c',[4 5 6],'d',[7 8 9]))")
    a = vec(s["a"]); c = vec(s["b"]["c"]); d = vec(s["b"]["d"])
    diff = max(maximum(abs.(a .- [1, 2, 3])), maximum(abs.(c .- [4, 5, 6])), maximum(abs.(d .- [7, 8, 9])))
    ok = (s isa Dict) && (s["b"] isa Dict) && diff <= TOL
    gate("3 nested struct of arrays", ok, diff, "Dict of Dict of Arrays")
end

function case_fsr(h)
    stars = read_csv(joinpath(CODE, "FSR", "reference", "stars.csv"))
    y = reshape(stars[:, end], :, 1); X = stars[:, 1:end-1]
    out = call(h, "FSR", y, X; nsamp = 0, intercept = true, plots = 0, msg = 0)
    cls = get(out, "class", "")
    mdr = out["mdr"]
    tail = mdr[end-4:end, :]
    gold = read_csv(joinpath(CODE, "FSR", "reference", "FSR_mdr.csv"))
    gtail = gold[end-4:end, :]
    diff = maximum(abs.(tail .- gtail))
    gate("4 char scalar + struct (FSR)", cls == "FSR" && diff <= TOL, diff, "class=$(repr(cls)); mdr tail")
end

function case_fsraddt(h)
    wool = read_csv(joinpath(CODE, "FSRaddt", "reference", "wool.csv"))
    y = reshape(wool[:, end], :, 1); X = wool[:, 1:end-1]
    out = call(h, "FSRaddt", y, X; nsamp = 0, intercept = true, plots = 0, msg = 0)
    tail = out["Tdel"][end-2:end, :]
    gold = read_csv(joinpath(CODE, "FSRaddt", "reference", "FSRaddt_Tdel.csv"))
    gtail = gold[end-2:end, :]
    diff = maximum(abs.(tail .- gtail))
    gate("+ routine-agnostic (FSRaddt)", diff <= TOL, diff, "out[\"Tdel\"] tail")
end

function case_table(h)
    t = eval_expr(h, "array2table([1 2 3;4 5 6],'VariableNames',{'aa','bb','cc'})")
    r = eval_expr(h, "array2table([10;20],'VariableNames',{'v'},'RowNames',{'r1','r2'})")
    names_ok = (t["VariableNames"] == ["aa", "bb", "cc"]) && isempty(t["RowNames"])
    rownames_ok = (r["RowNames"] == ["r1", "r2"])
    diff = max(maximum(abs.(vec(t["data"]["aa"]) .- [1, 4])),
               maximum(abs.(vec(t["data"]["bb"]) .- [2, 5])),
               maximum(abs.(vec(t["data"]["cc"]) .- [3, 6])),
               maximum(abs.(vec(r["data"]["v"]) .- [10, 20])))
    gate("5 table -> Dict", names_ok && rownames_ok && diff <= TOL, diff, "VariableNames + data + RowNames")
end

function case_univariatems(h)
    Random.seed!(0)
    n, p = 60, 5
    X = randn(n, p)
    y = reshape(3.0 .* X[:, 1] .- 2.0 .* X[:, 3] .+ 0.3 .* randn(n), :, 1)
    Tsel = call(h, "univariatems", y, X)
    hgt = Int(Tsel["height"])
    names = Tsel["VariableNames"]; rownames = Tsel["RowNames"]
    cols_ok = all(length(vec(v)) == hgt for v in values(Tsel["data"]))
    ok = (Tsel isa Dict) && length(names) >= 1 && length(rownames) == hgt && hgt >= 1 && cols_ok
    gate("6 real table fn (univariatems)", ok, 0.0, "structural: Tsel -> Dict, $(length(names)) cols x $hgt rows")
end

function case_corrnominal(h)
    N = [10.0 20 30; 40 50 60; 70 80 90]
    out = call(h, "corrNominal", N; dispresults = false)
    (out isa Dict) || return gate("7 multivariate (corrNominal)", false, Inf, "expected Dict")
    rt = sum(N, dims = 2); ct = sum(N, dims = 1); tot = sum(N)
    E = rt .* ct ./ tot
    chi2_ref = sum((N .- E) .^ 2 ./ E)
    I, J = size(N); cramer_ref = sqrt(chi2_ref / (tot * (min(I, J) - 1)))
    chi2 = Float64(first(out["Chi2"])); cramer = Float64(first(out["CramerV"]))
    diff = max(abs(chi2 - chi2_ref), abs(cramer - cramer_ref))
    gate("7 multivariate (corrNominal)", diff <= TOL, diff, "chi2/CramerV vs oracle")
end

function case_fsm(h)
    Y = read_csv(joinpath(REFERENCE, "FSM_Y.csv"))      # shared fixture (same Y as Python)
    eval_expr(h, "rng(0)"; nargout = 0)                 # fix FSM's random initial subset
    out = call(h, "FSM", Y; plots = 0, msg = 0)
    (out isa Dict && get(out, "class", "") == "FSM") ||
        return gate("8 FSM (multivariate FS)", false, Inf, "expected FSM struct")
    mmd = out["mmd"]
    gold = read_csv(joinpath(REFERENCE, "FSM_mmd.csv"))
    tail = mmd[end-4:end, :]; gtail = gold[end-4:end, :]
    diff = maximum(abs.(tail .- gtail))
    gate("8 FSM (multivariate FS)", diff <= TOL, diff, "out[\"mmd\"] tail vs gold")
end

function case_mcd(h)
    Y = read_csv(joinpath(REFERENCE, "FSM_Y.csv"))
    v = size(Y, 2)
    eval_expr(h, "rng(0)"; nargout = 0)
    res = call(h, "mcd", Y; nargout = 2, plots = 0, msg = 0)   # tuple -> Vector of 2 Dicts
    (res isa AbstractVector && length(res) == 2) ||
        return gate("9 mcd (nargout=2 tuple)", false, Inf, "expected 2 outputs")
    RAW, REW = res[1], res[2]
    ok = (RAW isa Dict) && (REW isa Dict) &&
         get(RAW, "class", "") == "mcd" && get(REW, "class", "") == "mcdr" &&
         length(vec(RAW["loc"])) == v && size(RAW["cov"]) == (v, v)
    gate("9 mcd (nargout=2 tuple)", ok, 0.0,
         "RAW.class=$(get(RAW,"class","")), REW.class=$(get(REW,"class","")), cov $(size(RAW["cov"]))")
end

# scalar extractor: a direct scalar output crosses as a Number; a 1x1 struct field as a 1x1 array
_scal(x) = x isa Number ? Float64(x) : Float64(first(x))

function _corr(Y)                          # correlation matrix (no Statistics dependency)
    n = size(Y, 1)
    Yc = Y .- sum(Y, dims = 1) ./ n
    S = (Yc' * Yc) ./ (n - 1)
    d = sqrt.(diag(S))
    return S ./ (d * d')
end

function case_pcafs(h)
    Y = read_csv(joinpath(REFERENCE, "FSM_Y.csv"))
    out = call(h, "pcaFS", Y; plots = 0)
    (out isa Dict) || return gate("10 multivariate (pcaFS)", false, Inf, "expected Dict")
    expl = out["explained"]                        # (p, 3) Matrix
    eig_ref = reverse(eigvals(Symmetric(_corr(Y)))) # eigenvalues of corr, descending
    diff = maximum(abs.(expl[:, 1] .- eig_ref))
    gate("10 multivariate (pcaFS)", diff <= TOL, diff, "explained eigenvalues vs cor")
end

function case_cressieread(h)
    N = [10.0 20 30; 40 50 60; 70 80 90]
    res = call(h, "CressieRead", N; nargout = 2)   # no 'plots' option on this routine
    (res isa AbstractVector && length(res) == 2) ||
        return gate("11 multivariate (CressieRead)", false, Inf, "expected 2 outputs")
    PD = _scal(res[1])
    rt = sum(N, dims = 2); ct = sum(N, dims = 1); tot = sum(N)
    E = rt .* ct ./ tot
    la = 2.0 / 3.0
    PD_ref = (2.0 / (la * (la + 1.0))) * sum(N .* ((N ./ E) .^ la .- 1.0))
    diff = abs(PD - PD_ref)
    gate("11 multivariate (CressieRead)", diff <= TOL, diff, "PD vs oracle")
end

function main()
    fsda_root = length(ARGS) >= 1 && !isempty(ARGS[1]) ? ARGS[1] : nothing
    h = start_engine(fsda_root = fsda_root)
    results = try
        d = diagnostics(h)
        rs = [case_numeric(h), case_struct(h), case_nested(h), case_fsr(h),
              case_fsraddt(h), case_table(h), case_univariatems(h),
              case_corrnominal(h), case_fsm(h), case_mcd(h),
              case_pcafs(h), case_cressieread(h)]
        (d, rs)
    finally
        try; stop_engine(h); catch; end
    end
    diag, rs = results
    overall = all(r.ok for r in rs)

    println("=== spec 017: generic FSDA engine — Julia surface ===")
    println("Julia        : ", diag.julia)
    println("PythonCall   : ", diag.pythoncall)
    println("Python       : ", diag.python_version)
    println("MATLAB       : ", diag.matlab)
    println("engine pkg   : ", diag.matlabengine)
    println("tolerance    : atol ", @sprintf("%.0e", TOL))
    println("cases (one shared engine call / eval_expr):")
    for r in rs
        @printf("  [%s]  %-30s  max abs diff %.3e   %s\n",
                r.ok ? "PASS" : "FAIL", r.name, r.diff, r.note)
    end
    println("RESULT       : ", overall ? "PASS" : "FAIL")
    return overall ? 0 : 1
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
