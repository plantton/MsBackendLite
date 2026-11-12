#' @include hidden_aliases.R
NULL

#' @title Read-only SQLite backend for Spectra
#'
#' @aliases MsBackendLite-class
#'
#' @description
#'
#' `MsBackendLite` stores mass spectrometry data in a single SQLite file and
#' never changes that file. m/z and intensity values are stored as plain
#' numeric columns, one row per peak, and are read in chunks sized by number
#' of peaks.
#'
#' `MsBackendLite()` returns an empty backend. A database is created with
#' `export()` from a [Spectra::Spectra()] object that uses any backend:
#'
#' ```
#' export(sps, MsBackendLite(), file = "data.sqlite")
#' ```
#'
#' The processing queue of the `Spectra` object is applied while writing, so
#' the new file contains the processed peaks. Peaks with a missing m/z or
#' intensity are dropped and peaks are sorted by m/z. The summary variables
#' `peaksCount`, `totIonCurrent`, `basePeakMZ`, `basePeakIntensity`,
#' `lowMZ` and `highMZ` are recomputed from the stored peaks. Spectra
#' variables of type `integer`, `numeric`, `character`, `factor` (stored as
#' character) and `logical` are stored; other variables (for example lists)
#' are dropped with a message.
#'
#' Profile-mode data is refused: spectra with `centroided` `FALSE` stop the
#' write before anything is written. For spectra with `centroided` `NA` the
#' same heuristic as [Spectra::isCentroided()] is applied to the peaks unless
#' `assumeCentroided = TRUE`. Centroid such data first, for example with
#' `export(pickPeaks(sps), MsBackendLite(), file = )`.
#'
#' The file is written as `<file>.partial` and renamed to `file` only after
#' its consistency has been checked; on error the partial file is removed.
#'
#' @param object For `export()`: an `MsBackendLite` object (usually
#'     `MsBackendLite()`).
#'
#' @param x For `export()`: the [Spectra::Spectra()] object to write.
#'
#' @param file For `export()`: `character(1)`, path of the new database. Its
#'     directory must exist.
#'
#' @param chunkPeaks For `export()`: `numeric(1)`, approximate number of
#'     peaks read and written at a time. Used when the spectra variable
#'     `peaksCount` is available, otherwise 500 spectra are written at a
#'     time.
#'
#' @param pageSize For `export()`: `integer(1)`, SQLite page size in bytes.
#'
#' @param overwrite For `export()`: `logical(1)`, whether an existing `file`
#'     may be replaced.
#'
#' @param assumeCentroided For `export()`: `logical(1)`, if `TRUE` spectra
#'     with `centroided` `NA` are accepted without checking their peaks.
#'
#' @param ... Ignored.
#'
#' @return `MsBackendLite()` returns an empty `MsBackendLite` object.
#'     `export()` returns the path of the new database invisibly.
#'
#' @name MsBackendLite
#'
#' @author Chong Tang
#'
#' @exportClass MsBackendLite
#'
#' @importClassesFrom Spectra MsBackendCached
#'
#' @examples
#'
#' library(Spectra)
#' df <- data.frame(msLevel = c(1L, 2L), rtime = c(1.2, 3.4),
#'                  centroided = TRUE)
#' df$mz <- list(c(100.1, 200.2), c(150.5, 250.5, 350.5))
#' df$intensity <- list(c(10, 20), c(5, 15, 25))
#' sps <- Spectra(df)
#' file <- tempfile(fileext = ".sqlite")
#' export(sps, MsBackendLite(), file = file)
#' file.exists(file)
#' unlink(file)
NULL

setClass(
    "MsBackendLite",
    contains = "MsBackendCached",
    slots = c(
        dbfile = "character",
        spectraIds = "integer",
        peakStart = "numeric",
        peakCount = "integer",
        varClasses = "character",
        .con = "environment"),
    prototype = prototype(readonly = TRUE, version = "0.1"))

setValidity("MsBackendLite", function(object) {
    msg <- character()
    n <- object@nspectra
    if (length(object@spectraIds) != n || length(object@peakStart) != n ||
        length(object@peakCount) != n)
        msg <- c(msg, paste0("'spectraIds', 'peakStart' and 'peakCount' ",
                             "must have the length of the object"))
    if (length(object@dbfile) > 1L)
        msg <- c(msg, "'dbfile' must have length 0 or 1")
    if (length(msg)) msg else TRUE
})

#' @rdname MsBackendLite
#'
#' @importFrom methods new
#'
#' @export
MsBackendLite <- function() {
    ## A new environment per object: an environment in the prototype would
    ## be shared by all objects (DESIGN 5.1).
    new("MsBackendLite", .con = new.env(parent = emptyenv()))
}
