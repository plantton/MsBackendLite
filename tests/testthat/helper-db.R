## Build a tiny database by hand (plain SQL, no writer). Spectra have
## `peak_count` peaks; m/z increases within each spectrum. The connection is
## read-write, closed and the file removed when the calling test finishes.
.hand_db <- function(peak_count = c(3L, 0L, 5L), .env = parent.frame()) {
    file <- tempfile(fileext = ".sqlite")
    con <- DBI::dbConnect(RSQLite::SQLite(), file)
    do.call(on.exit, list(bquote({
        DBI::dbDisconnect(.(con))
        unlink(.(file))
    }), add = TRUE), envir = .env)
    DBI::dbExecute(con, "CREATE TABLE metadata (key TEXT PRIMARY KEY,
        value TEXT)")
    DBI::dbExecute(con, "CREATE TABLE spectra_variable (name TEXT PRIMARY
        KEY, r_class TEXT NOT NULL)")
    DBI::dbExecute(con, "CREATE TABLE source (source_id_ INTEGER PRIMARY KEY,
        type TEXT NOT NULL)")
    DBI::dbExecute(con, "CREATE TABLE spectrum (spectrum_id_ INTEGER PRIMARY
        KEY, peak_start INTEGER NOT NULL, peak_count INTEGER NOT NULL)")
    DBI::dbExecute(con, "CREATE TABLE peak (peak_id_ INTEGER PRIMARY KEY,
        mz REAL NOT NULL, intensity REAL NOT NULL)")
    n <- length(peak_count)
    start <- cumsum(c(1L, peak_count))[seq_len(n)]
    DBI::dbWriteTable(con, "spectrum", data.frame(
        spectrum_id_ = seq_len(n), peak_start = start,
        peak_count = as.integer(peak_count)), append = TRUE)
    p <- sum(peak_count)
    DBI::dbWriteTable(con, "peak", data.frame(
        peak_id_ = seq_len(p), mz = seq_len(p) * 10 + 0.5,
        intensity = seq_len(p) * 100), append = TRUE)
    con
}
