# Virgule roadmap

This checklist is the source of truth for scope. Check an item only after it has been verified in a compiling commit, except for documentation-only tasks that do not produce a binary.

## Iteration rules

- [ ] Every step ends with an atomic commit.
- [ ] Every application commit compiles on Apple Silicon running macOS 26+.
- [ ] Every feature has a reproducible verification method (test, command, or documented procedure).
- [ ] The source CSV is never opened for writing.
- [ ] Heavy processing never blocks the AppKit main thread.

## 0. Foundation — in progress

- [x] Initialize the Git repository.
- [x] Document the product vision, constraints, and target architecture.
- [x] Create this detailed roadmap.
- [x] Create the initial documentation commit.
- [x] Add contributor workflow guidance in `AGENTS.md`.

## 1. Compilable workspace

- [x] Create the arm64 macOS 26+ AppKit Xcode project.
- [x] Create the Rust engine crate and an Xcode-integrated build script.
- [x] Define a small, safe C FFI API to create and destroy the engine.
- [x] Add the Rust test target.
- [x] Document prerequisites and build/test commands.
- [x] Verify a Debug build of the application.

## 2. Reliable CSV ingestion

- [x] Detect comma, semicolon, tab, and pipe delimiters.
- [x] Allow manual delimiter override.
- [x] Read UTF-8, UTF-16, and Windows-1252; expose manual selection.
- [x] Support files with and without headers.
- [x] Stream-parse quoted fields containing delimiters.
- [x] Stream-parse quoted fields containing line breaks.
- [x] Support escaped quotes.
- [x] Infer null, boolean, integer, decimal, date/datetime, and text.
- [x] Preserve text when inference is ambiguous.
- [x] Write the required Rust unit tests for a quoted comma and a quoted line break.

## 3. SQLite cache and query engine

- [x] Create an application-managed local SQLite cache associated with the source file.
- [x] Import in one transaction using prepared statements.
- [x] Create the `csv` table and retain column metadata.
- [x] Expose progress, early preview, completion, and errors through FFI.
- [x] Paginate results without materializing them in the UI.
- [x] Validate read-only `SELECT`, `WITH`, and `EXPLAIN` queries.
- [x] Reject `INSERT`, `UPDATE`, `DELETE`, `DROP`, `ATTACH`, and other writes.
- [x] Add SQL-validation and pagination tests.

## 4. AppKit application and file opening

- [x] Create a native macOS window with a toolbar.
- [x] Add a CSV file picker.
- [x] Add CSV drag and drop.
- [x] Run imports off the main thread.
- [x] Show the first rows while the import continues.
- [x] Clearly display “Read-only — the source file is not modified.”
- [x] Display progress and actionable errors.

## 5. Virtualized grid

- [x] Implement a native, virtualized AppKit grid.
- [x] Keep the header pinned.
- [x] Keep row numbers stable.
- [x] Make columns resizable.
- [x] Load SQLite pages on demand while scrolling.
- [ ] Reuse visible row/cell views.
- [ ] Verify that no cells are created for off-screen rows.
- [ ] Measure scrolling with a one-million-row dataset.

## 6. SQL query bar

- [ ] Always display the active SQL above the grid.
- [ ] Support multi-line editing and execution with Command-Return.
- [ ] Immediately reflect valid user SQL in the grid.
- [ ] Update readable SQL from sort and filter actions.
- [ ] Add syntax highlighting, indentation, and pretty printing.
- [ ] Add validation while typing with line/column errors.
- [ ] Add contextual completion for keywords, tables, columns, and functions.
- [ ] Add function/operator quick help, undo/redo, history, and copy.
- [ ] Support SQL calculated columns in the view.

## 7. Data interactions

- [ ] Add Command-F search (whole dataset or a column; text/regex).
- [ ] Add single/multi-column sorting with Shift-click.
- [ ] Add text, empty/non-empty, numeric, and date filters.
- [ ] Add cell, range, row, column, and Command multi-selection.
- [ ] Copy the selection as TSV with Command-C.
- [ ] Add local colored row annotations.
- [ ] Add a file, bookmark, and schema sidebar.
- [ ] Add an optional inspector (type, nulls, distinct values).

## 8. MVP persistence and quality

- [ ] Save/restore bookmarks: name, SQL, visible columns, sizes, sorting/filters, annotations, and view state.
- [ ] Add explicit export of a view to a new CSV (if retained).
- [ ] Add a local one-million-row dataset generator.
- [ ] Measure import, search, sorting, and scrolling with a documented procedure.
- [ ] Define performance targets and run them on Apple Silicon.
- [ ] Verify accessibility, macOS shortcuts, and error states.
- [ ] Verify that the source CSV is never written.
- [ ] Build and test the MVP before any visual polish.
