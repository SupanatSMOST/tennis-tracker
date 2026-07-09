---
name: project-auth
description: Concrete spec-level auth choices made for Tennis Shot Tracker beyond what DESIGN.md states
metadata:
  type: project
---

DESIGN.md locks the auth shape (bcrypt + non-expiring JWT wrapping user_id, Keychain storage, single-user revocation trade-off accepted). These are the concrete choices the spec added on top, which DESIGN.md leaves open:

- bcrypt **cost factor 12** (spec quality bar bans vague terms, so a number was chosen).
- JWT algorithm **HS256** (symmetric — one service, one key from env; asymmetric buys nothing here). Middleware must reject non-HS256 `alg` to guard against `alg:none` / algorithm-confusion.
- **No `exp` claim** — the absence of exp IS the non-expiry requirement; don't add expiry.
- Middleware resolves the `user_login` row (not just signature) because `GET /me` returns `username` while the token carries only `user_id`.

See [[spec-conventions]].
