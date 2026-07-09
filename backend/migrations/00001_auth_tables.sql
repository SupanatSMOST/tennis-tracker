-- +goose Up
CREATE TABLE user_login (
    user_id       UUID        PRIMARY KEY,
    username      TEXT        NOT NULL UNIQUE,
    password_hash TEXT        NOT NULL,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE profile (
    user_id      UUID        PRIMARY KEY REFERENCES user_login(user_id),
    display_name TEXT        NOT NULL,
    avatar_url   TEXT,
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- +goose Down
DROP TABLE profile;
DROP TABLE user_login;
