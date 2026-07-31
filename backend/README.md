# Inkwell backend

Receives a captured inkling from the phone and writes it as markdown into a git repo. See
`/docs/api-contract.md` for the full API and `/README.md` for why Go. No external dependencies -
standard library only, plus the system `git` binary via `os/exec`.

Day to day, run this through `../dev.sh` from the repo root, not directly - it gives this worktree
its own port and storage so it can't collide with another worktree's backend (see
`/docs/runtime-isolation.md`). What follows here is the raw binary's own interface, for reference
and for quick one-off iteration on the backend alone.

## Run

```
go run . --addr 127.0.0.1:8080 --storage-dir ./data
```

| Flag             | Env var                 | Default          | Meaning                                    |
|------------------|--------------------------|------------------|---------------------------------------------|
| `--addr`         | `INKWELL_ADDR`           | `127.0.0.1:8080` | listen address                              |
| `--storage-dir`  | `INKWELL_STORAGE_DIR`    | `./data`         | the git repo of markdown files              |

Both are config, never hardcoded - moving from a local dev backend to a VPS means changing these
(e.g. `--addr 0.0.0.0:8080`), not changing code.

`--storage-dir` is `git init`'d automatically on first run if it isn't already a repo, with a
repo-local `user.name`/`user.email` set so commits work even on a machine with no global git
identity configured.

## Test

```
go test ./...
```

Covers slug generation, front-matter round-tripping, upsert-by-id (same id twice updates the
same file rather than duplicating it, and produces two separate commits), and the HTTP handlers
end to end (`POST` then `GET`, retry-safety, validation).

## Build a binary

```
go build -o inkwell-backend .
./inkwell-backend --addr 127.0.0.1:8080 --storage-dir /path/to/data
```

One self-contained binary, no install step beyond copying it over.
