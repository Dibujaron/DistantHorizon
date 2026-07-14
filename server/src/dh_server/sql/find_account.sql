-- Look up an account by username for login. At most one row (username is
-- UNIQUE).
SELECT id, password_hash, salt
FROM accounts
WHERE username = $1
