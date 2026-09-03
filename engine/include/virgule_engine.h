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

/// Imports source_path synchronously. The UTF-8 path and callback are borrowed
/// for this call only. Operational failures are emitted as VIRGULE_IMPORT_ERROR.
/// Returns 0 for a valid call and -1 for invalid arguments.
int32_t virgule_engine_import_csv(
    VirguleEngine *engine,
    const char *source_path,
    VirguleImportCallback callback,
    void *context
);

#ifdef __cplusplus
}
#endif

#endif /* VIRGULE_ENGINE_H */
