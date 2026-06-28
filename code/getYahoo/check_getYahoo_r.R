# Spec-015 agreement tolerance: the R surface must reproduce the fixed-window OHLCV
# golden from the Python/FSDA spec 013 to this absolute tolerance.
TOL = 1e-9
PLOTS = 1  # getYahoo plot level (0 headless; 1 shows a three-panel figure per ticker)
MSG = 1    # getYahoo message level (1 routes progress messages to this console)

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
  candidates = c(here, file.path(here, "code", "getYahoo"))
  for (candidate in candidates) {
    if (file.exists(file.path(candidate, "bridge.R"))) {
      return(normalizePath(candidate, winslash = "/", mustWork = TRUE))
    }
  }

  stop("Cannot locate code/getYahoo/check_getYahoo_r.R; run from the repo or target directory.")
}

.running_as_script = function() {
  args = commandArgs(trailingOnly = FALSE)
  any(grepl("^--file=", args))
}

.load_golden = function(path) {
  # Spec 013 owns the OHLCV golden; this check reproduces it. Columns:
  # ticker,time,Open,High,Low,Close,Volume.
  if (!file.exists(path)) {
    stop(paste0("Missing spec-013 golden artifact: ", path, ". Run check_getYahoo.py first."))
  }
  d = utils::read.csv(path, stringsAsFactors = FALSE, colClasses = "character")
  need = c("ticker", "time", "Open", "High", "Low", "Close", "Volume")
  if (!all(need %in% names(d))) {
    stop("Spec-013 golden must have columns ticker,time,Open,High,Low,Close,Volume.")
  }
  rows = lapply(seq_len(nrow(d)), function(i) {
    list(
      ticker = d$ticker[i],
      time = d$time[i],
      ohlcv = as.numeric(c(d$Open[i], d$High[i], d$Low[i], d$Close[i], d$Volume[i]))
    )
  })
  rows
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
  cat("getYahoo path: ", diagnostics$getyahoo_path, "\n", sep = "")
}

.surface_rows = function(bridge, res, q) {
  # Run the fixed timerange window over every ticker; flatten to gate rows.
  rows = list()
  for (idx in seq_along(res)) {   # 1-based, matching MATLAB out(idx)
    win = timerange_window(bridge, idx, q$t0, q$t1)
    times = as.character(win$time)
    for (j in seq_along(times)) {
      rows[[length(rows) + 1]] = list(
        ticker = res[[idx]]$Ticker,
        time = times[j],
        ohlcv = as.numeric(c(win$Open[j], win$High[j], win$Low[j],
                             win$Close[j], win$Volume[j]))
      )
    }
  }
  rows
}

main = function() {
  script_dir = .script_dir()
  source(file.path(script_dir, "bridge.R"))

  reference_dir = file.path(script_dir, "reference")
  query_path = file.path(reference_dir, "getYahoo_query.json")
  if (!file.exists(query_path)) {
    stop(paste0("Missing fixture: ", query_path, ". Run check_getYahoo.py first."))
  }
  golden = .load_golden(file.path(reference_dir, "getYahoo_window.csv"))

  args = commandArgs(trailingOnly = TRUE)
  fsda_root = if (length(args) > 0 && nzchar(args[[1]])) args[[1]] else NULL
  bridge = start_bridge(fsda_root = fsda_root)
  on.exit(try(stop_bridge(bridge), silent = TRUE), add = TRUE)

  # Parse the shared fixed input via Python's json (no extra R dependency); NULLs
  # for last_period / interval map straight back to Python None on the next call.
  reticulate = asNamespace("reticulate")
  json = reticulate$import("json", convert = TRUE)
  q = json$loads(paste(readLines(query_path), collapse = "\n"))

  diagnostics = bridge_diagnostics(bridge)
  res = get_yahoo(bridge, as.character(q$tickers), plots = PLOTS, msg = MSG,
                  last_period = q$last_period, interval = q$interval)

  cat("=== spec 015: R reticulate getYahoo agreement check ===\n")
  .print_diagnostics(diagnostics)
  cat("tickers      : ", paste(vapply(res, function(r) r$Ticker, ""), collapse = " "),
      "  (nout=", length(res), ")\n", sep = "")
  for (r in res) {
    cat(sprintf("  %-8s Success=%s interval=%s tz=%s TT=%d rows  msg='%s'\n",
                r$Ticker, as.character(isTRUE(r$Success)), r$intervalActual,
                r$TimeZone, length(r$TT$time), r$Message))
  }

  # Network / availability handling: if nothing downloaded, this is almost
  # certainly an unreachable Yahoo (or offline CI) -- SKIP rather than FAIL.
  if (!any(vapply(res, function(r) isTRUE(r$Success), logical(1)))) {
    cat("SKIP         : Yahoo returned no data for any ticker ",
        "(unreachable / offline?) -- deterministic gate not evaluated.\n", sep = "")
    return(0)
  }

  rows = .surface_rows(bridge, res, q)
  if (length(rows) == 0) {
    cat("window       : ", q$t0, " .. ", q$t1, "\n", sep = "")
    cat("RESULT       : FAIL -- no bar fell inside the fixed window ",
        "(bar aged out? refresh t0/t1 in getYahoo_query.json).\n", sep = "")
    return(1)
  }

  labels = vapply(rows, function(r) paste(r$ticker, r$time), "")
  glabels = vapply(golden, function(g) paste(g$ticker, g$time), "")
  ok = length(rows) == length(golden) && identical(labels, glabels)
  diffs = numeric(0)
  if (ok) {
    diffs = vapply(seq_along(rows),
                   function(i) max(abs(rows[[i]]$ohlcv - golden[[i]]$ohlcv)), 0)
  }
  max_abs_diff = if (length(diffs) == 0) Inf else max(diffs)
  ok = ok && all(diffs <= TOL)

  if (!dir.exists(reference_dir)) {
    dir.create(reference_dir, recursive = TRUE)
  }
  if (length(diffs) > 0) {
    artifact = data.frame(
      ticker = vapply(rows, function(r) r$ticker, ""),
      time = vapply(rows, function(r) r$time, ""),
      Open = vapply(rows, function(r) r$ohlcv[1], 0),
      High = vapply(rows, function(r) r$ohlcv[2], 0),
      Low = vapply(rows, function(r) r$ohlcv[3], 0),
      Close = vapply(rows, function(r) r$ohlcv[4], 0),
      Volume = vapply(rows, function(r) r$ohlcv[5], 0),
      abs_diff = diffs
    )
    utils::write.csv(
      artifact,
      file = file.path(reference_dir, "getYahoo_r_check.csv"),
      row.names = FALSE
    )
  }

  cat("window       : ", q$t0, " .. ", q$t1, "\n", sep = "")
  cat("fixed-window OHLCV (ticker, time, O, H, L, C, V):\n")
  for (r in rows) {
    cat(sprintf("  %-8s %s  %.6f %.6f %.6f %.6f %.0f\n",
                r$ticker, r$time, r$ohlcv[1], r$ohlcv[2], r$ohlcv[3],
                r$ohlcv[4], r$ohlcv[5]))
  }
  cat("max abs diff : ", formatC(max_abs_diff, digits = 3, format = "e"), "  (tol 1e-09)\n", sep = "")
  cat("RESULT       : ", if (ok) "PASS" else "FAIL", "\n", sep = "")

  # Keep the engine (and the figure windows) alive until the user closes them
  # (on.exit then quits the engine). Blocking is driven MATLAB-side (uiwait):
  # reading a key in R does not work because the embedded Python/MATLAB engine
  # hijacks R's stdin. Gated on a real controlling terminal so piped / CI never hangs.
  if (PLOTS != 0 && .has_terminal()) {
    cat("Close the getYahoo figure window(s) to stop the engine and finish...\n")
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
