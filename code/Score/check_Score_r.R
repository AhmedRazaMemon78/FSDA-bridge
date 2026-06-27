# Spec-006 agreement tolerance: the R surface must reproduce the Python/FSDA
# oracle artifact from spec 004 to this absolute tolerance.
TOL = 1e-9

.script_dir = function() {
  # Support both Rscript and source() from an interactive session launched at
  # either the repo root or the target folder.
  args = commandArgs(trailingOnly = FALSE)
  file_arg = args[grepl("^--file=", args)]
  if (length(file_arg) > 0) {
    script = sub("^--file=", "", file_arg[[1]])
    return(normalizePath(dirname(script), winslash = "/", mustWork = TRUE))
  }

  here = normalizePath(getwd(), winslash = "/", mustWork = TRUE)
  candidates = c(here, file.path(here, "code", "Score"))
  for (candidate in candidates) {
    if (file.exists(file.path(candidate, "bridge.R"))) {
      return(normalizePath(candidate, winslash = "/", mustWork = TRUE))
    }
  }

  stop("Cannot locate code/Score/check_Score_r.R; run from the repo or target directory.")
}

.running_as_script = function() {
  # When sourced, return the status invisibly instead of terminating R.
  args = commandArgs(trailingOnly = FALSE)
  any(grepl("^--file=", args))
}
.format_vector = function(x) {
  paste(formatC(x, digits = 10, format = "fg"), collapse = " ")
}

.load_wool = function(path) {
  # Genuine FSDA wool fixture persisted by check_Score.py (last column = y).
  if (!file.exists(path)) {
    stop(
      paste0("Missing fixture: ", path, ". Run code/Score/check_Score.py first.")
    )
  }
  d = utils::read.csv(path, stringsAsFactors = FALSE)
  M = as.matrix(d)
  storage.mode(M) = "double"
  dimnames(M) = NULL
  ncol_M = ncol(M)
  if (ncol_M < 2) {
    stop("wool fixture must have at least one predictor plus y.")
  }
  list(y = M[, ncol_M], X = M[, seq_len(ncol_M - 1), drop = FALSE])
}

.load_oracle = function(reference_path, la) {
  # Spec 004 owns the genuine FSDA oracle artifact; this check only verifies
  # that the R wrapper reproduces it for the same fixed input.
  if (!file.exists(reference_path)) {
    stop(
      paste0(
        "Missing spec-004 oracle artifact: ", reference_path,
        ". Run code/Score/check_Score.py first."
      )
    )
  }

  oracle = utils::read.csv(reference_path, stringsAsFactors = FALSE)
  required = c("la", "Score_fsda")
  missing = setdiff(required, names(oracle))
  if (length(missing) > 0) {
    stop("Spec-004 oracle is missing columns: ", paste(missing, collapse = ", "))
  }
  if (nrow(oracle) != length(la) || any(abs(oracle$la - la) > 0)) {
    stop("Spec-004 oracle la column does not match the spec-006 fixed la.")
  }

  as.numeric(oracle$Score_fsda)
}

.print_diagnostics = function(diagnostics) {
  # Print enough environment detail to make reticulate/Python/MATLAB mismatches
  # visible when the agreement check is run on another machine.
  cat("R            : ", diagnostics$r, "\n", sep = "")
  cat("reticulate   : ", diagnostics$reticulate, "\n", sep = "")
  cat("Python       : ", diagnostics$python_version, "\n", sep = "")
  cat("Python path  : ", diagnostics$python, "\n", sep = "")
  cat("MATLAB       : ", diagnostics$matlab, "\n", sep = "")
  cat("engine pkg   : ", diagnostics$matlabengine, "\n", sep = "")
  cat("Score path   : ", diagnostics$score_path, "\n", sep = "")
}

main = function() {
  # Fixed fixture shared with spec 004 (genuine FSDA wool; default la).
  script_dir = .script_dir()
  source(file.path(script_dir, "bridge.R"))

  LA = c(-1.0, -0.5, 0.0, 0.5, 1.0)

  reference_dir = file.path(script_dir, "reference")
  wool = .load_wool(file.path(reference_dir, "wool.csv"))
  oracle_sc = .load_oracle(file.path(reference_dir, "Score_check.csv"), LA)

  args = commandArgs(trailingOnly = TRUE)
  fsda_root = if (length(args) > 0 && nzchar(args[[1]])) args[[1]] else NULL
  bridge = start_bridge(fsda_root = fsda_root)
  # Always ask MATLAB to quit, including failed comparisons or write errors.
  on.exit(try(stop_bridge(bridge), silent = TRUE), add = TRUE)

  diagnostics = bridge_diagnostics(bridge)
  sc = score(bridge, wool$y, wool$X, la = LA, intercept = TRUE)

  abs_diff = abs(sc - oracle_sc)
  max_abs_diff = max(abs_diff)
  ok = length(sc) == length(oracle_sc) && all(abs_diff <= TOL)

  if (!dir.exists(reference_dir)) {
    # Ensure the reference folder exists before writing the R artifact.
    dir.create(reference_dir, recursive = TRUE)
  }
  # Save the R-specific gold artifact for later wrapper comparisons.
  artifact = data.frame(
    i = seq_along(LA),
    la = LA,
    Score_surface = sc,
    Score_oracle = oracle_sc,
    abs_diff = abs_diff
  )
  utils::write.csv(
    artifact,
    file = file.path(reference_dir, "Score_r_check.csv"),
    row.names = FALSE
  )

  cat("=== spec 006: R reticulate Score agreement check ===\n")
  .print_diagnostics(diagnostics)
  cat("lambda       : ", .format_vector(LA), "\n", sep = "")
  cat("R surface    : ", .format_vector(sc), "\n", sep = "")
  cat("oracle       : ", .format_vector(oracle_sc), "\n", sep = "")
  cat("max abs diff : ", formatC(max_abs_diff, digits = 3, format = "e"), "  (tol 1e-09)\n", sep = "")
  cat("RESULT       : ", if (ok) "PASS" else "FAIL", "\n", sep = "")

  if (ok) 0 else 1
}

status = tryCatch(
  main(),
  error = function(e) {
    cat("ERROR        : ", conditionMessage(e), "\n", sep = "", file = stderr())
    1
  }
)
if (.running_as_script()) {
  quit(status = status, save = "no")
}

invisible(status)
