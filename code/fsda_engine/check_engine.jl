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

function case_logfactorial(h)
    lf = _scal(call(h, "logfactorial", 10.0))
    ref = sum(log.(1:10))
    gate("12 utilities_stat (logfactorial)", abs(lf - ref) <= TOL, abs(lf - ref), "log(10!) vs oracle")
end

function case_tabulatefs(h)
    x = [1.0, 1, 2, 3, 3, 3]
    tb = call(h, "tabulateFS", x)                 # (3,3) Matrix [value, count, percent]
    vals = sort(unique(x))
    cnts = Float64[count(==(v), x) for v in vals]
    ref = hcat(vals, cnts, cnts ./ length(x) .* 100)
    same = size(tb) == size(ref)
    diff = same ? maximum(abs.(tb .- ref)) : Inf
    gate("13 utilities_stat (tabulateFS)", same && diff <= TOL, diff, "value/count/percent vs oracle")
end

function case_tbwei(h)
    u = reshape([-3.0, -1, 0, 0.5, 2, 5], :, 1); c = 4.685
    w = vec(call(h, "TBwei", u, c))
    uu = vec(u)
    ref = ifelse.(abs.(uu) .<= c, (1 .- (uu ./ c) .^ 2) .^ 2, 0.0)
    diff = maximum(abs.(w .- ref))
    gate("14 utilities_stat (TBwei)", diff <= TOL, diff, "Tukey biweight vs oracle")
end

function case_gower(h)
    Y = read_csv(joinpath(REFERENCE, "FSM_Y.csv"))
    res = call(h, "GowerIndex", Y; nargout = 2)
    (res isa AbstractVector && length(res) == 2) ||
        return gate("15 clustering (GowerIndex)", false, Inf, "expected 2 outputs")
    S = res[1]
    R = vec(maximum(Y, dims = 1) .- minimum(Y, dims = 1))
    n, p = size(Y)
    Sref = [1 - sum(abs.(Y[i, :] .- Y[j, :]) ./ R) / p for i in 1:n, j in 1:n]
    diff = maximum(abs.(S .- Sref))
    stable_ok = (res[2] isa Dict) && haskey(res[2], "VariableNames")
    gate("15 clustering (GowerIndex)", diff <= TOL && stable_ok, diff,
         "Gower S vs oracle; Stable=$(stable_ok ? "table-dict" : "NOT")")
end

function case_tclustic(h)
    Y = read_csv(joinpath(REFERENCE, "FSM_Y.csv"))
    eval_expr(h, "rng(0)"; nargout = 0)
    out = call(h, "tclustIC", Y; plots = 0, msg = 0, kk = [2.0, 3.0])   # 2-D cell -> nested list
    ok = (out isa Dict) && haskey(out, "IDXCLA") && (out["IDXCLA"] isa AbstractVector) &&
         !isempty(out["IDXCLA"]) && (out["IDXCLA"][1] isa AbstractVector) &&
         haskey(out, "IDXMIX") && (out["IDXMIX"] isa AbstractVector)
    detail = ok ? "IDXCLA $(length(out["IDXCLA"]))x$(length(out["IDXCLA"][1])) nested list" :
                  "IDXCLA not a nested list"
    gate("16 clustering 2-D cell (tclustIC)", ok, 0.0, detail)
end

function case_removeextraspaces(h)
    s = call(h, "removeExtraSpacesLF", "a   b    c  d")   # positional String in -> String out
    ok = (s == "a b c d")
    gate("17 utilities (removeExtraSpacesLF)", ok, ok ? 0.0 : Inf, "str -> str: $(repr(s))")
end

function case_triu2vec(h)
    A = [1.0 2 3; 4 5 6; 7 8 9]
    y = vec(call(h, "triu2vec", A, 1))
    ref = [A[1, 2], A[1, 3], A[2, 3]]                     # strictly-upper, 3x3
    diff = length(y) == length(ref) ? maximum(abs.(y .- ref)) : Inf
    gate("18 utilities (triu2vec)", diff <= TOL, diff, "upper triangle vs oracle")
end

# lexicographic m-combinations of v (Base only; no Combinatorics dependency)
function _combinations(v, m)
    n = length(v)
    res = Vector{Vector{eltype(v)}}()
    idx = collect(1:m)
    while true
        push!(res, [v[i] for i in idx])
        i = m
        while i >= 1 && idx[i] == n - m + i
            i -= 1
        end
        i == 0 && break
        idx[i] += 1
        for j in (i + 1):m
            idx[j] = idx[j - 1] + 1
        end
    end
    return res
end

function case_bc(h)
    c = _scal(call(h, "bc", 12.0, 5.0))
    ref = Float64(binomial(12, 5))
    gate("19 combinatorial (bc)", abs(c - ref) <= TOL, abs(c - ref), "C(12,5) vs binomial")
end

function case_combsfs(h)
    v = [2.0, 4.0, 6.0, 8.0, 10.0]; m = 3
    P = call(h, "combsFS", reshape(v, 1, :), Float64(m))   # 1 x n row; exercises v -> P mapping
    ref = permutedims(hcat(_combinations(v, m)...))         # (nCk) x m, lexicographic
    same = size(P) == size(ref)
    diff = same ? maximum(abs.(P .- ref)) : Inf
    gate("20 combinatorial (combsFS)", same && diff <= TOL, diff,
         "$(size(P, 1))x$(size(P, 2)) combinations vs oracle")
end

function case_lexunrank(h)
    n, k, N = 6, 3, 7
    res = call(h, "lexunrank", Float64(n), Float64(k), Float64(N); nargout = 2)   # numeric tuple
    (res isa AbstractVector && length(res) == 2) ||
        return gate("21 combinatorial (lexunrank)", false, Inf, "expected 2 outputs")
    kcomb = sort(vec(Float64.(res[1])))                     # FSDA orders descending -> sort as set
    calls = _scal(res[2])
    ref = sort(_combinations(collect(1.0:n), k)[binomial(n, k) - N])   # lex position bc(n,k)-N
    same = length(kcomb) == length(ref)
    diff = same ? maximum(abs.(kcomb .- ref)) : Inf
    ok = same && diff <= TOL && isfinite(calls) && calls > 0
    gate("21 combinatorial (lexunrank)", ok, diff, "kcomb(set) vs oracle; calls=$(Int(calls))")
end

function case_publishfs(h)
    out = call(h, "publishFS", "mahalFS"; write2file = false, evalCode = false,
               Display = "none", ErrWrngSeeAlso = false)
    (out isa Dict) || return gate("22 utilities_help (publishFS)", false, Inf,
                                  "expected Dict, got $(typeof(out))")
    inp = get(out, "InpArgs", nothing)                 # 3x8 nested list via _marshal_cell2d
    in_names = (inp isa AbstractVector && !isempty(inp) && inp[1] isa AbstractVector) ?
               String[String(r[1]) for r in inp] : nothing
    outa = get(out, "OutArgs", nothing)                # column cell -> flat list
    out_first = (outa isa AbstractVector && !isempty(outa)) ? outa[1] : nothing
    ok = get(out, "titl", nothing) == "mahalFS" &&
         in_names == ["Y", "MU", "SIGMA"] && out_first == "d" &&
         get(out, "laste", nothing) == ""
    gate("22 utilities_help (publishFS)", ok, ok ? 0.0 : Inf,
         "titl=$(repr(get(out, "titl", nothing))); InpArgs=$(in_names)")
end

function case_distribspec(h)
    eval_expr(h, "figure"; nargout = 0)                # valid ambient gcf/gca for distribspec
    p = _scal(eval_expr(h, "distribspec(makedist('Normal','mu',0,'sigma',1)," *
                           "[-1.96 1.96],'inside')"))  # nargout=1 -> p only; handle h not requested
    m = pyimport("math")
    ref = 0.5 * (pyconvert(Float64, m.erf(1.96 / sqrt(2))) -
                 pyconvert(Float64, m.erf(-1.96 / sqrt(2))))
    gate("23 graphics (distribspec)", abs(p - ref) <= TOL, abs(p - ref),
         "P(|Z|<1.96)=$(round(p, digits = 6)) vs erf oracle (handle not requested)")
end

function case_histfs(h)
    y = read_csv(joinpath(REFERENCE, "FSM_Y.csv"))[:, 1]         # committed 40-vector
    edges = collect(range(minimum(y) - 1e-9, maximum(y) + 1e-9; length = 6))  # 5 bins
    gy = Float64.(y .> (sum(y) / length(y)))                     # 2 groups (any split)
    ng = call(h, "histFS", y, edges, gy; nargout = 1)           # (bins x groups); hb not requested
    binsum = vec(sum(ng, dims = 2))
    ref = Float64[count(e -> edges[i] <= e < edges[i+1], y) for i in 1:length(edges)-1]
    same = length(binsum) == length(ref) && Int(sum(ng)) == length(y)
    diff = same ? maximum(abs.(binsum .- ref)) : Inf
    gate("24 graphics (histFS)", same && diff <= TOL, diff,
         "ng $(size(ng)) bin totals vs native histogram (n=$(length(y)))")
end

function case_boxplotb(h)
    Y = read_csv(joinpath(REFERENCE, "FSM_Y.csv"))[:, 1:2]       # bivariate
    out = call(h, "boxplotb", Y; nargout = 1)
    (out isa Dict) || return gate("25 graphics (boxplotb)", false, Inf,
                                  "expected Dict, got $(typeof(out))")
    cent = vec(Float64.(out["cent"]))
    spl = out["Spl"]
    ok = length(cent) == size(Y, 2) && ndims(spl) == 2 && size(spl, 2) == 4 &&
         haskey(out, "outliers") && haskey(out, "handles")
    gate("25 graphics (boxplotb)", ok, ok ? 0.0 : Inf,
         "cent$(size(cent)) Spl$(size(spl)); struct-embedded handles cross empty")
end

function main()
    fsda_root = length(ARGS) >= 1 && !isempty(ARGS[1]) ? ARGS[1] : nothing
    h = start_engine(fsda_root = fsda_root)
    results = try
        d = diagnostics(h)
        rs = [case_numeric(h), case_struct(h), case_nested(h), case_fsr(h),
              case_fsraddt(h), case_table(h), case_univariatems(h),
              case_corrnominal(h), case_fsm(h), case_mcd(h),
              case_pcafs(h), case_cressieread(h),
              case_logfactorial(h), case_tabulatefs(h), case_tbwei(h),
              case_gower(h), case_tclustic(h),
              case_removeextraspaces(h), case_triu2vec(h),
              case_bc(h), case_combsfs(h), case_lexunrank(h),
              case_publishfs(h), case_distribspec(h), case_histfs(h), case_boxplotb(h)]
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
