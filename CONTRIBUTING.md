# Contributing to approx_count

Thanks for your interest in improving `approx_count`.

## Licensing

`approx_count` is triple-licensed under the PostgreSQL License, MIT, and
Apache-2.0 (see `LICENSE`). By submitting a contribution you agree that it is
offered under the same triple-license terms.

## Source of truth

`sql/approx_count--1.0.sql` is the canonical definition for **both** install
paths (`tools/render.sh` is re-pointed to the current version's file on each minor
bump). It uses the `@extschema@` placeholder and contains no `BEGIN`/`COMMIT`,
`CREATE SCHEMA`, `CREATE EXTENSION`, or psql backslash commands. The extension
control is templated in `approx_count.control.in`, which uses a separate
`@PGFC_SCHEMA@` placeholder. After editing either source, regenerate the build
artifacts:

```bash
make render            # regenerates approx_count.control + install.sql (schema approx_count)
make render SCHEMA=x   # retarget both artifacts to schema "x"
```

Do not edit `approx_count.control` or `install.sql` directly; they are generated
from `approx_count.control.in` and `sql/approx_count--1.0.sql`, and CI checks
they are in sync.

## Tests

Run the full matrix locally (requires Docker):

```bash
./ci/run_postgres_matrix.sh        # PostgreSQL 14-18
./ci/run_postgres_matrix.sh 17     # a single version
```

The suite runs pgTAP behavioral tests, a `plpgsql_check` statement-coverage gate,
and a concurrency regression harness. CI runs the same script.

## Versioning

The extension `default_version` (currently `1.0`) maps to the matching PGXN/semver
release (`1.0.0`). For each new version, add `sql/approx_count--X.Y.sql` (the full
install) and, when the schema changes, an upgrade script
`sql/approx_count--<prev>--X.Y.sql` so existing installs can
`ALTER EXTENSION approx_count UPDATE`. Re-point `tools/render.sh` and `META.json`
at the new full-install file, list the new files in the `Makefile` `DATA`, and
bump `approx_count.control.in`, `META.json`, and `CHANGELOG.md`.
