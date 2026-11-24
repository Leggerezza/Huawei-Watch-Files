# Deploy-Hap.ps1 - wait for the watch, install the HAP and launch it.
# Requires a signed HAP: enable automatic signing once in DevEco Studio
# (File > Project Structure > Signing Configs > Automatically generate signature).
param(
    [string]$Device = '192.168.137.91:44219',
    [string]$Hap = '',
    [int]$WaitSeconds = 180,
    [string]$DevEcoHome = 'D:\Program Files\Huawei\DevEco Studio',
    [string]$BundleName = 'io.github.leggerezza.files',
    [string]$AbilityName = 'EntryAbility'
)

$ErrorActionPreference = 'Stop'
$HDC = Join-Path $DevEcoHome 'sdk\default\openharmony\toolchains\hdc.exe'
if (-not (Test-Path -LiteralPath $HDC)) { throw "hdc not found: $HDC" }
if ([string]::IsNullOrWhiteSpace($Hap)) {
    $Hap = Join-Path $PSScriptRoot 'entry\build\default\outputs\default\entry-default-signed.hap'
}
if (-not (Test-Path -LiteralPath $Hap)) {
    throw "signed HAP not found: $Hap`nEnable automatic signing in DevEco Studio, then rebuild."
}

function Invoke-HdcTimed {
    param([string[]]$HdcArgs, [int]$TimeoutMs = 25000)
    $outFile = [IO.Path]::GetTempFileName()
    $errFile = [IO.Path]::GetTempFileName()
    try {
        $p = Start-Process -FilePath $HDC -ArgumentList $HdcArgs -NoNewWindow -PassThru `
            -RedirectStandardOutput $outFile -RedirectStandardError $errFile
        if (-not $p.WaitForExit($TimeoutMs)) {
            try { $p.Kill() } catch { }
            return @{ ok = $false; output = 'timeout' }
        }
        $text = (Get-Content -LiteralPath $outFile -Raw -ErrorAction SilentlyContinue) +
                (Get-Content -LiteralPath $errFile -Raw -ErrorAction SilentlyContinue)
        return @{ ok = $true; output = "$text" }
    } finally {
        Remove-Item -LiteralPath $outFile, $errFile -Force -ErrorAction SilentlyContinue
    }
}

$deadline = (Get-Date).AddSeconds($WaitSeconds)
$online = $false
while ((Get-Date) -lt $deadline) {
    $r = Invoke-HdcTimed -HdcArgs @('list', 'targets', '-v') -TimeoutMs 15000
    if ($r.ok -and $r.output -match [regex]::Escape($Device) -and $r.output -match 'Connected') {
        $online = $true
        break
    }
    Write-Host "[deploy] waiting for $Device ..."
    Invoke-HdcTimed -HdcArgs @('tconn', $Device) -TimeoutMs 8000 | Out-Null
    Start-Sleep -Seconds 2
}
if (-not $online) {
    throw "watch still offline at $Device. Check the watch Wi-Fi and the wireless-debugging port (changes after reboot)."
}
Write-Host "[deploy] device online: $Device"

$r = Invoke-HdcTimed -HdcArgs @('-t', $Device, 'install', '-r', $Hap) -TimeoutMs 180000
Write-Host "[deploy] install: $($r.output.Trim())"
if ($r.output -notmatch 'success') { throw "install failed: $($r.output)" }

$r = Invoke-HdcTimed -HdcArgs @('-t', $Device, 'shell', "aa start -a $AbilityName -b $BundleName") -TimeoutMs 30000
Write-Host "[deploy] launch: $($r.output.Trim())"
