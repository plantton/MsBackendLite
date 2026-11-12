test_that("the package attaches together with Spectra", {
    expect_true("MsBackendLite" %in% loadedNamespaces())
    expect_true("package:Spectra" %in% search())
    expect_true(packageVersion("Spectra") >= "1.23.7")
})
