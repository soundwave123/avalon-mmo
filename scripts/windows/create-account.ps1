# Avalon — create a player account on YOUR OWN server (Windows).
# Mirrors scripts/tester-accounts.sh `add`: Postgres stores sha256$<salt>$<digest>
# (digest = SHA-256 of "salt:password"); the plaintext password exists only in this
# window's final output. Run after run-server.bat has the stack up.
#
#   powershell -ExecutionPolicy Bypass -File scripts\windows\create-account.ps1 <username>

param([Parameter(Mandatory = $true)][string]$Username)

$ErrorActionPreference = "Stop"

if ($Username -cnotmatch "^[a-z0-9_-]{3,20}$") {
    Write-Host "ERROR: username must match ^[a-z0-9_-]{3,20}$ (lowercase)" -ForegroundColor Red
    exit 2
}

docker exec avalon-postgres pg_isready -U avalon -d avalon *> $null
if ($LASTEXITCODE -ne 0) {
    Write-Host "ERROR: Postgres isn't up — run scripts\windows\run-server.bat first." -ForegroundColor Red
    exit 1
}

$rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
function New-Hex([int]$bytes) {
    $b = New-Object byte[] $bytes
    $rng.GetBytes($b)
    return ([System.BitConverter]::ToString($b) -replace "-", "").ToLower()
}

$password = New-Hex 18
$salt = New-Hex 16
$sha = [System.Security.Cryptography.SHA256]::Create()
$digestBytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes("${salt}:${password}"))
$digest = ([System.BitConverter]::ToString($digestBytes) -replace "-", "").ToLower()
$hash = "sha256`$$salt`$$digest"

$sql = "INSERT INTO auth.accounts (username, password_hash) VALUES ('$Username', '$hash') " +
       "ON CONFLICT (username) DO NOTHING RETURNING username;"
$result = docker exec avalon-postgres psql -U avalon -d avalon -tA -c $sql
if ($LASTEXITCODE -ne 0) { Write-Host "ERROR: insert failed." -ForegroundColor Red; exit 1 }
if (-not $result -or $result.Trim() -ne $Username) {
    Write-Host "ERROR: account '$Username' already exists (nothing changed)." -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "Account created on your local server:" -ForegroundColor Green
Write-Host "  username: $Username"
Write-Host "  password: $password"
Write-Host ""
Write-Host "Save the password now — it is not stored anywhere in plaintext."
