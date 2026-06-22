# PGXS build for approx_count.
#
#   make install                       # copy control + SQL into the server's extension dir
#   CREATE EXTENSION approx_count;     -- then, inside the target database (schema is pinned)
#
# Override the target server with: make PG_CONFIG=/path/to/pg_config install
#
#   make render                        # (re)generate approx_count.control + install.sql
#   make render SCHEMA=myschema        # render both artifacts for a different schema

EXTENSION = approx_count
DATA = sql/approx_count--1.0.sql

SCHEMA ?= approx_count

PG_CONFIG ?= pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)

.PHONY: render
render:
	SCHEMA=$(SCHEMA) ./tools/render.sh
