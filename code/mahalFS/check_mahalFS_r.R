# Spec-003 agreement tolerance: the R surface must reproduce the Python/FSDA
# oracle artifact from spec 001 to this absolute tolerance.
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
  candidates = c(here, file.path(here, "code", "mahalFS"))
  for (candidate in candidates) {
    if (file.exists(file.path(candidate, "bridge.R"))) {
      return(normalizePath(candidate, winslash = "/", mustWork = TRUE))
    }
  }

  stop("Cannot locate code/mahalFS/check_mahalFS_r.R; run from the repo or target directory.")
}

.running_as_script = function() {
  # When sourced, return the status invisibly instead of terminating R.
  args = commandArgs(trailingOnly = FALSE)
  any(grepl("^--file=", args))
}
.format_vector = function(x) {
  paste(formatC(x, digits = 10, format = "fg"), collapse = " ")
}

.load_oracle = function(reference_path, Y) {
  # Spec 001 owns the genuine FSDA oracle artifact; this check only verifies
  # that the R wrapper reproduces it for the same fixed input.
  if (!file.exists(reference_path)) {
    stop(
      paste0(
        "Missing spec-001 oracle artifact: ", reference_path,
        ". Run code/mahalFS/check_mahalFS.py first."
      )
    )
  }

  oracle = utils::read.csv(reference_path, stringsAsFactors = FALSE)
  required = c("y1", "y2", "d_fsda")
  missing = setdiff(required, names(oracle))
  if (length(missing) > 0) {
    stop("Spec-001 oracle is missing columns: ", paste(missing, collapse = ", "))
  }
  if (nrow(oracle) != nrow(Y) ||
      any(abs(oracle$y1 - Y[, 1]) > 0) ||
      any(abs(oracle$y2 - Y[, 2]) > 0)) {
    stop("Spec-001 oracle inputs do not match the spec-003 fixed input.")
  }

  as.numeric(oracle$d_fsda)
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
  cat("mahalFS path : ", diagnostics$mahalfs_path, "\n", sep = "")
}

main = function() {
  # Fixed fixture shared with spec 001.
  script_dir = .script_dir()
  source(file.path(script_dir, "bridge.R"))

  Y = matrix(
    c(1.0, 2.0,
      2.0, 0.0,
      3.0, 5.0,
      0.0, -1.0,
      4.0, 4.0),
    ncol = 2,
    byrow = TRUE
  )
  MU = c(2.0, 2.0)
  SIGMA = matrix(
    c(2.0, 0.5,
      0.5, 1.0),
    ncol = 2,
    byrow = TRUE
  )

  reference_dir = file.path(script_dir, "reference")
  oracle_path = file.path(reference_dir, "mahalFS_check.csv")
  oracle_d = .load_oracle(oracle_path, Y)

  args = commandArgs(trailingOnly = TRUE)
  fsda_root = if (length(args) > 0 && nzchar(args[[1]])) args[[1]] else NULL
  bridge = start_bridge(fsda_root = fsda_root)
  # Always ask MATLAB to quit, including failed comparisons or write errors.
  on.exit(try(stop_bridge(bridge), silent = TRUE), add = TRUE)

  diagnostics = bridge_diagnostics(bridge)
  d_fsda = mahal_fs(bridge, Y, MU, SIGMA)

  abs_diff = abs(d_fsda - oracle_d)
  max_abs_diff = max(abs_diff)
  ok = length(d_fsda) == length(oracle_d) && all(abs_diff <= TOL)

  if (!dir.exists(reference_dir)) {
    # Ensure the reference folder exists before writing the R artifact.
    dir.create(reference_dir, recursive = TRUE)
  }
  # Save the R-specific gold artifact for later wrapper comparisons.
  artifact = data.frame(
    i = seq_len(nrow(Y)),
    y1 = Y[, 1],
    y2 = Y[, 2],
    d_fsda = d_fsda,
    d_oracle = oracle_d,
    abs_diff = abs_diff
  )
  utils::write.csv(
    artifact,
    file = file.path(reference_dir, "mahalFS_r_check.csv"),
    row.names = FALSE
  )

  cat("=== spec 003: R reticulate mahalFS agreement check ===\n")
  .print_diagnostics(diagnostics)
  cat("R surface    : ", .format_vector(d_fsda), "\n", sep = "")
  cat("oracle       : ", .format_vector(oracle_d), "\n", sep = "")
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
