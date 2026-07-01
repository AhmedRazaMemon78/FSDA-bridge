# Agreement gate for the generic FSDA engine — R (reticulate) surface (spec 018).
#
# Runs the same cases as check_engine.py through the *generic* R engine (engine.R),
# proving the R surface reproduces the Python gate at atol=1e-9 (univariatems
# structural). Gates against the committed, language-neutral golds (read-only):
# mahalFS_check.csv, Score_check.csv, FSR_mdr.csv, FSRaddt_Tdel.csv — plus constructed
# struct/table round-trips and a live univariatems.
#
# Run (engine boot is slow; one session is reused):
#     export FSDA_DEV_VENV="/Users/aldocorbellini/miniconda3/bin/python"
#     Rscript code/fsda_engine/check_engine.R [FSDA_ROOT]

.script_dir = local({
  args = commandArgs(trailingOnly = FALSE)
  fa = grep("^--file=", args, value = TRUE)
  if (length(fa) == 1) {
    return(normalizePath(dirname(sub("^--file=", "", fa)), winslash = "/", mustWork = TRUE))
  }
  here = normalizePath(getwd(), winslash = "/", mustWork = TRUE)
  for (c in c(here, file.path(here, "code", "fsda_engine"))) {
    if (file.exists(file.path(c, "engine.R"))) return(normalizePath(c, winslash = "/", mustWork = TRUE))
  }
  stop("Cannot locate code/fsda_engine/engine.R")
})

source(file.path(.script_dir, "engine.R"))

TOL = 1e-9
CODE = normalizePath(file.path(.script_dir, ".."), winslash = "/", mustWork = TRUE)  # .../code
REFERENCE = file.path(.script_dir, "reference")  # engine's own golds/fixtures
LA = c(-1.0, -0.5, 0.0, 0.5, 1.0)

read_matrix = function(...) {
  path = file.path(...)
  if (!file.exists(path)) stop("missing fixture/gold: ", path, " (run the Python per-target check first)")
  as.matrix(read.csv(path))
}

gate = function(name, ok, diff, note) {
  list(name = name, ok = isTRUE(ok), diff = as.numeric(diff), note = note)
}

case_numeric = function(h) {
  Y = matrix(c(1, 2, 2, 0, 3, 5, 0, -1, 4, 4), nrow = 5, byrow = TRUE)
  MU = c(2.0, 2.0)                          # 1-D -> 1 x v row
  SIGMA = matrix(c(2, 0.5, 0.5, 1), 2, 2)
  d = as.numeric(fsda_call(h, "mahalFS", Y, MU, SIGMA))
  gold = read_matrix(CODE, "mahalFS", "reference", "mahalFS_check.csv")[, "d_fsda"]
  diff = max(abs(d - gold))
  gate("1 numeric array (mahalFS)", diff <= TOL, diff, "matlab.double -> vector")
}

case_struct = function(h) {
  wool = read_matrix(CODE, "Score", "reference", "wool.csv")
  y = matrix(wool[, ncol(wool)], ncol = 1)  # (n,1) column
  X = wool[, 1:(ncol(wool) - 1)]
  out = fsda_call(h, "Score", y, X, la = LA, intercept = TRUE)
  if (!is.list(out)) return(gate("2 struct -> list (Score)", FALSE, Inf, "expected named list"))
  sc = as.numeric(out$Score)
  gold = read_matrix(CODE, "Score", "reference", "Score_check.csv")[, "Score_fsda"]
  diff = max(abs(sc - gold))
  gate("2 struct -> list (Score)", diff <= TOL, diff, "struct -> list, out$Score")
}

case_nested = function(h) {
  s = eval_m(h, "struct('a',[1 2 3],'b',struct('c',[4 5 6],'d',[7 8 9]))")
  a = as.numeric(s$a); c = as.numeric(s$b$c); d = as.numeric(s$b$d)
  diff = max(abs(a - c(1, 2, 3)), abs(c - c(4, 5, 6)), abs(d - c(7, 8, 9)))
  ok = is.list(s) && is.list(s$b) && diff <= TOL
  gate("3 nested struct of arrays", ok, diff, "list of list of vectors")
}

case_fsr = function(h) {
  stars = read_matrix(CODE, "FSR", "reference", "stars.csv")
  y = matrix(stars[, ncol(stars)], ncol = 1)
  X = matrix(stars[, 1:(ncol(stars) - 1)], ncol = ncol(stars) - 1)
  out = fsda_call(h, "FSR", y, X, nsamp = 0, intercept = TRUE, plots = 0, msg = 0)
  cls = if (is.null(out$class)) "" else as.character(out$class)
  mdr = out$mdr
  tail = mdr[(nrow(mdr) - 4):nrow(mdr), ]
  gold = read_matrix(CODE, "FSR", "reference", "FSR_mdr.csv")
  gtail = gold[(nrow(gold) - 4):nrow(gold), ]
  diff = max(abs(tail - gtail))
  gate("4 char scalar + struct (FSR)", cls == "FSR" && diff <= TOL, diff, paste0("class=", cls, "; mdr tail"))
}

case_fsraddt = function(h) {
  wool = read_matrix(CODE, "FSRaddt", "reference", "wool.csv")
  y = matrix(wool[, ncol(wool)], ncol = 1)
  X = wool[, 1:(ncol(wool) - 1)]
  out = fsda_call(h, "FSRaddt", y, X, nsamp = 0, intercept = TRUE, plots = 0, msg = 0)
  td = out$Tdel
  tail = td[(nrow(td) - 2):nrow(td), ]
  gold = read_matrix(CODE, "FSRaddt", "reference", "FSRaddt_Tdel.csv")
  gtail = gold[(nrow(gold) - 2):nrow(gold), ]
  diff = max(abs(tail - gtail))
  gate("+ routine-agnostic (FSRaddt)", diff <= TOL, diff, "out$Tdel tail")
}

case_table = function(h) {
  t = eval_m(h, "array2table([1 2 3;4 5 6],'VariableNames',{'aa','bb','cc'})")
  r = eval_m(h, "array2table([10;20],'VariableNames',{'v'},'RowNames',{'r1','r2'})")
  names_ok = identical(unlist(t$VariableNames), c("aa", "bb", "cc")) && length(unlist(t$RowNames)) == 0
  rownames_ok = identical(unlist(r$RowNames), c("r1", "r2"))
  diff = max(abs(as.numeric(t$data$aa) - c(1, 4)), abs(as.numeric(t$data$bb) - c(2, 5)),
             abs(as.numeric(t$data$cc) - c(3, 6)), abs(as.numeric(r$data$v) - c(10, 20)))
  gate("5 table -> list", names_ok && rownames_ok && diff <= TOL, diff, "VariableNames + data + RowNames")
}

case_univariatems = function(h) {
  set.seed(0)
  n = 60; p = 5
  X = matrix(rnorm(n * p), n, p)
  y = matrix(3 * X[, 1] - 2 * X[, 3] + 0.3 * rnorm(n), ncol = 1)
  Tsel = fsda_call(h, "univariatems", y, X)
  hgt = as.integer(Tsel$height)
  names = unlist(Tsel$VariableNames); rownames = unlist(Tsel$RowNames)
  cols_ok = all(vapply(Tsel$data, function(v) length(as.numeric(v)) == hgt, logical(1)))
  ok = is.list(Tsel) && length(names) >= 1 && length(rownames) == hgt && hgt >= 1 && cols_ok
  gate("6 real table fn (univariatems)", ok, 0.0,
       paste0("structural: Tsel -> list, ", length(names), " cols x ", hgt, " rows"))
}

case_corrnominal = function(h) {
  N = matrix(c(10, 20, 30, 40, 50, 60, 70, 80, 90), 3, 3, byrow = TRUE)
  out = fsda_call(h, "corrNominal", N, dispresults = FALSE)
  if (!is.list(out)) return(gate("7 multivariate (corrNominal)", FALSE, Inf, "expected list"))
  rt = rowSums(N); ct = colSums(N); tot = sum(N)
  E = outer(rt, ct) / tot
  chi2_ref = sum((N - E)^2 / E)
  cramer_ref = sqrt(chi2_ref / (tot * (min(dim(N)) - 1)))
  chi2 = as.numeric(out$Chi2)[1]; cramer = as.numeric(out$CramerV)[1]
  diff = max(abs(chi2 - chi2_ref), abs(cramer - cramer_ref))
  gate("7 multivariate (corrNominal)", diff <= TOL, diff, "chi2/CramerV vs oracle")
}

case_fsm = function(h) {
  Y = read_matrix(REFERENCE, "FSM_Y.csv")          # shared fixture (same Y as Python)
  eval_m(h, "rng(0)", nargout = 0)                 # fix FSM's random initial subset
  out = fsda_call(h, "FSM", Y, plots = 0, msg = 0)
  cls = if (is.null(out$class)) "" else as.character(out$class)
  if (!is.list(out) || cls != "FSM") return(gate("8 FSM (multivariate FS)", FALSE, Inf, "expected FSM struct"))
  mmd = out$mmd
  gold = read_matrix(REFERENCE, "FSM_mmd.csv")
  tail = mmd[(nrow(mmd) - 4):nrow(mmd), ]
  gtail = gold[(nrow(gold) - 4):nrow(gold), ]
  diff = max(abs(tail - gtail))
  gate("8 FSM (multivariate FS)", diff <= TOL, diff, "out$mmd tail vs gold")
}

case_mcd = function(h) {
  Y = read_matrix(REFERENCE, "FSM_Y.csv")
  v = ncol(Y)
  eval_m(h, "rng(0)", nargout = 0)
  res = fsda_call(h, "mcd", Y, nargout = 2, plots = 0, msg = 0)   # tuple -> list of 2 lists
  if (!is.list(res) || length(res) != 2) return(gate("9 mcd (nargout=2 tuple)", FALSE, Inf, "expected 2 outputs"))
  RAW = res[[1]]; REW = res[[2]]
  ok = is.list(RAW) && is.list(REW) &&
       identical(as.character(RAW$class), "mcd") && identical(as.character(REW$class), "mcdr") &&
       length(as.numeric(RAW$loc)) == v && all(dim(as.matrix(RAW$cov)) == c(v, v))
  gate("9 mcd (nargout=2 tuple)", ok, 0.0,
       paste0("RAW.class=", as.character(RAW$class), ", REW.class=", as.character(REW$class)))
}

case_pcafs = function(h) {
  Y = read_matrix(REFERENCE, "FSM_Y.csv")
  out = fsda_call(h, "pcaFS", Y, plots = 0)
  if (!is.list(out)) return(gate("10 multivariate (pcaFS)", FALSE, Inf, "expected list"))
  expl = as.matrix(out$explained)
  eig_ref = sort(eigen(cor(Y), only.values = TRUE)$values, decreasing = TRUE)
  diff = max(abs(expl[, 1] - eig_ref))
  gate("10 multivariate (pcaFS)", diff <= TOL, diff, "explained eigenvalues vs cor")
}

case_cressieread = function(h) {
  N = matrix(c(10, 20, 30, 40, 50, 60, 70, 80, 90), 3, 3, byrow = TRUE)
  res = fsda_call(h, "CressieRead", N, nargout = 2)   # no 'plots' option on this routine
  if (!is.list(res) || length(res) != 2) return(gate("11 multivariate (CressieRead)", FALSE, Inf, "expected 2 outputs"))
  PD = as.numeric(res[[1]])[1]
  rt = rowSums(N); ct = colSums(N); tot = sum(N)
  E = outer(rt, ct) / tot
  la = 2 / 3
  PD_ref = (2 / (la * (la + 1))) * sum(N * ((N / E)^la - 1))
  diff = abs(PD - PD_ref)
  gate("11 multivariate (CressieRead)", diff <= TOL, diff, "PD vs oracle")
}

case_logfactorial = function(h) {
  lf = as.numeric(fsda_call(h, "logfactorial", 10))[1]
  ref = sum(log(1:10))
  gate("12 utilities_stat (logfactorial)", abs(lf - ref) <= TOL, abs(lf - ref), "log(10!) vs oracle")
}

case_tabulatefs = function(h) {
  x = c(1, 1, 2, 3, 3, 3)
  tb = as.matrix(fsda_call(h, "tabulateFS", x))   # (3,3) [value, count, percent]
  cnts = as.numeric(table(x))
  ref = cbind(sort(unique(x)), cnts, cnts / length(x) * 100)
  same = all(dim(tb) == dim(ref))
  diff = if (same) max(abs(tb - ref)) else Inf
  gate("13 utilities_stat (tabulateFS)", same && diff <= TOL, diff, "value/count/percent vs oracle")
}

case_tbwei = function(h) {
  u = matrix(c(-3, -1, 0, 0.5, 2, 5), ncol = 1); c = 4.685
  w = as.numeric(fsda_call(h, "TBwei", u, c))
  uu = as.numeric(u)
  ref = ifelse(abs(uu) <= c, (1 - (uu / c)^2)^2, 0)
  diff = max(abs(w - ref))
  gate("14 utilities_stat (TBwei)", diff <= TOL, diff, "Tukey biweight vs oracle")
}

case_gower = function(h) {
  Y = read_matrix(REFERENCE, "FSM_Y.csv")
  res = fsda_call(h, "GowerIndex", Y, nargout = 2)
  if (!is.list(res) || length(res) != 2) return(gate("15 clustering (GowerIndex)", FALSE, Inf, "expected 2 outputs"))
  S = as.matrix(res[[1]])
  R = apply(Y, 2, max) - apply(Y, 2, min)
  n = nrow(Y); p = ncol(Y); Sref = matrix(0, n, n)
  for (i in 1:n) for (j in 1:n) Sref[i, j] = 1 - sum(abs(Y[i, ] - Y[j, ]) / R) / p
  diff = max(abs(S - Sref))
  stable_ok = is.list(res[[2]]) && "VariableNames" %in% names(res[[2]])
  gate("15 clustering (GowerIndex)", diff <= TOL && stable_ok, diff,
       paste0("Gower S vs oracle; Stable=", if (stable_ok) "table-dict" else "NOT"))
}

case_tclustic = function(h) {
  Y = read_matrix(REFERENCE, "FSM_Y.csv")
  eval_m(h, "rng(0)", nargout = 0)
  out = fsda_call(h, "tclustIC", Y, plots = 0, msg = 0, kk = c(2, 3))   # 2-D cell -> nested list
  ok = is.list(out) && !is.null(out$IDXCLA) && is.list(out$IDXCLA) &&
       length(out$IDXCLA) >= 1 && is.list(out$IDXCLA[[1]]) &&
       !is.null(out$IDXMIX) && is.list(out$IDXMIX)
  detail = if (ok) paste0("IDXCLA ", length(out$IDXCLA), "x", length(out$IDXCLA[[1]]), " nested list") else "IDXCLA not nested"
  gate("16 clustering 2-D cell (tclustIC)", ok, 0.0, detail)
}

case_removeextraspaces = function(h) {
  s = fsda_call(h, "removeExtraSpacesLF", "a   b    c  d")   # positional string in -> string out
  ok = identical(as.character(s), "a b c d")
  gate("17 utilities (removeExtraSpacesLF)", ok, if (ok) 0.0 else Inf, paste0("str -> str: ", as.character(s)))
}

case_triu2vec = function(h) {
  A = matrix(c(1, 2, 3, 4, 5, 6, 7, 8, 9), 3, 3, byrow = TRUE)
  y = as.numeric(fsda_call(h, "triu2vec", A, 1))
  ref = c(A[1, 2], A[1, 3], A[2, 3])                         # strictly-upper, 3x3
  diff = if (length(y) == length(ref)) max(abs(y - ref)) else Inf
  gate("18 utilities (triu2vec)", diff <= TOL, diff, "upper triangle vs oracle")
}

case_bc = function(h) {
  c = as.numeric(fsda_call(h, "bc", 12, 5))[1]
  ref = choose(12, 5)
  gate("19 combinatorial (bc)", abs(c - ref) <= TOL, abs(c - ref), "C(12,5) vs choose")
}

case_combsfs = function(h) {
  v = c(2, 4, 6, 8, 10); m = 3
  P = as.matrix(fsda_call(h, "combsFS", matrix(v, nrow = 1), m))   # 1 x n row; exercises v -> P
  ref = t(combn(v, m))                                            # (nCk) x m, lexicographic
  same = all(dim(P) == dim(ref))
  diff = if (same) max(abs(P - ref)) else Inf
  gate("20 combinatorial (combsFS)", same && diff <= TOL, diff,
       paste0(nrow(P), "x", ncol(P), " combinations vs oracle"))
}

case_lexunrank = function(h) {
  n = 6; k = 3; N = 7
  res = fsda_call(h, "lexunrank", n, k, N, nargout = 2)           # numeric tuple -> list of 2
  if (!is.list(res) || length(res) != 2) return(gate("21 combinatorial (lexunrank)", FALSE, Inf, "expected 2 outputs"))
  kcomb = sort(as.numeric(res[[1]]))                              # FSDA orders descending -> sort as set
  calls = as.numeric(res[[2]])[1]
  ref = sort(combn(1:n, k)[, choose(n, k) - N])                   # lex position bc(n,k)-N
  same = length(kcomb) == length(ref)
  diff = if (same) max(abs(kcomb - ref)) else Inf
  ok = same && diff <= TOL && is.finite(calls) && calls > 0
  gate("21 combinatorial (lexunrank)", ok, diff, paste0("kcomb(set) vs oracle; calls=", calls))
}

case_publishfs = function(h) {
  out = fsda_call(h, "publishFS", "mahalFS", write2file = FALSE, evalCode = FALSE,
                  Display = "none", ErrWrngSeeAlso = FALSE)
  if (!is.list(out)) return(gate("22 utilities_help (publishFS)", FALSE, Inf, "expected named list"))
  inp = out$InpArgs                                        # 3x8 nested list via _marshal_cell2d
  in_names = if (is.list(inp) && length(inp) > 0)
               vapply(inp, function(r) as.character(r[[1]])[1], character(1)) else NULL
  outa = out$OutArgs                                       # column cell -> list / vector
  out_first = if (length(outa) > 0) as.character(if (is.list(outa)) outa[[1]] else outa[1]) else NULL
  ok = identical(as.character(out$titl), "mahalFS") &&
       identical(in_names, c("Y", "MU", "SIGMA")) &&
       identical(out_first, "d") && identical(as.character(out$laste), "")
  gate("22 utilities_help (publishFS)", ok, if (ok) 0.0 else Inf,
       paste0("titl=", as.character(out$titl), "; InpArgs=", paste(in_names, collapse = ",")))
}

case_distribspec = function(h) {
  eval_m(h, "figure", nargout = 0)                         # valid ambient gcf/gca for distribspec
  p = as.numeric(eval_m(h, "distribspec(makedist('Normal','mu',0,'sigma',1),[-1.96 1.96],'inside')"))[1]
  ref = pnorm(1.96) - pnorm(-1.96)                         # base-R normal CDF oracle; handle not requested
  gate("23 graphics (distribspec)", abs(p - ref) <= TOL, abs(p - ref),
       paste0("P(|Z|<1.96)=", round(p, 6), " vs pnorm oracle (handle not requested)"))
}

case_histfs = function(h) {
  y = read_matrix(REFERENCE, "FSM_Y.csv")[, 1]             # committed 40-vector
  edges = seq(min(y) - 1e-9, max(y) + 1e-9, length.out = 6)  # 5 bins spanning data
  gy = as.numeric(y > mean(y))                             # 2 groups (any split)
  ng = as.matrix(fsda_call(h, "histFS", y, edges, gy, nargout = 1))  # bins x groups; hb not requested
  binsum = rowSums(ng)
  ref = hist(y, breaks = edges, plot = FALSE)$counts       # base-R oracle
  same = length(binsum) == length(ref) && round(sum(ng)) == length(y)
  diff = if (same) max(abs(binsum - ref)) else Inf
  gate("24 graphics (histFS)", same && diff <= TOL, diff,
       paste0("ng ", nrow(ng), "x", ncol(ng), " bin totals vs hist (n=", length(y), ")"))
}

case_boxplotb = function(h) {
  Y = read_matrix(REFERENCE, "FSM_Y.csv")[, 1:2]           # bivariate
  out = fsda_call(h, "boxplotb", Y, nargout = 1)
  if (!is.list(out)) return(gate("25 graphics (boxplotb)", FALSE, Inf, "expected named list"))
  cent = as.numeric(out$cent)
  spl = as.matrix(out$Spl)
  ok = length(cent) == ncol(Y) && ncol(spl) == 4 &&
       "outliers" %in% names(out) && "handles" %in% names(out)
  gate("25 graphics (boxplotb)", ok, if (ok) 0.0 else Inf,
       paste0("cent(", length(cent), ") Spl(", nrow(spl), "x", ncol(spl), "); handles cross empty"))
}

main = function() {
  fsda_root = local({ a = commandArgs(trailingOnly = TRUE); if (length(a) >= 1 && nzchar(a[1])) a[1] else NULL })
  h = start_engine(fsda_root = fsda_root)
  on.exit(try(stop_engine(h), silent = TRUE))

  diags = diagnostics(h)
  rs = list(case_numeric(h), case_struct(h), case_nested(h), case_fsr(h),
            case_fsraddt(h), case_table(h), case_univariatems(h),
            case_corrnominal(h), case_fsm(h), case_mcd(h),
            case_pcafs(h), case_cressieread(h),
            case_logfactorial(h), case_tabulatefs(h), case_tbwei(h),
            case_gower(h), case_tclustic(h),
            case_removeextraspaces(h), case_triu2vec(h),
            case_bc(h), case_combsfs(h), case_lexunrank(h),
            case_publishfs(h), case_distribspec(h), case_histfs(h), case_boxplotb(h))

  overall = all(vapply(rs, function(r) r$ok, logical(1)))
  cat("=== spec 018: generic FSDA engine — R surface ===\n")
  cat("R            :", diags$r, "\n")
  cat("reticulate   :", diags$reticulate, "\n")
  cat("Python       :", diags$python_version, "\n")
  cat("MATLAB       :", diags$matlab, "\n")
  cat("engine pkg   :", diags$matlabengine, "\n")
  cat(sprintf("tolerance    : atol %.0e\n", TOL))
  cat("cases (one shared fsda_call / eval_m):\n")
  for (r in rs) {
    cat(sprintf("  [%s]  %-30s  max abs diff %.3e   %s\n",
                if (r$ok) "PASS" else "FAIL", r$name, r$diff, r$note))
  }
  cat("RESULT       :", if (overall) "PASS" else "FAIL", "\n")
  if (overall) 0 else 1
}

status = tryCatch(main(), error = function(e) { cat("ERROR        :", conditionMessage(e), "\n"); 1 })
quit(status = status)
