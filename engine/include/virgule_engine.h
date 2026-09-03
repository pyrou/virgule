#ifndef VIRGULE_ENGINE_H
#define VIRGULE_ENGINE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct VirguleEngine VirguleEngine;

/// Allocates an opaque engine handle. Returns NULL if allocation fails.
VirguleEngine *virgule_engine_create(void);

/// Releases an engine created by virgule_engine_create. NULL is accepted.
void virgule_engine_destroy(VirguleEngine *engine);

typedef enum VirguleImportEventKind {
    VIRGULE_IMPORT_STARTED = 0,
    VIRGULE_IMPORT_PREVIEW = 1,
    VIRGULE_IMPORT_PROGRESS = 2,
    VIRGULE_IMPORT_COMPLETED = 3,
    VIRGULE_IMPORT_ERROR = 4,
    VIRGULE_IMPORT_HEADERS = 5,
} VirguleImportEventKind;

/// Borrowed UTF-8 values. Every pointer is valid only while the callback runs.
typedef struct VirguleImportEvent {
    uint32_t kind;
    size_t row;
    size_t imported_rows;
    uint64_t total_bytes;
    const char * const *values;
    size_t value_count;
    const char *message;
} VirguleImportEvent;

typedef void (*VirguleImportCallback)(const VirguleImportEvent *event, void *context);

/// Imports source_path synchronously into cache_directory. The UTF-8 paths and
/// callback are borrowed for this call only. Operational failures are emitted as
/// VIRGULE_IMPORT_ERROR.
/// Returns 0 for a valid call and -1 for invalid arguments.
int32_t virgule_engine_import_csv(
    VirguleEngine *engine,
    const char *source_path,
    const char *cache_directory,
    VirguleImportCallback callback,
    void *context
);

/// One borrowed CSV result row. The values and message pointers are valid only
/// while the page callback runs. `result_row` is the zero-based row index in
/// the current result, while `source_row` is the stable SQLite rowid.
typedef struct VirgulePageRow {
    size_t result_row;
    int64_t source_row;
    const char * const *values;
    size_t value_count;
    const char *message;
} VirgulePageRow;

typedef void (*VirgulePageCallback)(const VirgulePageRow *row, void *context);

/// Reads one bounded page from a completed local cache. The source CSV is
/// never opened or modified. On an operational error, the callback receives a
/// row with result_row set to SIZE_MAX and a descriptive message.
/// Returns 0 for a valid call and -1 for invalid arguments.
int32_t virgule_engine_read_csv_page(
    VirguleEngine *engine,
    const char *cache_path,
    size_t offset,
    size_t limit,
    VirgulePageCallback callback,
    void *context
);

/// Metadata for a validated query. `values` contains column names and
/// `imported_rows` is the total result count. Errors use `message`.
int32_t virgule_engine_describe_query(
    VirguleEngine *engine, const char *cache_path, const char *sql,
    VirguleImportCallback callback, void *context
);

/// Checks editor SQL without executing it. A VIRGULE_IMPORT_HEADERS callback
/// means valid; errors use `message`, including line and column when available.
int32_t virgule_engine_validate_query(
    VirguleEngine *engine, const char *cache_path, const char *sql,
    VirguleImportCallback callback, void *context
);

/// Reads one bounded page of a validated SQL result. Result row numbers refer
/// to the current view, not necessarily the source CSV order.
int32_t virgule_engine_read_query_page(
    VirguleEngine *engine, const char *cache_path, const char *sql,
    size_t offset, size_t limit, VirgulePageCallback callback, void *context
);

#ifdef __cplusplus
}
#endif

#endif /* VIRGULE_ENGINE_H */
