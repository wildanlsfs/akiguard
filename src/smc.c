// AkiGuard — akses minimal ke Apple SMC lewat IOKit.
// Struktur data mengikuti antarmuka AppleSMC yang dipakai smcFanControl/SMCKit.
#include "smc.h"
#include <IOKit/IOKitLib.h>
#include <string.h>

#define KERNEL_INDEX_SMC      2
#define SMC_CMD_READ_BYTES    5
#define SMC_CMD_WRITE_BYTES   6
#define SMC_CMD_READ_KEYINFO  9

typedef struct {
    char     major;
    char     minor;
    char     build;
    char     reserved[1];
    uint16_t release;
} SMCVers;

typedef struct {
    uint16_t version;
    uint16_t length;
    uint32_t cpuPLimit;
    uint32_t gpuPLimit;
    uint32_t memPLimit;
} SMCPLimit;

typedef struct {
    uint32_t dataSize;
    uint32_t dataType;
    char     dataAttributes;
} SMCKeyInfo;

typedef struct {
    uint32_t   key;
    SMCVers    vers;
    SMCPLimit  pLimitData;
    SMCKeyInfo keyInfo;
    char       result;
    char       status;
    char       data8;
    uint32_t   data32;
    uint8_t    bytes[32];
} SMCKeyData;

static io_connect_t g_conn = 0;

static uint32_t key_to_u32(const char *k) {
    return ((uint32_t)(uint8_t)k[0] << 24) | ((uint32_t)(uint8_t)k[1] << 16) |
           ((uint32_t)(uint8_t)k[2] << 8)  |  (uint32_t)(uint8_t)k[3];
}

static int smc_call(SMCKeyData *in, SMCKeyData *out) {
    size_t outSize = sizeof(SMCKeyData);
    kern_return_t r = IOConnectCallStructMethod(g_conn, KERNEL_INDEX_SMC,
                                                in, sizeof(SMCKeyData), out, &outSize);
    if (r != KERN_SUCCESS) return -1;
    if (out->result != 0) return -(int)(uint8_t)out->result;   // 132 = key tidak ada
    return 0;
}

int smc_open(void) {
    if (g_conn) return 0;
    io_service_t svc = IOServiceGetMatchingService(MACH_PORT_NULL, IOServiceMatching("AppleSMC"));
    if (!svc) return -1;
    kern_return_t r = IOServiceOpen(svc, mach_task_self(), 0, &g_conn);
    IOObjectRelease(svc);
    if (r != KERN_SUCCESS) { g_conn = 0; return -2; }
    return 0;
}

void smc_close(void) {
    if (g_conn) { IOServiceClose(g_conn); g_conn = 0; }
}

static int key_info(const char *key, SMCKeyInfo *info) {
    if (!key || strlen(key) != 4) return -3;
    SMCKeyData in, out;
    memset(&in, 0, sizeof in); memset(&out, 0, sizeof out);
    in.key = key_to_u32(key);
    in.data8 = SMC_CMD_READ_KEYINFO;
    int r = smc_call(&in, &out);
    if (r) return r;
    *info = out.keyInfo;
    return 0;
}

int smc_key_size(const char *key, uint32_t *size) {
    SMCKeyInfo info;
    int r = key_info(key, &info);
    if (r) return r;
    *size = info.dataSize;
    return 0;
}

int smc_read(const char *key, uint8_t *buf, uint32_t *size) {
    SMCKeyInfo info;
    int r = key_info(key, &info);
    if (r) return r;
    SMCKeyData in, out;
    memset(&in, 0, sizeof in); memset(&out, 0, sizeof out);
    in.key = key_to_u32(key);
    in.keyInfo.dataSize = info.dataSize;
    in.data8 = SMC_CMD_READ_BYTES;
    r = smc_call(&in, &out);
    if (r) return r;
    uint32_t n = info.dataSize > 32 ? 32 : info.dataSize;
    memcpy(buf, out.bytes, n);
    *size = n;
    return 0;
}

int smc_write(const char *key, const uint8_t *buf, uint32_t size) {
    SMCKeyInfo info;
    int r = key_info(key, &info);
    if (r) return r;
    if (info.dataSize != size || size > 32) return -4;   // ukuran harus persis sama
    SMCKeyData in, out;
    memset(&in, 0, sizeof in); memset(&out, 0, sizeof out);
    in.key = key_to_u32(key);
    in.data8 = SMC_CMD_WRITE_BYTES;
    in.keyInfo.dataSize = size;
    memcpy(in.bytes, buf, size);
    return smc_call(&in, &out);
}
