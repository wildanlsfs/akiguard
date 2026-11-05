// AkiGuard Pro hooks. The free build links pro_stub.c; the Pro build links pro/heat.c.
#pragma once

extern const int PRO_BUILD;

// Returns 1 if charging should be held because the battery is too hot.
// enabled: heat_protect from config; limit_c: threshold in C; temp_c10: battery temp in 0.1 C (-1 = unknown)
int pro_heat_hold(int enabled, int limit_c, int temp_c10);
