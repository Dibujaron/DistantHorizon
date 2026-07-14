//// This module contains the code to run the sql queries defined in
//// `./src/dh_server/sql`.
//// > 🐿️ This module was generated automatically using v4.7.0 of
//// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
////

import gleam/dynamic/decode
import pog

/// A row you get from running the `find_account` query
/// defined in `./src/dh_server/sql/find_account.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type FindAccountRow {
  FindAccountRow(id: Int, password_hash: String, salt: String)
}

/// Look up an account by username for login. At most one row (username is
/// UNIQUE).
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn find_account(
  db: pog.Connection,
  username: String,
) -> Result(pog.Returned(FindAccountRow), pog.QueryError) {
  let decoder = {
    use id <- decode.field(0, decode.int)
    use password_hash <- decode.field(1, decode.string)
    use salt <- decode.field(2, decode.string)
    decode.success(FindAccountRow(id:, password_hash:, salt:))
  }

  "-- Look up an account by username for login. At most one row (username is
-- UNIQUE).
SELECT id, password_hash, salt
FROM accounts
WHERE username = $1
"
  |> pog.query
  |> pog.parameter(pog.text(username))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// A row you get from running the `insert_account` query
/// defined in `./src/dh_server/sql/insert_account.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type InsertAccountRow {
  InsertAccountRow(id: Int)
}

/// Register a new account, returning its generated id.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn insert_account(
  db: pog.Connection,
  arg_1: String,
  arg_2: String,
  arg_3: String,
) -> Result(pog.Returned(InsertAccountRow), pog.QueryError) {
  let decoder = {
    use id <- decode.field(0, decode.int)
    decode.success(InsertAccountRow(id:))
  }

  "-- Register a new account, returning its generated id.
INSERT INTO accounts (username, password_hash, salt)
VALUES ($1, $2, $3)
RETURNING id
"
  |> pog.query
  |> pog.parameter(pog.text(arg_1))
  |> pog.parameter(pog.text(arg_2))
  |> pog.parameter(pog.text(arg_3))
  |> pog.returning(decoder)
  |> pog.execute(db)
}
