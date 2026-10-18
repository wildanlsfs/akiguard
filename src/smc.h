// AkiGuard — akses minimal ke Apple SMC (System Management Controller)
#pragma once
#include <stdint.h>

int  smc_open(void);
void smc_close(void);
// Semua fungsi mengembalikan 0 jika sukses, negatif jika gagal.
// -132 (0x84) biasanya berarti key tidak ada di Mac ini.
int  smc_key_size(const char *key, uint32_t *size);
int  smc_read(const char *key, uint8_t *buf, uint32_t *size);
int  smc_write(const char *key, const uint8_t *buf, uint32_t size);
