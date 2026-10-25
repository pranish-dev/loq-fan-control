#ifndef CSENSORS_H
#define CSENSORS_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// Reads AppleSMC keys (e.g. TC0P for CPU package temperature).
// Returns 0 on success.
int omen_smc_read(const char *key, double *value);

// Queries NVIDIA RM thermal sensors directly through com.nullmoth.NVRM user client.
// Returns 0 on success.
int omen_nvidia_temperature(double *value, char *message, size_t capacity);

#ifdef __cplusplus
}
#endif

#endif /* CSENSORS_H */
