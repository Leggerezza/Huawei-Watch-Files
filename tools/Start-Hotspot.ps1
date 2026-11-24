# Start-Hotspot.ps1 - bring the Windows mobile hotspot back up (WinRT, PS 5.1 only).
#
# Why: Windows 11 turns the hotspot off once no device is connected for a while.
# If the watch then sleeps, it can never rejoin and hdc goes offline forever --
# a deadlock that looks like "the watch keeps disconnecting".
#
# Run with Windows PowerShell (not pwsh 7):
#   powershell -ExecutionPolicy Bypass -File .\tools\Start-Hotspot.ps1
param(
    [string]$ExpectedGateway = '192.168.137.1'
)

$ErrorActionPreference = 'Stop'

$existing = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object { $_.IPAddress -eq $ExpectedGateway }
if ($existing) {
    Write-Host "[hotspot] already up at $ExpectedGateway ($($existing.InterfaceAlias))"
    exit 0
}

Add-Type -AssemblyName System.Runtime.WindowsRuntime
$asTaskGeneric = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
    $_.Name -eq 'AsTask' -and
    $_.GetParameters().Count -eq 1 -and
    $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
})[0]

function Await($WinRtTask, $ResultType) {
    $asTask = $asTaskGeneric.MakeGenericMethod($ResultType)
    $netTask = $asTask.Invoke($null, @($WinRtTask))
    $netTask.Wait(-1) | Out-Null
    $netTask.Result
}

$null = [Windows.Networking.Connectivity.NetworkInformation, Windows.Networking.Connectivity, ContentType = WindowsRuntime]
$null = [Windows.Networking.NetworkOperators.NetworkOperatorTetheringManager, Windows.Networking.NetworkOperators, ContentType = WindowsRuntime]

$profile = [Windows.Networking.Connectivity.NetworkInformation]::GetInternetConnectionProfile()
if (-not $profile) { throw 'no internet connection profile to share' }
Write-Host "[hotspot] sharing network: $($profile.ProfileName)"

$mgr = [Windows.Networking.NetworkOperators.NetworkOperatorTetheringManager]::CreateFromConnectionProfile($profile)
$result = Await ($mgr.StartTetheringAsync()) ([Windows.Networking.NetworkOperators.NetworkOperatorTetheringOperationResult])
Write-Host "[hotspot] start result: $($result.Status) $($result.AdditionalErrorMessage)"

Start-Sleep -Seconds 2
$now = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object { $_.IPAddress -eq $ExpectedGateway }
if ($now) {
    Write-Host "[hotspot] up at $ExpectedGateway ($($now.InterfaceAlias)); the watch should rejoin within ~30s"
} else {
    Write-Warning "[hotspot] gateway $ExpectedGateway still missing; enable Mobile hotspot manually in Settings"
}
