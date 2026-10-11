# Virgule

**Your CSV files. The power of SQL. A native Mac experience.**

Virgule is a native macOS CSV explorer powered by Swift, Rust, and SQLite. Browse large datasets, search and sort rows, or write SQL to filter, aggregate, and calculate—all without modifying your original files.

> **Early development · Build from source.** Prebuilt releases will be available later. For now, compile and run Virgule yourself with Xcode. See [Getting started](#getting-started) below.

## What you can do

- Open CSV and TSV files through the file picker or drag and drop, with an early preview while import runs in the background.
- Explore a virtualized native grid with pinned headers, resizable columns, and pages loaded on demand.
- Query your data with a multiline SQL editor, syntax highlighting, contextual completion, validation, formatting, and query history.
- Sort by one or more columns, search the dataset or a single column with text or regular expressions, and copy selected rows as TSV.
- Export the current view to a new CSV file.

Virgule is under active development. Dedicated filter controls, cell/range selection, row annotations, and saved bookmarks are still planned. See [`docs/ROADMAP.md`](docs/ROADMAP.md) for progress and acceptance criteria.

## SQL for any CSV

Every imported file becomes a local SQLite table. Use `$file` to refer to the currently opened CSV, regardless of its filename:

```sql
SELECT *
FROM $file
ORDER BY $row_id
```

`$row_id` is the stable source row identifier. You can use SQLite expressions, aggregates, and calculated columns to explore your data. For example, if your CSV contains `category` and `amount` columns:

```sql
SELECT category, SUM(amount) AS total
FROM $file
GROUP BY category
ORDER BY total DESC
```

Press **Command-Return** to execute a query. The editor shows the SQL behind the current view, including sorting and search operations. Only read-only `SELECT`, `WITH`, and `EXPLAIN` queries are accepted; statements that can modify the database are rejected.

## Your source files stay untouched

Rust streams the CSV into an application-managed SQLite cache in the macOS cache directory. Queries run against that local cache, and the grid loads only the result pages it needs. Virgule never writes to the source CSV or stores its cache next to it. Export creates a separate CSV file.

The interface uses AppKit and Swift, with a Rust engine connected through a C API. No embedded browser or WebView.

## Supported CSV formats

- Comma, semicolon, tab, and pipe delimiters, with detection and manual override.
- Quoted fields, escaped quotes, and delimiters or line breaks inside fields.
- UTF-8, UTF-16, and Windows-1252, with detection and manual selection.
- Files with or without headers.
- Conservative inference of text, integer, decimal, boolean, date/datetime, and null values. Ambiguous values are preserved as text.

## Getting started

### Requirements

- An Apple Silicon Mac running **macOS 26 or later**.
- **Xcode 26 or later**, including the macOS SDK and command-line tools.
- **Rust 1.85 or later**, installed through [rustup](https://rustup.rs/). The build expects Cargo in `~/.cargo/bin`.

### Build and run with Xcode

There is no prebuilt download yet. To run the app:

1. Clone the repository:

   ```sh
   git clone https://github.com/pyrou/virgule.git
   cd virgule
   ```

2. Open [`virgule.xcodeproj`](virgule.xcodeproj) in Xcode.
3. Select the **virgule** scheme and **My Mac** destination.
4. Choose **Product → Run** (**Command-R**).
5. Open a CSV or TSV file, or drop one onto the window.

Xcode runs [`scripts/build-rust-engine.sh`](scripts/build-rust-engine.sh) before compiling Swift. It builds and links the Rust static library automatically; you do not need to build the engine separately. The first build needs network access to download Rust dependencies.

## Tests

Run the Swift/AppKit tests in Xcode with **Product → Test** (**Command-U**).

Run the Rust engine tests independently with:

```sh
cargo test --manifest-path engine/Cargo.toml
```

The AppKit test `gridVirtualizesOneMillionRowsWhileScrolling` exercises a synthetic one-million-row, 24-column grid and checks that rendered views remain bounded by the viewport. This checks grid virtualization; broader end-to-end performance measurements remain on the roadmap.

## Scope

Virgule focuses on exploring CSV data through a native interface and SQL. Cell editing, spreadsheet formulas, and source-file rewriting are outside its scope.
