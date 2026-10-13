# Tests for the pure parts of scripts/mojang.ps1 (zip read by ranges, CRC, tint, URL check).
BeforeAll {
    Add-Type -AssemblyName System.Drawing, System.IO.Compression
    . (Join-Path (Split-Path -Parent $PSScriptRoot) 'plugins\opaiva-code-widget\scripts\mojang.ps1')
    . (Join-Path (Split-Path -Parent $PSScriptRoot) 'plugins\opaiva-code-widget\scripts\common.ps1')
    . (Join-Path $PSScriptRoot 'helpers\FakeMojang.ps1')

    function New-TestZip([hashtable]$Files) {
        $ms = New-Object IO.MemoryStream
        $zip = New-Object IO.Compression.ZipArchive $ms, ([IO.Compression.ZipArchiveMode]::Create), $true
        foreach ($name in $Files.Keys) {
            $e = $zip.CreateEntry($name, [IO.Compression.CompressionLevel]::Optimal)
            $s = $e.Open()
            $b = [byte[]]$Files[$name]
            $s.Write($b, 0, $b.Length)
            $s.Dispose()
        }
        $zip.Dispose()
        return , $ms.ToArray()
    }
    function New-Reader([byte[]]$Bytes) {
        return { param($a, $b) , ([byte[]]$Bytes[[int]$a..[int]$b]) }.GetNewClosure()
    }
    function New-TestPng([int]$W, [int]$H, $Color) {
        $bmp = New-Object System.Drawing.Bitmap $W, $H
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.Clear($Color)
        $g.Dispose()
        $ms = New-Object IO.MemoryStream
        $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
        $bmp.Dispose()
        return , $ms.ToArray()
    }
}

Describe 'Get-Crc32' {
    It 'matches the standard check value' {
        Get-Crc32 ([Text.Encoding]::ASCII.GetBytes('123456789')) | Should -Be 3421780262
    }
    It 'is 0 for no data' {
        Get-Crc32 (New-Object byte[] 0) | Should -Be 0
    }
}

Describe 'zip read by ranges' {
    BeforeAll {
        $text = [Text.Encoding]::UTF8.GetBytes(('hello zip ' * 50))
        $other = [byte[]](0..255)
        $files = @{ 'a/one.txt' = $text; 'b/two.bin' = $other }
        1..300 | ForEach-Object { $files["filler/f$_.txt"] = [Text.Encoding]::UTF8.GetBytes("filler $_") }
        $zipBytes = New-TestZip $files
        $read = New-Reader $zipBytes
        $index = Read-ZipIndex $read $zipBytes.Length
    }
    It 'lists every entry' {
        $index.Count | Should -Be 302
        $index.ContainsKey('a/one.txt') | Should -BeTrue
    }
    It 'stops early when it has found the wanted entries' {
        $some = Read-ZipIndex $read $zipBytes.Length @('a/one.txt')
        $some.ContainsKey('a/one.txt') | Should -BeTrue
        $some.Count | Should -BeLessThan 302
    }
    It 'reads and inflates an entry' {
        $got = Get-ZipEntryBytes $read $index['a/one.txt']
        [Convert]::ToBase64String($got) | Should -Be ([Convert]::ToBase64String($text))
        [Convert]::ToBase64String((Get-ZipEntryBytes $read $index['b/two.bin'])) | Should -Be ([Convert]::ToBase64String($other))
    }
    It 'rejects a wrong CRC' {
        $e = @{} + $index['a/one.txt']
        $e.crc = $e.crc + 1
        { Get-ZipEntryBytes $read $e } | Should -Throw '*CRC*'
    }
    It 'rejects an entry bigger than the limit' {
        { Get-ZipEntryBytes $read $index['a/one.txt'] 10 } | Should -Throw '*too big*'
    }
    It 'rejects zip64 and files that are not zips' {
        $bad = $zipBytes.Clone()
        $eocd = -1
        for ($i = $bad.Length - 22; $i -ge 0; $i--) { if ($bad[$i] -eq 0x50 -and $bad[$i + 1] -eq 0x4B -and $bad[$i + 2] -eq 5 -and $bad[$i + 3] -eq 6) { $eocd = $i; break } }
        $bad[$eocd + 10] = 255
        $bad[$eocd + 11] = 255
        { Read-ZipIndex (New-Reader $bad) $bad.Length } | Should -Throw '*zip64*'
        $junk = [byte[]](1..200)
        { Read-ZipIndex (New-Reader $junk) $junk.Length } | Should -Throw '*end record*'
    }
}

Describe 'ConvertTo-TintedPng' {
    It 'multiplies each channel by the tint and keeps alpha' {
        $png = New-TestPng 4 4 ([System.Drawing.Color]::FromArgb(128, 200, 200, 200))
        $out = ConvertTo-TintedPng $png '#FF8000'
        $bmp = [System.Drawing.Bitmap]::FromStream((New-Object IO.MemoryStream (, $out)))
        $c = $bmp.GetPixel(1, 1)
        $bmp.Dispose()
        $c.A | Should -Be 128
        # GDI+ premultiplies semi-transparent pixels, so allow a rounding step
        $c.R | Should -BeIn (198..200)
        $c.G | Should -BeIn (99..101)
        $c.B | Should -Be 0
    }
    It 'crops the wanted square' {
        $bmp = New-Object System.Drawing.Bitmap 8, 8
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.Clear([System.Drawing.Color]::White)
        $g.FillRectangle((New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255, 100, 100, 100))), 4, 4, 4, 4)
        $g.Dispose()
        $ms = New-Object IO.MemoryStream
        $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
        $bmp.Dispose()
        $out = ConvertTo-TintedPng $ms.ToArray() '#FFFFFF' @(4, 4, 4, 4)
        $res = [System.Drawing.Bitmap]::FromStream((New-Object IO.MemoryStream (, $out)))
        $res.Width | Should -Be 4
        $res.GetPixel(0, 0).R | Should -Be 100
        $res.Dispose()
    }
    It 'rejects a crop outside the image' {
        $png = New-TestPng 4 4 ([System.Drawing.Color]::Gray)
        { ConvertTo-TintedPng $png '#FFFFFF' @(0, 0, 16, 16) } | Should -Throw '*crop*'
    }
}

Describe 'Test-MojangUrl' {
    It 'allows https on the Mojang hosts' -ForEach @(
        @{ url = 'https://piston-meta.mojang.com/v1/packages/x.json' }
        @{ url = 'https://piston-data.mojang.com/v1/objects/x/client.jar' }
        @{ url = 'https://resources.download.minecraft.net/ab/abcdef' }
        @{ url = 'https://launchermeta.mojang.com/x' }
    ) { Test-MojangUrl $url $false | Should -BeTrue }
    It 'refuses http, other hosts and garbage' -ForEach @(
        @{ url = 'http://piston-meta.mojang.com/x' }
        @{ url = 'https://evil.example.com/x' }
        @{ url = 'https://piston-meta.mojang.com.evil.example/x' }
        @{ url = 'not a url' }
        @{ url = '' }
    ) { Test-MojangUrl $url $false | Should -BeFalse }
    It 'allows anything in test mode' {
        Test-MojangUrl 'http://127.0.0.1:1234/x' $true | Should -BeTrue
    }
}


Describe 'mojang.ps1 download against a fake Mojang' {
    BeforeAll {
        $mojang = Join-Path (Split-Path -Parent $PSScriptRoot) 'plugins\opaiva-code-widget\scripts\mojang.ps1'
        function Invoke-FakeDownload([hashtable]$Options = @{}) {
            $srv = Start-FakeMojang
            $saved = $env:CLAUDE_WIDGET_MOJANG
            try {
                $orig = New-FakeMojangRoutes $srv $Options
                $env:CLAUDE_WIDGET_MOJANG = $srv.Url
                $dir = Join-Path ([IO.Path]::GetTempPath()) ('ccw-mc-' + [guid]::NewGuid().ToString('N'))
                New-Item -ItemType Directory -Path $dir | Out-Null
                & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $mojang -Dir $dir | Out-Null
                return @{ Dir = $dir; Exit = $LASTEXITCODE; Orig = $orig }
            }
            finally { $env:CLAUDE_WIDGET_MOJANG = $saved; Stop-FakeMojang $srv }
        }
        function Get-McFilesPresent([string]$dir) {
            @(Get-ChildItem -LiteralPath (Get-MinecraftFile $dir '' '') -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'status.json' })
        }
    }
    It 'downloads the sounds and textures and ends ready' {
        $r = Invoke-FakeDownload
        try {
            $r.Exit | Should -Be 0
            Get-MinecraftState $r.Dir | Should -Be 'ready'
            [Convert]::ToBase64String([IO.File]::ReadAllBytes((Get-MinecraftFile $r.Dir 'sounds' 'xp.ogg'))) | Should -Be ([Convert]::ToBase64String($r.Orig.xp))
            [Convert]::ToBase64String([IO.File]::ReadAllBytes((Get-MinecraftFile $r.Dir 'sounds' 'levelup.ogg'))) | Should -Be ([Convert]::ToBase64String($r.Orig.levelup))
            [Convert]::ToBase64String([IO.File]::ReadAllBytes((Get-MinecraftFile $r.Dir 'textures' 'dirt.png'))) | Should -Be ([Convert]::ToBase64String($r.Orig.dirt))
            $grass = [System.Drawing.Bitmap]::FromFile((Get-MinecraftFile $r.Dir 'textures' 'grass.png'))
            $orb = [System.Drawing.Bitmap]::FromFile((Get-MinecraftFile $r.Dir 'textures' 'orb.png'))
            try {
                $c = $grass.GetPixel(2, 2)   # gray 128 x #79C05A
                $c.R | Should -BeIn (59..61)
                $c.G | Should -BeIn (95..97)
                $c.B | Should -BeIn (44..46)
                $orb.Width | Should -Be 16
            }
            finally { $grass.Dispose(); $orb.Dispose() }
            (Read-MinecraftStatus $r.Dir).version | Should -Be '9.9'
        }
        finally { Remove-Item -LiteralPath $r.Dir -Recurse -Force -ErrorAction SilentlyContinue }
    }
    It 'saves nothing and fails when a sound has the wrong hash' {
        $r = Invoke-FakeDownload @{ BadSound = $true }
        try {
            $r.Exit | Should -Not -Be 0
            Get-MinecraftState $r.Dir | Should -Be 'failed'
            Get-MinecraftMessage $r.Dir | Should -Match 'hash'
            Get-McFilesPresent $r.Dir | Should -BeNullOrEmpty
        }
        finally { Remove-Item -LiteralPath $r.Dir -Recurse -Force -ErrorAction SilentlyContinue }
    }
    It 'fails cleanly when a texture is missing from the jar' {
        $r = Invoke-FakeDownload @{ NoJarEntry = $true }
        try {
            $r.Exit | Should -Not -Be 0
            Get-MinecraftState $r.Dir | Should -Be 'failed'
            Get-McFilesPresent $r.Dir | Should -BeNullOrEmpty
        }
        finally { Remove-Item -LiteralPath $r.Dir -Recurse -Force -ErrorAction SilentlyContinue }
    }
    It 'fails at once when the server ignores Range (it must not read the whole jar)' {
        $r = Invoke-FakeDownload @{ NoRange = $true }
        try {
            $r.Exit | Should -Not -Be 0
            Get-MinecraftState $r.Dir | Should -Be 'failed'
            Get-MinecraftMessage $r.Dir | Should -Match '200'
            Get-McFilesPresent $r.Dir | Should -BeNullOrEmpty
        }
        finally { Remove-Item -LiteralPath $r.Dir -Recurse -Force -ErrorAction SilentlyContinue }
    }
    It 'fails when the server is not there' {
        $saved = $env:CLAUDE_WIDGET_MOJANG
        $dir = Join-Path ([IO.Path]::GetTempPath()) ('ccw-mc-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $dir | Out-Null
        try {
            $env:CLAUDE_WIDGET_MOJANG = 'http://127.0.0.1:1'
            & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $mojang -Dir $dir | Out-Null
            $LASTEXITCODE | Should -Not -Be 0
            Get-MinecraftState $dir | Should -Be 'failed'
        }
        finally { $env:CLAUDE_WIDGET_MOJANG = $saved; Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
