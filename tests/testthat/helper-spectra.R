## Small synthetic Spectra object (DESIGN 11.1): very different lengths,
## empty spectra first / middle / last, MS levels 1-3, NA precursor values,
## a logical, a character and a list variable, unsorted m/z and NA peaks in
## spectrum 5, all centroided.
.synthetic_spectra <- function() {
    set.seed(123)
    n <- c(0L, 5L, 120L, 0L, 7L, 3000L, 1L, 40L, 0L)
    mz <- lapply(n, function(k) sort(round(runif(k, 100, 1500), 4)))
    int <- lapply(n, function(k) round(runif(k, 1, 1e5), 2))
    mz[[5L]] <- rev(mz[[5L]])
    mz[[5L]][2L] <- NA
    int[[5L]][4L] <- NA
    df <- data.frame(
        msLevel = c(1L, 2L, 2L, 1L, 2L, 1L, 3L, 2L, 1L),
        rtime = seq(10, 90, by = 10),
        precursorMz = c(NA, 400.5, 500.25, NA, 600.125, NA, 700, 800, NA),
        centroided = TRUE,
        flag = c(TRUE, FALSE, NA, TRUE, TRUE, FALSE, NA, TRUE, FALSE),
        label = c("a", NA, "c", "d", "e", "f", NA, "h", "i"))
    df$mz <- mz
    df$intensity <- int
    sps <- Spectra::Spectra(df)
    sps$lst <- as.list(seq_along(sps))
    sps
}

## Expected peaks after the writer's clean-up: NA rows dropped, sorted by m/z.
.clean_peaks <- function(z) {
    z <- z[!is.na(z[, 1L]) & !is.na(z[, 2L]), , drop = FALSE]
    z[order(z[, 1L]), , drop = FALSE]
}

## Read the written peaks of one spectrum with plain SQL.
.sql_peaks <- function(con, i) {
    s <- DBI::dbGetQuery(con, "SELECT peak_start, peak_count FROM spectrum
                               WHERE spectrum_id_ = ?", params = list(i))
    DBI::dbGetQuery(con, "SELECT mz, intensity FROM peak
                          WHERE peak_id_ BETWEEN ? AND ? ORDER BY peak_id_",
                    params = list(s$peak_start,
                                  s$peak_start + s$peak_count - 1))
}
