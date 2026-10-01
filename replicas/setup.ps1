# Starts primary + replicas + cascade + PgBouncer and shows replication status
$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot

docker compose up -d --wait
if ($LASTEXITCODE -ne 0) { throw 'docker compose up failed' }

Write-Host "`n== Replicas connected to the primary"
docker exec pg-primary psql -U postgres -c "SELECT application_name, client_addr, state, sync_state FROM pg_stat_replication;"

Write-Host "== Replicas connected to replica1 (cascade)"
docker exec pg-replica1 psql -U postgres -c "SELECT application_name, client_addr, state FROM pg_stat_replication;"

Write-Host "Done."
Write-Host "  Writes (primary):    docker exec -it pg-primary psql -U postgres"
Write-Host "  Reads (replica):     docker exec -it pg-replica1 psql -U postgres"
Write-Host "  Via PgBouncer:       localhost:6432, db app_rw or app_ro, user/password postgres"
