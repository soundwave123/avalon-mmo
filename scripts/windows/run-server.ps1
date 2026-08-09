# Avalon — run the full server stack on Windows.
#
# Double-click scripts\windows\run-server.bat (which invokes this) or run from PowerShell:
#   powershell -ExecutionPolicy Bypass -File scripts\windows\run-server.ps1
#
# What it does, in order:
#   1. Starts Postgres in Docker (Docker Desktop must be installed and running)
#   2. Creates .env from .env.example with generated secrets on first run
#   3. Applies any missing database migrations (tracked in infra.schema_migrations,
#      mirroring scripts/apply-migrations.sh — already-applied files are skipped)
#   4. Launches the three servers in dependency order, each in its own window:
#      master (ws://0.0.0.0:9100) -> gateway (ws://0.0.0.0:9001) -> world (enet://0.0.0.0:9200)
#
# Requirements: Docker Desktop, and Godot 4.7.1 for Windows.
#   Download "Godot_v4.7.1-stable_win64.exe" from https://godotengine.org/download/archive/
#   and either put it next to this script, anywhere on PATH, or set GODOT_EXE to its path.

$ErrorActionPreference = "Stop"
$Root = Resolve-Path (Join-Path $PSScriptRoot "..\..")
Set-Location $Root
Write-Host "[avalon] repo root: $Root"

# ---- 1. Find Godot -----------------------------------------------------------
$godot = $env:GODOT_EXE
if (-not $godot) {
    $candidates = @(
        (Join-Path $PSScriptRoot "Godot_v4.7.1-stable_win64_console.exe"),
        (Join-Path $PSScriptRoot "Godot_v4.7.1-stable_win64.exe"),
        "Godot_v4.7.1-stable_win64_console.exe",
        "Godot_v4.7.1-stable_win64.exe",
        "godot.exe"
    )
    foreach ($c in $candidates) {
        $found = Get-Command $c -ErrorAction SilentlyContinue
        if ($found) { $godot = $found.Source; break }
        if (Test-Path $c) { $godot = $c; break }
    }
}
if (-not $godot) {
    Write-Host ""
    Write-Host "[avalon] Godot 4.7.1 not found." -ForegroundColor Red
    Write-Host "  Download Godot_v4.7.1-stable_win64.exe from:"
    Write-Host "    https://godotengine.org/download/archive/"
    Write-Host "  then place it next to this script, add it to PATH, or set GODOT_EXE."
    exit 1
}
Write-Host "[avalon] godot: $godot"

# ---- 2. Postgres via Docker --------------------------------------------------
docker info *> $null
if ($LASTEXITCODE -ne 0) {
    Write-Host "[avalon] Docker is not running. Start Docker Desktop and retry." -ForegroundColor Red
    exit 1
}
Write-Host "[avalon] starting Postgres container..."
docker compose -f (Join-Path $Root "infra\docker-compose.yml") up -d postgres
if ($LASTEXITCODE -ne 0) { Write-Host "[avalon] docker compose failed." -ForegroundColor Red; exit 1 }

Write-Host "[avalon] waiting for Postgres to be ready..."
$ready = $false
for ($i = 0; $i -lt 30; $i++) {
    docker exec avalon-postgres pg_isready -U avalon -d avalon *> $null
    if ($LASTEXITCODE -eq 0) { $ready = $true; break }
    Start-Sleep -Seconds 2
}
if (-not $ready) { Write-Host "[avalon] Postgres never became ready." -ForegroundColor Red; exit 1 }
Write-Host "[avalon] Postgres is up."

# ---- 3. .env (first run: generate secrets) -----------------------------------
$envFile = Join-Path $Root ".env"
if (-not (Test-Path $envFile)) {
    Write-Host "[avalon] no .env found — creating one from .env.example with generated secrets."
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    function New-Secret {
        $bytes = New-Object byte[] 32
        $rng.GetBytes($bytes)
        return ([System.BitConverter]::ToString($bytes) -replace "-", "").ToLower()
    }
    $content = Get-Content (Join-Path $Root ".env.example") -Raw
    $content = $content -replace "AVALON_JWT_SECRET=.*", "AVALON_JWT_SECRET=$(New-Secret)"
    $content = $content -replace "AVALON_JWT_REFRESH_SECRET=.*", "AVALON_JWT_REFRESH_SECRET=$(New-Secret)"
    Set-Content -Path $envFile -Value $content -NoNewline
}

# Load .env into this process so the three server windows inherit it.
Get-Content $envFile | ForEach-Object {
    if ($_ -match "^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$") {
        [System.Environment]::SetEnvironmentVariable($Matches[1], $Matches[2])
    }
}
if (-not $env:AVALON_PG_PASSWORD) { $env:AVALON_PG_PASSWORD = "avalon_dev_only_not_for_prod" }

# ---- 4. Migrations (tracked, skip-applied — mirrors scripts/apply-migrations.sh) ----
Write-Host "[avalon] applying database migrations..."
docker exec avalon-postgres psql -U avalon -d avalon -v ON_ERROR_STOP=1 -c `
    "CREATE SCHEMA IF NOT EXISTS infra; CREATE TABLE IF NOT EXISTS infra.schema_migrations (filename TEXT PRIMARY KEY, applied_at TIMESTAMPTZ NOT NULL DEFAULT now());" | Out-Null

$applied = 0; $skipped = 0
Get-ChildItem (Join-Path $Root "infra\postgres\migrations\*.sql") | Sort-Object Name | ForEach-Object {
    $fn = $_.Name
    $exists = docker exec avalon-postgres psql -U avalon -d avalon -tA -c `
        "SELECT EXISTS(SELECT 1 FROM infra.schema_migrations WHERE filename = '$fn');"
    if ($exists.Trim() -eq "t") { $script:skipped++; return }
    Write-Host "[avalon]   applying $fn"
    Get-Content $_.FullName -Raw | docker exec -i avalon-postgres psql -U avalon -d avalon -v ON_ERROR_STOP=1
    if ($LASTEXITCODE -ne 0) {
        Write-Host "[avalon] migration $fn FAILED — servers not started." -ForegroundColor Red
        exit 1
    }
    docker exec avalon-postgres psql -U avalon -d avalon -c `
        "INSERT INTO infra.schema_migrations (filename) VALUES ('$fn') ON CONFLICT DO NOTHING;" | Out-Null
    $script:applied++
}
Write-Host "[avalon] migrations: $applied applied, $skipped already up to date."

# ---- 5. Launch the three servers (dependency order, one window each) ---------
function Start-Service([string]$name, [string]$projectDir) {
    Write-Host "[avalon] starting $name..."
    Start-Process -FilePath $godot `
        -ArgumentList @("--headless", "--path", (Join-Path $Root $projectDir)) `
        -WindowStyle Minimized
}

Start-Service "master  (ws://0.0.0.0:9100)" "server\master"
Start-Sleep -Seconds 3   # gateway and world both connect to the master on boot
Start-Service "gateway (ws://0.0.0.0:9001)" "server\gateway"
Start-Service "world   (enet://0.0.0.0:9200)" "server\world"

Write-Host ""
Write-Host "[avalon] server stack is up:" -ForegroundColor Green
Write-Host "  master   ws://localhost:9100   (internal)"
Write-Host "  gateway  ws://localhost:9001   (clients log in here)"
Write-Host "  world    enet://localhost:9200 (clients play here)"
Write-Host ""
Write-Host "  Point a client at it: edit server.cfg next to Avalon.exe -> host=`"localhost`""
Write-Host "  Stop everything:      scripts\windows\stop-server.bat"
