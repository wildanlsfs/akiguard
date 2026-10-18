// AkiGuard — pengatur charging/discharging MacBook (alternatif AlDente buatan sendiri).
//
//   akiguard daemon          jalan sebagai root lewat launchd (dipasang install.sh)
//   akiguard status          tampilkan baterai, kunci SMC yang tersedia, status daemon
//   akiguard keys            cek kunci SMC yang didukung Mac ini
//   akiguard reset           (root) kembalikan semua ke normal: charging on, adaptor on, BCLM 100
//   akiguard read KEY        (root) baca kunci SMC mentah, mis. akiguard read BCLM
//   akiguard write KEY HEX   (root) tulis kunci SMC mentah, mis. akiguard write CH0B 02
//
// Konfigurasi: /Library/Application Support/AkiGuard/akiguard.conf (diubah oleh menu bar app)

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/IOMessage.h>
#include <IOKit/pwr_mgt/IOPMLib.h>
#include <IOKit/ps/IOPowerSources.h>
#include <IOKit/ps/IOPSKeys.h>
#include <dispatch/dispatch.h>
#include <ctype.h>
#include <errno.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#include "smc.h"

#define CONF_DIR    "/Library/Application Support/AkiGuard"
#define CONF_PATH   CONF_DIR "/akiguard.conf"
#define STATUS_PATH CONF_DIR "/status"
#define TICK_SEC    15
#define MAX_SCHED   16
#define SAFETY_PCT  10      // di bawah ini adaptor & charging selalu dinyalakan

/* ------------------------------------------------------------------ util */

static void logmsg(const char *fmt, ...) {
    char ts[32];
    time_t t = time(NULL);
    strftime(ts, sizeof ts, "%Y-%m-%d %H:%M:%S", localtime(&t));
    printf("[%s] ", ts);
    va_list ap; va_start(ap, fmt); vprintf(fmt, ap); va_end(ap);
    printf("\n");
    fflush(stdout);
}

static char *trim(char *s) {
    while (isspace((unsigned char)*s)) s++;
    char *e = s + strlen(s);
    while (e > s && isspace((unsigned char)e[-1])) *--e = 0;
    return s;
}

static int clampi(int v, int lo, int hi) { return v < lo ? lo : v > hi ? hi : v; }

/* ------------------------------------------------------------ kunci SMC */

typedef struct { const char *name; uint32_t size; int present; } smckey;

// Intel: BCLM (batas charge oleh firmware), CH0B/CH0C (tahan charging), CH0I (matikan adaptor)
// Apple Silicon (firmware baru): CHTE (tahan charging), CHIE (matikan adaptor)
static smckey K_BCLM = {"BCLM"}, K_CH0B = {"CH0B"}, K_CH0C = {"CH0C"}, K_CHTE = {"CHTE"};
static smckey K_CH0I = {"CH0I"}, K_CHIE = {"CHIE"};
static smckey *ALLKEYS[] = {&K_BCLM, &K_CH0B, &K_CH0C, &K_CHTE, &K_CH0I, &K_CHIE};
#define NKEYS (int)(sizeof ALLKEYS / sizeof ALLKEYS[0])

static void probe_keys(void) {
    for (int i = 0; i < NKEYS; i++) {
        uint32_t sz = 0;
        ALLKEYS[i]->present = (smc_key_size(ALLKEYS[i]->name, &sz) == 0 && sz > 0);
        ALLKEYS[i]->size = sz;
    }
}

static int write_byte(smckey *k, uint8_t v) {
    if (!k->present || k->size == 0 || k->size > 32) return 0;
    uint8_t buf[32] = {0};
    buf[0] = v;
    int r = smc_write(k->name, buf, k->size);
    if (r) logmsg("gagal menulis %s (kode %d)", k->name, r);
    return r == 0;
}

static int can_inhibit(void)  { return K_CH0B.present || K_CH0C.present || K_CHTE.present; }
static int can_discharge(void){ return K_CH0I.present || K_CHIE.present; }

static void hw_set_charging(int allow) {
    write_byte(&K_CH0B, allow ? 0x00 : 0x02);
    write_byte(&K_CH0C, allow ? 0x00 : 0x02);
    write_byte(&K_CHTE, allow ? 0x00 : 0x01);
}

static void hw_set_adapter(int on) {
    write_byte(&K_CH0I, on ? 0x00 : 0x01);
    write_byte(&K_CHIE, on ? 0x00 : 0x08);
}

static void hw_set_bclm(int pct) {
    write_byte(&K_BCLM, (uint8_t)clampi(pct, 20, 100));
}

/* -------------------------------------------------------------- baterai */

typedef struct { int ok, pct, ac, charging; } ag_battery_t;

static int cfnum(CFDictionaryRef d, CFStringRef key) {
    int v = -1;
    CFNumberRef n = CFDictionaryGetValue(d, key);
    if (n && CFGetTypeID(n) == CFNumberGetTypeID()) CFNumberGetValue(n, kCFNumberIntType, &v);
    return v;
}

static ag_battery_t read_battery(void) {
    ag_battery_t b = {0, -1, 0, 0};
    CFTypeRef info = IOPSCopyPowerSourcesInfo();
    if (!info) return b;
    CFArrayRef list = IOPSCopyPowerSourcesList(info);
    if (list) {
        for (CFIndex i = 0; i < CFArrayGetCount(list); i++) {
            CFDictionaryRef d = IOPSGetPowerSourceDescription(info, CFArrayGetValueAtIndex(list, i));
            if (!d) continue;
            CFStringRef type = CFDictionaryGetValue(d, CFSTR(kIOPSTypeKey));
            if (!type || CFStringCompare(type, CFSTR(kIOPSInternalBatteryType), 0) != kCFCompareEqualTo)
                continue;
            int cur = cfnum(d, CFSTR(kIOPSCurrentCapacityKey));
            int max = cfnum(d, CFSTR(kIOPSMaxCapacityKey));
            if (cur >= 0 && max > 0) { b.pct = cur * 100 / max; b.ok = 1; }
            CFStringRef st = CFDictionaryGetValue(d, CFSTR(kIOPSPowerSourceStateKey));
            b.ac = st && CFStringCompare(st, CFSTR(kIOPSACPowerValue), 0) == kCFCompareEqualTo;
            CFBooleanRef ch = CFDictionaryGetValue(d, CFSTR(kIOPSIsChargingKey));
            b.charging = ch && CFBooleanGetValue(ch);
            break;
        }
        CFRelease(list);
    }
    CFRelease(info);
    return b;
}

/* ------------------------------------------------------------ konfigurasi */

typedef enum { M_OFF = 0, M_LIMIT, M_DISCHARGE, M_FULL } agmode;
static const char *MODE_NAME[] = {"off", "limit", "discharge", "full"};

typedef struct { int start, end, days; agmode mode; int value; } ag_sched_t;   // days: bit0=Sen ... bit6=Min

typedef struct {
    agmode mode;
    int limit, sail, auto_dis, discharge_to;
    agmode ovr; long ovr_until;
    ag_sched_t sched[MAX_SCHED]; int nsched;
} ag_conf_t;

static int parse_mode(const char *s, agmode *m) {
    for (int i = 0; i < 4; i++) if (strcasecmp(s, MODE_NAME[i]) == 0) { *m = (agmode)i; return 1; }
    return 0;
}

static int parse_days(const char *s) {
    if (strcmp(s, "*") == 0) return 0x7f;
    int mask = 0;
    for (; *s; s++) if (*s >= '1' && *s <= '7') mask |= 1 << (*s - '1');
    return mask;
}

static void conf_defaults(ag_conf_t *c) {
    memset(c, 0, sizeof *c);
    c->mode = M_LIMIT; c->limit = 80; c->sail = 5; c->auto_dis = 0; c->discharge_to = 50;
    c->ovr = M_OFF; c->ovr_until = 0;
}

static void load_conf(ag_conf_t *c) {
    conf_defaults(c);
    FILE *f = fopen(CONF_PATH, "r");
    if (!f) return;
    char line[256];
    while (fgets(line, sizeof line, f)) {
        char *s = trim(line);
        if (!*s || *s == '#') continue;
        char *eq = strchr(s, '=');
        if (!eq) continue;
        *eq = 0;
        char *k = trim(s), *v = trim(eq + 1);
        if      (!strcmp(k, "mode"))           parse_mode(v, &c->mode);
        else if (!strcmp(k, "limit"))          c->limit = clampi(atoi(v), 20, 100);
        else if (!strcmp(k, "sail"))           c->sail = clampi(atoi(v), 1, 20);
        else if (!strcmp(k, "auto_discharge")) c->auto_dis = atoi(v) != 0;
        else if (!strcmp(k, "discharge_to"))   c->discharge_to = clampi(atoi(v), 20, 100);
        else if (!strcmp(k, "override"))       { if (!parse_mode(v, &c->ovr)) c->ovr = M_OFF; }
        else if (!strcmp(k, "override_until")) c->ovr_until = atol(v);
        else if (!strcmp(k, "schedule") && c->nsched < MAX_SCHED) {
            int h1, m1, h2, m2, val = -1;
            char days[16] = "", mode[16] = "";
            int n = sscanf(v, "%d:%d-%d:%d %15s %15s %d", &h1, &m1, &h2, &m2, days, mode, &val);
            ag_sched_t sc;
            if (n >= 6 && parse_mode(mode, &sc.mode) && h1 >= 0 && h1 < 24 && h2 >= 0 && h2 < 24 &&
                m1 >= 0 && m1 < 60 && m2 >= 0 && m2 < 60) {
                sc.start = h1 * 60 + m1; sc.end = h2 * 60 + m2;
                sc.days = parse_days(days);
                sc.value = val;
                if (sc.days && sc.start != sc.end) c->sched[c->nsched++] = sc;
            }
        }
    }
    fclose(f);
}

typedef struct { agmode mode; int value; int auto_dis; char src[48]; } ag_policy_t;

static int sched_active(const ag_sched_t *s, const struct tm *tm) {
    int now = tm->tm_hour * 60 + tm->tm_min;
    int today = (tm->tm_wday + 6) % 7;          // 0=Sen ... 6=Min
    int yesterday = (today + 6) % 7;
    if (s->start < s->end)
        return (s->days & (1 << today)) && now >= s->start && now < s->end;
    // melewati tengah malam, mis. 22:00-06:00
    return ((s->days & (1 << today)) && now >= s->start) ||
           ((s->days & (1 << yesterday)) && now < s->end);
}

static int default_value(const ag_conf_t *c, agmode m) {
    return m == M_DISCHARGE ? c->discharge_to : m == M_FULL ? 100 : c->limit;
}

static ag_policy_t effective_policy(const ag_conf_t *c) {
    ag_policy_t p;
    time_t t = time(NULL);
    struct tm tm; localtime_r(&t, &tm);
    p.auto_dis = c->auto_dis;
    if (c->ovr != M_OFF && c->ovr_until > (long)t) {
        p.mode = c->ovr; p.value = default_value(c, c->ovr);
        snprintf(p.src, sizeof p.src, "override");
        return p;
    }
    for (int i = 0; i < c->nsched; i++) {
        if (sched_active(&c->sched[i], &tm)) {
            p.mode = c->sched[i].mode;
            p.value = c->sched[i].value > 0 ? c->sched[i].value : default_value(c, p.mode);
            snprintf(p.src, sizeof p.src, "jadwal %02d:%02d-%02d:%02d",
                     c->sched[i].start / 60, c->sched[i].start % 60,
                     c->sched[i].end / 60, c->sched[i].end % 60);
            return p;
        }
    }
    p.mode = c->mode; p.value = default_value(c, c->mode);
    snprintf(p.src, sizeof p.src, "utama");
    return p;
}

/* ---------------------------------------------------------------- daemon */

static int st_inhibit = -1, st_adoff = -1, st_bclm = -1;
static int ticks_since_write = 0;
static int force_apply = 1;
static int sleeping = 0;
static io_connect_t pm_root = 0;
static time_t last_tick = 0;

static void write_status(const ag_battery_t *b, const ag_policy_t *p, const char *note) {
    char tmp[] = STATUS_PATH ".tmp";
    FILE *f = fopen(tmp, "w");
    if (!f) return;
    fprintf(f, "updated=%ld\n", (long)time(NULL));
    fprintf(f, "pct=%d\nac=%d\ncharging=%d\n", b->pct, b->ac, b->charging);
    fprintf(f, "mode=%s\nvalue=%d\nsource=%s\n", MODE_NAME[p->mode], p->value, p->src);
    fprintf(f, "charge_inhibited=%d\nadapter_disabled=%d\nbclm=%d\n",
            st_inhibit == 1, st_adoff == 1, st_bclm);
    fprintf(f, "can_inhibit=%d\ncan_discharge=%d\nhas_bclm=%d\n",
            can_inhibit(), can_discharge(), K_BCLM.present);
    fprintf(f, "note=%s\n", note ? note : "");
    fclose(f);
    chmod(tmp, 0644);
    rename(tmp, STATUS_PATH);
}

static void tick(void) {
    if (sleeping) return;
    time_t now = time(NULL);
    if (last_tick && now - last_tick > TICK_SEC * 4) force_apply = 1;   // baru bangun / jam bergeser
    last_tick = now;

    ag_conf_t c; load_conf(&c);
    ag_policy_t p = effective_policy(&c);
    ag_battery_t b = read_battery();
    const char *note = "";

    int want_inhibit = 0, want_adoff = 0, want_bclm = 100;

    if (!b.ok) {
        note = "baterai tidak terbaca, semua dikembalikan normal";
    } else if (p.mode == M_LIMIT || p.mode == M_DISCHARGE) {
        int n = clampi(p.value, 20, 100);
        int autod = (p.mode == M_DISCHARGE) || p.auto_dis;
        want_bclm = n;
        if (n >= 100) {
            want_inhibit = 0;
        } else if (b.pct >= n) {
            want_inhibit = 1;
        } else if (b.pct <= n - c.sail) {
            want_inhibit = 0;                       // turun di bawah batas sailing: charge lagi
        } else {
            want_inhibit = st_inhibit == -1 ? 1 : st_inhibit;   // di zona sailing: pertahankan
        }
        want_adoff = autod && b.pct > n && can_discharge();
        if (want_adoff) want_inhibit = 1;
    }
    // M_FULL dan M_OFF: charging normal sampai 100%

    if (b.ok && b.pct <= SAFETY_PCT) { want_inhibit = 0; want_adoff = 0; note = "baterai kritis, pengaman aktif"; }

    int changed = want_inhibit != st_inhibit || want_adoff != st_adoff || want_bclm != st_bclm;
    if (changed || force_apply || ++ticks_since_write >= 20) {
        if (K_BCLM.present) hw_set_bclm(want_bclm);
        hw_set_adapter(!want_adoff);
        hw_set_charging(!want_inhibit);
        if (changed)
            logmsg("baterai %d%% | mode %s %d (%s) -> charging %s, adaptor %s, BCLM %d",
                   b.pct, MODE_NAME[p.mode], p.value, p.src,
                   want_inhibit ? "DITAHAN" : "normal",
                   want_adoff ? "OFF (discharge)" : "on", want_bclm);
        st_inhibit = want_inhibit; st_adoff = want_adoff; st_bclm = want_bclm;
        ticks_since_write = 0; force_apply = 0;
    }
    write_status(&b, &p, note);
}

static void power_cb(void *refcon, io_service_t svc, natural_t type, void *arg) {
    (void)refcon; (void)svc;
    switch (type) {
    case kIOMessageCanSystemSleep:
        IOAllowPowerChange(pm_root, (long)arg);
        break;
    case kIOMessageSystemWillSleep:
        // Jangan biarkan adaptor mati selama sleep (baterai bisa terkuras habis).
        sleeping = 1;
        hw_set_adapter(1);
        st_adoff = 0;
        logmsg("sistem akan sleep: adaptor dinyalakan kembali");
        IOAllowPowerChange(pm_root, (long)arg);
        break;
    case kIOMessageSystemHasPoweredOn:
        sleeping = 0;
        force_apply = 1;
        logmsg("sistem bangun dari sleep");
        tick();
        break;
    default:
        break;
    }
}

static void restore_on_exit(int keep_bclm) {
    hw_set_adapter(1);
    hw_set_charging(1);
    if (!keep_bclm && K_BCLM.present) hw_set_bclm(100);
}

static int run_daemon(void) {
    if (geteuid() != 0) { fprintf(stderr, "daemon harus jalan sebagai root\n"); return 1; }
    if (smc_open()) { fprintf(stderr, "tidak bisa membuka AppleSMC\n"); return 1; }
    mkdir(CONF_DIR, 0755);
    probe_keys();
    logmsg("AkiGuard mulai. Kunci: BCLM=%d CH0B=%d CH0C=%d CHTE=%d CH0I=%d CHIE=%d",
           K_BCLM.present, K_CH0B.present, K_CH0C.present, K_CHTE.present,
           K_CH0I.present, K_CHIE.present);
    if (!can_inhibit() && !K_BCLM.present)
        logmsg("PERINGATAN: Mac ini tidak punya kunci untuk membatasi charging");

    IONotificationPortRef port = NULL;
    io_object_t notifier;
    pm_root = IORegisterForSystemPower(NULL, &port, power_cb, &notifier);
    if (pm_root && port)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), IONotificationPortGetRunLoopSource(port),
                           kCFRunLoopCommonModes);

    signal(SIGTERM, SIG_IGN);
    signal(SIGINT, SIG_IGN);
    dispatch_queue_t q = dispatch_get_main_queue();
    int sigs[] = {SIGTERM, SIGINT};
    for (int i = 0; i < 2; i++) {
        dispatch_source_t s = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, sigs[i], 0, q);
        dispatch_source_set_event_handler(s, ^{
            // BCLM tetap dipertahankan saat Mac dimatikan supaya batas tetap berlaku
            restore_on_exit(1);
            logmsg("AkiGuard berhenti: charging & adaptor dikembalikan normal");
            exit(0);
        });
        dispatch_resume(s);
    }

    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 0),
                              TICK_SEC * NSEC_PER_SEC, NSEC_PER_SEC);
    dispatch_source_set_event_handler(timer, ^{ tick(); });
    dispatch_resume(timer);

    CFRunLoopRun();
    return 0;
}

/* ------------------------------------------------------------------- CLI */

static int need_root(void) {
    if (geteuid() != 0) { fprintf(stderr, "perintah ini butuh sudo\n"); return 0; }
    return 1;
}

static int cmd_keys(void) {
    if (smc_open()) { fprintf(stderr, "tidak bisa membuka AppleSMC\n"); return 1; }
    probe_keys();
    for (int i = 0; i < NKEYS; i++)
        printf("%s  %s%s\n", ALLKEYS[i]->name, ALLKEYS[i]->present ? "ADA" : "-",
               ALLKEYS[i]->present ? "" : "");
    printf("\nBatasi charging : %s\n", (can_inhibit() || K_BCLM.present) ? "didukung" : "TIDAK didukung");
    printf("Discharge (adaptor off): %s\n", can_discharge() ? "didukung" : "TIDAK didukung");
    return 0;
}

static int cmd_status(void) {
    ag_battery_t b = read_battery();
    if (b.ok) printf("Baterai %d%%, %s, %s\n", b.pct, b.ac ? "adaptor terhubung" : "pakai baterai",
                     b.charging ? "sedang charging" : "tidak charging");
    FILE *f = fopen(STATUS_PATH, "r");
    if (f) {
        printf("\nStatus daemon (%s):\n", STATUS_PATH);
        char line[256];
        while (fgets(line, sizeof line, f)) printf("  %s", line);
        fclose(f);
    } else {
        printf("Daemon belum pernah jalan (status belum ada).\n");
    }
    return 0;
}

static int cmd_read(const char *key) {
    if (!need_root() || smc_open()) return 1;
    uint8_t buf[32]; uint32_t n = 0;
    int r = smc_read(key, buf, &n);
    if (r) { fprintf(stderr, "gagal membaca %s (kode %d)\n", key, r); return 1; }
    printf("%s =", key);
    for (uint32_t i = 0; i < n; i++) printf(" %02x", buf[i]);
    printf("\n");
    return 0;
}

static int cmd_write(const char *key, const char *hex) {
    if (!need_root() || smc_open()) return 1;
    uint8_t buf[32]; uint32_t n = 0;
    size_t len = strlen(hex);
    if (len % 2 || len / 2 > 32) { fprintf(stderr, "HEX tidak valid\n"); return 1; }
    for (size_t i = 0; i < len; i += 2) {
        unsigned v;
        if (sscanf(hex + i, "%2x", &v) != 1) { fprintf(stderr, "HEX tidak valid\n"); return 1; }
        buf[n++] = (uint8_t)v;
    }
    int r = smc_write(key, buf, n);
    if (r) { fprintf(stderr, "gagal menulis %s (kode %d; cek ukuran dengan 'read')\n", key, r); return 1; }
    printf("OK\n");
    return 0;
}

static int cmd_reset(void) {
    if (!need_root() || smc_open()) return 1;
    probe_keys();
    restore_on_exit(0);
    printf("Charging, adaptor dan BCLM dikembalikan ke normal.\n");
    return 0;
}

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IOLBF, 0);
    const char *cmd = argc > 1 ? argv[1] : "status";
    if (!strcmp(cmd, "daemon")) return run_daemon();
    if (!strcmp(cmd, "status")) return cmd_status();
    if (!strcmp(cmd, "keys"))   return cmd_keys();
    if (!strcmp(cmd, "reset"))  return cmd_reset();
    if (!strcmp(cmd, "read")  && argc == 3) return cmd_read(argv[2]);
    if (!strcmp(cmd, "write") && argc == 4) return cmd_write(argv[2], argv[3]);
    fprintf(stderr,
            "Pemakaian: akiguard [status|keys|reset|daemon|read KEY|write KEY HEX]\n");
    return 2;
}
