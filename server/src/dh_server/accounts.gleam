//// Postgres-backed account storage. `authenticator` implements the same
//// `auth.Authenticator` function type as the M1 accept-all stub, with
//// login-or-register semantics: an unknown username registers a new
//// account, a known username must present the matching password.
////
//// TODO(pre-launch): upgrade password hashing to a proper KDF (argon2/bcrypt).

import dh_server/auth.{type AuthError, InvalidCredentials, StorageError}
import dh_server/sql
import gleam/bit_array
import gleam/crypto
import gleam/erlang/process
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import pog

/// Start a supervised connection pool for `database_url` and ensure the
/// accounts table exists. Returns `Error` if the URL cannot be parsed or the
/// schema check fails (which also surfaces a database that is unreachable,
/// since `ensure_schema` runs a real query against it).
pub fn connect(database_url: String) -> Result(pog.Connection, String) {
  let name = process.new_name(prefix: "dh_accounts_db")
  use config <- result.try(
    pog.url_config(name, database_url)
    |> result.replace_error("invalid database url: " <> database_url),
  )
  // pgo's default queue_target/queue_interval (50ms / 1000ms) are tuned for
  // steady-state load shedding, not for detecting "this pool has never had
  // a live connection" — with the defaults, a checkout against an unreachable
  // database can take ~2 * queue_interval (2s) to fail. Tighten both so a
  // genuinely-unreachable database is detected quickly and `connect` doesn't
  // stall server boot.
  let config =
    config
    |> pog.queue_target(20)
    |> pog.queue_interval(200)
  use started <- result.try(
    pog.start(config)
    |> result.map_error(fn(err) {
      "failed to start postgres pool: " <> string.inspect(err)
    }),
  )
  let db = started.data
  // `pog.start` returns as soon as the pool supervisor is up, before it has
  // actually connected to Postgres, so an immediate query can spuriously
  // fail on a cold pool. Retry briefly so `connect` only reports failure for
  // a genuinely unreachable database, not a pool that's still dialing in.
  use _ <- result.try(wait_for_schema(db, 8))
  Ok(db)
}

fn wait_for_schema(
  db: pog.Connection,
  attempts_remaining: Int,
) -> Result(Nil, String) {
  case ensure_schema(db), attempts_remaining {
    Ok(_), _ -> Ok(Nil)
    Error(reason), remaining if remaining <= 1 -> Error(reason)
    Error(_), remaining -> {
      process.sleep(100)
      wait_for_schema(db, remaining - 1)
    }
  }
}

/// CREATE TABLE IF NOT EXISTS accounts (
///   id BIGSERIAL PRIMARY KEY, username TEXT NOT NULL UNIQUE,
///   password_hash TEXT NOT NULL, salt TEXT NOT NULL,
///   created_at TIMESTAMPTZ NOT NULL DEFAULT now());
pub fn ensure_schema(db: pog.Connection) -> Result(Nil, String) {
  let sql =
    "CREATE TABLE IF NOT EXISTS accounts (
      id BIGSERIAL PRIMARY KEY,
      username TEXT NOT NULL UNIQUE,
      password_hash TEXT NOT NULL,
      salt TEXT NOT NULL,
      created_at TIMESTAMPTZ NOT NULL DEFAULT now()
    )"
  pog.query(sql)
  |> pog.execute(on: db)
  |> result.map(fn(_) { Nil })
  |> result.map_error(string.inspect)
}

/// Login-or-register: an unknown username registers a new account and
/// returns its id; a known username must present the matching password.
/// Empty username or password is rejected without touching the database.
pub fn authenticator(db: pog.Connection) -> auth.Authenticator {
  fn(username: String, password: String) {
    case username, password {
      "", _ -> Error(InvalidCredentials)
      _, "" -> Error(InvalidCredentials)
      _, _ -> login_or_register(db, username, password)
    }
  }
}

fn login_or_register(
  db: pog.Connection,
  username: String,
  password: String,
) -> Result(Int, AuthError) {
  use existing <- result.try(find_account(db, username))
  case existing {
    Some(account) ->
      case hash_password(password, account.salt) == account.password_hash {
        True -> Ok(account.id)
        False -> Error(InvalidCredentials)
      }
    None -> register(db, username, password)
  }
}

// The queries themselves live in `sql/*.sql` and are compiled to typed
// functions in `dh_server/sql` by squirrel (`gleam run -m squirrel` with
// DATABASE_URL pointing at a database that has the accounts table).

fn find_account(
  db: pog.Connection,
  username: String,
) -> Result(Option(sql.FindAccountRow), AuthError) {
  case sql.find_account(db, username) {
    Ok(pog.Returned(_, [row])) -> Ok(Some(row))
    Ok(pog.Returned(_, [])) -> Ok(None)
    Ok(pog.Returned(_, _)) ->
      Error(StorageError("multiple accounts found for username"))
    Error(err) -> Error(StorageError(string.inspect(err)))
  }
}

fn register(
  db: pog.Connection,
  username: String,
  password: String,
) -> Result(Int, AuthError) {
  let salt = crypto.strong_random_bytes(16) |> bit_array.base16_encode
  let password_hash = hash_password(password, salt)
  case sql.insert_account(db, username, password_hash, salt) {
    Ok(pog.Returned(_, [row])) -> Ok(row.id)
    Ok(_) -> Error(StorageError("insert did not return an id"))
    Error(err) -> Error(StorageError(string.inspect(err)))
  }
}

// TODO(pre-launch): upgrade to a KDF (argon2/bcrypt).
fn hash_password(password: String, salt_hex: String) -> String {
  crypto.hash(crypto.Sha256, bit_array.from_string(salt_hex <> password))
  |> bit_array.base16_encode
}
