# Tests for the pure parts of scripts/mojang.ps1 (zip read by ranges, CRC, tint, URL check).
BeforeAll {
    Add-Type -AssemblyName System.Drawing, System.IO.Compression
    . (Join-Path (Split-Path -Parent $PSScriptRoot) 'plugins\opaiva-code-widget\scripts\mojang.ps1')

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
