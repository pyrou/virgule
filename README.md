# Virgule

A local, native CSV explorer for macOS — **"TablePlus for CSV files."**

Virgule lets people explore, filter, sort, and query very large CSV files without ever modifying the source file. Changes are reversible SQL views, stored locally alongside bookmarks and annotations.

> **Status: project foundation.** The compilable app will be built iteratively; follow [`docs/ROADMAP.md`](docs/ROADMAP.md).

## Product principles

- macOS 26+ and Apple Silicon only;
- a fully native application: AppKit + Swift for the UI, Rust for the engine;
- no embedded browser, WebView, or JavaScript;
- source CSV files are strictly read-only;
- no cell editing, formulas, or spreadsheet features;
- asynchronous processing: the UI thread never runs an import or an expensive query;
- smooth interaction with one-million-row files is the top priority.

## Target architecture

```text
AppKit (Swift)
  ├── Sidebar / query bar / inspector
  └── Virtualized NSView grid
           │ FFI (stable C API)
           ▼
Rust engine
  ├── Encoding and delimiter detection
  ├── Streaming CSV parser and type inference
  ├── Transactional SQLite import (prepared statements)
  ├── Read-only SQL validation
  └── Pagination, search, and metadata
           │
           ▼
Local temporary cache for each source file (SQLite)
```

Rust reads the CSV as a stream and imports it into a cached SQLite database in Virgule’s macOS cache directory; it never writes next to or modifies the source file. The grid receives only result pages, so it never creates cells for off-screen rows. The imported table is named `csv`.

The query bar always displays the exact SQL behind the current view. Sort and filter actions produce readable SQL. Only `SELECT`, `WITH`, and `EXPLAIN` queries are allowed; any statement that can modify SQLite is rejected.

## Supported CSV behavior

- detected delimiters: comma, semicolon, tab, and pipe — with manual override;
- quoted fields, escaped quotes, delimiters, and line breaks inside fields;
- UTF-8, UTF-16, and Windows-1252, with detection and manual choice;
- optional headers;
- conservative inference of text, integer, decimal, boolean, date/datetime, and null.

When inference is ambiguous, the raw text is preserved.

## Planned iterations

1. Documentation and repository foundation (this iteration).
2. Compilable Swift/Rust workspace and minimal FFI.
3. Streaming parser, SQLite import, and correctness tests.
4. AppKit window, file opening, and preview.
5. Paginated, virtualized grid.
6. SQL query bar and view operations.
7. Search, selection/copy, bookmarks, and annotations.
8. Performance measurement and MVP hardening.

The detailed acceptance criteria live in [`docs/ROADMAP.md`](docs/ROADMAP.md).

## Prerequisites

- Apple Silicon Mac running macOS 26 or later;
- Xcode 26 or later, including the macOS SDK and command-line tools;
- Rust 1.85 or later, installed through [rustup](https://rustup.rs/).

## Build and test

Open [`virgule.xcodeproj`](virgule.xcodeproj) in Xcode and run the `virgule`
scheme, or build the debug application from the command line:

```sh
xcodebuild -project virgule.xcodeproj -scheme virgule \\
  -configuration Debug -destination 'platform=macOS,arch=arm64' \\
  CODE_SIGNING_ALLOWED=NO build
```

Xcode invokes `scripts/build-rust-engine.sh` before compiling Swift. The script
builds the static Rust library for the selected configuration and links it into
the app.

Run the Rust engine tests independently with:

```sh
cargo test --manifest-path engine/Cargo.toml
```

### One-million-row scrolling check

The `gridVirtualizesOneMillionRowsWhileScrolling` AppKit test uses a
one-million-row, 24-column data source and scrolls across it in 25,000-row
increments. It verifies that the rendered row and cell counts remain bounded
by the viewport (fewer than 100 rows and 1,000 cells), and that the complete
scroll sweep finishes within one second. Run it with:

```sh
xcodebuild -project virgule.xcodeproj -scheme virgule \\
  -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO test
```

The AppKit window provides a toolbar button and a central button for selecting
a CSV or TSV file. It also accepts CSV and TSV files dropped onto the window.
During an import, its early rows are rendered in a native virtualized grid:
only row and cell views in the current viewport are created, then recycled as
the user scrolls. SQLite-backed page loading follows in the next grid slice.

## Non-goals

- rewriting or automatically saving the source CSV;
- spreadsheets, cell formatting, or formulas;
- loading the complete dataset into UI memory.

An explicit export of a view to a new CSV may be added later.
