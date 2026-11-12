# MsBackendLite

A read-only SQLite backend for the Bioconductor
[Spectra](https://github.com/rformassspectrometry/Spectra) package.

- m/z and intensity values are stored as plain numeric columns, one row per
  peak, so they can be queried with SQL and read without decoding.
- Peaks are read in chunks sized by number of peaks, so data larger than
  memory can be analysed on an ordinary computer.
- Nothing a user does to a `Spectra` object changes the database; every filter
  can be undone with `reset()`.

**Status:** early development. The package does not do anything yet.

## Installation

The package follows the `main` branch of `Spectra` (version 1.23.7 or newer).

```r
install.packages("BiocManager")
BiocManager::install("rformassspectrometry/Spectra")
BiocManager::install("plantton/MsBackendLite")
```

## License

Artistic-2.0
