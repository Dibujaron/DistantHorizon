//// The authentication seam. `Authenticator` is the function type both the
//// M1 accept-all stub (here) and a future Postgres-backed implementation
//// (Task 4) satisfy; `server.gleam` only ever depends on the function type,
//// never on how credentials are actually checked.

/// Why a login attempt was rejected.
pub type AuthError {
  InvalidCredentials
  StorageError(String)
}

/// Check a username/password pair, returning the account id on success.
pub type Authenticator =
  fn(String, String) -> Result(Int, AuthError)

/// An authenticator that accepts any non-empty username and password,
/// always returning account id 0. Rejects with `InvalidCredentials` if
/// either field is empty.
pub fn accept_all() -> Authenticator {
  fn(username: String, password: String) {
    case username, password {
      "", _ -> Error(InvalidCredentials)
      _, "" -> Error(InvalidCredentials)
      _, _ -> Ok(0)
    }
  }
}
