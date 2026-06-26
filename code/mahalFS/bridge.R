# Layer-2 R surface for spec 003. The actual MATLAB/FSDA call stays in the
# Python bridge; this file owns reticulate setup and R-side shape checks.

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
  candidates = c(here, file.path(here, "code", "mahalFS"))
  for (candidate in candidates) {
    if (file.exists(file.path(candidate, "bridge.py"))) {
      return(normalizePath(candidate, winslash = "/", mustWork = TRUE))
    }
  }

  stop("Cannot locate code/mahalFS/bridge.py; source bridge.R from the repo or target directory.")
})

.require_reticulate = function() {
  if (!requireNamespace("reticulate", quietly = TRUE)) {
    stop("R package 'reticulate' is required for spec 003.")
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

.validate_inputs = function(Y, MU, SIGMA) {
  # Fail before crossing the R/Python boundary; bridge.py performs the matching
  # authoritative checks before calling MATLAB.
  Y = .as_double_matrix(Y, "Y")
  n = nrow(Y)
  v = ncol(Y)
  if (n < 1 || v < 1) {
    stop("Y must have at least one row and one column.")
  }

  if (is.matrix(MU)) {
    MU = .as_double_matrix(MU, "MU")
    if (nrow(MU) != 1 || ncol(MU) != v) {
      stop("MU must be length ", v, " or a 1 x ", v, " numeric matrix.")
    }
  } else if (is.numeric(MU) && is.null(dim(MU))) {
    if (length(MU) != v) {
      stop("MU must be length ", v, " or a 1 x ", v, " numeric matrix.")
    }
    MU = matrix(as.numeric(MU), nrow = 1)
  } else {
    stop("MU must be a numeric vector or one-row numeric matrix.")
  }

  SIGMA = .as_double_matrix(SIGMA, "SIGMA")
  if (nrow(SIGMA) != v || ncol(SIGMA) != v) {
    stop("SIGMA must be a ", v, " x ", v, " numeric matrix.")
  }

  list(Y = Y, MU = MU, SIGMA = SIGMA)
}

.validate_bridge = function(bridge) {
  if (!inherits(bridge, "fsda_mahalfs_bridge") ||
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
  class(handle) = "fsda_mahalfs_bridge"
  handle
}

mahal_fs = function(bridge, Y, MU, SIGMA) {
  # Return the FSDA squared Mahalanobis distances as a plain R numeric vector.
  .validate_bridge(bridge)
  inputs = .validate_inputs(Y, MU, SIGMA)
  d = bridge$module$mahal_fs(bridge$engine, inputs$Y, inputs$MU, inputs$SIGMA)
  d = as.numeric(d)
  if (length(d) != nrow(inputs$Y)) {
    stop("expected FSDA output length ", nrow(inputs$Y), ", got ", length(d), ".")
  }
  d
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
    mahalfs_path = bridge$module$which_mahalfs(bridge$engine),
    bridge_dir = bridge$bridge_dir,
    requested_python = bridge$python
  )
}
