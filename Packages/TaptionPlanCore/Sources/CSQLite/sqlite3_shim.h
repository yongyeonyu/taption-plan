#ifndef TAPTION_SQLITE3_SHIM_H
#define TAPTION_SQLITE3_SHIM_H

typedef struct sqlite3 sqlite3;
typedef struct sqlite3_stmt sqlite3_stmt;
typedef void (*sqlite3_destructor_type)(void *);

int sqlite3_open_v2(const char *, sqlite3 **, int, const char *);
int sqlite3_close(sqlite3 *);
const char *sqlite3_errmsg(sqlite3 *);
int sqlite3_errcode(sqlite3 *);
int sqlite3_exec(sqlite3 *, const char *, int (*)(void *, int, char **, char **), void *, char **);
void sqlite3_free(void *);
int sqlite3_prepare_v2(sqlite3 *, const char *, int, sqlite3_stmt **, const char **);
int sqlite3_finalize(sqlite3_stmt *);
int sqlite3_step(sqlite3_stmt *);
int sqlite3_changes(sqlite3 *);
int sqlite3_wal_checkpoint_v2(sqlite3 *, const char *, int, int *, int *);
int sqlite3_bind_text(sqlite3_stmt *, int, const char *, int, sqlite3_destructor_type);
int sqlite3_bind_int64(sqlite3_stmt *, int, long long);
int sqlite3_bind_double(sqlite3_stmt *, int, double);
int sqlite3_bind_null(sqlite3_stmt *, int);
int sqlite3_bind_blob(sqlite3_stmt *, int, const void *, int, sqlite3_destructor_type);
const unsigned char *sqlite3_column_text(sqlite3_stmt *, int);
long long sqlite3_column_int64(sqlite3_stmt *, int);
double sqlite3_column_double(sqlite3_stmt *, int);
int sqlite3_column_type(sqlite3_stmt *, int);
const void *sqlite3_column_blob(sqlite3_stmt *, int);
int sqlite3_column_bytes(sqlite3_stmt *, int);

#define SQLITE_OK 0
#define SQLITE_ERROR 1
#define SQLITE_INTERNAL 2
#define SQLITE_ABORT 4
#define SQLITE_BUSY 5
#define SQLITE_LOCKED 6
#define SQLITE_NOMEM 7
#define SQLITE_READONLY 8
#define SQLITE_INTERRUPT 9
#define SQLITE_IOERR 10
#define SQLITE_CORRUPT 11
#define SQLITE_NOTFOUND 12
#define SQLITE_FULL 13
#define SQLITE_CANTOPEN 14
#define SQLITE_PROTOCOL 15
#define SQLITE_EMPTY 16
#define SQLITE_SCHEMA 17
#define SQLITE_TOOBIG 18
#define SQLITE_CONSTRAINT 19
#define SQLITE_MISMATCH 20
#define SQLITE_MISUSE 21
#define SQLITE_NOLFS 22
#define SQLITE_AUTH 23
#define SQLITE_FORMAT 24
#define SQLITE_RANGE 25
#define SQLITE_NOTADB 26
#define SQLITE_ROW 100
#define SQLITE_DONE 101
#define SQLITE_OPEN_READONLY 0x00000001
#define SQLITE_OPEN_READWRITE 0x00000002
#define SQLITE_OPEN_CREATE 0x00000004
#define SQLITE_OPEN_FULLMUTEX 0x00010000
#define SQLITE_CHECKPOINT_PASSIVE 0
#define SQLITE_NULL 5

#endif
