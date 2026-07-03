---
name: io.sqlite
module: io
kind: function
since: 1.7.0
stability: unstable
pledges: ["fs:read", "fs:write"]
origin: lus
params:
  - name: path
    type: string
  - name: mode
    type: string
    optional: true
returns: database
---

Opens the SQLite database at `path` and returns a database handle. SQLite is embedded in the runtime, so no external library or system package is involved. Passing `":memory:"` opens a private in-memory database that needs no filesystem pledge at all. The optional `mode` is `"rw"` (the default, which reads, writes, and creates) or `"r"` (read-only). A file-backed open pledge-checks the database path together with its `-journal`, `-wal`, and `-shm` sidecar files: `fs:read` always, and `fs:write` too under `"rw"`. Writable file-backed databases run in WAL mode, which supports concurrent readers alongside a single writer.

The handle runs statements and queries. `db:exec(sql)` runs one or more statements for their side effects. `db:run(sql, ...)` runs a single statement with bound parameters and returns the affected row count and the last inserted row id. `db:query(sql, ...)` runs a single statement and returns an iterator over the result rows, where each row is a table keyed by column name. `db:prepare(sql)` compiles a reusable statement whose `stmt:run(...)` and `stmt:query(...)` execute it with fresh bindings, and `stmt:close()` releases it early. `db:transaction(fn)` runs `fn` inside a transaction, commits when it returns (passing through all of `fn`'s return values), and rolls back when it raises. `db:close()` closes the handle.

Placeholders carry every value into a statement, so interpolated or concatenated text reaches the database as data. Positional `?` placeholders bind from the extra arguments in order, and named placeholders (`:name`, `@name`, or `$name`) bind from a single table argument keyed by the bare name. Numbered `?NNN` placeholders are not supported, and one statement never mixes named and positional styles. Bindable values map as nil to `NULL`, boolean to `1` or `0`, integer to `INTEGER`, float to `REAL`, string to `TEXT`, and `vector` to `BLOB`. Reading maps `INTEGER` to an integer, `REAL` to a float, `TEXT` to a string, `BLOB` to a `vector`, and `NULL` to an absent row field. Binding NaN stores `NULL`, following SQLite.

The handle manages its native resources the same way `io.open` file objects do. It carries a `__close` metamethod, so `local db <close> = io.sqlite(path)` closes the database when its block exits, including through an error, and a `__gc` finalizer releases any handle a program leaves open. Closing a database finalizes its live statements first. Prepared statements and query iterations follow the same lifetime rules with their own `__close` and `__gc`.

SQLite never touches a path outside the pledged set: temp structures live in memory, `ATTACH` and `VACUUM INTO` are denied, and URI filenames are rejected at open. A database handle lives in the interpreter state that opened it and cannot be sent to a worker, so a worker uses a database by opening the path itself.

```lus
global io, pledge

pledge("fs:read=./app.db*", "fs:write=./app.db*", "seal")

local db <close> = io.sqlite("app.db")
db:exec("CREATE TABLE IF NOT EXISTS users (id INTEGER PRIMARY KEY, name TEXT)")
db:run("INSERT INTO users (name) VALUES (?)", "Alice")
for row in db:query("SELECT id, name FROM users WHERE name = :name",
                    { name = "Alice" }) do
    print(row.id, row.name)
end
```
