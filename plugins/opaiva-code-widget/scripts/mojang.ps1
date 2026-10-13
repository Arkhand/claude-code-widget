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


function Get-MojangUrls {
    $test = $env:CLAUDE_WIDGET_MOJANG
    if ($test) { return @{ manifest = "$test/version_manifest_v2.json"; objects = "$test/objects"; test = $true } }
    return @{ manifest = 'https://piston-meta.mojang.com/mc/game/version_manifest_v2.json'; objects = 'https://resources.download.minecraft.net'; test = $false }
}

# GET -> bytes. With $From/$To it asks for that byte range and insists on a 206 answer: a server that
# ignores Range would send the whole 40 MB jar, so the body is never read in that case.
function Invoke-HttpGet([string]$Url, [long]$From = -1, [long]$To = -1, [int]$MaxBytes = 8388608) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $req = [Net.HttpWebRequest]::Create($Url)
    $req.Timeout = 20000
    $req.ReadWriteTimeout = 20000
    $req.UserAgent = 'opaiva-code-widget'
    if ($From -ge 0) { $req.AddRange($From, $To) }
    $res = $req.GetResponse()
    try {
        $want = if ($From -ge 0) { 206 } else { 200 }
        if ([int]$res.StatusCode -ne $want) { throw "$Url : HTTP $([int]$res.StatusCode) (wanted $want)" }
        $ms = New-Object IO.MemoryStream
        $st = $res.GetResponseStream()
        $buf = New-Object byte[] 65536
        while (($n = $st.Read($buf, 0, $buf.Length)) -gt 0) {
            $ms.Write($buf, 0, $n)
            if ($ms.Length -gt $MaxBytes) { throw "$Url : more than $MaxBytes bytes" }
        }
        return , $ms.ToArray()
    }
    finally { $res.Close() }
}

function Write-McStatus([string]$Mc, [string]$State, [string]$Message = '', [string]$Version = '') {
    $o = [ordered]@{ state = $State; message = $Message; version = $Version; pid = $PID; at = (Get-Date).ToString('s') }
    $tmp = Join-Path $Mc 'status.json.tmp'
    [IO.File]::WriteAllText($tmp, ($o | ConvertTo-Json -Compress), (New-Object Text.UTF8Encoding $false))
    Move-Item -LiteralPath $tmp -Destination (Join-Path $Mc 'status.json') -Force
}

function Save-McFile([string]$Path, [byte[]]$Bytes) {
    [IO.File]::WriteAllBytes("$Path.tmp", $Bytes)
    Move-Item -LiteralPath "$Path.tmp" -Destination $Path -Force
}

# file in the cache -> name in the game's asset index
$script:McSounds = [ordered]@{
    'xp.ogg'      = 'minecraft/sounds/random/orb.ogg'
    'pop.ogg'     = 'minecraft/sounds/random/pop.ogg'
    'levelup.ogg' = 'minecraft/sounds/random/levelup.ogg'
}
# file in the cache -> entry in the client jar, tint, crop
$script:McTextures = [ordered]@{
    'dirt.png'  = @{ entry = 'assets/minecraft/textures/block/dirt.png'; tint = $null; crop = $null }
    'grass.png' = @{ entry = 'assets/minecraft/textures/block/grass_block_top.png'; tint = '#79C05A'; crop = $null }
    'orb.png'   = @{ entry = 'assets/minecraft/textures/entity/experience/experience_orb.png'; tint = '#C8FF20'; crop = @(0, 0, 16, 16) }
}

# Downloads everything into memory, and only then writes the files and "ready": a failure on the way
# leaves no half-saved theme. Returns $true when ready.
function Invoke-MojangDownload([string]$Dir) {
    $ErrorActionPreference = 'Stop'
    $mc = Join-Path $Dir 'minecraft'
    $sounds = Join-Path $mc 'sounds'
    $textures = Join-Path $mc 'textures'
    New-Item -ItemType Directory -Force -Path $sounds, $textures | Out-Null
    $version = ''
    try {
        Write-McStatus $mc 'downloading'
        $u = Get-MojangUrls
        $getJson = {
            param($url)
            if (-not (Test-MojangUrl $url $u.test)) { throw "URL not allowed: $url" }
            [Text.Encoding]::UTF8.GetString([byte[]](Invoke-HttpGet $url)) | ConvertFrom-Json
        }
        $manifest = & $getJson $u.manifest
        $rel = @($manifest.versions | Where-Object { $_.id -eq $manifest.latest.release }) | Select-Object -First 1
        if (-not $rel) { throw 'no release in the version manifest' }
        $version = [string]$rel.id
        $ver = & $getJson ([string]$rel.url)
        $index = & $getJson ([string]$ver.assetIndex.url)

        $files = [ordered]@{}   # path -> bytes, saved at the end
        foreach ($name in $script:McSounds.Keys) {
            $key = $script:McSounds[$name]
            $obj = $index.objects.$key
            if (-not $obj) { throw "sound not in the asset index: $key" }
            $hash = [string]$obj.hash
            if ($hash -notmatch '^[0-9a-f]{40}$') { throw "bad hash for $name" }
            $bytes = [byte[]](Invoke-HttpGet "$($u.objects)/$($hash.Substring(0, 2))/$hash" -1 -1 $script:McLimit)
            $sha = [BitConverter]::ToString([Security.Cryptography.SHA1]::Create().ComputeHash($bytes)).Replace('-', '').ToLower()
            if ($sha -ne $hash) { throw "wrong hash for $name" }
            $files[(Join-Path $sounds $name)] = $bytes
        }

        $jarUrl = [string]$ver.downloads.client.url
        if (-not (Test-MojangUrl $jarUrl $u.test)) { throw "URL not allowed: $jarUrl" }
        $jarLen = [long]$ver.downloads.client.size
        $read = { param($a, $b) , (Invoke-HttpGet $jarUrl $a $b 8388608) }
        $zip = Read-ZipIndex $read $jarLen @($script:McTextures.Values | ForEach-Object { $_.entry })
        foreach ($name in $script:McTextures.Keys) {
            $t = $script:McTextures[$name]
            if (-not $zip.ContainsKey($t.entry)) { throw "texture not in the jar: $($t.entry)" }
            $png = [byte[]](Get-ZipEntryBytes $read $zip[$t.entry] $script:McLimit)
            if ($png.Length -lt 8 -or $png[0] -ne 0x89 -or $png[1] -ne 0x50 -or $png[2] -ne 0x4E -or $png[3] -ne 0x47) { throw "not a PNG: $($t.entry)" }
            if ($t.tint) { $png = [byte[]](ConvertTo-TintedPng $png $t.tint $t.crop) }
            $files[(Join-Path $textures $name)] = $png
        }

        foreach ($path in $files.Keys) { Save-McFile $path ([byte[]]$files[$path]) }
        Write-McStatus $mc 'ready' '' $version
        return $true
    }
    catch {
        try { Write-McStatus $mc 'failed' ([string]$_.Exception.Message) $version } catch {}
        return $false
    }
}

if ($Dir) {
    if (Invoke-MojangDownload $Dir) { exit 0 } else { exit 1 }
}
