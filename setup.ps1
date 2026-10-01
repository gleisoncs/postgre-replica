# Starts the local Citus cluster and loads schema + test data
$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot

docker compose up -d --wait
if ($LASTEXITCODE -ne 0) { throw 'docker compose up failed' }

foreach ($f in '01-cluster.sql', '02-schema.sql', '03-seed.sql') {
    Write-Host "== $f"
    docker exec citus-coordinator psql -U postgres -v ON_ERROR_STOP=1 -f "/sql/$f"
    if ($LASTEXITCODE -ne 0) { throw "$f failed" }
}

Write-Host "`nDone. Connect with: docker exec -it citus-coordinator psql -U postgres"
