#pragma once
#include "SilveranSQLiteAliases.h"
#include "../Vendor/sqlite3.h"
static inline sqlite3_destructor_type silveran_sqlite_transient(void) { return SQLITE_TRANSIENT; }
