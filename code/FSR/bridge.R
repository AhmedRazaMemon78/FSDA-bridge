# Layer-2 R surface for spec 009. The actual MATLAB/FSDA call stays in the
# Python bridge; this file owns reticulate setup and R-side shape checks. It is
# the `FSR` sibling of the spec-003/006 R surfaces.

.bridge_dir = local({
  # Prefer source(".../bridge.R") metadata, then fall back to common working
  # directories used by Rscript and interactive sessions.
  frames = sys.frames()
  for (i in rev(seq_along(frames))) {
    ofile = frames[[i]]$ofile
    if (!is.null(ofile) && nzchar(ofile) && basename(ofile) == "bridge.R") {
      return(normalizePath(dirname(ofile), winslash = "/", mustWork = TRUE))
    }
  }

  here = normalizePath(getwd(), winslash = "/", mustWork = TRUE)
  candidates = c(here, file.path(here, "code", "FSR"))
  for (candidate in candidates) {
    if (file.exists(file.path(candidate, "bridge.py"))) {
      return(normalizePath(candidate, winslash = "/", mustWork = TRUE))
    }
  }

  stop("Cannot locate code/FSR/bridge.py; source bridge.R from the repo or target directory.")
})

.require_reticulate = function() {
  if (!requireNamespace("reticulate", quietly = TRUE)) {
    stop("R package 'reticulate' is required for spec 009.")
  }
  asNamespace("reticulate")
}

.resolve_python = function(python) {
  # No machine-specific default in the repo: prefer FSDA_DEV_VENV (passed in as
  # `python`), then the active interpreter on PATH (python or python3, so macOS
  # works too), else stop with guidance.
  if (is.null(python) || !nzchar(python)) {
    found = Sys.which(c("python", "python3"))
    found = found[nzchar(found)]
    python = if (length(found) > 0) unname(found[[1]]) else ""
  }
  if (!nzchar(python)) {
    stop(
      "No Python interpreter found. Set FSDA_DEV_VENV to your venv's python ",
      "executable (Scripts\\python.exe on Windows, bin/python on macOS) that ",
      "has matlabengine installed."
    )
  }
  normalizePath(python, winslash = "/", mustWork = FALSE)
}

.configure_python = function(reticulate, python) {
  # Accept a direct executable, a virtualenv root, or a conda-style root. This
  # must run before any Python import because reticulate locks the interpreter.
  root_python = file.path(python, "python.exe")
  scripts_python = file.path(python, "Scripts", "python.exe")
  bin_python = file.path(python, "bin", "python")
  pyvenv_cfg = file.path(python, "pyvenv.cfg")

  if (file.exists(python)) {
    reticulate$use_python(python, required = TRUE)
  } else if (dir.exists(python) && file.exists(pyvenv_cfg)) {
    reticulate$use_virtualenv(python, required = TRUE)
  } else if (file.exists(root_python)) {
    reticulate$use_python(root_python, required = TRUE)
  } else if (file.exists(scripts_python)) {
    reticulate$use_python(scripts_python, required = TRUE)
  } else if (file.exists(bin_python)) {
    reticulate$use_python(bin_python, required = TRUE)
  } else {
    stop(
      paste0(
        "Python venv or executable not found: ", python,
        ". Set FSDA_DEV_VENV to the project venv or a Python executable with matlabengine."
      )
    )
  }
}

.as_double_matrix = function(x, name) {
  # Strip dimnames and coerce numeric storage while preserving the explicit
  # matrix shape reticulate will pass to Python.
  if (!is.matrix(x) || length(dim(x)) != 2 || !is.numeric(x)) {
    stop(name, " must be a 2D numeric matrix.")
  }
  out = matrix(as.numeric(x), nrow = nrow(x), ncol = ncol(x))
  dimnames(out) = NULL
  out
}

.validate_inputs = function(y, X) {
  # Fail before crossing the R/Python boundary; bridge.py performs the matching
  # authoritative checks before calling MATLAB.
  if (is.matrix(y)) {
    if (ncol(y) != 1) {
      stop("y must be a numeric vector or n x 1 matrix.")
    }
    y = as.numeric(y)
  } else if (is.numeric(y) && is.null(dim(y))) {
    y = as.numeric(y)
  } else {
    stop("y must be a numeric vector or n x 1 matrix.")
  }
  n = length(y)
  if (n < 1) {
    stop("y must have at least one element.")
  }

  X = .as_double_matrix(X, "X")
  if (nrow(X) != n) {
    stop("X must have ", n, " rows to match y, got ", nrow(X), ".")
  }

  list(y = y, X = X)
}

.validate_bridge = function(bridge) {
  if (!inherits(bridge, "fsda_fsr_bridge") ||
      is.null(bridge$module) ||
      is.null(bridge$engine)) {
    stop("bridge must be a handle returned by start_bridge().")
  }
}

.scalar_string = function(x) {
  paste(as.character(unlist(x, recursive = TRUE, use.names = FALSE)), collapse = " ")
}

start_bridge = function(python = Sys.getenv("FSDA_DEV_VENV"), fsda_root = NULL) {
  # Import the local Python bridge and start a reusable MATLAB engine session.
  reticulate = .require_reticulate()
  python = .resolve_python(python)
  .configure_python(reticulate, python)

  # Python caches imported modules by their bare name, and every FSDA target's
  # Layer-1 file is named bridge.py. Evict any 'bridge' cached by a different
  # target (e.g. mahalFS / Score) so THIS target's code/FSR/bridge.py is loaded
  # fresh. Without this, using two targets in one R session returns the first-
  # imported module (AttributeError on the other target's helpers) until R restart.
  reticulate$py_run_string("import sys; sys.modules.pop('bridge', None)")
  module = reticulate$import_from_path("bridge", path = .bridge_dir, convert = TRUE)
  if (is.null(fsda_root) || !nzchar(fsda_root)) {
    engine = module$start_engine()
  } else {
    engine = module$start_engine(fsda_root = fsda_root)
  }

  handle = list(
    module = module,
    engine = engine,
    python = python,
    bridge_dir = .bridge_dir
  )
  class(handle) = "fsda_fsr_bridge"
  handle
}

fsr = function(bridge, y, X, nsamp = 0, intercept = TRUE, plots = 0, msg = 0,
               h = NULL, init = NULL, bonflev = NULL) {
  # Run FSDA FSR through the Python bridge; return the key fields as plain R.
  .validate_bridge(bridge)
  inputs = .validate_inputs(y, X)
  # reticulate maps R named args to Python keyword args (NULL -> None); bridge.py
  # reads the struct fields, normalizes the 1-based outlier indices
  # (scalar/array/empty) to a clean vector, and handles plots/msg (default off;
  # msg routes MATLAB's messages to this console, plots opens live figure windows).
  res = bridge$module$fsr(
    bridge$engine, inputs$y, inputs$X,
    nsamp = as.integer(nsamp), intercept = isTRUE(intercept),
    plots = as.integer(plots), msg = as.integer(msg),
    h = h, init = init, bonflev = bonflev
  )

  mdr = as.matrix(res$mdr)
  if (ncol(mdr) != 2) {
    stop("expected FSR mdr to have 2 columns, got ", ncol(mdr))
  }
  dimnames(mdr) = NULL
  list(
    mdr = mdr,
    outliers = as.integer(res$outliers),   # 1-based unit indices (empty if none)
    beta = as.numeric(res$beta),
    scale = as.numeric(res$scale)
  )
}

render_figures = function(bridge) {
  # Force any open MATLAB figures (from fsr(plots=...)) to paint.
  .validate_bridge(bridge)
  bridge$module$render_figures(bridge$engine)
  invisible(NULL)
}

wait_for_figures = function(bridge) {
  # Block until the user closes all open MATLAB figures. Driven MATLAB-side
  # (uiwait), so it is immune to the terminal-stdin interference that makes
  # reading a key in R fail once the engine is embedded via reticulate. Returns
  # at once if no figures are open.
  .validate_bridge(bridge)
  bridge$module$wait_for_figures(bridge$engine)
  invisible(NULL)
}

stop_bridge = function(bridge) {
  # MATLAB engine startup is expensive, so callers control shutdown explicitly.
  .validate_bridge(bridge)
  bridge$module$stop_engine(bridge$engine)
  invisible(NULL)
}

bridge_diagnostics = function(bridge) {
  # Keep MATLAB-specific diagnostics behind Python helper functions to avoid
  # reticulate probing MATLAB engine method signatures directly.
  .validate_bridge(bridge)
  reticulate = .require_reticulate()
  py_config = reticulate$py_config()
  metadata = reticulate$import("importlib.metadata", convert = TRUE)
  engine_pkg = tryCatch(
    metadata$version("matlabengine"),
    error = function(e) "n/a"
  )

  list(
    r = as.character(getRversion()),
    reticulate = as.character(utils::packageVersion("reticulate")),
    python = .scalar_string(py_config$python),
    python_version = .scalar_string(py_config$version_string),
    matlab = bridge$module$matlab_version(bridge$engine),
    matlabengine = engine_pkg,
    fsr_path = bridge$module$which_fsr(bridge$engine),
    bridge_dir = bridge$bridge_dir,
    requested_python = bridge$python
  )
}
