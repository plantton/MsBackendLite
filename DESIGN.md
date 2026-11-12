# MsBackendLite — design

Status: design for the first prototype, no code written yet. Date: 2026-11-11.

This document is the design reference for the package. `PLAN.md` holds the
implementation steps, `CLAUDE.md` the working rules for Claude Code.

Interfaces were checked against these sources (clone them next to the repo for
reference, never inside it):

| Package | Version / commit | Used for |
|---|---|---|
| `rformassspectrometry/Spectra` | 1.23.7, `48cacff` (2026-10-30) | all `Spectra` / `MsBackend` behaviour described here |
| `rformassspectrometry/MsBackendSql` | 1.11.3, `9b5f2fe` | reference implementation of a backend extending `MsBackendCached` |
| `rformassspectrometry/ProtGenerics` | 1.45.0, `4def12d` | generics |

The package follows the `main` branch of `Spectra` on GitHub. Compatibility
with the current Bioconductor release is not a goal.

The SQL statements and the function sketches in this document (`.dbcon`,
`.fetch_peaks`, `.chunk_factor`, `.check_peak_limit`, `.peak_stats`) were
executed as printed here with RSQLite 2.3.4 (SQLite 3.44.2). The class
definition and the usage examples could not be run: the package itself has
not been written yet.

---

## 1. Purpose

`MsBackendLite` is a **read-only** backend for `Spectra` that stores mass
spectrometry data in a single SQLite file.

- m/z and intensity values are stored as plain numeric columns, not BLOBs, so
  they can be queried with SQL and read without decoding.
- Peak data is never loaded into memory as a whole. The target machine is an
  ordinary PC or laptop (8–16 GB RAM).
- Filtering is soft: nothing a user does to a `Spectra` object changes the
  database, so every filter can be undone.

Non-goals for the first version: writing to an existing database, profile-mode
data, ion mobility data, imaging data, other SQL engines.

Relation to `MsBackendSql` (Bioconductor): that package supports several SQL
engines and defaults to BLOB storage. This package supports SQLite only and
uses a layout (section 4) that needs a database which never changes.

## 2. Rules that must always hold

1. **A database file is immutable once written.** No method writes to an
   existing database. New data always means a new file (import, export,
   merge). Reading uses a read-only connection.
2. **All state of a `Spectra` object lives in the R object**, never in the
   database: which spectra are selected, cached spectra variables, and the
   `Spectra` processing queue.
3. **Peaks are read in chunks sized by number of peaks**, not by number of
   spectra.
4. **A database connection never crosses a process boundary.** Objects carry
   the file path and reconnect on demand
   ([BiocParallel #129](https://github.com/Bioconductor/BiocParallel/issues/129)).
5. **Values stored in the database describe the stored data.** Anything that
   depends on the current state of an object (after filtering) is computed,
   never read from a stored column.
6. **The package stays light.** Runtime dependencies beyond what `Spectra`
   already needs: `DBI` and `RSQLite` only. No benchmark code in this
   repository (that is the separate `MsBench` package).

## 3. Overview

```
 raw files (mzML)                 any Spectra object              several databases
        │ createMsBackendLiteDatabase()     │ export()                    │ mergeSQLiteDatabases()
        ▼                                   ▼                             ▼
   A.sqlite, B.sqlite, ...            derived.sqlite                 study.sqlite
   (one per raw file)                 (processing applied)           (pure SQL append)
        │
        ▼  Spectra("A.sqlite", source = MsBackendLite())
   read-only backend ── filters, processing queue, reset() ── all in the R object
```

Recommended workflow for a batch of raw files:

1. Import: one database per raw file, optionally in parallel, plus an import
   report.
2. The user reads the report and decides which files to keep.
3. Merge the chosen databases into one study database.
4. Analyse the study database with `Spectra`.

```r
files  <- list.files("raw", pattern = "mzML$", full.names = TRUE)
report <- createMsBackendLiteDatabase(files, outdir = "db")        # 1
report[, c("file", "status", "n_spectra", "n_peaks", "error")]     # 2
keep   <- report$dbfile[report$status == "ok"]
mergeSQLiteDatabases(keep, file = "study.sqlite",                  # 3
                     note = "C.mzML excluded: profile MS1")
sps <- Spectra("study.sqlite", source = MsBackendLite())           # 4
sps2 <- sps |> filterMsLevel(2L) |> filterRt(c(300, 1800)) |>
    filterIntensity(c(100, Inf))            # nothing is written; sps is unchanged
sps3 <- export(sps2, MsBackendLite(), file = "ms2_clean.sqlite")   # fixed result, new file
```

## 4. Database layout

### 4.1 Tables

```sql
PRAGMA page_size = 32768;            -- must run before the first CREATE TABLE

CREATE TABLE metadata (key TEXT PRIMARY KEY, value TEXT);

CREATE TABLE spectra_variable (       -- R class of every spectra variable column
    name    TEXT PRIMARY KEY,
    r_class TEXT NOT NULL             -- integer | numeric | character | logical
);

CREATE TABLE source (                 -- where the data in this file came from
    source_id_      INTEGER PRIMARY KEY,
    type            TEXT NOT NULL,    -- 'mzML', 'MsBackendLite', or a backend class
    path            TEXT,
    md5             TEXT,
    n_spectra       INTEGER,
    n_peaks         INTEGER,
    spectrum_offset INTEGER NOT NULL DEFAULT 0,
    peak_offset     INTEGER NOT NULL DEFAULT 0,
    info            TEXT
);

CREATE TABLE spectrum (
    spectrum_id_        INTEGER PRIMARY KEY,
    peak_start          INTEGER NOT NULL,   -- peak_id_ of the first peak
    peak_count          INTEGER NOT NULL,   -- number of peaks, may be 0
    source_id_          INTEGER NOT NULL DEFAULT 1,
    source_spectrum_id_ INTEGER,
    -- one column per spectra variable, identifiers always quoted:
    "msLevel" INTEGER, "rtime" REAL, "precursorMz" REAL, "dataOrigin" TEXT, ...
    -- recomputed from the stored peaks when the file is written:
    "peaksCount" INTEGER, "totIonCurrent" REAL, "basePeakMZ" REAL,
    "basePeakIntensity" REAL, "lowMZ" REAL, "highMZ" REAL
);

CREATE TABLE peak (
    peak_id_  INTEGER PRIMARY KEY,          -- alias of the SQLite rowid
    mz        REAL NOT NULL,
    intensity REAL NOT NULL
);

CREATE VIEW peak_long AS                    -- convenience for hand-written SQL
SELECT s.spectrum_id_, p.mz, p.intensity
FROM spectrum s
JOIN peak p ON p.peak_id_ BETWEEN s.peak_start AND s.peak_start + s.peak_count - 1;

-- after all rows are written:
CREATE INDEX idx_spectrum_mslevel_rtime ON spectrum ("msLevel", "rtime");
CREATE INDEX idx_spectrum_precursormz   ON spectrum ("precursorMz");
ANALYZE;
```

One peak is one row of `peak`; its m/z and intensity sit side by side in that
row. The `peak` table does not store which spectrum a peak belongs to. That
link is the pair `peak_start` / `peak_count` in `spectrum` (the same idea as
the CSR format for sparse matrices).

Example with three spectra (3, 0 and 5 peaks):

| spectrum_id_ | peak_start | peak_count |
|---|---|---|
| 1 | 1 | 3 |
| 2 | 4 | 0 |
| 3 | 4 | 5 |

The peaks of spectrum 3 are rows 4 to 8 of `peak`:
`SELECT mz, intensity FROM peak WHERE peak_id_ BETWEEN 4 AND 8 ORDER BY peak_id_`.
SQLite answers this with a rowid range scan
(`SEARCH peak USING INTEGER PRIMARY KEY (rowid>? AND rowid<?)`).

Why this layout: a spectrum of 10 peaks and one of 50 000 peaks are read the
same way; the number of peaks of every spectrum is known before reading, which
makes chunking by peak count possible; only two values per peak are
transferred to R. The price is that the file cannot be modified in place:
inserting one peak would shift every later `peak_start`. That is why rule 1
exists.

### 4.2 Invariants

A valid database satisfies all of these. `.valid_db()` checks I1–I4 with SQL
after every write; I5–I7 are guaranteed by the writer.

- I1 `spectrum_id_` is `1..N` without gaps.
- I2 `peak_id_` is `1..P` without gaps.
- I3 The first spectrum has `peak_start = 1`; every other spectrum has
  `peak_start` = previous `peak_start + peak_count` (also for empty spectra).
- I4 `SUM(peak_count) = P`.
- I5 Within a spectrum, peaks are ordered by increasing m/z.
- I6 `peaksCount = peak_count`; the other five summary columns match the
  stored peaks. For an empty spectrum: `peaksCount = 0`, `totIonCurrent = 0`,
  the other four `NULL` (same convention as `Spectra:::.write_ms_data_mzR`).
- I7 No `NULL` or `NaN` in `mz` or `intensity`.

Check used for I1–I4 (tested):

```sql
SELECT (SELECT SUM(peak_count) FROM spectrum) AS sum_count,
       (SELECT COUNT(*) FROM peak)            AS n_peak,
       (SELECT MAX(peak_id_) FROM peak)       AS max_peak_id,
       (SELECT COUNT(*) FROM spectrum)        AS n_spectrum,
       (SELECT MAX(spectrum_id_) FROM spectrum) AS max_spectrum_id;

SELECT COUNT(*) AS n_bad FROM (
    SELECT peak_start,
           LAG(peak_start + peak_count, 1, 1) OVER (ORDER BY spectrum_id_) AS expected
    FROM spectrum)
WHERE peak_start != expected;                 -- must be 0
```

### 4.3 Columns and types

- Reserved names: `spectrum_id_`, `peak_start`, `peak_count`, `source_id_`,
  `source_spectrum_id_`, `mz`, `intensity`, `dataStorage`. The writer never
  copies a variable with one of these names as an ordinary column. When the
  input uses `MsBackendLite` they are replaced by the new values; when
  another backend provides a variable called `spectrum_id_`, `peak_start`,
  `peak_count`, `source_id_` or `source_spectrum_id_`, the writer stops and
  asks the user to rename it.
- `spectrum_id_`, `source_id_` and `source_spectrum_id_` are visible as
  read-only spectra variables. `peak_start` and `peak_count` are hidden.
- `dataStorage` is not stored; the backend returns the database path.
- Type mapping: integer → `INTEGER`, numeric → `REAL`, character and factor →
  `TEXT`, logical → `INTEGER` (0/1) with `r_class = 'logical'` so it is turned
  back into `logical` on reading. Columns of any other type (lists, S4
  objects) are dropped with a message and listed in the report.
- All identifiers are quoted with `DBI::dbQuoteIdentifier()`.
- `peak_start` can exceed the range of an R integer. Always read it as
  `CAST(peak_start AS REAL)` and keep it as `numeric` in R.

### 4.4 `metadata` keys

`schema_version` (`"1"`), `kind` (`import` | `export` | `merge`),
`package_version`, `spectra_version`, `created` (UTC, ISO 8601), `n_spectra`,
`n_peaks`, `page_size`, `ms_levels` (import filter or `all`),
`processing_log` (text of `processingLog()` for exports), `note` (free text
given by the user at merge time).

`backendInitialize()` stops with a clear message if `schema_version` is
missing or not supported.

### 4.5 Pragmas

- Writing a new file: `page_size = 32768`, `journal_mode = OFF`,
  `synchronous = OFF`. Safe because the file is written as `<name>.partial`
  and renamed only after `.valid_db()` passes; a crash leaves a `.partial`
  file that is deleted on the next run.
- Reading: `dbConnect(SQLite(), dbfile, flags = RSQLite::SQLITE_RO)` followed
  by `PRAGMA mmap_size = 268435456` (256 MB). Memory-mapped pages belong to
  the operating system's file cache and can be dropped at any time.
- `page_size` is a parameter of the writer (default 32 KB). 16/32/64 KB will
  be compared with real data later.

## 5. The backend class

```r
setClass(
    "MsBackendLite",
    contains = "MsBackendCached",
    slots = c(
        dbfile     = "character",     # normalized path, the source of truth
        spectraIds = "integer",       # spectrum_id_ of each spectrum, any order, duplicates allowed
        peakStart  = "numeric",       # peak_start of each spectrum
        peakCount  = "integer",       # peak_count of each spectrum
        varClasses = "character",     # named: spectra variable -> r_class
        .con       = "environment"),  # connection cache, see 5.1
    prototype = prototype(readonly = TRUE, version = "0.1"))
```

`spectraIds`, `peakStart` and `peakCount` always have length `nspectra` and
are subset together. Keeping `peakStart` / `peakCount` in the object (12 bytes
per spectrum) means reading peaks, `lengths()` and chunk planning need no
query on the `spectrum` table.

`MsBackendCached` (from `Spectra`) provides the local cache that makes
`sps$newVariable <- value` work on a read-only backend. Its contract
(`R/MsBackendCached.R`): call its `backendInitialize()` with `nspectra` and
`spectraVariables`; `spectraData()` must first ask the cached method; `[` /
`extractByIndex()` must also call the inherited method. `MsBackendSql` shows
the pattern (`R/MsBackendSql.R`, `R/MsBackendSql-functions.R`:
`.spectra_data_sql()`, `.combine()`).

### 5.1 Connection handling

The `.con` slot is an environment holding the connection and the id of the
process that opened it.

```r
.dbcon <- function(x) {
    e <- x@.con
    if (is.null(e$con) || !identical(e$pid, Sys.getpid()) || !dbIsValid(e$con)) {
        if (!is.null(e$con))
            e$stale <- c(e$stale, list(e$con))   # never use or close an inherited handle
        e$con <- dbConnect(SQLite(), x@dbfile, flags = SQLITE_RO)
        dbExecute(e$con, "PRAGMA mmap_size = 268435456")
        e$pid <- Sys.getpid()
    }
    e$con
}
```

- After `saveRDS()` / `readRDS()` or in a parallel worker the stored
  connection is invalid and a new one is opened from `dbfile` (tested with
  `serialize()` / `unserialize()`).
- In a forked child the inherited connection looks valid but must not be
  used; the process id check catches this.
- The environment must be created in `backendInitialize()` with
  `new.env(parent = emptyenv())`. **Do not put `new.env()` in the class
  prototype**: a prototype environment is shared by all objects (tested).
- If `dbfile` does not exist, stop with a message that names the path.

### 5.2 Methods

`be` is the backend, `n` its number of spectra.

| Method | Implementation |
|---|---|
| `backendInitialize(object, dbfile, ...)` | Check file and `schema_version`. Read `spectrum_id_`, `CAST(peak_start AS REAL)`, `peak_count` ordered by `spectrum_id_`. Read `spectra_variable`. Then `callNextMethod(object, nspectra = , spectraVariables = c(<visible columns>, "mz", "intensity"))`. Must accept `...` (`Spectra()` passes `BPPARAM`). |
| `show` | Class, number of spectra, total number of peaks, database path, and the approximate size if all peaks were loaded (16 bytes per peak). |
| `length`, `spectraVariables`, `$`, `selectSpectraVariables`, `dropNaSpectraVariables` | Inherited. |
| `dataStorage` | `rep(dbfile, n)`. |
| `spectraData(object, columns)` | 1. cached and core variables via the `MsBackendCached` method; 2. remaining database columns (section 6.2); 3. `mz` / `intensity` as `NumericList(..., compress = FALSE)` when requested; 4. restore `logical` columns using `varClasses`; 5. return columns in the requested order. |
| `peaksData(object, columns = c("mz", "intensity"))` | `.fetch_peaks()` (section 6.1). List of numeric matrices, one per spectrum, 0-row matrix for empty spectra. |
| `mz`, `intensity` | `.fetch_peaks()` with one column, wrapped in `NumericList`. Only that column is selected in SQL. |
| `peaksVariables` | `c("mz", "intensity")`. |
| `lengths` | `object@peakCount` (integer, no query). |
| `isEmpty` | Default (`lengths(x) == 0L`). |
| `ionCount` | The `totIonCurrent` column read **from the database**, not from the cache. Correct because the backend has no peak-level state (rule 5). |
| `tic(object, initial = TRUE)` | `initial = TRUE`: default method (reads `totIonCurrent`). `initial = FALSE`: `ionCount(object)`. |
| `[`, `extractByIndex` | `[`: `extractByIndex(x, i2index(i, length(x)))`. `extractByIndex`: subset `spectraIds`, `peakStart`, `peakCount`, then `callNextMethod()`. |
| `backendMerge` | All objects must have the same `dbfile`: concatenate the three slots and the cached data (see `.combine()` in `MsBackendSql`). Different files: stop and point to `mergeSQLiteDatabases()`. |
| `reset` | `backendInitialize(MsBackendLite(), object@dbfile)`. Restores all spectra and drops cached variables. |
| `isReadOnly` | `TRUE` (prototype). `supportsSetBackend` is then `FALSE` by default; converting other data goes through `export()`. |
| `$<-` | Stop for `spectrum_id_`, `source_id_`, `source_spectrum_id_`, `mz`, `intensity`; otherwise inherited (cache). |
| `spectraNames` | `NULL`. `spectraNames<-` stops. |
| `backendBpparam` | `SerialParam()` in the first version. |
| `backendParallelFactor` | `.chunk_factor(object@peakCount)` (section 7). |
| `export(object, x, file, ...)` | The writer (section 9.3). |
| `filterMsLevel`, `filterRt`, ... (all spectrum-level filters) | **Not overridden in the first version.** See section 8.2. |

Constructor: `MsBackendLite()` returns an empty object. Users write
`Spectra("A.sqlite", source = MsBackendLite())`, which calls
`backendInitialize(MsBackendLite(), "A.sqlite", ...)`.

Every method must work on the empty object (no file, zero spectra) and on a
zero-length subset without opening a connection.

Validity: `spectraIds`, `peakStart` and `peakCount` have length `nspectra`;
`dbfile` has length 0 or 1.

## 6. Reading

### 6.1 Peaks

One query per call. Ranges of spectra that are adjacent in the `peak` table
are merged; all ranges are sent as one parameterised query (RSQLite returns
the rows of all parameter sets in order). Duplicated and unordered spectra are
handled in R. Tested for full, shuffled, duplicated, empty and reversed
selections.

```r
.fetch_peaks <- function(x, columns = c("mz", "intensity")) {
    cnt <- x@peakCount
    .check_peak_limit(sum(as.numeric(cnt)))                  # section 7.3
    empty <- matrix(numeric(), ncol = length(columns),
                    dimnames = list(NULL, columns))
    res <- rep(list(empty), length(x))
    u <- which(!duplicated(x@spectraIds) & cnt > 0L)
    if (!length(u))
        return(res)
    u <- u[order(x@peakStart[u])]
    s <- x@peakStart[u]
    e <- s + cnt[u] - 1
    brk <- c(TRUE, s[-1L] != e[-length(e)] + 1)              # TRUE where a new range starts
    qry <- paste0("SELECT ", paste(columns, collapse = ", "),
                  " FROM peak WHERE peak_id_ BETWEEN ? AND ? ORDER BY peak_id_")
    p <- dbGetQuery(.dbcon(x), qry,
                    params = list(s[brk], e[c(brk[-1L], TRUE)]))
    if (nrow(p) != sum(cnt[u]))
        stop("Database is inconsistent: unexpected number of peaks returned")
    m <- as.matrix(p)
    pl <- unname(lapply(split(seq_len(nrow(m)), rep.int(seq_along(u), cnt[u])),
                        function(i) m[i, , drop = FALSE]))
    has <- cnt > 0L
    res[has] <- pl[match(x@spectraIds[has], x@spectraIds[u])]
    res
}
```

### 6.2 Spectra variables

Select the requested columns plus `spectrum_id_`:

- ids form one increasing run without gaps:
  `WHERE spectrum_id_ BETWEEN ? AND ? ORDER BY spectrum_id_`;
- otherwise: `WHERE spectrum_id_ IN (<sorted unique ids, inlined>)`, then
  `match()` to restore order and duplicates.

Measured on a table with 1 million spectra: full column 0.3 s, inlined `IN`
list of 500 000 ids 0.8 s, range of 200 000 rows 0.1 s.

## 7. Memory

### 7.1 Chunked operations (bounded automatically)

`Spectra` functions that reduce peaks to one value per spectrum
(`lengths()` with a processing queue, `ionCount()`, `isEmpty()`,
`containsMz()`, ...) go through `Spectra:::.peaksapply()`. It splits the
backend with `backendParallelFactor()`, reads one chunk, applies the
processing queue and the function, keeps the small result and drops the
peaks. With `SerialParam()` only one chunk is in memory at a time.

```r
.chunk_factor <- function(cnt, budget = getOption("MsBackendLite.chunkPeaks", 1e6)) {
    cs <- cumsum(as.numeric(cnt))
    if (!length(cs) || cs[length(cs)] <= budget)
        return(factor())                       # small object: no chunking
    g <- pmax(ceiling(cs / budget), 1)
    factor(g, levels = unique(g))
}
```

A chunk holds about one million peaks (roughly 50 MB while it is processed);
a single spectrum larger than the budget gets a chunk of its own. A value set
by the user with `processingChunkSize()` takes precedence (that is `Spectra`
behaviour).

### 7.2 What each call costs

| Call | Reads peaks? | Memory |
|---|---|---|
| `sps$peaksCount`, `tic(sps)`, `msLevel(sps)`, all spectrum-level filters | no | one value per spectrum |
| `lengths(sps)` on a small object without processing queue | no | one value per spectrum |
| `lengths(sps)` otherwise, `ionCount(sps)`, `isEmpty(sps)` | yes, chunk by chunk | one chunk |
| `peaksData(sps)`, `mz(sps)`, `intensity(sps)` | yes | **all requested peaks** |

### 7.3 Limit on a single request

```r
.check_peak_limit <- function(n, limit = getOption("MsBackendLite.maxPeaks", 5e7)) {
    if (n > limit)
        stop("This request would load ",
             format(n, big.mark = ",", scientific = FALSE),
             " peaks into memory; the limit is ",
             format(limit, big.mark = ",", scientific = FALSE),
             ". Filter the data first, process it in chunks, or raise ",
             "options(MsBackendLite.maxPeaks = ).", call. = FALSE)
}
```

The backend knows the number of peaks before reading and refuses a request
above the limit (default 50 million peaks, about 800 MB).

**Known gap.** The limit sees one backend request at a time. For a large
object `Spectra` itself splits `mz(sps)`, `intensity(sps)` and
`peaksData(sps)` into chunks (they use the same chunk factor as the reducing
functions), so each request is small and the limit does not trigger, while
`Spectra` accumulates the full result. The backend cannot tell an accumulating
call from a reducing one. For the first version:

- the limit protects calls made directly on the backend (for example
  `peaksData(sps@backend)` or `spectraData(be)`), not chunked `Spectra`
  calls;
- `show()` prints the total number of peaks and the size if fully loaded;
- the vignette states which calls load everything (table above) and
  recommends `mem.maxVSize()` at the start of a session so that R stops with
  an error instead of exhausting the machine.

A real guard for this case is an open item (section 12).

## 8. Statistics, filtering, reversibility

### 8.1 Stored values and current values

| Wanted | Call | Source |
|---|---|---|
| peak count / total ion current / base peak / m/z range of the **stored** data | `sps$peaksCount`, `tic(sps)`, `sps$basePeakMZ`, `sps$lowMZ`, ... | columns of `spectrum`, instant |
| the same for the **current** state (after peak filtering) | `lengths(sps)`, `ionCount(sps)`, `isEmpty(sps)` | computed chunk by chunk from the peaks |

The six stored variables are the standard mzML header variables. They do not
change under lazy filtering with any `Spectra` backend, so the meaning is
already familiar.

Example (intensities `10, 50, 20` / none / `5, 8, 90, 12, 3`):

| Step | Database | `lengths()` | `ionCount()` | `sps$peaksCount` |
|---|---|---|---|---|
| opened | unchanged | 3, 0, 5 | 80, 0, 118 | 3, 0, 5 |
| `filterIntensity(sps, c(10, Inf))` | unchanged | 3, 0, 2 | 80, 0, 102 | 3, 0, 5 |
| `reset(sps)` | unchanged | 3, 0, 5 | 80, 0, 118 | 3, 0, 5 |

### 8.2 Three layers of state

| Layer | Where | Changed by | Undone by |
|---|---|---|---|
| selected spectra and their order | backend slots `spectraIds`, `peakStart`, `peakCount` | `[`, `filterMsLevel()`, `filterRt()`, ... | `reset()` |
| cached / added spectra variables | `MsBackendCached` local data | `sps$x <- value` | `reset()` |
| peak-level processing | `Spectra` processing queue | `filterIntensity()`, `filterMzRange()`, `pickPeaks()`, ... | `reset()` |

Ways to go back: keep the object from before the filter (nothing was written,
so it is untouched); `reset()` returns to the state after opening the
database; a result fixed with `export()` leaves the source database as it was.
Undoing only the last step is not part of the first version.

**Spectrum-level filters use the `Spectra` default methods in the first
version.** The defaults (`R/MsBackend.R`) read one spectra variable and
subset, for example `object[msLevel(object) %in% msLevel]`. With this backend
that is one column query and never touches the peaks. This is correct,
memory-safe and, at 0.3–0.8 s per column for a million spectra, fast enough.
(`filterEmptySpectra(sps)` is the exception: `Spectra` computes it from
`lengths(sps)`, see section 7.2.) Overriding
filters with SQL `WHERE` clauses is an optimisation for later (section 11).

**Peak-level filters** are the `Spectra` functions; they only add a step to
the processing queue. The backend has no peak-level state.

## 9. Writing databases

### 9.1 One writer for import and export

`.write_spectra_db(x, file, kind, ...)` writes any `Spectra` object `x` to a
new file. Import and export both use it.

1. Refuse to overwrite unless `overwrite = TRUE`. Write to `<file>.partial`.
2. Decide the columns and their R classes from the spectra variables of `x`
   (for example from the first chunk): drop reserved names and unsupported
   types, drop the six summary variables (they are recomputed).
3. Create tables (section 4.1) with the pragmas of section 4.5.
4. Plan chunks by number of peaks: use `x$peaksCount` when it is available
   and plausible (no `NA`, not all zero), otherwise 500 spectra per chunk.
5. For each chunk, in one transaction:
   - `peaksData()` of the chunk (this applies the processing queue);
   - per spectrum: drop rows with `NA` m/z or intensity, sort by m/z if
     needed, compute the six summary values (`.peak_stats()` below);
   - append peaks with explicit `peak_id_` (running offset);
   - append spectrum rows with `spectrum_id_`, `peak_start`, `peak_count`,
     `source_id_ = 1`, `source_spectrum_id_`;
   - discard the chunk.
6. Create indices, `ANALYZE`, write `metadata`, `spectra_variable`, `source`.
7. Run `.valid_db()`. On success disconnect and rename to `file`; on any
   error delete the `.partial` file and stop.

`source_spectrum_id_` is the `spectrum_id_` in the source database when `x`
uses `MsBackendLite`, otherwise the position of the spectrum in `x`.

```r
.peak_stats <- function(z) {                       # z: matrix sorted by m/z
    n <- nrow(z)
    if (!n)
        return(c(peaksCount = 0, totIonCurrent = 0, basePeakMZ = NA_real_,
                 basePeakIntensity = NA_real_, lowMZ = NA_real_, highMZ = NA_real_))
    mz <- z[, 1L]
    int <- z[, 2L]
    i <- which.max(int)
    c(peaksCount = n, totIonCurrent = sum(int), basePeakMZ = mz[i],
      basePeakIntensity = int[i], lowMZ = mz[1L], highMZ = mz[n])
}
```

**Profile data is rejected** by the writer, per spectrum:

- `centroided` is `FALSE`: profile.
- `centroided` is `NA`: use `isCentroided()` on those spectra; `FALSE` means
  profile, `NA` (too few peaks to tell) is accepted and counted. With
  `assumeCentroided = TRUE` the heuristic is skipped.
- Any profile spectrum stops the write. The message says how many spectra of
  which MS level are affected and gives two remedies: convert again with
  msconvert and `--filter "peakPicking vendor msLevel=1-"`, or
  `export(pickPeaks(sps), MsBackendLite(), file = )` (`pickPeaks()` sets
  `centroided` to `TRUE`; the export applies it chunk by chunk).

### 9.2 Import

```r
createMsBackendLiteDatabase(
    x,                              # character: raw files (mzML, mzXML)
    outdir = ".",                   # one database per file: <outdir>/<name>.sqlite
                                    # (<name> = file name without .mzML / .mzML.gz / .mzXML)
    msLevel = integer(),            # import only these MS levels; empty = all
    assumeCentroided = FALSE,
    chunkPeaks = 1e6, pageSize = 32768L,
    overwrite = FALSE,
    BPPARAM = SerialParam())        # parallel over files, never within a file
```

Per file, in its own worker when `BPPARAM` is parallel:

1. `Spectra(file, source = MsBackendMzR())`; needs `mzR` (in `Suggests`,
   checked with `requireNamespace()`).
2. Apply `msLevel`. With the default every spectrum is imported. `msLevel`
   exists for files that mix profile MS1 with centroided MS2: the user states
   explicitly that only some levels are wanted; the skipped spectra are
   counted in the report and recorded in `metadata`.
3. Fail fast: if the header already flags selected spectra as profile, stop
   before reading peaks.
4. `.write_spectra_db()`; `source` gets one row of type `mzML` with path and
   md5 of the raw file.
5. Return one report row. An error in one file is caught and reported; the
   other files continue.

A file whose database already exists is skipped (`status = "skipped"`) unless
`overwrite = TRUE`; leftover `.partial` files are removed and redone. The
function returns the report as a `data.frame` and writes it to
`<outdir>/import_report.csv`; each database stores its own row in a table
`import_report`.

Report columns: `file`, `dbfile`, `status` (`ok` | `failed` | `skipped`),
`n_spectra`, `n_peaks`, `ms_levels`, `n_skipped`, `rt_min`, `rt_max`,
`mz_min`, `mz_max`, `n_centroid_unknown`, `n_unsorted_fixed`,
`n_peaks_removed`, `file_size`, `db_size`, `md5`, `seconds`, `warnings`,
`error`.

### 9.3 Export

```r
export(sps, backend = MsBackendLite(), file = "derived.sqlite",
       chunkPeaks = 1e6, pageSize = 32768L, overwrite = FALSE)
```

Works for a `Spectra` object with any backend. The processing queue is
executed while writing, so the new file contains the processed peaks and its
summary columns are valid for them. `metadata` records `processing_log`;
`source` gets one row describing the source. The source database is not
touched. Returns a `Spectra` object on the new file.

### 9.4 Merge

```r
mergeSQLiteDatabases(x, file, note = character(), overwrite = FALSE)
```

`x` is a character vector of database files (or the import report, from which
the `dbfile` column is used; rows with a status other than `ok` are an
error). Pure SQL; peak data does not pass through R.

Checks before writing: all files exist and are not `.partial`; same
`schema_version`; no raw file appears twice (compare `source.md5`); spectra
variables with the same name have the same `r_class`.

The destination `spectrum` table has the union of all input columns; missing
columns stay `NULL`. For each input, in order (tested):

```sql
ATTACH DATABASE 'file:B.sqlite?mode=ro' AS src;      -- read-only attach, outside a transaction

-- :peak_off = SELECT COALESCE(MAX(peak_id_), 0)     FROM main.peak
-- :spec_off = SELECT COALESCE(MAX(spectrum_id_), 0) FROM main.spectrum
BEGIN;
INSERT INTO main.peak (peak_id_, mz, intensity)
SELECT peak_id_ + :peak_off, mz, intensity FROM src.peak ORDER BY peak_id_;

INSERT INTO main.spectrum (spectrum_id_, peak_start, peak_count, <columns>,
                           source_id_, source_spectrum_id_)
SELECT spectrum_id_ + :spec_off, peak_start + :peak_off, peak_count, <columns>,
       :source_id, spectrum_id_
FROM src.spectrum ORDER BY spectrum_id_;
COMMIT;

DETACH DATABASE src;
```

`peak_count` is copied unchanged; `peak_start` and `peak_id_` are shifted by
the number of peaks already in the destination; `spectrum_id_` is shifted by
the number of spectra already there. One database is attached at a time, so
the SQLite limit of 10 attached databases does not matter.

Afterwards: indices, `ANALYZE`, one `source` row per input (path, md5,
counts, offsets), `metadata` with `kind = merge` and `note`, `.valid_db()`,
rename from `.partial`. Per-input counts in `source` must equal the counts in
each input. Input databases are kept.

`c()` on objects that point to different files stops and names
`mergeSQLiteDatabases()`.

## 10. Package

```
Package: MsBackendLite
Depends: R (>= 4.1.0), Spectra (>= 1.23.7)
Imports: methods, tools, utils, DBI, RSQLite, ProtGenerics, S4Vectors,
         IRanges, BiocParallel, MsCoreUtils
Suggests: testthat (>= 3.0.0), mzR, MsDataHub, knitr, rmarkdown, BiocStyle,
          roxygen2
License: Artistic-2.0
biocViews: Infrastructure, MassSpectrometry, Proteomics, Metabolomics, DataImport
```

Files:

```
R/hidden_aliases.R
R/MsBackendLite.R               class, validity, S4 methods
R/MsBackendLite-functions.R     .dbcon, .fetch_peaks, .fetch_spectra_data, .chunk_factor, ...
R/db-schema.R                   DDL, metadata, .valid_db
R/db-write.R                    .write_spectra_db, .peak_stats, export method
R/createMsBackendLiteDatabase.R
R/mergeSQLiteDatabases.R
tests/testthat.R, tests/testthat/test_*.R
vignettes/MsBackendLite.Rmd
```

Code style as in `Spectra`: S4, camelCase for exported names, internal
functions start with a dot, 4 spaces, lines up to 80 characters, `stop()` /
`stopifnot()` for checks, `message()` for progress, roxygen2 with markdown
(`#'`), methods of one topic documented on one page.

Exported: `MsBackendLite()`, `createMsBackendLiteDatabase()`,
`mergeSQLiteDatabases()`, and the S4 methods of section 5.2.

Functions return structured results (the import report is a `data.frame`),
take every decision as an argument (no interactive prompts) and signal errors
with informative messages. This keeps the package usable from a GUI or an
agent later.

## 11. Testing

1. **Synthetic data, no external files.** A helper builds a small `Spectra`
   object in memory with: spectra of very different lengths, empty spectra
   (first, middle, last), several MS levels, `NA` precursor values, a logical
   and a character variable, unsorted m/z in one spectrum. Written with
   `export()` to a temporary file. This covers almost everything and runs in
   seconds without `mzR`.
2. **Reference comparison.** For the same data, every accessor and filter
   gives the same result as `MsBackendMemory`.
3. **`Spectra` compliance suite.** As in `MsBackendSql/tests/testthat.R`:

   ```r
   be <- <initialized MsBackendLite>
   test_suite <- system.file("test_backends", "test_MsBackend", package = "Spectra")
   test_dir(test_suite, stop_on_failure = TRUE)
   ```

   Run it on the full backend and on a shuffled subset with duplicates. The
   suite compares filters against `getMethod("filterX", "MsBackend")`.
4. **State and reversibility.** After any sequence of filters and processing
   the database file is byte-identical (md5); `reset()` restores the opening
   state; statistics follow section 8.1.
5. **Serialization.** `saveRDS()` / `readRDS()` round trip; object used in a
   `SnowParam(2)` worker.
6. **Writer and merge.** `.valid_db()` passes; merged data equals the
   concatenated inputs; all error paths (existing file, profile data,
   duplicate source, class conflict) leave no `.partial` file.
7. **Real mzML** (`skip_if_not_installed("mzR")`, `MsDataHub`): import and
   compare every spectrum with `MsBackendMzR`. Runs in CI.

Tests use `SerialParam()` or at most two workers.

Performance and memory measurements are done with `MsBench`, outside this
repository. Acceptance targets: streaming throughput, single-spectrum
latency, and R memory that stays near the chunk budget on a database larger
than RAM.

## 12. Later versions

In rough order. Each item was discussed and must not be lost.

1. **SQL `WHERE` for hot spectrum-level filters** (`filterRt`,
   `filterMsLevel`, `filterPrecursorMzRange`, `filterPrecursorMzValues`).
   Each override must give the same result as the default method and must
   fall back to the default when the variable was changed in the cache
   (`.has_local_variable()` in `MsBackendSql`). Do it only where `MsBench`
   shows a gain.
2. **Stateless SQL queries on peaks**: extract an ion chromatogram, find
   spectra that contain an m/z. They return results and do not change the
   object. They query the stored peaks of the selected spectra and stop when
   the processing queue is not empty unless `raw = TRUE`. With them comes the
   optional index `CREATE INDEX idx_peak_mz ON peak (mz, intensity)` as a
   writer argument (`mzIndex = FALSE` by default; about 60–70 % more disk).
3. **A guard for accumulated reads** at `Spectra` level (section 7.3). One
   idea: a `split()` method that gives the chunks of one operation a shared
   counter and checks the growth of the R heap with `gc()` once more peaks
   than the limit were delivered. It needs care for chunk objects that
   outlive the operation.
4. **`chunkFUN` for `export()`**: for each chunk, convert to
   `MsBackendMemory`, apply a user function (for example `peaksData<-`),
   append to the new file. Memory stays bounded by the chunk. Add when a real
   use case appears.
5. **Undo of the last step** (history of the three state layers).
6. **Persistent SQL peak filter in the backend** (`filterPeaksSql()`): only if
   measurements show the need. Rules: only on an empty processing queue; all
   peak reads through one function; peak-by-peak comparison with the
   `Spectra` filter; objects with different filters cannot be merged.
7. Parallel reading (`backendBpparam()` returning the user's choice).
8. `page_size` benchmark (16/32/64 KB); read-only view over several database
   files without merging; `addIndex()` for derived databases only; disk space
   check before merge; import from mzPeak through `MsBackendMzPeak` (works
   through `export()` without new code).
9. A guided interface for users without programming experience (separate
   package).

## 13. What went wrong in the 2021 attempt (`plantton/MsBackendSql`)

| Then | Now |
|---|---|
| Wide tables with a fixed number of peak columns per MS level | One row per peak, any length, any MS level |
| Peak filters wrote a mask into the database, so all objects on that file changed together and `reset()` reset all of them | Nothing is written; state lives in each object |
| Filter methods defined on the backend that `Spectra` never calls for peak filters | Peak filters are the `Spectra` functions |
| One query per spectrum | One query per call, ranges merged |
| `ALTER TABLE` on the source database for new variables | `MsBackendCached` local data |
| A live query result stored in a slot | Only the file path and plain vectors; connection cached in an environment and rebuilt on demand |

## 14. Feasibility numbers

Measured with plain DBI calls on a cloud VM, not with the package and not on
the target laptop. They show the approach works; they are not benchmarks.

- 17.4 million peaks in 40 000 spectra (10 % with 3 000 peaks, 90 % with
  150): file 362 MB, 20.8 bytes per peak with integer-valued intensities
  (expect up to about 26 with fractional intensities).
- Summing intensities per spectrum over all 17.4 million peaks in chunks of
  one million: 5.3 s, R memory peak about 180 MB.
- One chunk of one million peaks, read and split into 2 300 matrices: 0.3 s.
- 18 000 separate ranges (2.7 million peaks) in one parameterised query:
  0.8 s. One spectrum: 0.4 ms.
- `spectrum` table with one million rows and seven columns: 51 MB.

## 15. Open points

- Section 7.3: accumulated reads at `Spectra` level are not guarded.
- `lengths(sps)` on a large object reads all peaks even without a processing
  queue, because `Spectra` only asks the backend when no chunking is active.
  `sps$peaksCount` is the instant alternative. Document it.
- Which `MsDataHub` files are centroided, profile or mixed has not been
  checked. Before writing import tests run
  `table(msLevel(sps), centroided(sps))` on the candidate files; the TMT
  Erwinia file is expected to be mixed and the Sciex files profile.
- Read-only `ATTACH` with a `file:` URI worked with RSQLite 2.3.4; confirm
  with the installed version, otherwise attach normally.
- `dataOrigin` is stored as text in every row. Fine for now; a lookup table
  would save space in merged databases.
- Repository location is assumed to be `plantton/MsBackendLite`.
