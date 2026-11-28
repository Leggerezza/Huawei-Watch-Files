param(
  [Parameter(Mandatory=$true)][string]$In,
  [Parameter(Mandatory=$true)][string]$Out,
  [double]$Scale = 1.0
)
Add-Type -AssemblyName System.Drawing
$src = [System.Drawing.Image]::FromFile($In)
$w = $src.Width; $h = $src.Height
$bmp = New-Object System.Drawing.Bitmap $w, $h
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.DrawImage($src, 0, 0, $w, $h)
$g.Dispose()
# A round watch shows only the inscribed circle of the framebuffer.
$cx = $w / 2.0; $cy = $h / 2.0
$r = [Math]::Min($cx, $cy)
$mask = New-Object System.Drawing.Bitmap $w, $h
$mg = [System.Drawing.Graphics]::FromImage($mask)
$mg.Clear([System.Drawing.Color]::Black)
$brush = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::White)
$mg.FillEllipse($brush, [single]($cx - $r), [single]($cy - $r), [single](2 * $r), [single](2 * $r))
$mg.Dispose()
for ($y = 0; $y -lt $h; $y++) {
  for ($x = 0; $x -lt $w; $x++) {
    if ($mask.GetPixel($x, $y).R -lt 128) { $bmp.SetPixel($x, $y, [System.Drawing.Color]::Black) }
  }
}
$mask.Dispose(); $src.Dispose()
$bmp.Save($Out, [System.Drawing.Imaging.ImageFormat]::Png)
$bmp.Dispose()
Write-Output "masked -> $Out"
