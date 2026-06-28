# Spec-012 agreement tolerance: the R surface must reproduce the last 5 rows of
# the Python/FSDA out.Tdel golden from spec 010 to this absolute tolerance.
TOL = 1e-9
TAIL = 5   # the gate compares the last TAIL rows of out.Tdel
PLOTS = 1  # FSRaddt plot level (0 headless; 1 shows the deletion-t figure window)
MSG = 1    # FSRaddt message level (1 routes MATLAB's progress messages to this console)

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
  candidates = c(here, file.path(here, "code", "FSRaddt"))
  for (candidate in candidates) {
    if (file.exists(file.path(candidate, "bridge.R"))) {
      return(normalizePath(candidate, winslash = "/", mustWork = TRUE))
    }
  }

  stop("Cannot locate code/FSRaddt/check_FSRaddt_r.R; run from the repo or target directory.")
}

.running_as_script = function() {
  args = commandArgs(trailingOnly = FALSE)
  any(grepl("^--file=", args))
}

.load_wool = function(path) {
  # Genuine FSDA wool fixture persisted by check_FSRaddt.py (last column = y).
  if (!file.exists(path)) {
    stop(paste0("Missing fixture: ", path, ". Run code/FSRaddt/check_FSRaddt.py first."))
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

.load_golden_tdel = function(path) {
  # Spec 010 owns the FSDA golden; this check reproduces its last TAIL rows. The
  # golden is variable-width: header step,t1,t2,... (one t per tested variable).
  if (!file.exists(path)) {
    stop(paste0("Missing spec-010 golden artifact: ", path, ". Run code/FSRaddt/check_FSRaddt.py first."))
  }
  d = utils::read.csv(path, stringsAsFactors = FALSE)
  if (names(d)[1] != "step") {
    stop("Spec-010 golden must have first column step.")
  }
  M = as.matrix(d)
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
  cat("FSRaddt path : ", diagnostics$fsraddt_path, "\n", sep = "")
}

main = function() {
  script_dir = .script_dir()
  source(file.path(script_dir, "bridge.R"))

  reference_dir = file.path(script_dir, "reference")
  wool = .load_wool(file.path(reference_dir, "wool.csv"))
  golden = .load_golden_tdel(file.path(reference_dir, "FSRaddt_Tdel.csv"))

  args = commandArgs(trailingOnly = TRUE)
  fsda_root = if (length(args) > 0 && nzchar(args[[1]])) args[[1]] else NULL
  bridge = start_bridge(fsda_root = fsda_root)
  on.exit(try(stop_bridge(bridge), silent = TRUE), add = TRUE)

  diagnostics = bridge_diagnostics(bridge)
  res = fsraddt(bridge, wool$y, wool$X, nsamp = 0, intercept = TRUE, plots = PLOTS, msg = MSG)

  Tdel = res$Tdel
  if (nrow(Tdel) < TAIL || nrow(golden) < TAIL) {
    stop("need at least ", TAIL, " Tdel rows on both sides.")
  }
  if (ncol(Tdel) != ncol(golden)) {
    stop("Tdel width ", ncol(Tdel), " != golden width ", ncol(golden))
  }
  tail = Tdel[(nrow(Tdel) - TAIL + 1):nrow(Tdel), , drop = FALSE]
  gtail = golden[(nrow(golden) - TAIL + 1):nrow(golden), , drop = FALSE]
  abs_diff = abs(tail - gtail)
  row_diff = apply(abs_diff, 1, max)
  max_abs_diff = max(abs_diff)
  ok = all(dim(tail) == dim(gtail)) && all(abs_diff <= TOL)

  if (!dir.exists(reference_dir)) {
    dir.create(reference_dir, recursive = TRUE)
  }
  artifact = data.frame(step = tail[, 1])
  for (j in seq_len(ncol(tail) - 1)) {
    artifact[[paste0("t", j, "_surface")]] = tail[, j + 1]
    artifact[[paste0("t", j, "_golden")]] = gtail[, j + 1]
  }
  artifact$max_abs_diff = row_diff
  utils::write.csv(
    artifact,
    file = file.path(reference_dir, "FSRaddt_r_check.csv"),
    row.names = FALSE
  )

  cat("=== spec 012: R reticulate FSRaddt agreement check ===\n")
  .print_diagnostics(diagnostics)
  cat("tested vars  : la(1-b)=", paste(res$la, collapse = " "), "  (k=", length(res$la), ")\n", sep = "")
  cat("Un cells     : ", length(res$Un), " (cell->list); shapes ",
      paste(vapply(res$Un, function(u) paste(dim(u), collapse = "x"), character(1)), collapse = " "),
      "\n", sep = "")
  cat("Tdel last ", TAIL, " rows (step, deletion t-stats):\n", sep = "")
  for (i in seq_len(TAIL)) {
    cells = paste(sprintf("%.6f", tail[i, -1]), collapse = "  ")
    cat(sprintf("   %3d  %s\n", as.integer(tail[i, 1]), cells))
  }
  cat("max abs diff : ", formatC(max_abs_diff, digits = 3, format = "e"), "  (tol 1e-09)\n", sep = "")
  cat("RESULT       : ", if (ok) "PASS" else "FAIL", "\n", sep = "")

  # Keep the engine (and the figure window) alive until the user closes it
  # (on.exit then quits the engine). Blocking is driven MATLAB-side (uiwait):
  # reading a key in R does not work because the embedded Python/MATLAB engine
  # hijacks R's stdin. Gated on a real controlling terminal so piped / CI never hangs.
  if (PLOTS != 0 && .has_terminal()) {
    cat("Close the FSRaddt figure window(s) to stop the engine and finish...\n")
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
