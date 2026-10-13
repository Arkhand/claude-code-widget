# A fake Mojang for the tests: a local HttpListener that serves a version manifest, a version JSON,
# an asset index, three sound objects and a small client.jar, with HTTP Range support.
# Needs System.Drawing and System.IO.Compression loaded.

function New-FakePng([int]$W, [int]$H, $Color) {
    $bmp = New-Object System.Drawing.Bitmap $W, $H
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.Clear($Color)
    $g.Dispose()
    $ms = New-Object IO.MemoryStream
    $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    return , $ms.ToArray()
}

function Get-Sha1Hex([byte[]]$Bytes) {
    [BitConverter]::ToString([Security.Cryptography.SHA1]::Create().ComputeHash($Bytes)).Replace('-', '').ToLower()
}

function Start-FakeMojang {
    $routes = [hashtable]::Synchronized(@{})
    $l = $null
    for ($try = 0; $try -lt 30 -and -not $l; $try++) {
        $port = Get-Random -Minimum 20000 -Maximum 60000
        $cand = New-Object System.Net.HttpListener
        $cand.Prefixes.Add("http://127.0.0.1:$port/")
        try { $cand.Start(); $l = $cand } catch { $cand.Close() }
    }
    if (-not $l) { throw 'no free port for the fake Mojang' }
    $ps = [powershell]::Create()
    [void]$ps.AddScript({
            param($l, $routes)
            while ($l.IsListening) {
                try { $ctx = $l.GetContext() } catch { break }
                try {
                    $path = $ctx.Request.Url.AbsolutePath
                    if (-not $routes.ContainsKey($path)) { $ctx.Response.StatusCode = 404; $ctx.Response.Close(); continue }
                    [byte[]]$body = $routes[$path]
                    $range = $ctx.Request.Headers['Range']
                    if ($range -and $range -match '^bytes=(\d+)-(\d+)$' -and -not $routes.ContainsKey('__norange')) {
                        $a = [long]$Matches[1]
                        $b = [math]::Min([long]$Matches[2], $body.Length - 1)
                        $len = $b - $a + 1
                        $ctx.Response.StatusCode = 206
                        $ctx.Response.ContentLength64 = $len
                        $ctx.Response.OutputStream.Write($body, [int]$a, [int]$len)
                    }
                    else {
                        $ctx.Response.ContentLength64 = $body.Length
                        $ctx.Response.OutputStream.Write($body, 0, $body.Length)
                    }
                    $ctx.Response.Close()
                }
                catch { try { $ctx.Response.Abort() } catch {} }
            }
        }).AddArgument($l).AddArgument($routes)
    $handle = $ps.BeginInvoke()
    return @{ Url = "http://127.0.0.1:$port"; Listener = $l; Ps = $ps; Handle = $handle; Routes = $routes }
}

function Stop-FakeMojang($Server) {
    try { $Server.Listener.Stop(); $Server.Listener.Close() } catch {}
    try { $Server.Ps.Dispose() } catch {}
}

# Fills the routes. Options: BadSound (the xp sound is served with other bytes than its hash),
# NoRange (the server ignores Range), NoJarEntry (the jar lacks the dirt texture).
# Returns the original files, to compare with what the download saved.
function New-FakeMojangRoutes($Server, [hashtable]$Options = @{}) {
    Add-Type -AssemblyName System.Drawing, System.IO.Compression
    $url = $Server.Url
    $r = $Server.Routes
    $dirt = New-FakePng 16 16 ([System.Drawing.Color]::FromArgb(255, 255, 0, 0))
    $grass = New-FakePng 16 16 ([System.Drawing.Color]::FromArgb(255, 128, 128, 128))
    $orb = New-FakePng 64 64 ([System.Drawing.Color]::FromArgb(255, 128, 128, 128))
    $entries = @{
        'assets/minecraft/textures/block/grass_block_top.png'           = $grass
        'assets/minecraft/textures/entity/experience/experience_orb.png' = $orb
    }
    if (-not $Options.NoJarEntry) { $entries['assets/minecraft/textures/block/dirt.png'] = $dirt }
    1..300 | ForEach-Object { $entries["assets/minecraft/filler/f$_.txt"] = [Text.Encoding]::UTF8.GetBytes("filler $_") }
    $ms = New-Object IO.MemoryStream
    $zip = New-Object IO.Compression.ZipArchive $ms, ([IO.Compression.ZipArchiveMode]::Create), $true
    foreach ($name in $entries.Keys) {
        $e = $zip.CreateEntry($name, [IO.Compression.CompressionLevel]::Optimal)
        $s = $e.Open()
        $b = [byte[]]$entries[$name]
        $s.Write($b, 0, $b.Length)
        $s.Dispose()
    }
    $zip.Dispose()
    $jar = $ms.ToArray()
    $sounds = @{
        'minecraft/sounds/random/orb.ogg'     = [byte[]](@(0x4F, 0x67, 0x67, 0x53) + (1..60))
        'minecraft/sounds/random/pop.ogg'     = [byte[]](@(0x4F, 0x67, 0x67, 0x53) + (61..140))
        'minecraft/sounds/random/levelup.ogg' = [byte[]](@(0x4F, 0x67, 0x67, 0x53) + (141..250))
    }
    $objects = [ordered]@{}
    foreach ($k in $sounds.Keys) {
        $hash = Get-Sha1Hex $sounds[$k]
        $objects[$k] = @{ hash = $hash; size = $sounds[$k].Length }
        $served = $sounds[$k]
        if ($Options.BadSound -and $k -like '*orb.ogg') { $served = [byte[]](@(0x4F, 0x67, 0x67, 0x53) + (200..210)) }
        $r["/objects/$($hash.Substring(0, 2))/$hash"] = $served
    }
    $enc = New-Object Text.UTF8Encoding $false
    $r['/idx/34.json'] = $enc.GetBytes((@{ objects = $objects } | ConvertTo-Json -Depth 5 -Compress))
    $r['/client.jar'] = $jar
    $ver = @{ id = '9.9'; assetIndex = @{ id = '34'; url = "$url/idx/34.json" }; downloads = @{ client = @{ url = "$url/client.jar"; size = $jar.Length } } }
    $r['/v/9.9.json'] = $enc.GetBytes(($ver | ConvertTo-Json -Depth 6 -Compress))
    $manifest = @{ latest = @{ release = '9.9'; snapshot = '9.9' }; versions = @(@{ id = '9.9'; type = 'release'; url = "$url/v/9.9.json" }) }
    $r['/version_manifest_v2.json'] = $enc.GetBytes(($manifest | ConvertTo-Json -Depth 6 -Compress))
    if ($Options.NoRange) { $r['__norange'] = [byte[]]@(1) }
    return @{ dirt = $dirt; xp = $sounds['minecraft/sounds/random/orb.ogg']; pop = $sounds['minecraft/sounds/random/pop.ogg']; levelup = $sounds['minecraft/sounds/random/levelup.ogg'] }
}

# A ready Minecraft cache with synthetic files (dirt: solid red), for the widget tests
function New-FakeMinecraftCache([string]$Dir) {
    Add-Type -AssemblyName System.Drawing
    $mc = Join-Path $Dir 'minecraft'
    New-Item -ItemType Directory -Force -Path (Join-Path $mc 'textures'), (Join-Path $mc 'sounds') | Out-Null
    [IO.File]::WriteAllBytes((Join-Path (Join-Path $mc 'textures') 'dirt.png'), (New-FakePng 16 16 ([System.Drawing.Color]::FromArgb(255, 255, 0, 0))))
    [IO.File]::WriteAllBytes((Join-Path (Join-Path $mc 'textures') 'grass.png'), (New-FakePng 16 16 ([System.Drawing.Color]::FromArgb(255, 0, 255, 0))))
    [IO.File]::WriteAllBytes((Join-Path (Join-Path $mc 'textures') 'orb.png'), (New-FakePng 16 16 ([System.Drawing.Color]::FromArgb(255, 255, 255, 0))))
    foreach ($n in 'xp.ogg', 'pop.ogg', 'levelup.ogg') { [IO.File]::WriteAllBytes((Join-Path (Join-Path $mc 'sounds') $n), [byte[]](1, 2, 3)) }
    [IO.File]::WriteAllText((Join-Path $mc 'status.json'), '{"state":"ready","message":"","version":"test","pid":1}')
}
