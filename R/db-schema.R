## Database layout (DESIGN section 4): tables, types, metadata, validation.

.SUMMARY_COLUMNS <- c(peaksCount = "integer", totIonCurrent = "numeric",
                      basePeakMZ = "numeric", basePeakIntensity = "numeric",
                      lowMZ = "numeric", highMZ = "numeric")

.RESERVED_NAMES <- c("spectrum_id_", "peak_start", "peak_count", "source_id_",
                     "source_spectrum_id_", "mz", "intensity", "dataStorage")

.SUPPORTED_CLASSES <- c("integer", "numeric", "character", "logical")

#' Map R classes to SQLite column types (DESIGN 4.3)
#'
#' @param x `character` of R classes.
#' @return `character` of SQLite types, same length as `x`.
#' @noRd
.sql_type <- function(x) {
    types <- c(integer = "INTEGER", numeric = "REAL", character = "TEXT",
               logical = "INTEGER")
    bad <- !x %in% names(types)
    if (any(bad))
        stop("unsupported class: ", paste(unique(x[bad]), collapse = ", "),
             call. = FALSE)
    unname(types[x])
}

#' Stored R class of a vector, `NA_character_` if it cannot be stored.
#' @noRd
.r_class <- function(x) {
    if (is.factor(x) || is.character(x))
        "character"
    else if (is.logical(x))
        "logical"
    else if (is.integer(x))
        "integer"
    else if (is.numeric(x))
        "numeric"
    else NA_character_
}

.check_variable_classes <- function(vars) {
    if (!length(vars))
        return(invisible(vars))
    if (!is.character(vars) || is.null(names(vars)) || anyNA(names(vars)) ||
        any(!nzchar(names(vars))))
        stop("'vars' must be a named character vector of R classes",
             call. = FALSE)
    if (anyDuplicated(names(vars)))
        stop("duplicated variable names: ",
             paste(unique(names(vars)[duplicated(names(vars))]),
                   collapse = ", "), call. = FALSE)
    reserved <- names(vars) %in% c(.RESERVED_NAMES, names(.SUMMARY_COLUMNS))
    if (any(reserved))
        stop("reserved variable name(s): ",
             paste(names(vars)[reserved], collapse = ", "), call. = FALSE)
    .sql_type(vars)
    invisible(vars)
}

#' Create the tables and the view of a new database (DESIGN 4.1, 4.5)
#'
#' `page_size` is set before the first table is created. Indices are created
#' separately with `.create_db_indices()` after all rows are written.
#'
#' @param con writable connection to a new, empty database.
#' @param vars named `character`: R class of every spectra variable column of
#'     the `spectrum` table (without the six summary columns).
#' @noRd
.create_db_schema <- function(con, vars = character(), page_size = 32768L) {
    stopifnot(is.numeric(page_size), length(page_size) == 1L)
    .check_variable_classes(vars)
    DBI::dbExecute(con, sprintf("PRAGMA page_size = %d", as.integer(page_size)))
    DBI::dbExecute(con, "PRAGMA journal_mode = OFF")
    DBI::dbExecute(con, "PRAGMA synchronous = OFF")
    DBI::dbExecute(con, "CREATE TABLE metadata (key TEXT PRIMARY KEY,
                         value TEXT)")
    DBI::dbExecute(con, "CREATE TABLE spectra_variable (
                         name TEXT PRIMARY KEY, r_class TEXT NOT NULL)")
    DBI::dbExecute(con, "CREATE TABLE source (
        source_id_ INTEGER PRIMARY KEY, type TEXT NOT NULL, path TEXT,
        md5 TEXT, n_spectra INTEGER, n_peaks INTEGER,
        spectrum_offset INTEGER NOT NULL DEFAULT 0,
        peak_offset INTEGER NOT NULL DEFAULT 0, info TEXT)")
    cols <- c(vars, .SUMMARY_COLUMNS)
    DBI::dbExecute(con, sprintf(
        "CREATE TABLE spectrum (
        spectrum_id_ INTEGER PRIMARY KEY, peak_start INTEGER NOT NULL,
        peak_count INTEGER NOT NULL, source_id_ INTEGER NOT NULL DEFAULT 1,
        source_spectrum_id_ INTEGER%s)",
        if (length(cols))
            paste0(", ", paste(DBI::dbQuoteIdentifier(con, names(cols)),
                               .sql_type(cols), collapse = ", "))
        else ""))
    DBI::dbExecute(con, "CREATE TABLE peak (
        peak_id_ INTEGER PRIMARY KEY, mz REAL NOT NULL,
        intensity REAL NOT NULL)")
    DBI::dbExecute(con, "CREATE VIEW peak_long AS
        SELECT s.spectrum_id_, p.mz, p.intensity FROM spectrum s
        JOIN peak p ON p.peak_id_ BETWEEN s.peak_start AND
                       s.peak_start + s.peak_count - 1")
    invisible(con)
}

#' Indices of DESIGN 4.1, to be created after all rows are written.
#' @noRd
.create_db_indices <- function(con) {
    DBI::dbExecute(con, "CREATE INDEX idx_spectrum_mslevel_rtime
                         ON spectrum (\"msLevel\", \"rtime\")")
    DBI::dbExecute(con, "CREATE INDEX idx_spectrum_precursormz
                         ON spectrum (\"precursorMz\")")
    invisible(con)
}

#' Write `metadata` rows (replacing existing keys). Values are stored as text.
#' @param values named list or vector.
#' @noRd
.write_metadata <- function(con, values) {
    if (!length(values))
        return(invisible(con))
    if (is.null(names(values)) || anyNA(names(values)) ||
        any(!nzchar(names(values))))
        stop("'values' must be named", call. = FALSE)
    value <- vapply(values, function(z) as.character(z)[1L], character(1))
    DBI::dbExecute(con, "INSERT OR REPLACE INTO metadata (key, value)
                         VALUES (?, ?)",
                   params = list(names(values), unname(value)))
    invisible(con)
}

#' Read `metadata` as a named character vector.
#' @noRd
.read_metadata <- function(con) {
    res <- DBI::dbGetQuery(con, "SELECT key, value FROM metadata ORDER BY key")
    structure(as.character(res$value), names = as.character(res$key))
}

#' Write the R class of every spectra variable, in column order.
#' @noRd
.write_spectra_variable <- function(con, vars) {
    .check_variable_classes(vars)
    if (!length(vars))
        return(invisible(con))
    DBI::dbExecute(con, "INSERT OR REPLACE INTO spectra_variable
                         (name, r_class) VALUES (?, ?)",
                   params = list(names(vars), unname(vars)))
    invisible(con)
}

#' Read `spectra_variable` as a named character vector in table order.
#' @noRd
.read_spectra_variable <- function(con) {
    res <- DBI::dbGetQuery(con, "SELECT name, r_class FROM spectra_variable
                                 ORDER BY rowid")
    structure(as.character(res$r_class), names = as.character(res$name))
}

#' Check invariants I1-I4 of DESIGN 4.2 with SQL
#'
#' @return `TRUE` if the database is valid, otherwise a `character` vector
#'     with one message per broken invariant (like an S4 validity method).
#' @noRd
.valid_db <- function(con) {
    needed <- c("metadata", "spectra_variable", "source", "spectrum", "peak")
    missing <- setdiff(needed, DBI::dbListTables(con))
    if (length(missing))
        return(paste0("missing table(s): ", paste(missing, collapse = ", ")))
    msg <- character()
    s <- DBI::dbGetQuery(con, "SELECT
        (SELECT COALESCE(SUM(peak_count), 0) FROM spectrum) AS sum_count,
        (SELECT COUNT(*) FROM peak) AS n_peak,
        (SELECT COALESCE(MIN(peak_id_), 1) FROM peak) AS min_peak_id,
        (SELECT COALESCE(MAX(peak_id_), 0) FROM peak) AS max_peak_id,
        (SELECT COUNT(*) FROM spectrum) AS n_spectrum,
        (SELECT COALESCE(MIN(spectrum_id_), 1) FROM spectrum) AS min_spec_id,
        (SELECT COALESCE(MAX(spectrum_id_), 0) FROM spectrum) AS max_spec_id")
    if (s$min_spec_id != 1 || s$max_spec_id != s$n_spectrum)
        msg <- c(msg, "I1: spectrum_id_ is not 1..N without gaps")
    if (s$min_peak_id != 1 || s$max_peak_id != s$n_peak)
        msg <- c(msg, "I2: peak_id_ is not 1..P without gaps")
    bad <- DBI::dbGetQuery(con, "SELECT COUNT(*) AS n_bad FROM (
        SELECT peak_start, LAG(peak_start + peak_count, 1, 1)
                   OVER (ORDER BY spectrum_id_) AS expected
        FROM spectrum) WHERE peak_start != expected")$n_bad
    if (bad)
        msg <- c(msg, paste0("I3: peak_start is not contiguous in ", bad,
                             " spectrum row(s)"))
    if (s$sum_count != s$n_peak)
        msg <- c(msg, paste0("I4: SUM(peak_count) = ", s$sum_count,
                             " but the peak table has ", s$n_peak, " rows"))
    if (length(msg)) msg else TRUE
}
