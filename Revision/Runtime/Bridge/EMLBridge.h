#ifndef EML_BRIDGE_H
#define EML_BRIDGE_H
#include <stddef.h>
#include <stdint.h>

// Both buffers are malloc-owned. Python exceptions cross this boundary as UTF-8 text.
int EMLCompile(const char *bundle, const uint8_t *source, size_t sourceSize, int strict,
               uint8_t **output, size_t *outputSize, char **error);
void EMLRelease(void *buffer);
#endif
