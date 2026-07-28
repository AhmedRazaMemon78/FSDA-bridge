#' Run the MATLAB FSRfan function
#'
#' Wrapper around the MATLAB FSDA FSRfan routine.
#'
#' @param handle Engine handle returned by start_engine().
#' @param y Response vector.
#' @param X Predictor matrix.
#' @param ... Additional MATLAB parameters.
#'
#' @return MATLAB output returned as an R object.
#'
#' @export
FSRfan <- function(handle, y, X, ...) {

  fsda_call(
    handle,
    "FSRfan",
    y,
    X,
    ...
  )

}