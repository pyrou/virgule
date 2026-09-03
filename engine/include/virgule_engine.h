#ifndef VIRGULE_ENGINE_H
#define VIRGULE_ENGINE_H

#ifdef __cplusplus
extern "C" {
#endif

typedef struct VirguleEngine VirguleEngine;

/// Allocates an opaque engine handle. Returns NULL if allocation fails.
VirguleEngine *virgule_engine_create(void);

/// Releases an engine created by virgule_engine_create. NULL is accepted.
void virgule_engine_destroy(VirguleEngine *engine);

#ifdef __cplusplus
}
#endif

#endif /* VIRGULE_ENGINE_H */
