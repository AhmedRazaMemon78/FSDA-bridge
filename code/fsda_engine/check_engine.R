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

main = function() {
  fsda_root = local({ a = commandArgs(trailingOnly = TRUE); if (length(a) >= 1 && nzchar(a[1])) a[1] else NULL })
  h = start_engine(fsda_root = fsda_root)
  on.exit(try(stop_engine(h), silent = TRUE))

  diags = diagnostics(h)
  rs = list(case_numeric(h), case_struct(h), case_nested(h), case_fsr(h),
            case_fsraddt(h), case_table(h), case_univariatems(h))

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
