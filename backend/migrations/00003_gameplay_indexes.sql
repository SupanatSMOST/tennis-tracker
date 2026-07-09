-- +goose Up
CREATE INDEX idx_record_match_id ON record (match_id);

-- +goose Down
DROP INDEX idx_record_match_id;
