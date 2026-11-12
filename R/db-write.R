## Writing new databases (DESIGN section 9). One writer for import and export.

#' Six summary values of one peak matrix sorted by m/z (DESIGN 9.1)
#' @noRd
.peak_stats <- function(z) {
    n <- nrow(z)
    if (!n)
        return(c(peaksCount = 0, totIonCurrent = 0, basePeakMZ = NA_real_,
                 basePeakIntensity = NA_real_, lowMZ = NA_real_,
                 highMZ = NA_real_))
    mz <- z[, 1L]
    int <- z[, 2L]
    i <- which.max(int)
    c(peaksCount = n, totIonCurrent = sum(int), basePeakMZ = mz[i],
      basePeakIntensity = int[i], lowMZ = mz[1L], highMZ = mz[n])
}

#' Drop peaks with missing m/z or intensity and sort by m/z (I5, I7)
#' @noRd
.clean_peak_matrix <- function(z) {
    keep <- !(is.na(z[, 1L]) | is.na(z[, 2L]))
    if (!all(keep))
        z <- z[keep, , drop = FALSE]
    if (is.unsorted(z[, 1L]))
        z <- z[order(z[, 1L]), , drop = FALSE]
    z
}

#' Centroided heuristic of `Spectra::isCentroided()` for one peak matrix
#'
#' Same computation as `Spectra:::.peaks_is_centroided()`, applied to the
#' peaks that are about to be written so that they are read only once.
#' `NA` if there are too few peaks to tell.
#' @noRd
.is_centroided_peaks <- function(z, k = 0.025, qtl = 0.9) {
    if (!nrow(z))
        return(NA)
    q <- .quantile7(z[, 2L], qtl)
    mz <- z[z[, 2L] > q, 1L]
    .quantile7(diff(mz), 0.25) > k
}

#' Sample quantile, type 7 (the default of `stats::quantile()`), for one
#' probability. `NA` for an empty vector. Avoids importing `stats`.
#' @noRd
.quantile7 <- function(x, p) {
    n <- length(x)
    if (!n)
        return(NA_real_)
    x <- sort(x)
    h <- (n - 1) * p + 1
    lo <- floor(h)
    x[lo] + (h - lo) * (x[min(lo + 1, n)] - x[lo])
}

#' Split spectra into chunks of about `chunkPeaks` peaks (DESIGN 9.1 step 4)
#'
#' A spectrum goes to the chunk in which its first peak falls, so a chunk
#' holds less than `chunkPeaks` plus the size of its last spectrum, and a
#' spectrum larger than `chunkPeaks` does not pull the next spectra into its
#' chunk.
#'
#' @param cnt number of peaks per spectrum (for example `x$peaksCount`) or
#'     `NULL`. If `NULL`, with `NA` or all zero, chunks of `chunkSpectra`
#'     spectra are used.
#' @param n number of spectra, needed when `cnt` is `NULL`.
#' @return `list` of integer indices, one element per chunk.
#' @noRd
.plan_chunks <- function(cnt, chunkPeaks = 1e6, chunkSpectra = 500L,
                         n = length(cnt)) {
    if (!n)
        return(list())
    if (length(cnt) == n && !anyNA(cnt) && any(cnt > 0)) {
        start <- cumsum(c(0, as.numeric(cnt)))[seq_len(n)]
        g <- floor(start / chunkPeaks)
    } else
        g <- ceiling(seq_len(n) / chunkSpectra)
    unname(split(seq_len(n), factor(g, levels = unique(g))))
}

.profile_error <- function(mslevel, partial = FALSE) {
    tab <- table(mslevel)
    stop("Found profile-mode data: ", if (partial) "at least ",
         length(mslevel), " spectra (",
         paste0("MS", names(tab), ": ", as.integer(tab), collapse = ", "),
         "). MsBackendLite stores centroided data only. Convert the raw ",
         "file again with msconvert and --filter \"peakPicking vendor ",
         "msLevel=1-\", or centroid in R with ",
         "export(pickPeaks(sps), MsBackendLite(), file = ).", call. = FALSE)
}

#' Choose the spectra variables to store and their R classes (9.1 step 2)
#'
#' @return named `character` of R classes. Dropped names are reported with
#'     `message()` and returned in the attribute `"dropped"`.
#' @noRd
.write_variables <- function(x) {
    vars <- Spectra::spectraVariables(x)
    lite <- methods::is(x@backend, "MsBackendLite")
    ids <- c("spectrum_id_", "peak_start", "peak_count", "source_id_",
             "source_spectrum_id_")
    if (!lite && any(ids %in% vars))
        stop("Spectra variable(s) ", paste(intersect(ids, vars),
                                           collapse = ", "),
             " use reserved names. Rename them before writing.",
             call. = FALSE)
    vars <- setdiff(vars, c(.RESERVED_NAMES, names(.SUMMARY_COLUMNS)))
    sd <- Spectra::spectraData(x[seq_len(min(length(x), 1L))],
                               columns = vars)
    cls <- vapply(vars, function(v) .r_class(sd[[v]]), character(1))
    core <- Spectra::coreSpectraVariables()
    core <- core[names(core) %in% vars & core %in% .SUPPORTED_CLASSES]
    cls[names(core)] <- core
    dropped <- names(cls)[is.na(cls)]
    pv <- setdiff(Spectra::peaksVariables(x), c("mz", "intensity"))
    if (length(dropped))
        message("Dropping spectra variable(s) of unsupported type: ",
                paste(dropped, collapse = ", "))
    if (length(pv))
        message("Dropping peaks variable(s): ", paste(pv, collapse = ", "))
    res <- cls[!is.na(cls)]
    attr(res, "dropped") <- c(dropped, pv)
    res
}

#' Convert spectra variables of one chunk to their stored representation
#' @noRd
.db_columns <- function(sd, vars) {
    res <- lapply(names(vars), function(v) {
        z <- sd[[v]]
        if (is.factor(z))
            z <- as.character(z)
        cl <- .r_class(z)
        ok <- identical(cl, vars[[v]]) || all(is.na(z)) ||
            (cl == "integer" && vars[[v]] == "numeric")
        if (!ok)
            stop("Spectra variable '", v, "' is '", cl, "' in one chunk ",
                 "and '", vars[[v]], "' in another.", call. = FALSE)
        switch(vars[[v]],
               logical = as.integer(as.logical(z)),
               integer = as.integer(z),
               numeric = as.numeric(z),
               character = as.character(z))
    })
    names(res) <- names(vars)
    res
}

.source_row <- function(x, n_spectra, n_peaks) {
    be <- x@backend
    if (methods::is(be, "MsBackendLite"))
        path <- be@dbfile
    else {
        path <- unique(Spectra::dataStorage(x))
        if (length(path) != 1L)
            path <- NA_character_
    }
    if (!length(path))
        path <- NA_character_
    data.frame(source_id_ = 1L, type = class(be)[1L], path = path,
               md5 = NA_character_, n_spectra = n_spectra,
               n_peaks = n_peaks, spectrum_offset = 0, peak_offset = 0,
               info = NA_character_)
}

#' Write a Spectra object to a new database (DESIGN 9.1)
#'
#' @param x `Spectra` object, any backend. Its processing queue is applied.
#' @param file path of the new database.
#' @param kind `"import"`, `"export"` or `"merge"` (metadata).
#' @param metadata named list of further `metadata` values (for example
#'     `ms_levels`, `processing_log`).
#' @param source `data.frame` with rows for the `source` table, or `NULL`
#'     for one row describing `x`.
#' @param chunkSpectra spectra per chunk when `peaksCount` is not usable.
#' @return invisibly a `list` with `file`, `n_spectra`, `n_peaks`,
#'     `n_undetermined` (spectra whose centroided state could not be told)
#'     and `dropped` (names of variables not stored).
#' @noRd
.write_spectra_db <- function(x, file, kind = "export", chunkPeaks = 1e6,
                              pageSize = 32768L, overwrite = FALSE,
                              assumeCentroided = FALSE, metadata = list(),
                              source = NULL, chunkSpectra = 500L) {
    stopifnot(methods::is(x, "Spectra"), is.character(file),
              length(file) == 1L, !is.na(file),
              kind %in% c("import", "export", "merge"),
              is.numeric(chunkPeaks), length(chunkPeaks) == 1L,
              chunkPeaks > 0, is.logical(overwrite), length(overwrite) == 1L,
              is.logical(assumeCentroided), length(assumeCentroided) == 1L)
    if (!dir.exists(dirname(file)))
        stop("The directory of '", file, "' does not exist.", call. = FALSE)
    if (file.exists(file) && !overwrite)
        stop("File '", file, "' exists. Use 'overwrite = TRUE' to replace ",
             "it.", call. = FALSE)
    partial <- paste0(file, ".partial")
    if (file.exists(partial))
        unlink(partial)

    ## Checks that need no peaks run before anything is written.
    vars <- .write_variables(x)
    n <- length(x)
    cent <- if (n) Spectra::centroided(x) else logical()
    if (any(cent %in% FALSE))
        .profile_error(Spectra::msLevel(x)[cent %in% FALSE])
    mslevel <- if (n) Spectra::msLevel(x) else integer()
    srcid <- if (methods::is(x@backend, "MsBackendLite"))
                 x@backend@spectraIds else seq_len(n)
    cnt <- if ("peaksCount" %in% Spectra::spectraVariables(x))
               x$peaksCount else NULL
    chunks <- .plan_chunks(cnt, chunkPeaks, chunkSpectra, n = n)

    con <- DBI::dbConnect(RSQLite::SQLite(), partial)
    done <- FALSE
    on.exit({
        if (DBI::dbIsValid(con))
            DBI::dbDisconnect(con)
        if (!done)
            unlink(partial)
    })
    .create_db_schema(con, vars, page_size = pageSize)
    sumcols <- names(.SUMMARY_COLUMNS)
    n_peaks <- 0
    n_undet <- 0L
    for (idx in chunks) {
        xc <- x[idx]
        pks <- lapply(Spectra::peaksData(xc, columns = c("mz", "intensity")),
                      .clean_peak_matrix)
        if (!assumeCentroided && any(na <- is.na(cent[idx]))) {
            ic <- vapply(pks[na], .is_centroided_peaks, logical(1))
            if (any(ic %in% FALSE))
                .profile_error(mslevel[idx][na][ic %in% FALSE],
                               partial = TRUE)
            n_undet <- n_undet + sum(is.na(ic))
        }
        pc <- vapply(pks, nrow, integer(1))
        start <- n_peaks + cumsum(c(1, pc))[seq_along(pc)]
        st <- vapply(pks, .peak_stats, .peak_stats(matrix(0, 0L, 2L)))
        np <- sum(pc)
        sd <- Spectra::spectraData(xc, columns = names(vars))
        spec <- c(list(spectrum_id_ = idx, peak_start = start,
                       peak_count = pc, source_id_ = rep(1L, length(idx)),
                       source_spectrum_id_ = srcid[idx]),
                  .db_columns(sd, vars))
        spec[sumcols] <- lapply(sumcols, function(cn) st[cn, ])
        spec$peaksCount <- as.integer(spec$peaksCount)
        spec <- as.data.frame(spec, optional = TRUE)
        mat <- do.call(rbind, c(list(matrix(numeric(), 0L, 2L)),
                                lapply(pks, unname)))
        peak <- data.frame(peak_id_ = n_peaks + seq_len(np),
                           mz = mat[, 1L], intensity = mat[, 2L])
        DBI::dbWithTransaction(con, {
            DBI::dbWriteTable(con, "peak", peak, append = TRUE)
            DBI::dbWriteTable(con, "spectrum", spec, append = TRUE)
        })
        n_peaks <- n_peaks + np
    }
    .create_db_indices(con)
    DBI::dbExecute(con, "ANALYZE")
    md <- list(schema_version = "1", kind = kind,
               package_version = .pkg_version("MsBackendLite"),
               spectra_version = .pkg_version("Spectra"),
               created = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
               n_spectra = n, n_peaks = format(n_peaks, scientific = FALSE),
               page_size = as.integer(pageSize), ms_levels = "all")
    md[names(metadata)] <- metadata
    .write_metadata(con, md)
    .write_spectra_variable(con, vars)
    if (is.null(source))
        source <- .source_row(x, n, n_peaks)
    DBI::dbWriteTable(con, "source", source, append = TRUE)
    valid <- .valid_db(con)
    if (!isTRUE(valid))
        stop("The new database is not valid: ",
             paste(valid, collapse = "; "), call. = FALSE)
    ## Disconnect before renaming: Windows cannot rename an open file.
    DBI::dbDisconnect(con)
    if (file.exists(file) && unlink(file) != 0L)
        stop("Cannot remove existing file '", file, "'.", call. = FALSE)
    if (!file.rename(partial, file))
        stop("Cannot rename '", partial, "' to '", file, "'.", call. = FALSE)
    done <- TRUE
    invisible(list(file = file, n_spectra = n, n_peaks = n_peaks,
                   n_undetermined = n_undet,
                   dropped = attr(vars, "dropped")))
}

.pkg_version <- function(pkg) {
    as.character(utils::packageVersion(pkg))
}

#' @rdname MsBackendLite
#'
#' @importMethodsFrom Spectra export
#'
#' @exportMethod export
setMethod("export", "MsBackendLite", function(object, x, file, chunkPeaks = 1e6,
                                              pageSize = 32768L,
                                              overwrite = FALSE,
                                              assumeCentroided = FALSE, ...) {
    if (missing(file))
        stop("Argument 'file' is required.", call. = FALSE)
    if (missing(x) || !methods::is(x, "Spectra"))
        stop("'x' must be a 'Spectra' object.", call. = FALSE)
    log <- paste(Spectra::processingLog(x), collapse = "\n")
    res <- .write_spectra_db(x, file, kind = "export",
                             chunkPeaks = chunkPeaks, pageSize = pageSize,
                             overwrite = overwrite,
                             assumeCentroided = assumeCentroided,
                             metadata = list(processing_log = log))
    invisible(res$file)
})
