# Test-Http.ps1 - end-to-end checks for the watch HTTP file service.
#
# Uses curl with a cookie jar so the session flow is exercised the same way a
# browser would. Every check prints PASS/FAIL; the script exits 1 on any FAIL.
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File .\Test-Http.ps1 `
#       -WatchIp 192.168.137.223 -Port 51234 -Code 3gkm5p
param(
    [Parameter(Mandatory)][string]$WatchIp,
    [Parameter(Mandatory)][int]$Port,
    [Parameter(Mandatory)][string]$Code,
    [int]$SizeKb = 512
)

$ErrorActionPreference = 'Stop'
$base = "http://${WatchIp}:${Port}"
$work = Join-Path $env:TEMP 'watch-http-test'
New-Item -ItemType Directory -Force -Path $work | Out-Null
$jar = Join-Path $work 'cookies.txt'
Remove-Item -LiteralPath $jar -Force -ErrorAction SilentlyContinue
$anon = Join-Path $work 'anon.txt'
Remove-Item -LiteralPath $anon -Force -ErrorAction SilentlyContinue

$script:pass = 0
$script:fail = 0
function Check {
    param([string]$Name, [bool]$Ok, [string]$Detail = '')
    if ($Ok) {
        $script:pass++
        Write-Host ("  PASS  {0}" -f $Name) -ForegroundColor Green
    } else {
        $script:fail++
        Write-Host ("  FAIL  {0}   {1}" -f $Name, $Detail) -ForegroundColor Red
    }
}

function Status {
    param([string]$Url, [string[]]$Extra = @())
    $args = @('-s', '-o', 'NUL', '-w', '%{http_code}', '--max-time', '20') + $Extra + @($Url)
    return (curl.exe @args 2>&1)
}

Write-Host "`n=== 1. authentication gate ===" -ForegroundColor Cyan
$st = Status "$base/" @('-c', $anon)
Check 'unauthenticated GET / is 401' ($st -eq '401') "code=$st"

$body = curl.exe -s --max-time 20 -b $anon "$base/" 2>&1 | Out-String
Check 'login page renders' ($body -match '访问码' -and $body -match '<form') 'no login form in body'

$st = curl.exe -s -o NUL -w '%{http_code}' --max-time 20 -c $jar -d 'code=wrongcode' "$base/login" 2>&1
Check 'wrong access code is rejected' ($st -eq '401') "code=$st"

$st = curl.exe -s -o NUL -w '%{http_code}' --max-time 20 -c $jar -d "code=$Code" "$base/login" 2>&1
Check 'correct access code returns 302' ($st -eq '302') "code=$st"

$html = curl.exe -s --max-time 20 -b $jar "$base/" 2>&1 | Out-String
Check 'authenticated GET / returns the browser' ($html -match '手表文件' -and $html -match 'name="csrf"') 'browser not rendered'

$csrf = ''
if ($html -match 'name="csrf"\s+value="([0-9a-fA-F]+)"') { $csrf = $Matches[1] }
Check 'page carries a csrf token' ($csrf.Length -ge 16) "csrf='$csrf'"

Write-Host "`n=== 2. traversal and error handling ===" -ForegroundColor Cyan
$st = Status "$base/?p=%2F..%2F..%2F..%2F..%2Fetc" @('-b', $jar)
Check 'traversal in ?p lands on a missing path, not a system one' ($st -eq '404') "code=$st"
$body2 = curl.exe -s --max-time 20 -b $jar "$base/?p=%2F../../../../etc" 2>&1 | Out-String
Check 'traversal does not expose /etc' (-not ($body2 -match 'passwd')) 'unexpected system file content'

$st = Status "$base/dl?p=%2Fnope.bin" @('-b', $jar)
Check 'missing download is 404' ($st -eq '404') "code=$st"

$chunked = curl.exe -s -o NUL -w '%{http_code}' --max-time 20 -b $jar -H 'Transfer-Encoding: chunked' -X POST "$base/upload?p=%2F&name=x.bin&csrf=$csrf" 2>&1
Check 'chunked body is rejected with 501' ($chunked -eq '501') "code=$chunked"

Write-Host "`n=== 3. upload, download, range ===" -ForegroundColor Cyan
$len = $SizeKb * 1024
$bytes = New-Object byte[] $len
for ($i = 0; $i -lt $len; $i++) { $bytes[$i] = [byte]($i % 251) }
$src = Join-Path $work 'payload.bin'
[IO.File]::WriteAllBytes($src, $bytes)

$resp = curl.exe -s --max-time 60 -b $jar -X PUT --data-binary "@$src" "$base/upload?p=%2F&name=http-test.bin&csrf=$csrf" 2>&1 | Out-String
Check 'upload returns JSON ok' ($resp -match '"ok":true') $resp
$filed = ''
if ($resp -match '"path"\s*:\s*"([^"]+)"') { $filed = $Matches[1] }
Check 'upload reports the final path' ($filed -like '*/http-test.bin') "path='$filed'"
$filedDir = ''
if ($filed -match '^(.*)/[^/]+$') { $filedDir = $Matches[1] }
if ($filedDir -eq '') { $filedDir = '/' }
$filedQ = [uri]::EscapeDataString($filed)
$dirQ = [uri]::EscapeDataString($filedDir)

$list = curl.exe -s --max-time 20 -b $jar "$base/?p=$dirQ" 2>&1 | Out-String
Check 'uploaded file appears in its directory' ($list -match 'http-test\.bin') "dir=$filedDir"

$dst = Join-Path $work 'fetched.bin'
Remove-Item -LiteralPath $dst -Force -ErrorAction SilentlyContinue
curl.exe -s --max-time 60 -b $jar "$base/dl?p=$filedQ" -o $dst 2>&1 | Out-Null
$h1 = if (Test-Path $dst) { (Get-FileHash $src -Algorithm SHA256).Hash } else { '' }
$h2 = if (Test-Path $dst) { (Get-FileHash $dst -Algorithm SHA256).Hash } else { '' }
Check 'download round trip matches SHA-256' ($h1 -ne '' -and $h1 -eq $h2) "$h1 vs $h2"

$range = curl.exe -s --max-time 20 -b $jar -r 100-199 -o "$work/range.bin" -w '%{http_code}' "$base/dl?p=$filedQ" 2>&1
$rangeLen = if (Test-Path "$work/range.bin") { (Get-Item "$work/range.bin").Length } else { 0 }
Check 'range request returns 206 and 100 bytes' ($range -eq '206' -and $rangeLen -eq 100) "code=$range len=$rangeLen"

Write-Host "`n=== 4. mutations ===" -ForegroundColor Cyan
$mk = curl.exe -s -o NUL -w '%{http_code}' --max-time 20 -b $jar -d "csrf=$csrf&p=%2F&name=httptestdir" "$base/mkdir" 2>&1
Check 'mkdir returns a redirect' ($mk -eq '303') "code=$mk"

$filedEnc = [uri]::EscapeDataString($filed)
$renamed = "$filedDir/renamed.bin"
$renamedEnc = [uri]::EscapeDataString($renamed)
$rn = curl.exe -s -o NUL -w '%{http_code}' --max-time 20 -b $jar -d "csrf=$csrf&p=$filedEnc&name=renamed.bin" "$base/rename" 2>&1
Check 'rename succeeds' ($rn -eq '200') "code=$rn"

$bad = curl.exe -s -o NUL -w '%{http_code}' --max-time 20 -b $jar -d "csrf=deadbeef&p=$renamedEnc&name=x.bin" "$base/rename" 2>&1
Check 'a wrong csrf token is refused' ($bad -eq '403') "code=$bad"

$del = curl.exe -s -o NUL -w '%{http_code}' --max-time 20 -b $jar -d "csrf=$csrf&p=$renamedEnc" "$base/delete" 2>&1
Check 'delete succeeds' ($del -eq '200') "code=$del"

$rmd = curl.exe -s -o NUL -w '%{http_code}' --max-time 20 -b $jar -d "csrf=$csrf&p=%2Fhttptestdir" "$base/delete" 2>&1
Check 'removing the empty test dir succeeds' ($rmd -eq '200') "code=$rmd"

Write-Host "`n=== 5. session hygiene ===" -ForegroundColor Cyan
$logout = Status "$base/health" @('-b', $jar)
Check '/health answers when authorised' ($logout -eq '200') "code=$logout"

$anonHealth = Status "$base/health" @('-b', $anon)
Check '/health requires auth' ($anonHealth -eq '401') "code=$anonHealth"

Write-Host "`n================================================" -ForegroundColor Cyan
Write-Host ("  passed: {0}   failed: {1}" -f $script:pass, $script:fail)
if ($script:fail -gt 0) { exit 1 }
Write-Host '  ALL HTTP CHECKS PASSED' -ForegroundColor Green

