#!/bin/bash
# On first start, clones the upstream with pg_basebackup and becomes a standby (-R).
set -e

export PGPASSWORD="$REPL_PASSWORD"

if [ ! -s "$PGDATA/PG_VERSION" ]; then
  # retry: the upstream may restart right after init (entrypoint temporary server)
  for attempt in $(seq 1 30); do
    echo "Attempt $attempt: cloning $UPSTREAM_HOST (slot $SLOT_NAME)..."
    if pg_isready -h "$UPSTREAM_HOST" -U replicator -q \
      && psql -h "$UPSTREAM_HOST" -U replicator -d postgres -qtAc \
           "SELECT pg_create_physical_replication_slot('$SLOT_NAME')
            WHERE NOT EXISTS (SELECT 1 FROM pg_replication_slots WHERE slot_name = '$SLOT_NAME')" \
      && pg_basebackup -h "$UPSTREAM_HOST" -U replicator -D "$PGDATA" -X stream -R -S "$SLOT_NAME"; then
      break
    fi
    rm -rf "${PGDATA:?}"/*
    sleep 2
  done
  [ -s "$PGDATA/PG_VERSION" ] || { echo "Failed to clone $UPSTREAM_HOST"; exit 1; }
  chmod 700 "$PGDATA"
fi

exec postgres -c hot_standby_feedback=on
