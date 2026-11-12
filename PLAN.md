# MsBackendLite — implementation plan

Goal: a working prototype (milestones M0–M4), then documentation (M5).
`DESIGN.md` is the reference for every decision; section numbers below point
into it.

Tick the boxes as work is merged. Keep this file up to date in the same pull
request that completes a step.

## How to work

For every milestone:

1. Open a GitHub issue that states the goal and links the design section.
2. Work on a branch `feat-<topic>` (`bug-<topic>`, `docs-<topic>` for other
   work). Never commit to the default branch.
3. Small commits, one concern each, function + tests + documentation
   together. Conventional Commits (`feat:`, `fix:`, `test:`, `docs:`,
   `build:`, `ci:`, `refactor:`). End every commit message with
   `Assisted-by: Claude (Anthropic)`.
4. Open a pull request with `Closes #N`. Merge when CI is green.
5. Every pull request adds a line to `NEWS.md` and bumps the version
   (`0.99.0`, `0.99.1`, ...).

Done for a pull request means: new code has tests; the relevant tests pass
locally; `roxygen2::roxygenise()` was run; no dependency was added; CI is
green; this file is updated.

If something in `DESIGN.md` turns out not to work, stop, describe what was
found in the issue, and change `DESIGN.md` in the same pull request as the
code. Do not diverge silently.

## Working on a low-resource laptop

- Local tests use synthetic data only (DESIGN §11.1): a few dozen spectra, at
  most about 100 000 peaks. No large files, no downloads.
- `mzR` and `MsDataHub` are not needed locally. Tests that use them start
  with `skip_if_not_installed()` and run in CI.
- While developing run one test file:
  `Rscript -e 'devtools::load_all(); testthat::test_file("tests/testthat/test_<x>.R")'`
  (or `R CMD INSTALL .` followed by `testthat::test_file()` if `devtools` is
  not installed). Run the whole check once before opening a pull request, or
  let CI do it.
- Put shared test data in `tests/testthat/helper-*.R` so that both
  `test_file()` and `R CMD check` find it.
- Test databases go to `tempfile()` and are removed with `on.exit(unlink())`.
- Use `SerialParam()`; at most two workers in the parallel import test.
- If the repository sits on an NTFS partition: run
  `git config core.fileMode false`, and run `R CMD build` / `R CMD check`
  with the output directory on the Linux file system.
- Performance and memory are measured with `MsBench` on a bigger machine,
  not here and not in this repository.

## M0 — Environment and repository

- [x] **0.1 Inspect the machine and report**: R version,
  `BiocManager::version()`, free disk space, whether `gh` is authenticated,
  whether Docker exists.
- [x] **0.2 Environment.** `Spectra` 1.23.7 needs `MsCoreUtils (>= 1.23.6)`
  and `ProtGenerics (>= 1.39.2)`, which means Bioconductor devel. CI is the
  reference environment whichever route is used. Done with route C.
  - Route A (preferred when disk is short): R 4.6 with
    `BiocManager::install(version = "devel")`, then `Spectra` from GitHub
    `main`, `DBI`, `RSQLite`, `testthat`, `roxygen2`.
  - Route B: Docker image `bioconductor/bioconductor_docker:devel`
    (several GB).
  - Route C: Existing R 4.5.0; Bioconductor packages for R 4.5 plus
    ProtGenerics, MsCoreUtils, MetaboCoreUtils and Spectra (1.23.7) from
    GitHub with upgrade = 'never'. CI stays on R 4.6 devel.
- [x] **0.3 Repository** (`plantton/MsBackendLite`): `DESCRIPTION`
  (DESIGN §10), `NAMESPACE` via roxygen2,
  `README.md`, `NEWS.md`, `.Rbuildignore` (`CLAUDE.md`, `DESIGN.md`,
  `PLAN.md`, `.github`), `.gitignore`, `.editorconfig` (copy from `Spectra`),
  `R/hidden_aliases.R`, `tests/testthat.R`.
- [x] **0.4 CI**: one job in the Bioconductor devel container, see below.

Starting point for `.github/workflows/check.yml`:

```yaml
name: check
on: [push, pull_request]
jobs:
  check:
    runs-on: ubuntu-latest
    container: bioconductor/bioconductor_docker:devel
    steps:
      - uses: actions/checkout@v4
      - name: Install dependencies
        shell: Rscript {0}
        run: |
          BiocManager::install(c("remotes", "rcmdcheck"), ask = FALSE, update = FALSE)
          remotes::install_deps(dependencies = TRUE,
                                repos = BiocManager::repositories())
          BiocManager::install("rformassspectrometry/Spectra",
                               ask = FALSE, update = FALSE)
      - name: Check
        shell: Rscript {0}
        run: rcmdcheck::rcmdcheck(args = "--no-manual", error_on = "warning")
```

Accepted when: the empty package passes `R CMD check` in CI.

## M1 — Schema and writer (DESIGN §4, §9.1, §9.3)

- [x] **1.1 `feat-schema`** — `R/db-schema.R`: create tables, type mapping,
  read/write `metadata` and `spectra_variable`, `.valid_db()`.
  Tests: build a tiny database by hand; `.valid_db()` accepts it and
  rejects each broken invariant I1–I4.
- [x] **1.2 `feat-writer`** — class definition and constructor only
  (DESIGN §5), `R/db-write.R`: chunk planning, `.peak_stats()`, peak
  clean-up (drop `NA`, sort by m/z), profile check, `.write_spectra_db()`,
  `export()` method (returns the file path invisibly for now).
  Tests with the synthetic `Spectra` helper, checked with plain SQL:
  row counts, `peak_start` / `peak_count`, summary columns, m/z order,
  empty spectra, zero spectra, logical / character variables, dropped
  unsupported columns, several chunks (set a small `chunkPeaks`),
  refusal to overwrite, profile data rejected with no `.partial` left.

Accepted when: a synthetic `Spectra` object is written to a valid database
and the stored values equal the input.

- [ ] **1.3 CI on Windows and macOS** (`ci-matrix`): add a `check-os` job
  (`windows-latest`, `macos-latest`) next to the Ubuntu job. `Spectra` from
  GitHub, Bioconductor devel, `mzR` / `MsDataHub` left to the Ubuntu job.
  Starts with `continue-on-error: true`; remove it when the job is stable.
  Accepted when the package passes `R CMD check` on all three systems.

## M2 — Reading (DESIGN §5–§8)

- [ ] **2.1 `feat-backend-init`** — validity, `.dbcon()`,
  `backendInitialize()`, `show`, `dataStorage`, `.fetch_spectra_data()`,
  `spectraData()` for spectra variables, `[`, `extractByIndex()`,
  `lengths()`, `peaksVariables()`, `spectraNames()`.
- [ ] **2.2 `feat-peaks`** — `.fetch_peaks()`, `peaksData()`, `mz()`,
  `intensity()`, `mz` / `intensity` in `spectraData()`, `ionCount()`,
  `tic()`, `.check_peak_limit()`, `.chunk_factor()`,
  `backendParallelFactor()`, `backendBpparam()`.
- [ ] **2.3 `feat-backend-state`** — `backendMerge()`, `reset()`, `$<-`
  restrictions, `export()` now returns a `Spectra` object.
  Tests (DESIGN §11.2–§11.5): comparison with `MsBackendMemory` for every
  accessor and filter; the `Spectra` compliance suite on the full backend
  and on a shuffled subset with duplicates (run from `tests/testthat.R`
  after `test_check()`, as `MsBackendSql` does); the statistics table of
  §8.1;
  database md5 unchanged after filters, processing and `reset()`;
  `saveRDS()` round trip; chunked operations give the same result with a
  small `MsBackendLite.chunkPeaks`; the peak limit error.

Accepted when: the compliance suite passes and
`Spectra(file, source = MsBackendLite())` behaves like the in-memory object
it was exported from.

## M3 — Import from raw files (DESIGN §9.2)

- [ ] **3.1 `feat-import`** — `createMsBackendLiteDatabase()` with
  `SerialParam()`: `msLevel`, fail-fast profile check, report
  (`data.frame`, CSV, `import_report` table), `.partial` handling, skip
  existing files, `overwrite`. Before writing tests, check which
  `MsDataHub` files are centroided, profile or mixed (DESIGN §15).
- [ ] **3.2 `feat-import-parallel`** — one worker per file through `BPPARAM`,
  one failing file does not stop the others. Real-data tests (CI):
  every spectrum equals `MsBackendMzR`; a mixed file fails by default and
  imports with `msLevel = 2L`.

Accepted when: a batch with one bad file yields valid databases for the good
files and a report that names the bad one and the reason.

## M4 — Merge (DESIGN §9.4)

- [ ] **4.1 `feat-merge`** — `mergeSQLiteDatabases()`: checks, union of
  columns, append with offsets, `source` rows, `note`, `.valid_db()`.
  Tests: merged object equals `c()` of the in-memory inputs; different
  column sets; duplicate source and class conflict are errors; inputs
  unchanged (md5); `c()` across files gives the documented error.

Accepted when: the four-step workflow of DESIGN §3 runs from raw files to an
analysed study database.

## M5 — Documentation

- [ ] **5.1 `docs-vignette`** — vignette built around the workflow of DESIGN
  §3, including: what is stored and what is computed (§8.1), how to undo
  (§8.2), which calls load all peaks and the `mem.maxVSize()` advice
  (§7.2, §7.3), how to centroid profile data.
- [ ] **5.2 `docs-polish`** — complete man pages, README, `NEWS.md`;
  `R CMD check` without warnings or notes; run `BiocCheck` and list what
  remains.

## After the prototype

Follow DESIGN §12 in order. The first three items are: SQL `WHERE` for the
hot spectrum-level filters (measured with `MsBench`), stateless SQL peak
queries with the optional m/z index, and a guard for accumulated reads.
