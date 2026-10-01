# PostgreSQL: Sharding (Citus) vs Replicas (OpenAI-style)

Local lab with two ways to scale PostgreSQL, using the same schema and the same data volume for comparison:

| | Folder | Strategy |
|---|---|---|
| **Citus** | `./` (root) | Sharding: data split across workers |
| **Replicas** | `./replicas` | 1 primary for writes + replicas for reads (ChatGPT architecture) |

> ⚠️ **Local testing only.** The Citus cluster uses `POSTGRES_HOST_AUTH_METHOD=trust` (accepts any connection without a password, including superuser). Passwords are hardcoded in the files. All ports listen only on `127.0.0.1`. See [Production checklist](#production-checklist).

---

## Prerequisites

- Docker Desktop running (tested with Docker 29.7 / Compose v5)
- Free ports: `5433` (Citus), `5434-5437` and `6432` (replicas)
- Port `5432` is **not** used, to avoid conflicting with an existing local PostgreSQL

## Test data (identical in both environments)

| Table | Rows | Citus | Replicas |
|---|---|---|---|
| `countries` | 4 | reference table (copy on every node) | regular table |
| `customers` | 10,000 | distributed by `id`, 32 shards | regular table |
| `orders` | 1,000,000 | distributed by `customer_id`, colocated with `customers` | regular table |

---

## 1. Citus cluster (sharding)

### Architecture

```
              app / psql
                  │
        coordinator (localhost:5433)   ← receives queries, routes them to shards
           ┌──────┴──────┐
       worker1        worker2          ← 16 shards of each distributed table
```

Image: `citusdata/citus:13.0` (PostgreSQL 17).

### Files

| File | Purpose |
|---|---|
| `docker-compose.yml` | coordinator + 2 workers |
| `setup.ps1` | starts the cluster and runs the SQL files |
| `sql/01-cluster.sql` | registers coordinator and workers |
| `sql/02-schema.sql` | creates and distributes the tables (`shard_count => 32` set explicitly) |
| `sql/03-seed.sql` | loads the test data |

### Start / connect / tear down

```powershell
.\setup.ps1                                        # start and seed
docker exec -it citus-coordinator psql -U postgres # connect
docker compose down                                # stop (keeps data)
docker compose down -v                             # stop and delete data
```

GUI client: `localhost:5433`, user `postgres`, password `postgres`.

### Queries to explore

```sql
-- With shard key: routed to 1 shard (Task Count: 1)
EXPLAIN ANALYZE SELECT * FROM orders WHERE customer_id = 42;

-- Without shard key: runs on all 32 shards in parallel (Task Count: 32)
EXPLAIN ANALYZE SELECT count(*), sum(total) FROM orders;

-- Colocated JOIN: resolved locally on each worker
SELECT c.name, count(*), sum(o.total)
FROM customers c JOIN orders o ON o.customer_id = c.id
GROUP BY c.name ORDER BY 3 DESC LIMIT 10;

-- JOIN with a reference table
SELECT co.name, sum(o.total)
FROM orders o
JOIN customers c ON c.id = o.customer_id
JOIN countries co ON co.code = c.country_code
GROUP BY co.name;

-- Where each shard lives
SELECT table_name, shard_name, nodename, pg_size_pretty(shard_size)
FROM citus_shards ORDER BY nodename, shard_name;

-- Which shard holds customer 42
SELECT get_shard_id_for_distribution_column('orders', 42);
```

### Key concepts

- **Shard key in the PK:** the distribution column must be part of the PRIMARY KEY and of any UNIQUE constraint. That is why `orders` has `PRIMARY KEY (customer_id, id)`.
- **Colocation:** `customers` and `orders` share the same distribution, so shard N of both tables lives on the same worker and a JOIN on `customer_id` moves no data over the network.
- **Reference table:** small tables (`countries`) are fully copied to every node for local JOINs.
- **Why 32 shards:** it is the Citus default (`citus.shard_count`), set explicitly in `02-schema.sql`.
  - A shard is the smallest unit Citus moves, so 32 shards let the cluster grow up to 32 workers.
  - Changing it later requires rewriting the table (`alter_distributed_table(..., shard_count := N, cascade_to_colocated := true)`).
  - Too many shards cost planning time and connections. Too few limit parallelism and rebalancing.
  - Documentation rule of thumb: 32 for small and medium clusters, 64 to 128 for large or analytical ones.
  - `shard_count` cannot be combined with `colocate_with`. `orders` inherits the 32 shards from `customers`.
- **Shards hidden from `\dt`:** since Citus 11, workers only show the "shell tables" (`orders`, `customers`...), not the physical shards (`orders_102040`...). To see the physical shards:
  ```sql
  SET citus.show_shards_for_app_name_prefixes = '*';
  \dt
  ```
  `citus_shards` on the coordinator gives the same information.

### Next experiment: scaling out

1. Add `worker3` to `docker-compose.yml`
2. `SELECT citus_add_node('worker3', 5432);`
3. `SELECT citus_rebalance_start();` and track it with `SELECT * FROM citus_rebalance_status();`

---

## 2. Primary + Replicas (OpenAI-style)

### Architecture

```
                       ┌─> replica1 (5435) ──> cascade (5437)   ← replica of a replica
   primary (5434) ─────┤
   (all writes)        └─> replica2 (5436)

   PgBouncer (6432):  app_rw → primary
                      app_ro → replica1 + replica2 (round-robin)
```

Image: `postgres:17`. Asynchronous streaming replication with replication slots.

### Files (`replicas/`)

| File | Purpose |
|---|---|
| `docker-compose.yml` | primary, replica1, replica2, cascade, pgbouncer |
| `setup.ps1` | starts everything and shows replication status |
| `init/01-replication.sh` | creates the `replicator` user and allows it in `pg_hba.conf` (primary only) |
| `init/02-schema-seed.sql` | schema and data (same as Citus, without distribution) |
| `scripts/replica-entrypoint.sh` | on first start, clones the upstream with `pg_basebackup -R` and becomes a standby |
| `pgbouncer/pgbouncer.ini` | `app_rw` and `app_ro` pools, `pool_mode = transaction` |
| `pgbouncer/userlist.txt` | PgBouncer credentials |

### Start / connect / tear down

```powershell
cd replicas
.\setup.ps1
docker exec -it pg-primary psql -U postgres     # writes
docker exec -it pg-replica1 psql -U postgres    # reads
docker compose down -v                          # delete everything
```

| Target | Host:port | Database |
|---|---|---|
| Primary | `localhost:5434` | `postgres` |
| Replica1 / Replica2 / Cascade | `localhost:5435` / `5436` / `5437` | `postgres` |
| PgBouncer writes | `localhost:6432` | `app_rw` |
| PgBouncer reads | `localhost:6432` | `app_ro` |

User/password: `postgres` / `postgres`.

### Queries to explore

```sql
-- On the primary: connected replicas and their lag
SELECT application_name, client_addr, state, replay_lag FROM pg_stat_replication;

-- On replica1: shows the cascade replica connected to it
SELECT application_name, client_addr, state FROM pg_stat_replication;

-- On a replica: confirms standby mode and shows the lag
SELECT pg_is_in_recovery(), now() - pg_last_xact_replay_timestamp() AS lag;

-- Which server the connection landed on (useful through PgBouncer)
SELECT inet_server_addr(), pg_is_in_recovery();
```

### What was validated

- All 4 nodes have 1,000,000 `orders`.
- An `INSERT` on the primary shows up on the cascade replica.
- Writing to a replica fails with `ERROR: cannot execute INSERT in a read-only transaction`.
- `app_rw` lands on the primary. With 6 concurrent reads on `app_ro`, 3 went to replica1 and 3 to replica2.
- **Sequential** reads through `app_ro` always land on the same replica: PgBouncer reuses the idle pooled connection. Round-robin only applies when it opens new server connections.

---

## Comparison: sharding vs replicas

| | Replicas (OpenAI) | Citus (sharding) |
|---|---|---|
| Scales writes | ❌ single primary | ✅ writes split across workers |
| Scales reads | ✅ add replicas | ✅ parallelized across shards |
| Data per node | full database on each | only a slice |
| Application impact | low (split reads and writes) | shard key everywhere, constraints on PK, UNIQUE and JOINs |
| Limit | size and write throughput of one machine | more complex rebalancing and operations |

With 1 million rows, timings are similar because everything fits in one machine's memory. Sharding pays off once data or write volume exceeds what a single node can handle.

### What OpenAI did ("Scaling PostgreSQL" article, 2026)

Based on secondary sources; the original article returned 403 when fetched.

- 1 primary on Azure Database for PostgreSQL Flexible Server and about 50 read replicas across multiple regions.
- **No sharding in Postgres**, by choice: it would require changing hundreds of endpoints and take months or years.
- Write-heavy workloads that could be sharded were moved to Azure Cosmos DB.
- Supporting measures: PgBouncer, multi-layer rate limiting, query simplification, workload isolation, strict schema change rules and cascading replication.

### Who uses Citus in production

Published case studies, mostly from 2016 to 2021. Current usage not verified.

- Microsoft (Windows team): 44 nodes, over 800M devices
- Algolia: a table with over 500 billion rows
- Pex: 80 billion rows updated per day
- Heap
- Cloudflare (reportedly moved this pipeline to ClickHouse around 2018; not verified)
- HSL (Helsinki public transport)
- Also listed: Neustar, Agari, Freshworks, Sportradar
- Typical use cases: real-time analytics and multi-tenant SaaS (sharding by `tenant_id`)
- Managed version: Azure Cosmos DB for PostgreSQL

---

## Production checklist

What changes compared to this lab:

1. **Authentication:** `scram-sha-256` in `pg_hba.conf`, allowing only the cluster and application networks. Never `trust`.
2. **Between Citus nodes:** `.pgpass` on each node.
3. **Secrets:** Docker secrets, Vault or the cloud secret manager. Nothing in the compose file or in git.
4. **TLS:** certificates on every node, `citus.node_conninfo = 'sslmode=verify-full'` and clients with `sslmode=verify-full`.
5. **Network:** only the coordinator or PgBouncer reachable by the application. Workers and replicas on a private network.
6. **Users:** the application uses a non-superuser account with least privilege.
7. **High availability:** primary + standby for **each** node. Patroni 3.x supports Citus natively.
8. **Backup:** pgBackRest or WAL-G per node. On Citus, `citus_create_restore_point()` gives a cluster-wide consistent point.
9. **Operations:** PgBouncer and monitoring (postgres_exporter, Prometheus, Grafana).
10. **License:** open-source Citus is AGPLv3. Check with your legal team.
11. **Where to run:** managed (Azure Cosmos DB for PostgreSQL), Kubernetes with StackGres, or VMs with Patroni. Docker Compose is not suitable for production: no failover and no multi-host.

---

## Troubleshooting

| Problem | Cause | Fix |
|---|---|---|
| `failed to connect to the docker API ... dockerDesktopLinuxEngine` | Docker Desktop is not running | Start Docker Desktop |
| `Bind for 0.0.0.0:5432 failed: port is already allocated` | another PostgreSQL/container already uses 5432 | Citus is mapped to 5433 |
| Replica exits with `pg_basebackup: error: unexpected termination of replication stream` | the replica connected to the primary's temporary server during init | `replica-entrypoint.sh` already retries (up to 30 times) and creates the slot idempotently |
| `\dt` on a worker shows no shards | Citus 11+ hides shards | `SET citus.show_shards_for_app_name_prefixes = '*';` |
| Change to `02-schema.sql` had no effect | scripts only run on creation | `docker compose down -v`, then `.\setup.ps1` |

## References

- [Citus documentation](https://docs.citusdata.com/)
- [Citus customers](https://www.citusdata.com/customers/)
- [ByteByteGo — How OpenAI Scaled to 800 Million Users With Postgres](https://blog.bytebytego.com/p/how-openai-scaled-to-800-million)
- [Pigsty — Scaling Postgres to the Next Level at OpenAI](https://pigsty.io/blog/db/openai-pg/)
- [OpenAI — Scaling PostgreSQL](https://openai.com/index/scaling-postgresql/)
