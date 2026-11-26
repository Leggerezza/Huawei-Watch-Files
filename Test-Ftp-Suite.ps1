# Test-Ftp-Suite.ps1 - protocol-level test suite for the watch FTP server.
#
# Uses a raw control connection (TcpClient) so it can check replies exactly,
# and opens passive data channels by hand. No external FTP client needed.
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File .\Test-Ftp-Suite.ps1 `
#       -WatchIp 192.168.137.223 -Port 56783 -User mfic -Pass pws8v6
param(
    [Parameter(Mandatory)][string]$WatchIp,
    [Parameter(Mandatory)][int]$Port,
    [Parameter(Mandatory)][string]$User,
    [Parameter(Mandatory)][string]$Pass,
    [int]$LargeMb = 8,
    [switch]$TestLockout
)

$ErrorActionPreference = 'Stop'
$script:Passed = 0
$script:Failed = 0
$script:Failures = @()

function Check {
    param([string]$Name, [bool]$Ok, [string]$Detail = '')
    if ($Ok) {
        $script:Passed++
        Write-Host ("  PASS  {0}" -f $Name) -ForegroundColor Green
    } else {
        $script:Failed++
        $script:Failures += $Name
        Write-Host ("  FAIL  {0}   {1}" -f $Name, $Detail) -ForegroundColor Red
    }
}

# --------------------------------------------------------------- FTP plumbing

function Read-Line {
    param($Stream, $Enc)
    $buf = New-Object System.Collections.Generic.List[byte]
    while ($true) {
        $b = $Stream.ReadByte()
        if ($b -lt 0) { break }
        if ($b -eq 10) { break }
        if ($b -ne 13) { $buf.Add([byte]$b) }
    }
    return $Enc.GetString($buf.ToArray())
}

function Read-Reply {
    param($Stream, $Enc)
    $lines = New-Object System.Collections.Generic.List[string]
    while ($true) {
        $l = Read-Line $Stream $Enc
        $lines.Add($l)
        if ($l.Length -lt 4) { break }
        if ($l[3] -ne '-') { break }
    }
    return $lines.ToArray()
}

function New-Control {
    $c = New-Object System.Net.Sockets.TcpClient
    $c.Connect($WatchIp, $Port)
    # A control connection can stay silent for the whole duration of a large
    # transfer, so this must be much longer than one data transfer.
    $c.ReceiveTimeout = 120000
    $s = $c.GetStream()
    # The server speaks UTF-8 (advertised in FEAT), so path arguments must be
    # encoded as UTF-8 too; ASCII would turn a Chinese name into '?'.
    $enc = [Text.Encoding]::UTF8
    $greeting = Read-Reply $s $enc
    return @{ Client = $c; Stream = $s; Enc = $enc; Greeting = $greeting }
}

function Send-Cmd {
    param($Conn, [string]$Cmd)
    $bytes = $Conn.Enc.GetBytes("$Cmd`r`n")
    $Conn.Stream.Write($bytes, 0, $bytes.Length)
    $Conn.Stream.Flush()
    return (Read-Reply $Conn.Stream $Conn.Enc)
}

function Close-Control {
    param($Conn)
    try { $Conn.Client.Close() } catch { }
}

function Login {
    param($Conn, [string]$U = $User, [string]$P = $Pass)
    $r1 = @(Send-Cmd $Conn "USER $U")
    $r2 = @(Send-Cmd $Conn "PASS $P")
    return @{ User = $r1; Pass = $r2 }
}

function Open-Pasv {
    param($Conn)
    $r = @(Send-Cmd $Conn 'PASV')
    $line = $r[-1]
    if ($line -notmatch '\((\d+),(\d+),(\d+),(\d+),(\d+),(\d+)\)') { throw "PASV failed: $line" }
    $dport = [int]$Matches[5] * 256 + [int]$Matches[6]
    $d = New-Object System.Net.Sockets.TcpClient
    $peer = $Conn.Client.Client.RemoteEndPoint.Address
    $d.Connect($peer, $dport)
    $d.ReceiveTimeout = 20000
    return $d
}

function Read-AllBytes {
    param($DataClient)
    $ms = New-Object System.IO.MemoryStream
    $buf = New-Object byte[] 65536
    $s = $DataClient.GetStream()
    while ($true) {
        $n = $s.Read($buf, 0, $buf.Length)
        if ($n -le 0) { break }
        $ms.Write($buf, 0, $n)
    }
    # The comma keeps PowerShell from unrolling an empty array into $null.
    return ,$ms.ToArray()
}

function Invoke-Download {
    param($Conn, [string]$Path)
    $d = Open-Pasv $Conn
    $r = @(Send-Cmd $Conn "RETR $Path")
    $bytes = Read-AllBytes $d
    $d.Close()
    $end = @(Read-Reply $Conn.Stream $Conn.Enc)
    return @{ Reply = ($r -join ' | '); Bytes = $bytes; End = ($end -join ' | ') }
}

function Invoke-Listing {
    param($Conn, [string]$Cmd)
    $d = Open-Pasv $Conn
    $r = @(Send-Cmd $Conn $Cmd)
    $bytes = Read-AllBytes $d
    $d.Close()
    $end = @(Read-Reply $Conn.Stream $Conn.Enc)
    return @{ Reply = ($r -join ' | '); Bytes = $bytes; End = ($end -join ' | ') }
}

function Invoke-Upload {
    param($Conn, [string]$Path, [byte[]]$Bytes, [switch]$Append)
    $d = Open-Pasv $Conn
    $verb = if ($Append) { 'APPE' } else { 'STOR' }
    $r = @(Send-Cmd $Conn "$verb $Path")
    $ds = $d.GetStream()
    $ds.Write($Bytes, 0, $Bytes.Length)
    $ds.Flush()
    $d.Close()
    $end = @(Read-Reply $Conn.Stream $Conn.Enc)
    return @{ Reply = ($r -join ' | '); End = ($end -join ' | ') }
}

# ------------------------------------------------------------------ the tests

Write-Host "`n=== 1. greeting and pre-auth gate ===" -ForegroundColor Cyan
$c = New-Control
$greeting = @($c.Greeting) -join ' '
Check 'greeting is 220' ($greeting -like '220*') $greeting
$r = @(Send-Cmd $c 'SIZE readme.txt')
Check 'SIZE before login is 530' ($r[-1] -like '530*') $r[-1]
$r = @(Send-Cmd $c 'LIST')
Check 'LIST before login is 530' ($r[-1] -like '530*') $r[-1]
$r = @(Send-Cmd $c 'PASV')
Check 'PASV before login is 530' ($r[-1] -like '530*') $r[-1]
$r = @(Send-Cmd $c 'FEAT')
Check 'FEAT before login is allowed' ($r[0] -like '211-*') $r[0]
Close-Control $c

Write-Host "`n=== 2. credential checks ===" -ForegroundColor Cyan
$c = New-Control
$r = @(Send-Cmd $c "USER nosuchuser")
Check 'unknown USER still gets 331 (no enumeration)' ($r[-1] -like '331*') $r[-1]
$r = @(Send-Cmd $c "PASS $Pass")
Check 'unknown user + valid password is rejected' ($r[-1] -like '530*') $r[-1]
Close-Control $c

$c = New-Control
$null = Send-Cmd $c "USER $User"
$r = @(Send-Cmd $c 'PASS wrong-password')
Check 'valid user + wrong password is rejected' ($r[-1] -like '530*') $r[-1]
Close-Control $c

$c = New-Control
$null = Send-Cmd $c "USER $User"
$null = Send-Cmd $c 'PASS wrong-1'
$null = Send-Cmd $c 'PASS wrong-2'
$r = @(Send-Cmd $c 'PASS wrong-3')
Check 'third bad password gets 421' ($r[-1] -like '421*') $r[-1]
$closed = $false
try {
    $c.Client.Client.Poll(300000, [System.Net.Sockets.SelectMode]::SelectRead) | Out-Null
    $closed = ($c.Client.Client.Available -eq 0)
} catch { $closed = $true }
Check 'connection dropped after 421' $closed
Close-Control $c

Write-Host "`n=== 3. login and basic commands ===" -ForegroundColor Cyan
$c = New-Control
$login = Login $c
Check 'USER gets 331' ($login.User[-1] -like '331*') $login.User[-1]
Check 'PASS gets 230' ($login.Pass[-1] -like '230*') $login.Pass[-1]
$r = @(Send-Cmd $c 'SYST')
Check 'SYST is 215 UNIX' ($r[-1] -like '215*UNIX*') $r[-1]
$r = @(Send-Cmd $c 'PWD')
Check 'PWD starts at /' ($r[-1] -like '257 "/"*') $r[-1]
$r = @(Send-Cmd $c 'TYPE I')
Check 'TYPE I accepted' ($r[-1] -like '200*') $r[-1]
$r = @(Send-Cmd $c 'PORT 127,0,0,1,10,10')
Check 'PORT rejected with 502' ($r[-1] -like '502*') $r[-1]

Write-Host "`n=== 4. path traversal is clamped ===" -ForegroundColor Cyan
$r = @(Send-Cmd $c 'CWD /../../../../')
Check 'CWD /../../ stays inside root' ($r[-1] -like '250*') $r[-1]
$r = @(Send-Cmd $c 'PWD')
Check 'PWD is still /' ($r[-1] -like '257 "/"*') $r[-1]
$r = @(Send-Cmd $c 'RETR ../../../etc/passwd')
Check 'RETR ../../../etc/passwd is 550' ($r[-1] -like '550*') $r[-1]
$r = @(Send-Cmd $c 'SIZE ../../etc/hosts')
Check 'SIZE ../../etc/hosts is 550' ($r[-1] -like '550*') $r[-1]

Write-Host "`n=== 4b. scratch workspace ===" -ForegroundColor Cyan
$r = @(Send-Cmd $c 'MKD /scratch')
Check 'MKD /scratch (or it already exists)' (($r[-1] -like '257*') -or ($r[-1] -like '550*')) $r[-1]
$r = @(Send-Cmd $c 'CWD /scratch')
Check 'CWD /scratch' ($r[-1] -like '250*') $r[-1]
# Clear anything a previous run left behind so later checks start from zero.
$pre = Invoke-Listing $c 'NLST'
foreach ($line in ([Text.Encoding]::UTF8.GetString($pre.Bytes) -split "`r`n")) {
    $n = $line.Trim()
    if ($n.Length -gt 0) { $null = Send-Cmd $c "DELE $n" }
}

Write-Host "`n=== 5. unicode name round trip ===" -ForegroundColor Cyan
# Built from code points so the test stays correct whatever encoding this
# .ps1 is read with (Windows PowerShell 5.1 assumes ANSI without a BOM).
$cn = (-join ([char]0x6D4B, [char]0x8BD5, [char]0x6587, [char]0x4EF6)) + '.bin'
$cnText = -join ([char]0x4F60, [char]0x597D, [char]0x624B, [char]0x8868)
$payload = [Text.Encoding]::UTF8.GetBytes("hello watch $cnText")
$up = Invoke-Upload $c $cn $payload
Check 'STOR unicode name gets 150/226' (($up.Reply -like '150*') -and ($up.End -like '226*')) "$($up.Reply) / $($up.End)"
$down = Invoke-Download $c $cn
Check 'RETR unicode name returns identical bytes' ([Text.Encoding]::UTF8.GetString($down.Bytes) -eq "hello watch $cnText") "got $($down.Bytes.Length) bytes"
$list = Invoke-Listing $c 'LIST'
$listing = [Text.Encoding]::UTF8.GetString($list.Bytes)
Check 'LIST shows the unicode name' ($listing -like "*$cn*")
$r = @(Send-Cmd $c "DELE $cn")
Check 'DELE unicode name ok' ($r[-1] -like '250*') $r[-1]

Write-Host "`n=== 6. SIZE / MDTM / MLSD ===" -ForegroundColor Cyan
$small = [Text.Encoding]::ASCII.GetBytes('0123456789')
$null = Invoke-Upload $c 'sizetest.txt' $small
$r = @(Send-Cmd $c 'SIZE sizetest.txt')
Check 'SIZE reports 10' ($r[-1] -eq '213 10') $r[-1]
$r = @(Send-Cmd $c 'MDTM sizetest.txt')
Check 'MDTM is 213 + 14 digits' ($r[-1] -match '^213 \d{14}$') $r[-1]
$mlsd = Invoke-Listing $c 'MLSD'
$mlsdText = [Text.Encoding]::UTF8.GetString($mlsd.Bytes)
Check 'MLSD has type/size/modify facts' ($mlsdText -match 'type=file;size=10;modify=\d{14};')
$r = @(Send-Cmd $c 'DELE sizetest.txt')
Check 'DELE ok' ($r[-1] -like '250*') $r[-1]

Write-Host "`n=== 7. APPE appends ===" -ForegroundColor Cyan
$null = Invoke-Upload $c 'appe.txt' ([Text.Encoding]::ASCII.GetBytes('AAA'))
$null = Invoke-Upload $c 'appe.txt' ([Text.Encoding]::ASCII.GetBytes('BBB')) -Append
$r = @(Send-Cmd $c 'SIZE appe.txt')
Check 'APPE grew the file to 6 bytes' ($r[-1] -eq '213 6') $r[-1]
$back = Invoke-Download $c 'appe.txt'
Check 'APPE content is AAABBB' ([Text.Encoding]::ASCII.GetString($back.Bytes) -eq 'AAABBB') ([Text.Encoding]::ASCII.GetString($back.Bytes))
$null = Send-Cmd $c 'DELE appe.txt'

Write-Host "`n=== 8. REST resume ===" -ForegroundColor Cyan
$null = Invoke-Upload $c 'rest.txt' ([Text.Encoding]::ASCII.GetBytes('0123456789'))
$r = @(Send-Cmd $c 'REST 4')
Check 'REST accepted with 350' ($r[-1] -like '350*') $r[-1]
$d = Open-Pasv $c
$r = @(Send-Cmd $c 'RETR rest.txt')
$tail = Read-AllBytes $d
$d.Close()
$null = Read-Reply $c.Stream $c.Enc
Check 'RETR after REST 4 returns the tail' ([Text.Encoding]::ASCII.GetString($tail) -eq '456789') ([Text.Encoding]::ASCII.GetString($tail))
$null = Send-Cmd $c 'DELE rest.txt'

Write-Host "`n=== 9. directory semantics ===" -ForegroundColor Cyan
$null = Send-Cmd $c 'CWD /'
$r = @(Send-Cmd $c 'MKD deep/nested/dir')
Check 'MKD creates nested path' ($r[-1] -like '257*') $r[-1]
$r = @(Send-Cmd $c 'CWD deep/nested/dir')
Check 'CWD into it' ($r[-1] -like '250*') $r[-1]
$r = @(Send-Cmd $c 'PWD')
Check 'PWD shows the nested path' ($r[-1] -like '257 "/deep/nested/dir"*') $r[-1]
$null = Send-Cmd $c 'CDUP'
$r = @(Send-Cmd $c 'PWD')
Check 'CDUP went up one level' ($r[-1] -like '257 "/deep/nested"*') $r[-1]
$null = Send-Cmd $c 'CWD /'
$r = @(Send-Cmd $c 'RMD deep')
Check 'RMD refuses a non-empty directory' ($r[-1] -like '550*') $r[-1]
$r = @(Send-Cmd $c 'DELE deep/nested/dir')
Check 'DELE on a directory is refused' ($r[-1] -like '550*') $r[-1]
$null = Send-Cmd $c 'RMD deep/nested/dir'
$null = Send-Cmd $c 'RMD deep/nested'
$r = @(Send-Cmd $c 'RMD deep')
Check 'RMD removes the empty tree bottom-up' ($r[-1] -like '250*') $r[-1]
$null = Send-Cmd $c 'CWD /scratch'

Write-Host "`n=== 10. rename ===" -ForegroundColor Cyan
$null = Invoke-Upload $c 'r1.txt' ([Text.Encoding]::ASCII.GetBytes('x'))
$r = @(Send-Cmd $c 'RNFR r1.txt')
Check 'RNFR gets 350' ($r[-1] -like '350*') $r[-1]
$r = @(Send-Cmd $c 'RNTO r2.txt')
Check 'RNTO gets 250' ($r[-1] -like '250*') $r[-1]
$r = @(Send-Cmd $c 'SIZE r1.txt')
Check 'old name is gone' ($r[-1] -like '550*') $r[-1]
$r = @(Send-Cmd $c 'SIZE r2.txt')
Check 'new name exists' ($r[-1] -eq '213 1') $r[-1]
$r = @(Send-Cmd $c 'RNTO r3.txt')
Check 'RNTO without RNFR is 503' ($r[-1] -like '503*') $r[-1]
$null = Send-Cmd $c 'DELE r2.txt'

Write-Host "`n=== 11. NLST and MLSD listings ===" -ForegroundColor Cyan
foreach ($n in 1..5) { $null = Invoke-Upload $c "many$n.txt" ([Text.Encoding]::ASCII.GetBytes("f$n")) }
$nlst = Invoke-Listing $c 'NLST'
$nlstText = [Text.Encoding]::UTF8.GetString($nlst.Bytes)
$count = ($nlstText -split "`r`n" | Where-Object { $_ -match '^many\d\.txt$' }).Count
Check 'NLST lists 5 uploaded files' ($count -eq 5) "count=$count"
$d = Open-Pasv $c
$r = @(Send-Cmd $c 'MLSD')
$mlsdText = [Text.Encoding]::UTF8.GetString((Read-AllBytes $d))
$d.Close()
$null = Read-Reply $c.Stream $c.Enc
Check 'MLSD lists the same 5 files' ((($mlsdText -split "`r`n") | Where-Object { $_ -match 'many\d\.txt' }).Count -ge 5)
foreach ($n in 1..5) { $null = Send-Cmd $c "DELE many$n.txt" }

Write-Host "`n=== 12. large transfer ($LargeMb MB) ===" -ForegroundColor Cyan
$payload = New-Object byte[] ($LargeMb * 1024 * 1024)
$rng = [System.Random]::new(12345)
$rng.NextBytes($payload)
$sw = [Diagnostics.Stopwatch]::StartNew()
$up = Invoke-Upload $c 'large.bin' $payload
$upMs = $sw.ElapsedMilliseconds
Check 'STOR large file completes' ($up.End -like '226*') "$($up.Reply) / $($up.End)"
$sw.Restart()
$down = Invoke-Download $c 'large.bin'
$downMs = $sw.ElapsedMilliseconds
Check 'RETR large file returns the same length' ($down.Bytes.Length -eq $payload.Length) "got $($down.Bytes.Length)"
$h1 = [BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash($payload))
$h2 = [BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash($down.Bytes))
Check 'SHA-256 matches on large file' ($h1 -eq $h2) "$h1 vs $h2"
Write-Host ("        upload {0} ms ({1:N1} MB/s), download {2} ms ({3:N1} MB/s)" -f `
        $upMs, ($LargeMb * 1000.0 / [Math]::Max($upMs, 1)), $downMs, ($LargeMb * 1000.0 / [Math]::Max($downMs, 1)))
$null = Send-Cmd $c 'DELE large.bin'

Write-Host "`n=== 13. concurrent clients ===" -ForegroundColor Cyan
$c2 = New-Control
$null = Login $c2
$r1 = @(Send-Cmd $c 'PWD')
$r2 = @(Send-Cmd $c2 'PWD')
Check 'two control connections are served at once' (($r1[-1] -like '257*') -and ($r2[-1] -like '257*'))
$l1 = Invoke-Listing $c 'LIST'
$l2 = Invoke-Listing $c2 'LIST'
Check 'both clients can open a data channel' (($l1.End -like '226*') -and ($l2.End -like '226*')) "$($l1.End) / $($l2.End)"
$r = @(Send-Cmd $c2 'QUIT')
Check 'QUIT gets 221' ($r[-1] -like '221*') $r[-1]
Close-Control $c2

Write-Host "`n=== 14. cleanup and final listing ===" -ForegroundColor Cyan
$scratch = Invoke-Listing $c 'LIST'
$scratchText = [Text.Encoding]::UTF8.GetString($scratch.Bytes)
Check 'scratch workspace is empty again' (($scratchText -split "`r`n" | Where-Object { $_.Trim() -ne '' }).Count -eq 0) $scratchText
$null = Send-Cmd $c 'CWD /'
$r = @(Send-Cmd $c 'RMD /scratch')
Check 'RMD /scratch' ($r[-1] -like '250*') $r[-1]
$final = Invoke-Listing $c 'LIST'
$finalText = [Text.Encoding]::UTF8.GetString($final.Bytes)
$names = @($finalText -split "`r`n" | Where-Object { $_.Trim() -ne '' })
Check 'root holds the six buckets and readme.txt' ($names.Count -eq 7) ($names -join ' | ')
$bucketsOk = $true
foreach ($b in @('Images', 'Videos', 'Audio', 'Documents', 'Archives', 'Others')) {
    if ($finalText -notmatch "(?m)^d.*\s$b\s*$") { $bucketsOk = $false }
}
Check 'all six buckets are present' $bucketsOk

Write-Host "`n=== 15. FTP keeps client paths (filing is HTTP-only) ===" -ForegroundColor Cyan
# Policy from stage 8.1: FTP must never move a file away from the path the
# client named, otherwise a follow-up SIZE/RETR on that path breaks.
$png = [byte[]](0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0)
$up = Invoke-Upload $c 'noext' $png
Check 'root upload does not report a different path' ($up.End -notlike '*Stored as*') $up.End
$r = @(Send-Cmd $c 'SIZE /noext')
Check 'the file stays at the path the client used' ($r[-1] -eq ("213 " + $png.Length)) $r[-1]
$r = @(Send-Cmd $c 'SIZE /Images/noext')
Check 'nothing was filed into /Images' ($r[-1] -like '550*') $r[-1]
$null = Send-Cmd $c 'DELE /noext'

$pdf = [byte[]](0x25, 0x50, 0x44, 0x46, 0x2D, 0x31, 0x2E, 0x34)
$null = Invoke-Upload $c 'report.pdf' $pdf
$r = @(Send-Cmd $c 'SIZE /report.pdf')
Check 'a .pdf also stays in the root' ($r[-1] -eq ("213 " + $pdf.Length)) $r[-1]
$null = Send-Cmd $c 'DELE /report.pdf'

$mp4 = [byte[]](0, 0, 0, 0x18, 0x66, 0x74, 0x79, 0x70, 0x6D, 0x70, 0x34, 0x32)
$up = Invoke-Upload $c 'clip.mp4' $mp4
Check 'a .mp4 is not moved to /Videos' ($up.End -notlike '*Stored as*') $up.End
$r = @(Send-Cmd $c 'SIZE /clip.mp4')
Check 'the .mp4 is readable at the client path' ($r[-1] -eq ("213 " + $mp4.Length)) $r[-1]
$null = Send-Cmd $c 'DELE /clip.mp4'

$r = @(Send-Cmd $c 'QUIT')
Check 'control connection closes cleanly' ($r[-1] -like '221*') $r[-1]
Close-Control $c

if ($TestLockout) {
    Write-Host "`n=== 15. login throttle (optional) ===" -ForegroundColor Cyan
    $locked = $false
    for ($i = 1; $i -le 25; $i++) {
        $lc = New-Control
        $null = Send-Cmd $lc "USER $User"
        $r = @(Send-Cmd $lc "PASS wrong-$i")
        if ($r[-1] -match '^421 .*retry in') { $locked = $true; Close-Control $lc; break }
        Close-Control $lc
    }
    Check 'repeated failures trigger a cooldown, not a shutdown' $locked
    if ($locked) {
        Write-Host '        waiting 31s for the cooldown to expire ...'
        Start-Sleep -Seconds 31
        $lc = New-Control
        $null = Send-Cmd $lc "USER $User"
        $r = @(Send-Cmd $lc "PASS $Pass")
        Check 'valid credentials work again after the cooldown' ($r[-1] -like '230*') $r[-1]
        Close-Control $lc
    }
}

Write-Host "`n================================================" -ForegroundColor Cyan
Write-Host ("  passed: {0}   failed: {1}" -f $script:Passed, $script:Failed)
if ($script:Failed -gt 0) {
    Write-Host "  failing checks:" -ForegroundColor Red
    $script:Failures | ForEach-Object { Write-Host "    - $_" -ForegroundColor Red }
    exit 1
}
Write-Host '  ALL CHECKS PASSED' -ForegroundColor Green
