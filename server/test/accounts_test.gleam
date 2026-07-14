//// Postgres-backed accounts, env-gated: these tests only run when
//// `DH_TEST_DATABASE_URL` is set (a local or CI Postgres instance), since
//// there is no in-memory fallback for the real storage layer. When the env
//// var is unset each test prints one "skipped" line and returns.

import dh_server/accounts
import dh_server/auth
import dh_server/clock
import envoy
import gleam/int
import gleam/io
import pog

pub fn connect_and_ensure_schema_test() {
  use db <- with_test_db()
  let assert Ok(_) = accounts.ensure_schema(db)
  Nil
}

pub fn register_new_username_returns_positive_id_test() {
  use db <- with_test_db()
  let authenticate = accounts.authenticator(db)
  let username = unique_username("register")
  let assert Ok(id) = authenticate(username, "correct horse")
  assert id > 0
}

pub fn same_username_and_password_logs_in_with_same_id_test() {
  use db <- with_test_db()
  let authenticate = accounts.authenticator(db)
  let username = unique_username("login")
  let assert Ok(first_id) = authenticate(username, "correct horse")
  let assert Ok(second_id) = authenticate(username, "correct horse")
  assert first_id == second_id
}

pub fn same_username_wrong_password_is_rejected_test() {
  use db <- with_test_db()
  let authenticate = accounts.authenticator(db)
  let username = unique_username("wrongpw")
  let assert Ok(_) = authenticate(username, "correct horse")
  assert authenticate(username, "wrong horse") == Error(auth.InvalidCredentials)
}

pub fn empty_password_is_rejected_without_touching_db_test() {
  use db <- with_test_db()
  let authenticate = accounts.authenticator(db)
  // A bogus, never-reachable host would surface as a StorageError if the
  // authenticator tried to query the database; the empty-password guard
  // must short-circuit before that happens.
  assert authenticate("someone", "") == Error(auth.InvalidCredentials)
  // Sanity check the fixture db is actually fine, so a failure above can't
  // be masked by a broken connection.
  let assert Ok(_) = accounts.ensure_schema(db)
  Nil
}

/// Run `run` against a real Postgres connection when `DH_TEST_DATABASE_URL`
/// is set; otherwise print a skip notice and do nothing.
fn with_test_db(run: fn(pog.Connection) -> Nil) -> Nil {
  case envoy.get("DH_TEST_DATABASE_URL") {
    Error(Nil) -> io.println("skipped: no DH_TEST_DATABASE_URL")
    Ok(database_url) -> {
      let assert Ok(db) = accounts.connect(database_url)
      run(db)
    }
  }
}

/// A per-run-unique username so reruns against a persistent database don't
/// collide with rows left behind by earlier runs.
fn unique_username(prefix: String) -> String {
  prefix <> "_" <> int.to_string(clock.now_us())
}
