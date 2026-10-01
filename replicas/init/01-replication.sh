#!/bin/bash
# Runs only on the primary, on first start: creates the replication user and allows it in pg_hba.
set -e

psql -v ON_ERROR_STOP=1 -U postgres -c \
  "CREATE ROLE replicator WITH REPLICATION LOGIN PASSWORD '$REPL_PASSWORD';"

echo "host replication replicator all scram-sha-256" >> "$PGDATA/pg_hba.conf"
