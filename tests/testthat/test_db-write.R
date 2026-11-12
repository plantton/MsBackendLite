.ro <- function(file, .env = parent.frame()) {
    con <- DBI::dbConnect(RSQLite::SQLite(), file,
                          flags = RSQLite::SQLITE_RO)
    do.call(on.exit, list(bquote(DBI::dbDisconnect(.(con))), add = TRUE),
            envir = .env)
    con
}

test_that(".peak_stats follows DESIGN 9.1", {
    z <- cbind(mz = c(100, 200, 300), intensity = c(5, 20, 10))
    expect_equal(.peak_stats(z),
                 c(peaksCount = 3, totIonCurrent = 35, basePeakMZ = 200,
                   basePeakIntensity = 20, lowMZ = 100, highMZ = 300))
    e <- .peak_stats(z[0, , drop = FALSE])
    expect_equal(e[["peaksCount"]], 0)
    expect_equal(e[["totIonCurrent"]], 0)
    expect_true(all(is.na(e[c("basePeakMZ", "basePeakIntensity", "lowMZ",
                              "highMZ")])))
})

test_that(".clean_peak_matrix drops NA rows and sorts by m/z", {
    z <- cbind(mz = c(3, NA, 1, 2), intensity = c(1, 2, NA, 4))
    expect_equal(unname(.clean_peak_matrix(z)), cbind(c(2, 3), c(4, 1)))
    s <- cbind(mz = c(1, 2), intensity = c(1, 1))
    expect_identical(.clean_peak_matrix(s), s)
})

test_that(".plan_chunks uses peaksCount, else a fixed number of spectra", {
    expect_equal(.plan_chunks(c(5, 5, 5, 5), 10), list(1:2, 3:4))
    expect_equal(.plan_chunks(c(25, 1, 1), 10), list(1L, 2:3))
    expect_equal(.plan_chunks(c(0, 0, 0), 10, chunkSpectra = 2L),
                 list(1:2, 3L))
    expect_equal(.plan_chunks(c(NA, 1, 1), 10, chunkSpectra = 2L),
                 list(1:2, 3L))
    expect_equal(.plan_chunks(NULL, 10, chunkSpectra = 2L, n = 3L),
                 list(1:2, 3L))
    expect_equal(.plan_chunks(numeric(), 10), list())
})

test_that(".is_centroided_peaks mirrors the Spectra heuristic", {
    prof <- cbind(mz = seq(100, 101, by = 0.001),
                  intensity = dnorm(seq(-3, 3, length.out = 1001)) * 1e4)
    expect_false(.is_centroided_peaks(prof))
    cent <- cbind(mz = seq(100, 1000, by = 10), intensity = 1:91)
    expect_true(.is_centroided_peaks(cent))
    expect_true(is.na(.is_centroided_peaks(cent[0, , drop = FALSE])))
})

test_that("export() writes a valid database equal to the input", {
    sps <- .synthetic_spectra()
    file <- tempfile(fileext = ".sqlite")
    on.exit(unlink(file))
    expect_message(res <- export(sps, MsBackendLite(), file = file),
                   "lst")
    expect_identical(res, file)
    expect_true(file.exists(file))
    expect_false(file.exists(paste0(file, ".partial")))
    con <- .ro(file)
    expect_true(.valid_db(con))

    ## row counts
    pks <- lapply(peaksData(sps), .clean_peaks)
    cnt <- vapply(pks, nrow, integer(1))
    expect_equal(DBI::dbGetQuery(con, "SELECT COUNT(*) FROM spectrum")[[1L]],
                 length(sps))
    expect_equal(DBI::dbGetQuery(con, "SELECT COUNT(*) FROM peak")[[1L]],
                 sum(cnt))

    ## peak_start / peak_count, empty spectra included
    s <- DBI::dbGetQuery(con, "SELECT * FROM spectrum ORDER BY spectrum_id_")
    expect_equal(s$spectrum_id_, seq_along(sps))
    expect_equal(s$peak_count, cnt)
    expect_equal(s$peak_start, cumsum(c(1, cnt))[seq_along(cnt)])
    expect_equal(s$source_id_, rep(1L, length(sps)))
    expect_equal(s$source_spectrum_id_, seq_along(sps))

    ## peaks: values and m/z order (spectrum 5 was unsorted with NAs)
    for (i in seq_along(sps)) {
        p <- .sql_peaks(con, i)
        expect_equal(unname(as.matrix(p)), unname(pks[[i]]))
        expect_false(is.unsorted(p$mz))
    }
    expect_equal(nrow(.sql_peaks(con, 5L)), 5L)

    ## spectra variables, typed
    expect_equal(s$msLevel, msLevel(sps))
    expect_equal(s$rtime, rtime(sps))
    expect_equal(s$precursorMz, precursorMz(sps))
    expect_equal(s$label, sps$label)
    expect_equal(s$flag, as.integer(sps$flag))
    expect_false("lst" %in% names(s))
    expect_false("dataStorage" %in% names(s))
    vc <- .read_spectra_variable(con)
    expect_equal(vc[["flag"]], "logical")
    expect_equal(vc[["label"]], "character")
    expect_equal(vc[["msLevel"]], "integer")
    expect_false("lst" %in% names(vc))
    expect_true(all(names(vc) %in% names(s)))

    ## summary columns recomputed from the stored peaks
    st <- do.call(rbind, lapply(pks, .peak_stats))
    for (cn in colnames(st))
        expect_equal(s[[cn]], unname(st[, cn]), info = cn)
    expect_equal(s$peaksCount[c(1, 4, 9)], c(0L, 0L, 0L))
    expect_equal(s$totIonCurrent[c(1, 4, 9)], c(0, 0, 0))
    expect_true(all(is.na(s$basePeakMZ[c(1, 4, 9)])))

    ## metadata and source
    md <- .read_metadata(con)
    expect_equal(md[["schema_version"]], "1")
    expect_equal(md[["kind"]], "export")
    expect_equal(md[["n_spectra"]], as.character(length(sps)))
    expect_equal(md[["n_peaks"]], as.character(sum(cnt)))
    expect_equal(md[["page_size"]], "32768")
    expect_equal(md[["ms_levels"]], "all")
    expect_true(all(c("package_version", "spectra_version", "created",
                      "processing_log") %in% names(md)))
    src <- DBI::dbGetQuery(con, "SELECT * FROM source")
    expect_equal(nrow(src), 1L)
    expect_equal(src$type, "MsBackendMemory")
    expect_equal(src$n_spectra, length(sps))
    expect_equal(src$n_peaks, sum(cnt))

    ## indices exist
    idx <- DBI::dbGetQuery(con, "SELECT name FROM sqlite_master
                                 WHERE type = 'index'")$name
    expect_true(all(c("idx_spectrum_mslevel_rtime",
                      "idx_spectrum_precursormz") %in% idx))
})

test_that("several chunks give the same database as one chunk", {
    sps <- .synthetic_spectra()
    sps$lst <- NULL
    f1 <- tempfile(fileext = ".sqlite")
    f2 <- tempfile(fileext = ".sqlite")
    f3 <- tempfile(fileext = ".sqlite")
    on.exit(unlink(c(f1, f2, f3)))
    export(sps, MsBackendLite(), file = f1)
    sps$peaksCount <- lengths(sps)
    export(sps, MsBackendLite(), file = f2, chunkPeaks = 50)
    sps$peaksCount <- NULL
    .write_spectra_db(sps, f3, chunkSpectra = 2L)
    c1 <- .ro(f1)
    c2 <- .ro(f2)
    c3 <- .ro(f3)
    q <- "SELECT * FROM %s ORDER BY 1"
    for (tbl in c("spectrum", "peak")) {
        expect_equal(DBI::dbGetQuery(c2, sprintf(q, tbl)),
                     DBI::dbGetQuery(c1, sprintf(q, tbl)), info = tbl)
        expect_equal(DBI::dbGetQuery(c3, sprintf(q, tbl)),
                     DBI::dbGetQuery(c1, sprintf(q, tbl)), info = tbl)
    }
    expect_true(.valid_db(c2))
})

test_that("the processing queue is applied while writing", {
    sps <- .synthetic_spectra()
    sps$lst <- NULL
    sps <- filterIntensity(sps, intensity = c(50000, Inf))
    file <- tempfile(fileext = ".sqlite")
    on.exit(unlink(file))
    export(sps, MsBackendLite(), file = file)
    con <- .ro(file)
    pks <- lapply(peaksData(sps), .clean_peaks)
    expect_equal(DBI::dbGetQuery(con, "SELECT COUNT(*) FROM peak")[[1L]],
                 sum(vapply(pks, nrow, integer(1))))
    expect_true(all(DBI::dbGetQuery(con,
                                    "SELECT intensity FROM peak")[[1L]] >=
                    50000))
    expect_true(.valid_db(con))
})

test_that("zero spectra give a valid empty database", {
    sps <- .synthetic_spectra()[integer()]
    file <- tempfile(fileext = ".sqlite")
    on.exit(unlink(file))
    suppressMessages(export(sps, MsBackendLite(), file = file))
    con <- .ro(file)
    expect_true(.valid_db(con))
    expect_equal(DBI::dbGetQuery(con, "SELECT COUNT(*) FROM spectrum")[[1L]],
                 0L)
    expect_equal(.read_metadata(con)[["n_peaks"]], "0")
})

test_that("an existing file is not overwritten unless asked", {
    sps <- .synthetic_spectra()
    sps$lst <- NULL
    file <- tempfile(fileext = ".sqlite")
    on.exit(unlink(file))
    writeLines("keep me", file)
    expect_error(export(sps, MsBackendLite(), file = file), "exists")
    expect_equal(readLines(file), "keep me")
    expect_false(file.exists(paste0(file, ".partial")))
    export(sps, MsBackendLite(), file = file, overwrite = TRUE)
    con <- .ro(file)
    expect_true(.valid_db(con))
})

test_that("a stale .partial file is removed", {
    sps <- .synthetic_spectra()
    sps$lst <- NULL
    file <- tempfile(fileext = ".sqlite")
    on.exit(unlink(file))
    writeLines("junk", paste0(file, ".partial"))
    export(sps, MsBackendLite(), file = file)
    expect_false(file.exists(paste0(file, ".partial")))
    expect_true(.valid_db(.ro(file)))
})

test_that("profile data is rejected and no .partial is left", {
    sps <- .synthetic_spectra()
    sps$lst <- NULL
    file <- tempfile(fileext = ".sqlite")
    on.exit(unlink(file))
    ## flagged as profile
    p <- sps
    p$centroided[c(2, 3)] <- FALSE
    expect_error(export(p, MsBackendLite(), file = file),
                 "2 spectra.*MS2: 2.*pickPeaks")
    expect_false(file.exists(file))
    expect_false(file.exists(paste0(file, ".partial")))

    ## not flagged, detected by the heuristic in a later chunk
    prof <- cbind(mz = seq(100, 101, by = 0.001),
                  intensity = dnorm(seq(-3, 3, length.out = 1001)) * 1e4)
    df <- data.frame(msLevel = c(1L, 1L, 1L), rtime = 1:3)
    df$mz <- list(c(100, 200), c(100, 300), prof[, 1])
    df$intensity <- list(c(1, 2), c(1, 2), prof[, 2])
    p <- Spectra::Spectra(df)
    expect_error(.write_spectra_db(p, file, chunkSpectra = 1L),
                 "profile.*MS1: 1")
    expect_false(file.exists(file))
    expect_false(file.exists(paste0(file, ".partial")))

    ## assumeCentroided skips the heuristic
    suppressMessages(export(p, MsBackendLite(), file = file,
                            assumeCentroided = TRUE))
    expect_true(.valid_db(.ro(file)))
})

test_that("reserved variable names from other backends are refused", {
    sps <- .synthetic_spectra()
    sps$lst <- NULL
    sps$peak_start <- 1L
    file <- tempfile(fileext = ".sqlite")
    on.exit(unlink(file))
    expect_error(export(sps, MsBackendLite(), file = file), "peak_start")
    expect_false(file.exists(file))
    expect_false(file.exists(paste0(file, ".partial")))
})

test_that("export() checks its arguments", {
    sps <- .synthetic_spectra()
    expect_error(export(MsBackendLite(), sps), "file")
    expect_error(export(MsBackendLite(), 1, file = tempfile()), "Spectra")
    expect_error(export(sps, MsBackendLite(),
                        file = file.path(tempfile(), "x.sqlite")),
                 "directory")
})
