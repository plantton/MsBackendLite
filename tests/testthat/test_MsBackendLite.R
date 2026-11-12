test_that("MsBackendLite() returns a valid empty object", {
    be <- MsBackendLite()
    expect_s4_class(be, "MsBackendLite")
    expect_true(validObject(be))
    expect_length(be, 0L)
    expect_identical(be@dbfile, character())
    expect_true(isReadOnly(be))
    expect_true(is.environment(be@.con))
})

test_that("each object gets its own connection environment", {
    a <- MsBackendLite()
    b <- MsBackendLite()
    expect_false(identical(a@.con, b@.con))
    assign("x", 1, envir = a@.con)
    expect_false(exists("x", envir = b@.con, inherits = FALSE))
})

test_that("validity checks slot lengths and dbfile", {
    be <- MsBackendLite()
    be@nspectra <- 2L
    be@localData <- data.frame(row.names = 1:2)
    expect_error(validObject(be), "length")
    be@spectraIds <- 1:2
    be@peakStart <- c(1, 4)
    be@peakCount <- c(3L, 0L)
    expect_true(validObject(be))
    be@dbfile <- c("a", "b")
    expect_error(validObject(be), "dbfile")
})
