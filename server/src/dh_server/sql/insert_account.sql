-- Register a new account, returning its generated id.
INSERT INTO accounts (username, password_hash, salt)
VALUES ($1, $2, $3)
RETURNING id
