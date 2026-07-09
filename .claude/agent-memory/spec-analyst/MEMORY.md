# Memory Index

- [Spec Conventions](spec_conventions.md) — keep specs faithful to DESIGN.md nullability; underspecified DDL → Assumptions; every auth AC needs a protected route
- [Project Auth](project_auth.md) — concrete spec choices atop DESIGN.md: bcrypt cost 12, HS256, no exp claim, alg:none guard, middleware resolves user row
