# Captures the primary screen (or a region) to a PNG for visual checks.
# Usage: screenshot.ps1 <out.png> [x y width height]
param([string]$Out, [int]$X = 0, [int]$Y = 0, [int]$W = 0, [int]$H = 0, [int]$Scale = 1)
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms
$bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
if ($W -le 0) { $W = $bounds.Width - $X }
if ($H -le 0) { $H = $bounds.Height - $Y }
$bitmap = New-Object System.Drawing.Bitmap $W, $H
$graphics = [System.Drawing.Graphics]::FromImage($bitmap)
$graphics.CopyFromScreen($bounds.X + $X, $bounds.Y + $Y, 0, 0, $bitmap.Size)
$graphics.Dispose()
if ($Scale -gt 1) {
  $scaled = New-Object System.Drawing.Bitmap ($W * $Scale), ($H * $Scale)
  $g2 = [System.Drawing.Graphics]::FromImage($scaled)
  $g2.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::NearestNeighbor
  $g2.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::Half
  $g2.DrawImage($bitmap, 0, 0, $W * $Scale, $H * $Scale)
  $g2.Dispose(); $bitmap.Dispose(); $bitmap = $scaled
}
$bitmap.Save($Out, [System.Drawing.Imaging.ImageFormat]::Png)
$bitmap.Dispose()
"saved $Out ($W x $H x$Scale)"
