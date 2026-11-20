# Databases upgrade from the first version on

Every milestone closes with a published version (`0.1.0` for milestone 1), and from `0.1.0` on a database created by any version must reach every later version by running the pending migrations. Migrations are therefore append-only from the first version: the initial migrations, edited in place until then, are frozen when `v0.1.0` is tagged.

We chose this because the published release archives and container image are the main path for new users, and an upgrade that silently needs a fresh database would lose their accounts and, from milestone 2, their characters. The alternative was to call the databases of all 0.x versions disposable and keep editing the initial migrations until a later version; it was rejected although the schema will change most in milestones 2 to 4.

## Consequences

- Every schema change after `0.1.0` is a new migration that runs on PostgreSQL and SQLite. With the portable subset (no `modify`, ADR 0004) a changed column means a new column or table plus a data copy, not an altered one.
- The changelog of each version says under "Moving from the previous version" what an administrator must do. Skipping versions must work: the migrations of the versions in between run in order.
- The promise covers the database only. Whether the data directory must be imported again is stated per version.
