# MsBackendLite

An R package: a read-only SQLite backend for the Bioconductor `Spectra`
package. It follows the conventions of the RforMassSpectrometry packages
(`Spectra`, `MsBackendSql`).

Read `DESIGN.md` (what and why) and `PLAN.md` (what to do next) before any
work. `PLAN.md` shows the current milestone; continue from the first
unticked box.

## Rules that must never be broken

1. Never write to an existing database. New data means a new file. Reading
   uses a read-only connection.
2. Never load all peaks of a large object into memory. Read peaks in chunks
   sized by number of peaks.
3. All state of an object (selected spectra, cached variables, processing)
   lives in R, never in the database.
4. Never pass a database connection to another process. Pass the file path.
5. Stored columns describe the stored data. Values that depend on the current
   state of an object are computed.
6. Do not add a dependency without asking. Runtime dependencies are those in
   `DESIGN.md` §10. No benchmark code in this repository.

If a rule or the design conflicts with what the code needs, stop and ask.

## Workflow

- One issue per milestone, branch `feat-<topic>`, small commits, pull request
  with `Closes #N`, merge when CI is green. Never commit to the default
  branch.
- Conventional Commits. End every commit message with
  `Assisted-by: Claude (Anthropic)`.
- Each pull request: tests for new code, `roxygen2::roxygenise()`, a line in
  `NEWS.md`, version bump, `PLAN.md` boxes ticked.
- Write the test first when the expected result is known (it usually is: the
  same data in `MsBackendMemory`).

## This machine

It is an old laptop with little memory and disk.

- Tests use small synthetic data only. No downloads, no large files.
- `mzR` and `MsDataHub` may be missing; tests that need them must skip. CI
  runs them.
- Run single test files while developing; run the full check before a pull
  request or leave it to CI.
- Do not run benchmarks here.

## Code style

As in `Spectra`: S4 classes and methods, camelCase for exported names,
internal functions start with a dot, 4 spaces, lines up to 80 characters,
`stop()` / `stopifnot()` for argument checks, `message()` for progress,
roxygen2 with markdown. Quote SQL identifiers with
`DBI::dbQuoteIdentifier()`; pass values as query parameters.

## Reference sources

Clone outside this repository and read when implementing a method:

- `rformassspectrometry/Spectra`: `R/MsBackendCached.R`, `R/MsBackend.R`
  (default methods), `R/Spectra-functions.R` (`.peaksapply`),
  `inst/test_backends/` (compliance suite).
- `rformassspectrometry/MsBackendSql`: `R/MsBackendSql.R`,
  `R/MsBackendSql-functions.R`, `tests/testthat.R`.

## Commands

```sh
Rscript -e 'roxygen2::roxygenise()'
Rscript -e 'devtools::load_all(); testthat::test_file("tests/testthat/test_<x>.R")'
R CMD build . && R CMD check --no-manual MsBackendLite_*.tar.gz
```
