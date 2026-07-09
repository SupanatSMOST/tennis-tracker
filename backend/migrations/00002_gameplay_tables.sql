-- +goose Up
CREATE TABLE match (
    match_id      UUID        PRIMARY KEY,
    user_id       UUID        NOT NULL REFERENCES user_login(user_id),
    location      TEXT,
    court_surface TEXT,
    played_at     TIMESTAMPTZ,
    video_ref     TEXT,
    ended_at      TIMESTAMPTZ,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE record (
    record_id  UUID        PRIMARY KEY,
    match_id   UUID        NOT NULL REFERENCES match(match_id),
    zone       TEXT,
    court_x    REAL,
    court_y    REAL,
    ts_ms      INTEGER,
    source     TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE match_summary (
    match_id    UUID        NOT NULL REFERENCES match(match_id),
    zone        TEXT        NOT NULL,
    shot_count  INTEGER     NOT NULL,
    computed_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (match_id, zone)
);

-- +goose Down
DROP TABLE match_summary;
DROP TABLE record;
DROP TABLE match;
