/* Disposable durability harness. Links the same namespaced engine as Kit. */
#include "SilveranSQLite.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static void run(sqlite3 *db, const char *sql) {
    int code = sqlite3_exec(db, sql, NULL, NULL, NULL);
    if (code != SQLITE_OK) {
        fprintf(stderr, "Durability fixture SQL failed: %d\n", code);
        _exit(91);
    }
}

int main(int argc, char **argv) {
    if (argc != 3 && argc != 6) return 90;
    sqlite3 *db = NULL;
    if (sqlite3_open_v2(argv[1], &db, SQLITE_OPEN_READWRITE, NULL) != SQLITE_OK) return 92;
    if (!strcmp(argv[2], "inspect")) {
        sqlite3_stmt *statement = NULL;
        if (sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &statement, NULL) != SQLITE_OK) return 93;
        if (sqlite3_step(statement) != SQLITE_ROW) return 94;
        printf("%d\n", sqlite3_column_int(statement, 0));
        sqlite3_finalize(statement);
        sqlite3_close(db);
        return 0;
    }
    run(db, "PRAGMA foreign_keys=ON; PRAGMA synchronous=FULL; PRAGMA cache_size=1; BEGIN IMMEDIATE;");
    if (!strcmp(argv[2], "restore")) {
        run(db, "DELETE FROM heads; DELETE FROM backup_intent; UPDATE delivery SET state='quarantined';");
    } else if (!strcmp(argv[2], "capture") || !strcmp(argv[2], "capture-commit")) {
        if (argc != 6) return 90;
        FILE *file = fopen(argv[5], "rb");
        if (!file || fseek(file, 0, SEEK_END)) return 96;
        long size = ftell(file);
        if (size < 0 || size > 1024 * 1024 || fseek(file, 0, SEEK_SET)) return 96;
        void *bytes = malloc(size ? (size_t)size : 1);
        if (!bytes || fread(bytes, 1, (size_t)size, file) != (size_t)size) return 96;
        fclose(file);
        sqlite3_stmt *statement = NULL;
        if (sqlite3_prepare_v2(db, "INSERT INTO legacy_capture VALUES (?, ?, ?, NULL)", -1, &statement, NULL) != SQLITE_OK) return 97;
        if (sqlite3_bind_text(statement, 1, argv[3], -1, SQLITE_TRANSIENT) != SQLITE_OK ||
            sqlite3_bind_text(statement, 2, argv[4], -1, SQLITE_TRANSIENT) != SQLITE_OK ||
            sqlite3_bind_blob(statement, 3, bytes, (int)size, SQLITE_TRANSIENT) != SQLITE_OK ||
            sqlite3_step(statement) != SQLITE_DONE) return 97;
        sqlite3_finalize(statement);
        free(bytes);
    } else if (!strcmp(argv[2], "legacy-staging")) {
        /* Storage-valid unfinished rows, deliberately not a valid domain command/receipt. */
        run(db, "INSERT INTO revisions VALUES ('00000000-0000-4000-8000-000000000001','{}','fixture',X'00',X'00',0);"
                "INSERT INTO heads VALUES ('{}','fixture','00000000-0000-4000-8000-000000000001');"
                "INSERT INTO backup_intent VALUES ('00000000-0000-4000-8000-000000000001');"
                "UPDATE legacy_capture SET verification=X'00';");
    } else if (!strcmp(argv[2], "schema2") || !strcmp(argv[2], "schema2-commit")) {
        run(db, "CREATE TABLE legacy_capture (capture_id TEXT PRIMARY KEY, capture_hash TEXT NOT NULL, capture BLOB NOT NULL, verification BLOB);"
                "PRAGMA user_version=3;");
    } else {
        run(db, "CREATE TABLE restore_checkpoints (restore_id TEXT PRIMARY KEY, request_hash TEXT NOT NULL,"
                "mode TEXT NOT NULL CHECK(mode IN ('merge','replace')), before_snapshot BLOB NOT NULL, receipt BLOB NOT NULL);"
                "CREATE TABLE legacy_capture (capture_id TEXT PRIMARY KEY, capture_hash TEXT NOT NULL, capture BLOB NOT NULL, verification BLOB);"
                "PRAGMA user_version=3;");
    }
    /* Spill real modified pages and a hot journal before abrupt process loss. */
    if (sqlite3_db_cacheflush(db) != SQLITE_OK) return 95;
    if (!strcmp(argv[2], "schema-commit") || !strcmp(argv[2], "schema2-commit") ||
        !strcmp(argv[2], "capture-commit")) run(db, "COMMIT;");
    _exit(73); /* Deliberately bypass rollback, statement finalization and connection close. */
}
