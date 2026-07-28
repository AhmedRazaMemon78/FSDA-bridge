#' Run the MATLAB Score function
#'
#' Wrapper around the MATLAB FSDA Score routine.
#'
#' @param handle Engine handle returned by start_engine().
#' @param y Response vector.
#' @param X Predictor matrix.
#' @param ... Additional MATLAB parameters.
#'
#' @return MATLAB output returned as an R object.
#'
#' @export
Score <- function(handle, y, X, ...) {

  fsda_call(
    handle,
    "Score",
    y,
    X,
    ...
  )

}