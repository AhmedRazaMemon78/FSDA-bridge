# Spec-009 agreement tolerance: the R surface must reproduce the last 5 rows of
# the Python/FSDA out.mdr golden from spec 007 to this absolute tolerance.
TOL = 1e-9
TAIL = 5   # the gate compares the last TAIL rows of out.mdr
PLOTS = 1  # FSR plot level (0 headless; 1 shows the mdr figure window)
MSG = 1    # FSR message level (1 routes MATLAB's progress messages to this console)

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
  candidates = c(here, file.path(here, "code", "FSR"))
  for (candidate in candidates) {
    if (file.exists(file.path(candidate, "bridge.R"))) {
      return(normalizePath(candidate, winslash = "/", mustWork = TRUE))
    }
  }

  stop("Cannot locate code/FSR/check_FSR_r.R; run from the repo or target directory.")
}

.running_as_script = function() {
  args = commandArgs(trailingOnly = FALSE)
  any(grepl("^--file=", args))
}

.load_stars = function(path) {
  # Genuine FSDA stars fixture persisted by check_FSR.py (last column = y).
  if (!file.exists(path)) {
    stop(paste0("Missing fixture: ", path, ". Run code/FSR/check_FSR.py first."))
  }
  d = utils::read.csv(path, stringsAsFactors = FALSE)
  M = as.matrix(d)
  storage.mode(M) = "double"
  dimnames(M) = NULL
  ncol_M = ncol(M)
  if (ncol_M < 2) {
    stop("stars fixture must have at least one predictor plus y.")
  }
  list(y = M[, ncol_M], X = M[, seq_len(ncol_M - 1), drop = FALSE])
}

.load_golden_mdr = function(path) {
  # Spec 007 owns the FSDA golden; this check reproduces its last TAIL rows.
  if (!file.exists(path)) {
    stop(paste0("Missing spec-007 golden artifact: ", path, ". Run code/FSR/check_FSR.py first."))
  }
  d = utils::read.csv(path, stringsAsFactors = FALSE)
  if (!all(c("step", "mdr") %in% names(d))) {
    stop("Spec-007 golden must have columns step,mdr.")
  }
  M = as.matrix(d[, c("step", "mdr")])
  storage.mode(M) = "double"
  dimnames(M) = NULL
  M
}

.has_terminal = function() {
  # Reliable interactive check under Rscript (isatty(stdin()) is not, and the
  # embedded engine interferes with R's stdin so key-reading cannot work). Can we
  # open the controlling terminal? TRUE in a real terminal, FALSE when piped / in
  # CI / with no tty (and on Windows, where /dev/tty does not exist).
  con = suppressWarnings(tryCatch(file("/dev/tty", open = "r"), error = function(e) NULL))
  if (is.null(con)) {
    return(FALSE)
  }
  close(con)
  TRUE
}

.print_diagnostics = function(diagnostics) {
  cat("R            : ", diagnostics$r, "\n", sep = "")
  cat("reticulate   : ", diagnostics$reticulate, "\n", sep = "")
  cat("Python       : ", diagnostics$python_version, "\n", sep = "")
  cat("Python path  : ", diagnostics$python, "\n", sep = "")
  cat("MATLAB       : ", diagnostics$matlab, "\n", sep = "")
  cat("engine pkg   : ", diagnostics$matlabengine, "\n", sep = "")
  cat("FSR path     : ", diagnostics$fsr_path, "\n", sep = "")
}

main = function() {
  script_dir = .script_dir()
  source(file.path(script_dir, "bridge.R"))

  reference_dir = file.path(script_dir, "reference")
  stars = .load_stars(file.path(reference_dir, "stars.csv"))
  golden = .load_golden_mdr(file.path(reference_dir, "FSR_mdr.csv"))

  args = commandArgs(trailingOnly = TRUE)
  fsda_root = if (length(args) > 0 && nzchar(args[[1]])) args[[1]] else NULL
  bridge = start_bridge(fsda_root = fsda_root)
  on.exit(try(stop_bridge(bridge), silent = TRUE), add = TRUE)

  diagnostics = bridge_diagnostics(bridge)
  res = fsr(bridge, stars$y, stars$X, nsamp = 0, intercept = TRUE, plots = PLOTS, msg = MSG)

  mdr = res$mdr
  if (nrow(mdr) < TAIL || nrow(golden) < TAIL) {
    stop("need at least ", TAIL, " mdr rows on both sides.")
  }
  tail = mdr[(nrow(mdr) - TAIL + 1):nrow(mdr), , drop = FALSE]
  gtail = golden[(nrow(golden) - TAIL + 1):nrow(golden), , drop = FALSE]
  abs_diff = abs(tail - gtail)
  row_diff = apply(abs_diff, 1, max)
  max_abs_diff = max(abs_diff)
  ok = all(dim(tail) == dim(gtail)) && all(abs_diff <= TOL)

  if (!dir.exists(reference_dir)) {
    dir.create(reference_dir, recursive = TRUE)
  }
  artifact = data.frame(
    step = tail[, 1],
    mdr_surface = tail[, 2],
    mdr_golden = gtail[, 2],
    abs_diff = row_diff
  )
  utils::write.csv(
    artifact,
    file = file.path(reference_dir, "FSR_r_check.csv"),
    row.names = FALSE
  )

  cat("=== spec 009: R reticulate FSR agreement check ===\n")
  .print_diagnostics(diagnostics)
  cat("outliers(1-b): ", paste(res$outliers, collapse = " "), "\n", sep = "")
  cat("mdr last ", TAIL, " rows (step, surface, golden):\n", sep = "")
  for (i in seq_len(TAIL)) {
    cat(sprintf("   %3d  %.10f  %.10f\n", as.integer(tail[i, 1]), tail[i, 2], gtail[i, 2]))
  }
  cat("max abs diff : ", formatC(max_abs_diff, digits = 3, format = "e"), "  (tol 1e-09)\n", sep = "")
  cat("RESULT       : ", if (ok) "PASS" else "FAIL", "\n", sep = "")

  # Keep the engine (and the figure windows) alive until the user closes them
  # (on.exit then quits the engine). Blocking is driven MATLAB-side (uiwait):
  # reading a key in R does not work because the embedded Python/MATLAB engine
  # hijacks R's stdin. Gated on a real controlling terminal so piped / CI never hangs.
  if (PLOTS != 0 && .has_terminal()) {
    cat("Close the FSR figure window(s) to stop the engine and finish...\n")
    wait_for_figures(bridge)
  }

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
