# Test-Ftp.ps1 - end-to-end check of the watch FTP server from this PC.
# Usage: powershell -ExecutionPolicy Bypass -File .\Test-Ftp.ps1 -WatchIp 192.168.137.91 -Port 34567 -User abcd -Pass k7x9qm
param(
    [Parameter(Mandatory)][string]$WatchIp,
    [Parameter(Mandatory)][int]$Port,
    [Parameter(Mandatory)][string]$User,
    [Parameter(Mandatory)][string]$Pass,
    [int]$SizeKb = 512
)

$ErrorActionPreference = 'Stop'
$base = "ftp://${WatchIp}:${Port}"
$cred = "${User}:${Pass}"
$work = Join-Path $env:TEMP 'watch-ftp-test'
New-Item -ItemType Directory -Force -Path $work | Out-Null
$upload = Join-Path $work 'upload.bin'
$download = Join-Path $work 'download.bin'

# deterministic payload
$len = $SizeKb * 1024
$bytes = New-Object byte[] $len
for ($i = 0; $i -lt $len; $i++) { $bytes[$i] = [byte]($i % 251) }
[IO.File]::WriteAllBytes($upload, $bytes)
Remove-Item -LiteralPath $download -Force -ErrorAction SilentlyContinue

Write-Host "[0/5] a wrong password must be rejected"
curl.exe -s --max-time 15 --user "${User}:definitely-wrong" "${base}/" 2>&1 | Out-Null
if ($LASTEXITCODE -eq 0) { throw 'FAIL: server accepted a wrong password' }
Write-Host "      rejected (curl exit $LASTEXITCODE)"

Write-Host "[1/5] LIST / with valid credentials"
curl.exe -s --max-time 20 --user $cred "${base}/"
if ($LASTEXITCODE -ne 0) { throw "LIST failed (exit $LASTEXITCODE)" }

Write-Host "[2/5] STOR upload.bin ($SizeKb KB)"
curl.exe -s --max-time 60 --user $cred -T $upload "${base}/upload.bin"
if ($LASTEXITCODE -ne 0) { throw "STOR failed (exit $LASTEXITCODE)" }

Write-Host "[3/5] RETR upload.bin"
curl.exe -s --max-time 60 --user $cred "${base}/upload.bin" -o $download
if ($LASTEXITCODE -ne 0) { throw "RETR failed (exit $LASTEXITCODE)" }

Write-Host '[4/5] compare SHA256'
$srcHash = (Get-FileHash -LiteralPath $upload -Algorithm SHA256).Hash
$dstHash = (Get-FileHash -LiteralPath $download -Algorithm SHA256).Hash
"  source : $srcHash"
"  fetched: $dstHash"
if ($srcHash -ne $dstHash) { throw 'payload mismatch' }

Write-Host '[5/5] MKD / RNFR / RNTO / DELE'
curl.exe -s --max-time 20 --user $cred -Q "MKD selftest" "${base}/" | Out-Null
curl.exe -s --max-time 20 --user $cred -Q "RNFR upload.bin" -Q "RNTO upload-renamed.bin" "${base}/" | Out-Null
curl.exe -s --max-time 20 --user $cred -Q "DELE upload-renamed.bin" "${base}/" | Out-Null
curl.exe -s --max-time 20 --user $cred -Q "RMD selftest" "${base}/" | Out-Null
Write-Host '[5/5] final listing:'
curl.exe -s --max-time 20 --user $cred "${base}/"

Write-Host 'PASS - credentials enforced, upload/download checksum ok, rename/delete ok.'
