# Build-Hap.ps1 - assemble a signed debug HAP for the Huawei Watch (wearable).
# Usage: powershell -ExecutionPolicy Bypass -File .\Build-Hap.ps1
param(
    [string]$DevEcoHome = 'D:\Program Files\Huawei\DevEco Studio'
)

$ErrorActionPreference = 'Stop'
$DevEcoHome = (Resolve-Path -LiteralPath $DevEcoHome).Path
$env:DEVECO_SDK_HOME = Join-Path $DevEcoHome 'sdk'
$env:JAVA_HOME = Join-Path $DevEcoHome 'jbr'
$sdk = Join-Path $env:DEVECO_SDK_HOME 'default'
$env:Path = "$DevEcoHome\tools\node;$DevEcoHome\tools\ohpm\bin;$sdk\hms\toolchains\lib;$sdk\openharmony\previewer\common\bin;$env:JAVA_HOME\bin;$env:Path"

Push-Location -LiteralPath $PSScriptRoot
try {
    & "$DevEcoHome\tools\node\node.exe" "$DevEcoHome\tools\hvigor\bin\hvigorw.js" `
        --no-daemon --mode module `
        -p product=default -p module=entry@default -p buildMode=debug `
        -p requiredDeviceType=wearable `
        assembleHap
    if ($LASTEXITCODE -ne 0) { throw "Hvigor exited with code $LASTEXITCODE" }
} finally {
    Pop-Location
}

$hap = Get-ChildItem -Path (Join-Path $PSScriptRoot 'entry\build\default\outputs') -Recurse -Filter '*-signed.hap' |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
if ($hap) {
    Write-Output "HAP: $($hap.FullName)  ($([math]::Round($hap.Length / 1KB, 1)) KB)"
} else {
    Write-Output 'HAP: not found (build may have produced only an unsigned artifact)'
}
