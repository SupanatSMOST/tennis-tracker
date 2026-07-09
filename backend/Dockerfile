# syntax=docker/dockerfile:1

# ---- build stage ----
FROM golang:1.25 AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
# Static binary (CGO off) so it runs on a minimal runtime image.
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -o /out/server ./cmd/server
# goose CLI for the release/migrate step (run by the compose "migrate" service).
RUN CGO_ENABLED=0 go install github.com/pressly/goose/v3/cmd/goose@latest \
    && cp "$(go env GOPATH)/bin/goose" /out/goose

# ---- runtime stage ----
FROM alpine:3.20
RUN adduser -D -u 10001 app
WORKDIR /app
COPY --from=build /out/server /app/server
COPY --from=build /out/goose  /app/goose
COPY migrations /app/migrations
USER app
EXPOSE 8080
ENTRYPOINT ["/app/server"]
