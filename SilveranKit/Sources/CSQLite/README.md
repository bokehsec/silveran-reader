# Pinned SQLite C engine

SQLite 3.53.4, official amalgamation https://sqlite.org/2026/sqlite-amalgamation-3530400.zip
SHA3-256 archive: 628a44cfe82c66aed1ccbbe85a562d2e33ebe64b3288981ed76285612227934e
License: public domain, https://sqlite.org/copyright.html

Vendor/sqlite3.c and sqlite3.h are unmodified release bytes. SilveranSQLiteAliases.h is generated from sqlite3 identifiers in that header, renaming public symbols/types with a silveran_ prefix through preprocessing. This prevents collisions with platform SQLite or another dependency. No database-engine fork is introduced. The package compiles one translation unit, SilveranSQLite.c, with extension loading disabled, DQS disabled, and thread safety enabled. The original C header retains upstream copyright/dedication and release ID.

Upgrade: download an official amalgamation, verify its official SHA3-256 hash, replace both vendor files, regenerate aliases using the same regex, record version/hash here, then run repository durability/migration/restore tests plus Apple/Linux/Android builds. Do not regenerate aliases from private app data. Inspect security/release notes and validate older database compatibility before rollout.
