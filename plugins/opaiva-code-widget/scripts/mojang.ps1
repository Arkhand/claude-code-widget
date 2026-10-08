# opaiva-code-widget: downloads the Minecraft theme's textures and sounds from Mojang's servers (the ones
# the game launcher uses) into <data folder>\minecraft\. Nothing from Mojang is part of this repository.
# Started in the background by widget.ps1 when you pick the Minecraft theme:
#   powershell -File mojang.ps1 -Dir <data folder>
# Without -Dir the file only defines its functions (the tests read it that way).
# Keep this file ASCII-only (Windows PowerShell 5.1 reads BOM-less files as ANSI).
param([string]$Dir = '')

$script:MojangHosts = @('piston-meta.mojang.com', 'piston-data.mojang.com', 'launchermeta.mojang.com', 'resources.download.minecraft.net')
$script:McLimit = 2097152   # no single file we keep is bigger than 2 MB

function Get-Crc32([byte[]]$Data) {
    if (-not $script:crcTable) {
        $t = New-Object 'long[]' 256
        for ($i = 0; $i -lt 256; $i++) {
            [long]$c = $i
            for ($k = 0; $k -lt 8; $k++) {
                if ($c -band 1) { $c = 3988292384 -bxor ($c -shr 1) } else { $c = $c -shr 1 }
            }
            $t[$i] = $c
        }
        $script:crcTable = $t
    }
    [long]$crc = 4294967295
    foreach ($b in $Data) { $crc = $script:crcTable[($crc -bxor $b) -band 255] -bxor ($crc -shr 8) }
    return ($crc -bxor 4294967295)
}

# Entries of a zip read through $ReadRange { param($from, $to) } (inclusive byte range), without
# downloading the whole file: the end record, then the central directory. With $Want, stops once
# every wanted name has been found.
function Read-ZipIndex([scriptblock]$ReadRange, [long]$Length, [string[]]$Want = $null) {
    $tail = [byte[]](& $ReadRange ([math]::Max(0, $Length - 65557)) ($Length - 1))
    $e = -1
    for ($i = $tail.Length - 22; $i -ge 0; $i--) {
        if ($tail[$i] -eq 0x50 -and $tail[$i + 1] -eq 0x4B -and $tail[$i + 2] -eq 5 -and $tail[$i + 3] -eq 6) { $e = $i; break }
    }
    if ($e -lt 0) { throw 'zip: end record not found' }
    $count = [BitConverter]::ToUInt16($tail, $e + 10)
    $cdSize = [long][BitConverter]::ToUInt32($tail, $e + 12)
    $cdOff = [long][BitConverter]::ToUInt32($tail, $e + 16)
    if ($count -eq 65535 -or $cdSize -eq 4294967295 -or $cdOff -eq 4294967295) { throw 'zip: zip64 is not supported' }
    if ($cdSize -gt 16777216) { throw 'zip: directory too big' }
    $cd = [byte[]](& $ReadRange $cdOff ($cdOff + $cdSize - 1))
    $wanted = @{}
    foreach ($w in @($Want)) { if ($w) { $wanted[$w] = $true } }
    $left = $wanted.Count
    $index = @{}
    $p = 0
    for ($n = 0; $n -lt $count; $n++) {
        if ($p + 46 -gt $cd.Length -or [BitConverter]::ToUInt32($cd, $p) -ne 33639248) { throw 'zip: bad directory' }
        $nl = [BitConverter]::ToUInt16($cd, $p + 28)
        $el = [BitConverter]::ToUInt16($cd, $p + 30)
        $cl = [BitConverter]::ToUInt16($cd, $p + 32)
        $name = [Text.Encoding]::UTF8.GetString($cd, $p + 46, $nl)
        $index[$name] = @{
            method = [int][BitConverter]::ToUInt16($cd, $p + 10)
            crc    = [long][BitConverter]::ToUInt32($cd, $p + 16)
            csize  = [long][BitConverter]::ToUInt32($cd, $p + 20)
            usize  = [long][BitConverter]::ToUInt32($cd, $p + 24)
            offset = [long][BitConverter]::ToUInt32($cd, $p + 42)
        }
        $p += 46 + $nl + $el + $cl
        if ($wanted.Count -gt 0 -and $wanted.ContainsKey($name)) {
            $left--
            if ($left -le 0) { break }
        }
    }
    return $index
}

# One entry's bytes, inflated, checked against the size and CRC32 in the directory
function Get-ZipEntryBytes([scriptblock]$ReadRange, [hashtable]$Entry, [long]$MaxBytes = 2097152) {
    if ($Entry.usize -gt $MaxBytes -or $Entry.csize -gt $MaxBytes) { throw 'zip: entry too big' }
    $h = [byte[]](& $ReadRange $Entry.offset ($Entry.offset + 29))
    if ([BitConverter]::ToUInt32($h, 0) -ne 67324752) { throw 'zip: bad local header' }
    $start = $Entry.offset + 30 + [BitConverter]::ToUInt16($h, 26) + [BitConverter]::ToUInt16($h, 28)
    $raw = if ($Entry.csize -gt 0) { [byte[]](& $ReadRange $start ($start + $Entry.csize - 1)) } else { New-Object byte[] 0 }
    if ($Entry.method -eq 0) { $out = $raw }
    elseif ($Entry.method -eq 8) {
        $ds = New-Object IO.Compression.DeflateStream (New-Object IO.MemoryStream (, $raw)), ([IO.Compression.CompressionMode]::Decompress)
        $o = New-Object IO.MemoryStream
        $buf = New-Object byte[] 65536
        while (($n = $ds.Read($buf, 0, $buf.Length)) -gt 0) {
            $o.Write($buf, 0, $n)
            if ($o.Length -gt $MaxBytes) { throw 'zip: entry too big' }
        }
        $out = $o.ToArray()
    }
    else { throw "zip: method $($Entry.method) is not supported" }
    if ($out.Length -ne $Entry.usize) { throw 'zip: wrong size' }
    if ((Get-Crc32 $out) -ne $Entry.crc) { throw 'zip: wrong CRC' }
    return , $out
}

# PNG bytes -> PNG bytes: optional crop @(x, y, w, h), every color channel multiplied by the tint
# (Mojang keeps grass and XP orbs in gray and tints them in the game)
function ConvertTo-TintedPng([byte[]]$Png, [string]$TintHex, [int[]]$Crop = $null) {
    Add-Type -AssemblyName System.Drawing
    $src = [System.Drawing.Bitmap]::FromStream((New-Object IO.MemoryStream (, $Png)))
    try {
        $x = 0; $y = 0; $w = $src.Width; $h = $src.Height
        if ($Crop) { $x, $y, $w, $h = $Crop }
        if ($w -le 0 -or $h -le 0 -or $x -lt 0 -or $y -lt 0 -or ($x + $w) -gt $src.Width -or ($y + $h) -gt $src.Height) { throw 'png: crop is outside the image' }
        $tint = [System.Drawing.ColorTranslator]::FromHtml($TintHex)
        $out = New-Object System.Drawing.Bitmap $w, $h, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        try {
            for ($j = 0; $j -lt $h; $j++) {
                for ($i = 0; $i -lt $w; $i++) {
                    $c = $src.GetPixel($x + $i, $y + $j)
                    $out.SetPixel($i, $j, [System.Drawing.Color]::FromArgb($c.A, [int]($c.R * $tint.R / 255), [int]($c.G * $tint.G / 255), [int]($c.B * $tint.B / 255)))
                }
            }
            $ms = New-Object IO.MemoryStream
            $out.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
            return , $ms.ToArray()
        }
        finally { $out.Dispose() }
    }
    finally { $src.Dispose() }
}

# Only https on the Mojang hosts (every URL comes from a JSON the server sent). $AllowAny is the test mode.
function Test-MojangUrl([string]$Url, [bool]$AllowAny) {
    if ($AllowAny) { return $true }
    try {
        $u = [Uri]$Url
        return ($u.Scheme -eq 'https' -and ($script:MojangHosts -contains $u.Host))
    } catch { return $false }
}
