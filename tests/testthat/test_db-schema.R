test_that(".sql_type maps R classes to SQLite types", {
    expect_equal(.sql_type("integer"), "INTEGER")
    expect_equal(.sql_type("numeric"), "REAL")
    expect_equal(.sql_type("character"), "TEXT")
    expect_equal(.sql_type("logical"), "INTEGER")
    expect_equal(.sql_type(c("numeric", "logical")), c("REAL", "INTEGER"))
    expect_error(.sql_type("list"), "unsupported")
})

test_that(".r_class gives the stored class of a vector or NA", {
    expect_equal(.r_class(1L), "integer")
    expect_equal(.r_class(1.5), "numeric")
    expect_equal(.r_class("a"), "character")
    expect_equal(.r_class(factor("a")), "character")
    expect_equal(.r_class(TRUE), "logical")
    expect_true(is.na(.r_class(list(1))))
    expect_true(is.na(.r_class(NULL)))
})

test_that(".create_db_schema creates the tables of DESIGN 4.1", {
    file <- tempfile(fileext = ".sqlite")
    on.exit(unlink(file))
    con <- DBI::dbConnect(RSQLite::SQLite(), file)
    on.exit(DBI::dbDisconnect(con), add = TRUE, after = FALSE)
    .create_db_schema(con, c(msLevel = "integer", rtime = "numeric",
                             flag = "logical", name = "character"))
    expect_setequal(DBI::dbListTables(con),
                    c("metadata", "spectra_variable", "source", "spectrum",
                      "peak", "peak_long"))
    expect_equal(DBI::dbGetQuery(con, "PRAGMA page_size")[[1L]], 32768L)
    cols <- DBI::dbGetQuery(con, "PRAGMA table_info(spectrum)")
    expect_equal(cols$name[1:5], c("spectrum_id_", "peak_start", "peak_count",
                                   "source_id_", "source_spectrum_id_"))
    expect_equal(cols$type[match(c("msLevel", "rtime", "flag", "name"),
                                 cols$name)],
                 c("INTEGER", "REAL", "INTEGER", "TEXT"))
    expect_true(all(c("peaksCount", "totIonCurrent", "basePeakMZ",
                      "basePeakIntensity", "lowMZ", "highMZ") %in% cols$name))
    expect_equal(DBI::dbGetQuery(con, "SELECT * FROM peak_long")$mz,
                 numeric())
})

test_that(".create_db_schema honours page_size and rejects bad input", {
    file <- tempfile(fileext = ".sqlite")
    on.exit(unlink(file))
    con <- DBI::dbConnect(RSQLite::SQLite(), file)
    on.exit(DBI::dbDisconnect(con), add = TRUE, after = FALSE)
    expect_error(.create_db_schema(con, c(msLevel = "list")), "unsupported")
    expect_error(.create_db_schema(con, c(peak_start = "integer")),
                 "reserved")
    expect_error(.create_db_schema(con, c(msLevel = "integer", msLevel = "integer")),
                 "duplicated")
    expect_error(.create_db_schema(con, c("integer")), "named")
    .create_db_schema(con, character(), page_size = 8192L)
    expect_equal(DBI::dbGetQuery(con, "PRAGMA page_size")[[1L]], 8192L)
})

test_that("variable names are quoted", {
    file <- tempfile(fileext = ".sqlite")
    on.exit(unlink(file))
    con <- DBI::dbConnect(RSQLite::SQLite(), file)
    on.exit(DBI::dbDisconnect(con), add = TRUE, after = FALSE)
    .create_db_schema(con, c(`select; DROP` = "integer", `a"b` = "numeric"))
    expect_true(all(c("select; DROP", "a\"b") %in%
                    DBI::dbListFields(con, "spectrum")))
})

test_that("metadata round trip, values stored as text", {
    file <- tempfile(fileext = ".sqlite")
    on.exit(unlink(file))
    con <- DBI::dbConnect(RSQLite::SQLite(), file)
    on.exit(DBI::dbDisconnect(con), add = TRUE, after = FALSE)
    .create_db_schema(con, character())
    expect_equal(.read_metadata(con), character())
    .write_metadata(con, list(schema_version = 1L, kind = "import",
                              n_spectra = 3L, note = NA))
    md <- .read_metadata(con)
    expect_equal(md[["schema_version"]], "1")
    expect_equal(md[["kind"]], "import")
    expect_equal(md[["n_spectra"]], "3")
    expect_true(is.na(md[["note"]]))
    .write_metadata(con, c(kind = "merge"))   # replaces, does not duplicate
    expect_equal(.read_metadata(con)[["kind"]], "merge")
    expect_equal(sum(names(.read_metadata(con)) == "kind"), 1L)
    expect_error(.write_metadata(con, c("a")), "named")
})

test_that("spectra_variable round trip keeps order and classes", {
    file <- tempfile(fileext = ".sqlite")
    on.exit(unlink(file))
    con <- DBI::dbConnect(RSQLite::SQLite(), file)
    on.exit(DBI::dbDisconnect(con), add = TRUE, after = FALSE)
    v <- c(msLevel = "integer", rtime = "numeric", flag = "logical",
           name = "character")
    .create_db_schema(con, v)
    .write_spectra_variable(con, v)
    expect_equal(.read_spectra_variable(con), v)
    expect_error(.write_spectra_variable(con, c(a = "list")), "unsupported")
})

test_that(".create_db_indices creates the two indices", {
    file <- tempfile(fileext = ".sqlite")
    on.exit(unlink(file))
    con <- DBI::dbConnect(RSQLite::SQLite(), file)
    on.exit(DBI::dbDisconnect(con), add = TRUE, after = FALSE)
    .create_db_schema(con, c(msLevel = "integer", rtime = "numeric",
                             precursorMz = "numeric"))
    .create_db_indices(con)
    idx <- DBI::dbGetQuery(con, "SELECT name FROM sqlite_master
                                 WHERE type = 'index' AND name LIKE 'idx_%'")
    expect_setequal(idx$name, c("idx_spectrum_mslevel_rtime",
                                "idx_spectrum_precursormz"))
})

test_that(".valid_db accepts a hand-built valid database", {
    con <- .hand_db(c(3L, 0L, 5L))
    expect_true(.valid_db(con))
    con2 <- .hand_db(c(0L, 2L, 0L))        # empty first and last
    expect_true(.valid_db(con2))
    con3 <- .hand_db(integer())            # zero spectra
    expect_true(.valid_db(con3))
    con4 <- .hand_db(c(0L, 0L))            # no peaks at all
    expect_true(.valid_db(con4))
})

test_that(".valid_db rejects I1: spectrum_id_ with a gap or not from 1", {
    con <- .hand_db(c(3L, 0L, 5L))
    DBI::dbExecute(con, "UPDATE spectrum SET spectrum_id_ = 5
                         WHERE spectrum_id_ = 2")
    res <- .valid_db(con)
    expect_type(res, "character")
    expect_match(res, "I1", all = FALSE)

    con <- .hand_db(c(3L, 1L))
    DBI::dbExecute(con, "UPDATE spectrum SET spectrum_id_ = spectrum_id_ + 1")
    expect_match(.valid_db(con), "I1", all = FALSE)
})

test_that(".valid_db rejects I2: peak_id_ with a gap or not from 1", {
    con <- .hand_db(c(3L, 0L, 5L))
    DBI::dbExecute(con, "DELETE FROM peak WHERE peak_id_ = 4")
    expect_match(.valid_db(con), "I2", all = FALSE)

    con <- .hand_db(c(3L, 0L, 5L))
    DBI::dbExecute(con, "UPDATE peak SET peak_id_ = peak_id_ + 1")
    expect_match(.valid_db(con), "I2", all = FALSE)
})

test_that(".valid_db rejects I3: peak_start not contiguous", {
    con <- .hand_db(c(3L, 0L, 5L))
    DBI::dbExecute(con, "UPDATE spectrum SET peak_start = 5
                         WHERE spectrum_id_ = 3")
    expect_match(.valid_db(con), "I3", all = FALSE)

    con <- .hand_db(c(3L, 0L, 5L))             # first spectrum not at 1
    DBI::dbExecute(con, "UPDATE spectrum SET peak_start = 2
                         WHERE spectrum_id_ = 1")
    expect_match(.valid_db(con), "I3", all = FALSE)

    con <- .hand_db(c(3L, 0L, 5L))             # empty spectrum misplaced
    DBI::dbExecute(con, "UPDATE spectrum SET peak_start = 1
                         WHERE spectrum_id_ = 2")
    expect_match(.valid_db(con), "I3", all = FALSE)
})

test_that(".valid_db rejects I4: SUM(peak_count) differs from the peaks", {
    con <- .hand_db(c(3L, 0L, 5L))
    DBI::dbExecute(con, "INSERT INTO peak VALUES (9, 1.0, 1.0)")
    expect_match(.valid_db(con), "I4", all = FALSE)

    con <- .hand_db(c(3L, 0L, 5L))
    DBI::dbExecute(con, "UPDATE spectrum SET peak_count = 4
                         WHERE spectrum_id_ = 3")
    expect_match(.valid_db(con), "I4", all = FALSE)
})

test_that(".valid_db reports missing tables and does not error", {
    file <- tempfile(fileext = ".sqlite")
    on.exit(unlink(file))
    con <- DBI::dbConnect(RSQLite::SQLite(), file)
    on.exit(DBI::dbDisconnect(con), add = TRUE, after = FALSE)
    res <- .valid_db(con)
    expect_type(res, "character")
    expect_match(res, "missing table", all = FALSE)
})

test_that(".valid_db works on a read-only connection and leaves the file", {
    con <- .hand_db(c(3L, 0L, 5L))
    file <- DBI::dbGetInfo(con)$dbname
    DBI::dbDisconnect(con)
    md5 <- unname(tools::md5sum(file))
    ro <- DBI::dbConnect(RSQLite::SQLite(), file, flags = RSQLite::SQLITE_RO)
    expect_true(.valid_db(ro))
    DBI::dbDisconnect(ro)
    expect_equal(unname(tools::md5sum(file)), md5)
    ## re-open so the helper's cleanup has a live connection
    assign("con", DBI::dbConnect(RSQLite::SQLite(), file), environment())
})
