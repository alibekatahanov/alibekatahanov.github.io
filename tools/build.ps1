# Legge la cartella Progetti e prepara il sito:
#  - riduce le immagini (max 1600 px di larghezza, JPG) in img/<progetto>/
#  - copia i video in img/<progetto>/
#  - genera projects.js con testi, dati e dimensioni delle immagini
# Gli originali in Progetti/ non vengono mai modificati.
#
# Uso:  powershell -ExecutionPolicy Bypass -File tools\build.ps1
#
# Regole per le cartelle dei progetti:
#  - una cartella per progetto, con numero davanti: "01. Nome progetto"
#  - info.txt con i campi (Titolo:, Sottotitolo:, Client:, ... Descrizione:)
#  - immagini e video numerati: 01.jpg, 02.png, 03.mp4 ...
#    (i file che non iniziano con un numero vengono ignorati)
#  - i progetti senza info.txt o senza immagini vengono saltati

param(
  [string]$Source = (Join-Path $PSScriptRoot "..\Progetti"),
  [string]$Out = (Join-Path $PSScriptRoot ".."),
  [int]$MaxWidth = 1600,
  [int]$Quality = 82
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Drawing

$jpegCodec = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() | Where-Object { $_.MimeType -eq "image/jpeg" }
$encParams = New-Object System.Drawing.Imaging.EncoderParameters 1
$encParams.Param[0] = New-Object System.Drawing.Imaging.EncoderParameter ([System.Drawing.Imaging.Encoder]::Quality), ([long]$Quality)

# Campi con un ruolo speciale; tutti gli altri (Client, City, Agency,
# Competition, Result...) finiscono nella tabella dati, nell'ordine del file
$specialKeys = "Titolo", "Sottotitolo", "Descrizione"

# Nome della cartella in img/, senza il numero d'ordine:
# così cambiare l'ordine dei progetti non richiede di rielaborare le immagini
function Get-Slug([string]$name) {
  $s = ($name -replace "^\d+\.?\s*", "").ToLower() -replace "[^a-z0-9]+", "-"
  return $s.Trim("-")
}

# Un campo inizia con "Nome:" all'inizio del file o dopo una riga vuota.
# Tutto quello che segue "Descrizione:" fa parte della descrizione.
function Read-Info([string]$path) {
  $lines = @(Get-Content -LiteralPath $path -Encoding UTF8)
  $fields = [ordered]@{}
  $key = $null
  $prevBlank = $true
  foreach ($line in $lines) {
    $t = $line.Trim()
    if ($key -ne "Descrizione" -and $prevBlank -and $t -match "^([A-Z][A-Za-z ]{0,30}):\s*(.*)$" -and $Matches[1] -notmatch "^https?$") {
      $key = $Matches[1].Trim()
      $fields[$key] = New-Object System.Collections.ArrayList
      if ($Matches[2].Trim()) { [void]$fields[$key].Add($Matches[2].Trim()) }
    } elseif ($key) {
      [void]$fields[$key].Add($t)
    }
    $prevBlank = ($t -eq "")
  }
  return $fields
}

# "Testo [https://...]" diventa un link; un indirizzo da solo diventa link a se stesso
function Convert-Links([string]$s) {
  $s = $s -replace "^(.+?)\s*\[(https?://[^\]\s]+)\]$", '<a href="$2" target="_blank" rel="noopener">$1</a>'
  $s = $s -replace "^\[?(https?://[^\]\s]+)\]?$", '<a href="$1" target="_blank" rel="noopener">$1</a>'
  return $s
}

# Righe consecutive unite con <br>; le righe vuote vengono tolte
function Join-Lines($list) {
  if (-not $list) { return "" }
  return ((@($list) | Where-Object { $_ -ne "" } | ForEach-Object { Convert-Links $_ }) -join "<br>")
}

# Legge larghezza e altezza di un file WebP dall'intestazione
function Get-WebpSize([string]$path) {
  $b = [IO.File]::ReadAllBytes($path)
  $chunk = [Text.Encoding]::ASCII.GetString($b, 12, 4)
  switch ($chunk) {
    "VP8X" { return @{ w = 1 + ($b[24] -bor ($b[25] -shl 8) -bor ($b[26] -shl 16)); h = 1 + ($b[27] -bor ($b[28] -shl 8) -bor ($b[29] -shl 16)) } }
    "VP8 " { return @{ w = ($b[26] -bor ($b[27] -shl 8)) -band 0x3FFF; h = ($b[28] -bor ($b[29] -shl 8)) -band 0x3FFF } }
    "VP8L" { return @{ w = 1 + ((($b[22] -band 0x3F) -shl 8) -bor $b[21]); h = 1 + ((($b[24] -band 0x0F) -shl 10) -bor ($b[23] -shl 2) -bor (($b[22] -band 0xC0) -shr 6)) } }
  }
  throw "WebP non riconosciuto: $path"
}

# Descrizione: paragrafi separati da una riga vuota
function Get-Paragraphs($list) {
  $paras = @(); $cur = @()
  foreach ($l in $list) {
    if ($l -eq "") { if ($cur.Count) { $paras += ($cur -join " "); $cur = @() } }
    else { $cur += $l }
  }
  if ($cur.Count) { $paras += ($cur -join " ") }
  return ,$paras
}

function Save-Image([string]$src, [string]$dst) {
  $img = [System.Drawing.Image]::FromFile($src)
  try {
    # Rispetta l'orientamento salvato dalla fotocamera (EXIF)
    if ($img.PropertyIdList -contains 274) {
      switch ($img.GetPropertyItem(274).Value[0]) {
        3 { $img.RotateFlip([System.Drawing.RotateFlipType]::Rotate180FlipNone) }
        6 { $img.RotateFlip([System.Drawing.RotateFlipType]::Rotate90FlipNone) }
        8 { $img.RotateFlip([System.Drawing.RotateFlipType]::Rotate270FlipNone) }
      }
    }
    $w = [Math]::Min($MaxWidth, $img.Width)
    $h = [int][Math]::Round($img.Height * $w / $img.Width)
    $bmp = New-Object System.Drawing.Bitmap $w, $h, ([System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.Clear([System.Drawing.Color]::White)   # le parti trasparenti dei PNG diventano bianche
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
    $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $g.DrawImage($img, 0, 0, $w, $h)
    $g.Dispose()
    $bmp.Save($dst, $jpegCodec, $encParams)
    $bmp.Dispose()
    return @{ w = $w; h = $h }
  } finally {
    $img.Dispose()
  }
}

# FFmpeg per comprimere i video (se installato)
$env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [Environment]::GetEnvironmentVariable("Path", "User")
$ffmpeg = (Get-Command ffmpeg -ErrorAction SilentlyContinue).Source
if (-not $ffmpeg) { Write-Host "!  FFmpeg non trovato: i video vengono copiati senza compressione" }

$projects = @()
$slugs = @()
$folders = Get-ChildItem -LiteralPath $Source -Directory | Where-Object { $_.Name -match "^\d+" } | Sort-Object Name

foreach ($folder in $folders) {
  $infoPath = Join-Path $folder.FullName "info.txt"
  $media = Get-ChildItem -LiteralPath $folder.FullName -File |
    Where-Object { $_.Name -match "^\d+.*\.(jpe?g|png|webp|mp4|webm|mov)$" } | Sort-Object Name
  $ignored = Get-ChildItem -LiteralPath $folder.FullName -File |
    Where-Object { $_.Name -ne "info.txt" -and $_.Name -notmatch "^\d+" }

  # I progetti senza immagini compaiono solo nell'elenco, come "in arrivo"
  $slug = Get-Slug $folder.Name
  $dir = Join-Path $Out "img\$slug"
  if ($media) { New-Item -ItemType Directory -Force $dir | Out-Null }

  $items = @()
  foreach ($f in @($media | Where-Object { $_ })) {
    $base = [IO.Path]::GetFileNameWithoutExtension($f.Name)
    $ext = $f.Extension.ToLower()
    if ($ext -in ".mp4", ".webm", ".mov") {
      # Video: MP4 H.264, max 1600 px di larghezza, senza audio (sul sito
      # partono da soli e muti). Senza FFmpeg vengono solo copiati.
      $outExt = if ($ffmpeg) { ".mp4" } else { $ext }
      $dst = Join-Path $dir ($base + $outExt)
      if (-not (Test-Path $dst) -or (Get-Item $dst).LastWriteTime -lt $f.LastWriteTime) {
        if ($ffmpeg) {
          & $ffmpeg -y -loglevel error -i $f.FullName -an -vf "scale='min(1600,iw)':-2" `
            -c:v libx264 -preset slow -crf 26 -pix_fmt yuv420p -movflags +faststart $dst
        } else {
          Copy-Item -LiteralPath $f.FullName $dst
        }
      }
      $mb = [Math]::Round((Get-Item $dst).Length / 1MB, 1)
      if ($mb -gt 10) { Write-Host "   ! $($f.Name): video di $mb MB, ancora pesante" }
      $items += [ordered]@{ type = "video"; src = "img/$slug/$base$outExt" }
    } elseif ($ext -eq ".webp") {
      # I WebP sono gia' leggeri e il browser li legge: vengono solo copiati
      $dst = Join-Path $dir "$base.webp"
      Copy-Item -LiteralPath $f.FullName $dst -Force
      $size = Get-WebpSize $dst
      $items += [ordered]@{ type = "image"; src = "img/$slug/$base.webp"; w = $size.w; h = $size.h }
    } else {
      $dst = Join-Path $dir "$base.jpg"
      if ((Test-Path $dst) -and (Get-Item $dst).LastWriteTime -gt $f.LastWriteTime) {
        $i = [System.Drawing.Image]::FromFile($dst); $size = @{ w = $i.Width; h = $i.Height }; $i.Dispose()
      } else {
        $size = Save-Image $f.FullName $dst
      }
      $items += [ordered]@{ type = "image"; src = "img/$slug/$base.jpg"; w = $size.w; h = $size.h }
    }
  }

  $info = if (Test-Path -LiteralPath $infoPath) { Read-Info $infoPath } else { [ordered]@{} }
  $meta = [ordered]@{}
  foreach ($k in $info.Keys) {
    if ($specialKeys -contains $k) { continue }
    $v = Join-Lines $info[$k]
    # 2026-2027 diventa 2026–2027 (trattino lungo), solo per l'anno
    if ($k -eq "Year") { $v = $v -replace "(\d)\s*[-–]\s*(\d)", ('$1' + [char]0x2013 + '$2') }
    if ($v) { $meta[$k] = $v }
  }

  # Senza titolo nel file si usa il nome della cartella (senza numero)
  $title = Join-Lines $info["Titolo"]
  if (-not $title) { $title = $folder.Name -replace "^\d+\.?\s*", "" }

  $projects += [ordered]@{
    title = $title
    sub   = Join-Lines $info["Sottotitolo"]
    meta  = $meta
    text  = Get-Paragraphs $info["Descrizione"]
    media = $items
  }
  # Toglie da img/<progetto> i file non più usati (immagini tolte o rinominate)
  if (Test-Path -LiteralPath $dir) {
    $used = $items | ForEach-Object { Split-Path $_.src -Leaf }
    Get-ChildItem -LiteralPath $dir -File | Where-Object { $used -notcontains $_.Name } | Remove-Item -Force
  }

  if ($items.Count) { Write-Host "ok $($folder.Name): $($items.Count) file" }
  else { Write-Host "-  $($folder.Name): solo nell'elenco (nessuna immagine)" }
  foreach ($x in $ignored) { Write-Host "   ! $($x.Name): ignorato (il nome non inizia con un numero)" }
  $slugs += $slug
}

# Toglie da img/ le cartelle di progetti che non esistono piu' (es. rinominati)
Get-ChildItem -LiteralPath (Join-Path $Out "img") -Directory |
  Where-Object { $slugs -notcontains $_.Name } |
  ForEach-Object { Remove-Item -LiteralPath $_.FullName -Recurse -Force; Write-Host "-  img/$($_.Name): rimossa (progetto non piu' presente)" }

$json = ConvertTo-Json -InputObject @($projects) -Depth 6
$js = "// Generato da tools/build.ps1 - non modificare a mano, modifica i file in Progetti/`n" +
      "window.PROJECTS = $json;`n"
[IO.File]::WriteAllText((Join-Path $Out "projects.js"), $js, (New-Object System.Text.UTF8Encoding $false))
Write-Host "projects.js aggiornato: $($projects.Count) progetti"
