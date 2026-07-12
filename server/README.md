# dh_server

[![Package Version](https://img.shields.io/hexpm/v/dh_server)](https://hex.pm/packages/dh_server)
[![Hex Docs](https://img.shields.io/badge/hex-docs-ffaff3)](https://hexdocs.pm/dh_server/)

```sh
gleam add dh_server@1
```
```gleam
import dh_server

pub fn main() -> Nil {
  // TODO: An example of the project in use
}
```

Further documentation can be found at <https://hexdocs.pm/dh_server>.

## Development

```sh
gleam run   # Run the project
gleam test  # Run the tests
```

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
