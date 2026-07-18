# dh_server

The Distant Horizon game server: a Gleam/OTP simulation actor ticking one star
system at 60 Hz, serving the v1 JSON protocol over WebSocket on
`127.0.0.1:8484/ws`. See [docs/M1-RESULTS.md](../docs/M1-RESULTS.md) for the
protocol and world-doc reference.

## Development

```sh
gleam run   # Run the server
gleam test  # Run the tests
```

CI runs `gleam format --check src test` and fails the build if anything is
unformatted. Enable the repo's pre-commit hook once per clone so a stray
unformatted file can't slip through (it lives in `.githooks/`, from the repo
root):

```sh
git config core.hooksPath .githooks
```

The hook blocks a commit that stages unformatted `server/**/*.gleam`; run
`gleam format src test` to fix.

## Environment variables

| var | default | meaning |
|---|---|---|
| `DH_WORLD` | `worlds/m1_system.json` | Path to the world doc to load at boot (relative to `server/`). Boot fails with a clear message if it's missing or invalid. |
| `DATABASE_URL` | `postgres://postgres@127.0.0.1:5432/dh_dev` | Postgres connection for accounts (see below). |
| `DH_TEST_DATABASE_URL` | *(unset)* | Enables the env-gated account tests in `gleam test` (see below). |

## Accounts (Postgres)

Player accounts are stored in Postgres. The server reads `DATABASE_URL`
(default `postgres://postgres@127.0.0.1:5432/dh_dev`) and connects on
startup, creating the `accounts` table if it doesn't already exist (see
`sql/schema.sql` for a documentation copy of the DDL — the real source of
truth is `dh_server/accounts.ensure_schema`). Login is login-or-register: an
unknown username registers a new account with the given password; a known
username must present the matching password.

If Postgres is unreachable at startup, the server still boots, but falls
back to an accept-all authenticator and prints a warning — auth is **not
persistent** in that mode (every login succeeds and nothing is saved).

### Typed queries (squirrel)

The account queries live as plain SQL in `src/dh_server/sql/*.sql` and are
compiled into typed Gleam functions (`src/dh_server/sql.gleam`, checked in)
by [squirrel](https://hexdocs.pm/squirrel/), which type-checks each query
against a live database at codegen time. After adding or editing a `.sql`
file, regenerate with:

```powershell
$env:DATABASE_URL = 'postgres://postgres@127.0.0.1:5432/dh_dev'
gleam run -m squirrel
```

The target database must already have the `accounts` table (run the server
once, or apply `ensure_schema`). DDL stays hand-written in
`accounts.ensure_schema`; squirrel only handles queries.

Local dev setup (Windows, scoop-installed Postgres with trust auth):

```sh
$env:Path = "$env:USERPROFILE\scoop\shims;$env:Path"
& "$env:USERPROFILE\scoop\apps\postgresql\current\bin\createdb.exe" -U postgres dh_dev
gleam run
```

### Running the accounts tests

`accounts_test.gleam` is env-gated: it only runs against a real database
when `DH_TEST_DATABASE_URL` is set. Without it, each test prints a
`skipped: no DH_TEST_DATABASE_URL` line and does nothing.

```powershell
$env:DH_TEST_DATABASE_URL = 'postgres://postgres@127.0.0.1:5432/dh_dev'
gleam test
```

CI runs the same tests against a disposable `postgres:18` service container
(see `.github/workflows/server-test.yml`).
