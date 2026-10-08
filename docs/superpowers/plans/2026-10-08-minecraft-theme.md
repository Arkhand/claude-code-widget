# Tema Minecraft Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Um tema Minecraft no menu do widget, com texturas e sons baixados dos servidores da Mojang na primeira vez que o usuário o escolhe (nada da Mojang no repositório).

**Architecture:** Um script separado `mojang.ps1` faz o download em segundo plano (índice de assets para os sons, leitura do `client.jar` por faixas para as texturas) e grava `<dados>\minecraft\` mais um `status.json`. O widget só acompanha o status. O tema entra como um mapa de cores a mais (5a) e, quando o cache está pronto, ganha texturas (moldura de terra, grama, orbe) e sons.

**Tech Stack:** Windows PowerShell 5.1, WPF, System.Drawing, System.Net.HttpWebRequest, Pester 5.5+.

**Spec:** `docs/superpowers/specs/2026-10-08-minecraft-theme-design.md`

## Global Constraints

- Arquivos `.ps1` só ASCII; texto de interface em `strings.json` (UTF-8). Evitar `\t`, `\u`, `\b` em strings digitadas por ferramenta: monte caminhos com `Join-Path` por partes e confira com `grep -c $'\t'` (deve dar 0).
- Nenhum parâmetro de handler chamado `$s` (use `$src`, `$e`). Nada em `widget.ps1` que dependa de `$Event`/`$Args`/`$Input` como nome de variável própria.
- Arquivos `.ps1` do repositório são CRLF (o `.gitattributes` converte no commit): ao editar por script, leia, troque `\r\n` por `\n`, edite e grave de volta com `\r\n`.
- Nada da Mojang entra no repositório: nem textura, nem som, nem print do tema Minecraft (README sem imagem desse tema).
- Sem `prefs.json` com `minecraft`, nada muda no comportamento atual; nenhuma chamada de rede acontece antes do clique do usuário em Minecraft.
- Versão alvo 2.5.0 (`plugin.json` e `CHANGELOG.md` batem; há teste).
- Testes de janela (tag `Desktop`) usam `CLAUDE_WIDGET_NO_TRAY=1` e põem o widget no canto superior esquerdo via `state.json` (`{"right":420,"bottom":220}`).
- Suíte completa: `powershell -NoProfile -File tools\test.ps1` (hoje 257 testes).

## Review Focus

- Um servidor que responde 200 em vez de 206 a um pedido de faixa não pode fazer o script baixar o jar inteiro (41 MB): falha logo, antes de ler o corpo (Task 3).
- Um som com hash errado, uma textura com CRC errado ou um arquivo grande demais nunca deixa arquivo novo pela metade em `minecraft\`, e o estado nunca fica `ready` (Task 3).
- Uma URL que sai da lista da Mojang (um JSON adulterado) não é seguida (Task 2/3).
- `status.json` `downloading` de um processo que morreu vira `failed`, não fica "baixando" para sempre (Task 1).
- O widget com `theme = minecraft` no `prefs.json` e sem cache abre só com a paleta, sem erro no log e sem tentar baixar (Task 4).
- Sair do tema Minecraft (escuro, claro) restaura moldura, cantos e pontos do jeito de antes, também depois de várias trocas (Task 4/5).
- Escolher Minecraft duas vezes seguidas (ou escolher de novo enquanto baixa) não dispara dois downloads (Task 5).
- Se o Windows não toca `.ogg`, o aviso continua tocando o som do sistema (herdado do 5a; conferência manual na Task 6).

---

### Task 1: Tema `minecraft` em prefs/mapa de cores e estado do cache

**Files:**
- Modify: `plugins/opaiva-code-widget/scripts/common.ps1`
- Test: `tests/common.Tests.ps1`

**Interfaces:**
- Produces: `Read-Prefs` aceita `theme = minecraft`; `Resolve-Theme 'minecraft'` -> `minecraft`; `Get-ColorMap 'minecraft'`; `Get-MinecraftFile([string]$Dir, [string]$Kind, [string]$Name)` -> `<Dir>\minecraft\<Kind>\<Name>` (Kind `textures` ou `sounds`; `$Name` vazio com `$Kind` vazio dá a pasta `minecraft`); `$script:McFiles` (lista de pares kind/nome dos seis arquivos); `Get-MinecraftState([string]$Dir)` -> `none|downloading|ready|failed`; `Get-MinecraftMessage([string]$Dir)` -> texto de falha ou `''`.

- [ ] **Step 1: Escrever os testes que falham**

Acrescentar ao fim de `tests/common.Tests.ps1`:

````powershell

Describe 'Minecraft theme: prefs, color map and cache state' {
    It 'Read-Prefs accepts the minecraft theme' {
        $dir = Join-Path $TestDrive ('mc' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $dir | Out-Null
        [IO.File]::WriteAllText((Join-Path $dir 'prefs.json'), '{"theme":"minecraft"}')
        (Read-Prefs $dir).theme | Should -Be 'minecraft'
    }
    It 'Resolve-Theme keeps minecraft whatever Windows uses' {
        Resolve-Theme 'minecraft' $true | Should -Be 'minecraft'
        Resolve-Theme 'minecraft' $false | Should -Be 'minecraft'
    }
    It 'the minecraft color map has unique values, none a key or a native color' {
        $m = Get-ColorMap 'minecraft'
        $m.Count | Should -BeGreaterThan 8
        @($m.Values | Select-Object -Unique).Count | Should -Be $m.Count
        foreach ($v in $m.Values) {
            $m.ContainsKey($v) | Should -BeFalse -Because "$v is also a key"
            @('#FFFFFF', '#2F6F4E') -contains $v | Should -BeFalse -Because "$v is a native color"
        }
    }
    It 'every key of the minecraft map is a color written in widget.ps1' {
        $text = [IO.File]::ReadAllText((Join-Path (Split-Path -Parent $PSScriptRoot) 'plugins\opaiva-code-widget\scripts\widget.ps1'))
        $hex = [regex]::Matches($text, '#[0-9A-Fa-f]{6}(?![0-9A-Fa-f])') | ForEach-Object { $_.Value.ToUpper() } | Sort-Object -Unique
        foreach ($k in (Get-ColorMap 'minecraft').Keys) { $hex -contains $k.ToUpper() | Should -BeTrue -Because "$k is not used by the widget" }
    }
    It 'switching light -> minecraft goes back through the dark colors without a clash' {
        $light = Get-ColorMap 'light'
        $mc = Get-ColorMap 'minecraft'
        $back = @{}
        foreach ($k in $light.Keys) { $back[$light[$k]] = $k }
        foreach ($k in $light.Keys) {
            # light value -> dark key -> minecraft value (or itself) is what Set-Theme computes
            Convert-ThemeColor (Convert-ThemeColor $light[$k] $back) $mc | Should -Be (Convert-ThemeColor $k $mc)
        }
    }

    Context 'Get-MinecraftState' {
        BeforeEach {
            $dir = Join-Path $TestDrive ('d' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $dir | Out-Null
            $mc = Get-MinecraftFile $dir '' ''
            New-Item -ItemType Directory -Path (Join-Path $mc 'textures'), (Join-Path $mc 'sounds') | Out-Null
        }
        It 'is none without a status file' {
            Get-MinecraftState $dir | Should -Be 'none'
        }
        It 'is ready when status says ready and all six files exist' {
            foreach ($f in $script:McFiles) { [IO.File]::WriteAllBytes((Get-MinecraftFile $dir $f[0] $f[1]), [byte[]](1, 2, 3)) }
            [IO.File]::WriteAllText((Join-Path $mc 'status.json'), '{"state":"ready","message":"","version":"1","pid":1}')
            Get-MinecraftState $dir | Should -Be 'ready'
        }
        It 'is none when status says ready but a file is missing' {
            foreach ($f in $script:McFiles) { [IO.File]::WriteAllBytes((Get-MinecraftFile $dir $f[0] $f[1]), [byte[]](1)) }
            Remove-Item -LiteralPath (Get-MinecraftFile $dir 'sounds' 'pop.ogg')
            [IO.File]::WriteAllText((Join-Path $mc 'status.json'), '{"state":"ready"}')
            Get-MinecraftState $dir | Should -Be 'none'
        }
        It 'is downloading while the downloader process is alive' {
            [IO.File]::WriteAllText((Join-Path $mc 'status.json'), ('{{"state":"downloading","pid":{0}}}' -f $PID))
            Get-MinecraftState $dir | Should -Be 'downloading'
        }
        It 'is failed when the downloader process is gone' {
            [IO.File]::WriteAllText((Join-Path $mc 'status.json'), '{"state":"downloading","pid":2147483000}')
            Get-MinecraftState $dir | Should -Be 'failed'
        }
        It 'is failed with the message of a failed download' {
            [IO.File]::WriteAllText((Join-Path $mc 'status.json'), '{"state":"failed","message":"wrong hash for xp.ogg"}')
            Get-MinecraftState $dir | Should -Be 'failed'
            Get-MinecraftMessage $dir | Should -Be 'wrong hash for xp.ogg'
        }
        It 'is none for a status file that is not JSON' {
            [IO.File]::WriteAllText((Join-Path $mc 'status.json'), '{{ no')
            Get-MinecraftState $dir | Should -Be 'none'
        }
    }
}
````

- [ ] **Step 2: Rodar e ver falhar**

Run: `powershell -NoProfile -Command "Import-Module Pester -MinimumVersion 5.5; Invoke-Pester -Path tests\common.Tests.ps1 -FullNameFilter '*Minecraft*' -Output Minimal"`
Expected: falhas (`Get-MinecraftFile` não existe; `theme` volta `dark`).

- [ ] **Step 3: Implementar em `common.ps1`**

1. Em `Read-Prefs`, trocar `@('dark', 'light', 'auto') -contains $j.theme` por `@('dark', 'light', 'auto', 'minecraft') -contains $j.theme`.
2. Em `Resolve-Theme`, acrescentar, antes do `if ($Theme -eq 'light')`: `if ($Theme -eq 'minecraft') { return 'minecraft' }`.
3. Em `Get-ColorMap`, trocar a primeira linha `if ($Theme -ne 'light') { return @{} }` por:

````powershell
    if ($Theme -eq 'minecraft') {
        # Stone and dirt browns, grass green. Only some colors change; the rest keep the dark theme's.
        return @{
            '#1E1E22' = '#2B2723'; '#34343B' = '#5B4332'; '#26262C' = '#3A342E'; '#141417' = '#1B1815'
            '#2C2C33' = '#4A3F35'; '#24242A' = '#34302B'; '#2A2A30' = '#4A4A4A'; '#3A3A42' = '#6B6B6B'
            '#5FB98A' = '#7FE03A'; '#D97757' = '#5D9A32'; '#3A2A24' = '#2F4A22'; '#F0A58A' = '#A8E070'
        }
    }
    if ($Theme -ne 'light') { return @{} }
````

4. Acrescentar ao fim de `common.ps1`:

````powershell

# ---------------- Minecraft theme cache (filled by mojang.ps1) ----------------

# <Dir>\minecraft\<Kind>\<Name>; with Kind and Name empty, the minecraft folder itself
function Get-MinecraftFile([string]$Dir, [string]$Kind, [string]$Name) {
    $p = Join-Path $Dir 'minecraft'
    if ($Kind) { $p = Join-Path $p $Kind }
    if ($Name) { $p = Join-Path $p $Name }
    return $p
}

# The six files the theme needs: kind, name
$script:McFiles = @(
    , @('textures', 'dirt.png'), @('textures', 'grass.png'), @('textures', 'orb.png'),
    @('sounds', 'xp.ogg'), @('sounds', 'pop.ogg'), @('sounds', 'levelup.ogg')
)

function Read-MinecraftStatus([string]$Dir) {
    try {
        $path = Join-Path (Get-MinecraftFile $Dir '' '') 'status.json'
        if (-not (Test-Path -LiteralPath $path)) { return $null }
        return [IO.File]::ReadAllText($path, (Get-Utf8NoBom)) | ConvertFrom-Json
    } catch { return $null }
}

# 'none' (never downloaded, or files missing), 'downloading', 'ready' or 'failed'
function Get-MinecraftState([string]$Dir) {
    $s = Read-MinecraftStatus $Dir
    if (-not $s) { return 'none' }
    if ($s.state -eq 'downloading') {
        # A downloader that died leaves "downloading" behind: that is a failure, not a wait
        try { if ($s.pid -and (Get-Process -Id ([int]$s.pid) -ErrorAction Stop)) { return 'downloading' } } catch {}
        return 'failed'
    }
    if ($s.state -eq 'ready') {
        foreach ($f in $script:McFiles) {
            if (-not (Test-Path -LiteralPath (Get-MinecraftFile $Dir $f[0] $f[1]))) { return 'none' }
        }
        return 'ready'
    }
    if ($s.state -eq 'failed') { return 'failed' }
    return 'none'
}

function Get-MinecraftMessage([string]$Dir) {
    $s = Read-MinecraftStatus $Dir
    if ($s -and $s.message) { return [string]$s.message }
    return ''
}
````

Nota: `, @(...)` no começo do array evita que o PowerShell achate o primeiro par; confirme com `$script:McFiles.Count` = 6 e `$script:McFiles[0][1]` = `dirt.png`.

- [ ] **Step 4: Rodar e ver passar**

Run: `powershell -NoProfile -Command "Import-Module Pester -MinimumVersion 5.5; Invoke-Pester -Path tests\common.Tests.ps1 -Output Minimal"`
Expected: tudo passa. Se "every key of the minecraft map is a color written in widget.ps1" falhar, uma chave do mapa não existe no widget: corrija a chave. Se `$script:McFiles` falhar nos testes por escopo (`$script:` de um arquivo dot-sourced), troque por `$McFiles` global do arquivo e ajuste os testes para `$McFiles`.

- [ ] **Step 5: Suíte sem Desktop e commit**

Run: `powershell -NoProfile -File tools\test.ps1 -ExcludeTag Desktop` -> Expected: verde.

```bash
git add plugins/opaiva-code-widget/scripts/common.ps1 tests/common.Tests.ps1
git commit -m "feat: minecraft theme in prefs and color map, cache state helpers"
```

---

### Task 2: Biblioteca do download (zip por faixas, CRC, tingimento, URLs)

**Files:**
- Create: `plugins/opaiva-code-widget/scripts/mojang.ps1`
- Create: `tests/mojang.Tests.ps1`

**Interfaces:**
- Produces (todas em `mojang.ps1`, que pode ser lido com `.` sem `-Dir`): `Get-Crc32([byte[]])` -> `[long]`; `Read-ZipIndex([scriptblock]$ReadRange, [long]$Length, [string[]]$Want = $null)` -> hashtable `nome -> @{ method; crc; csize; usize; offset }`; `Get-ZipEntryBytes([scriptblock]$ReadRange, [hashtable]$Entry, [long]$MaxBytes = 2097152)` -> `byte[]`; `ConvertTo-TintedPng([byte[]]$Png, [string]$TintHex, [int[]]$Crop = $null)` -> `byte[]`; `Test-MojangUrl([string]$Url, [bool]$AllowAny)` -> bool. `$ReadRange` é um scriptblock `{ param($from, $to) ... }` que devolve os bytes de `from` a `to` (inclusive).

- [ ] **Step 1: Escrever os testes que falham**

Criar `tests/mojang.Tests.ps1`:

````powershell
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
        $c.R | Should -Be 200
        $c.G | Should -Be 100
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
````

- [ ] **Step 2: Rodar e ver falhar**

Run: `powershell -NoProfile -Command "Import-Module Pester -MinimumVersion 5.5; Invoke-Pester -Path tests\mojang.Tests.ps1 -Output Minimal"`
Expected: erro ao ler `mojang.ps1` (não existe).

- [ ] **Step 3: Criar `scripts/mojang.ps1` (parte biblioteca)**

````powershell
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
````

- [ ] **Step 4: Rodar e ver passar**

Run: `powershell -NoProfile -Command "Import-Module Pester -MinimumVersion 5.5; Invoke-Pester -Path tests\mojang.Tests.ps1 -Output Minimal"`
Expected: tudo passa. Pontos a vigiar: (a) o desempacotamento `$x, $y, $w, $h = $Crop`; (b) `[byte[]]$Bytes[[int]$a..[int]$b]` no leitor de teste (se a precedência do cast confundir, escreva `,([byte[]]($Bytes[[int]$a..[int]$b]))`); (c) `-Throw '*CRC*'` compara com a mensagem da exceção.

- [ ] **Step 5: Suíte e commit**

Run: `powershell -NoProfile -File tools\test.ps1 -ExcludeTag Desktop` (inclui o teste de ASCII dos scripts) -> verde.

```bash
git add plugins/opaiva-code-widget/scripts/mojang.ps1 tests/mojang.Tests.ps1
git commit -m "feat: mojang.ps1 library: zip by ranges, CRC32, tint, URL check"
```

---

### Task 3: O download completo contra um servidor falso

**Files:**
- Modify: `plugins/opaiva-code-widget/scripts/mojang.ps1` (acrescentar o download e o ponto de entrada)
- Create: `tests/helpers/FakeMojang.ps1`
- Modify: `tests/mojang.Tests.ps1`

**Interfaces:**
- Consumes: Task 2 (`Read-ZipIndex`, `Get-ZipEntryBytes`, `ConvertTo-TintedPng`, `Test-MojangUrl`, `Get-Crc32`) e `Get-MinecraftFile`/`Get-MinecraftState` (Task 1, para os testes).
- Produces: `Invoke-HttpGet([string]$Url, [long]$From = -1, [long]$To = -1, [int]$MaxBytes = 8388608)` -> `byte[]` (200 sem faixa, 206 com faixa; outro código lança); `Invoke-MojangDownload([string]$Dir)` -> `$true`/`$false` (grava `<Dir>\minecraft\status.json` e os seis arquivos); ponto de entrada `if ($Dir) { exit ... }`; helper de teste `Start-FakeMojang`/`Stop-FakeMojang`/`New-FakeMojangRoutes`/`New-FakeMinecraftCache`.

- [ ] **Step 1: Escrever o helper do servidor falso**

Criar `tests/helpers/FakeMojang.ps1`:

````powershell
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
````

- [ ] **Step 2: Escrever os testes do download (falham)**

Em `tests/mojang.Tests.ps1`: no `BeforeAll`, acrescentar depois dos `Add-Type`: `. (Join-Path $PSScriptRoot 'helpers\FakeMojang.ps1')` e `. (Join-Path (Split-Path -Parent $PSScriptRoot) 'plugins\opaiva-code-widget\scripts\common.ps1')`; e acrescentar ao fim do arquivo:

````powershell

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
                $c.R | Should -Be 60
                $c.G | Should -Be 96
                $c.B | Should -Be 45
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
````

Run: `powershell -NoProfile -Command "Import-Module Pester -MinimumVersion 5.5; Invoke-Pester -Path tests\mojang.Tests.ps1 -FullNameFilter '*fake Mojang*' -Output Minimal"`
Expected: FAIL (`mojang.ps1` ainda não baixa nada: `status.json` não existe, saída 0 sem arquivos).

- [ ] **Step 3: Implementar o download em `mojang.ps1`**

Acrescentar ao fim de `mojang.ps1`:

````powershell

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
````

Nota: `$u` e `$jarUrl` são lidos pelos scriptblocks `$getJson`/`$read` por escopo dinâmico, porque eles rodam dentro de `Invoke-MojangDownload`.

- [ ] **Step 4: Rodar e ver passar**

Run: `powershell -NoProfile -Command "Import-Module Pester -MinimumVersion 5.5; Invoke-Pester -Path tests\mojang.Tests.ps1 -Output Minimal"`
Expected: tudo passa. Se o teste de Range falhar com mensagem diferente de `200`, confira a mensagem de `Invoke-HttpGet` (`HTTP 200 (wanted 206)`). Se o servidor falso travar, confira que `Stop-FakeMojang` roda (o `finally`).

- [ ] **Step 5: Suíte e commit**

Run: `powershell -NoProfile -File tools\test.ps1 -ExcludeTag Desktop` -> verde.

```bash
git add plugins/opaiva-code-widget/scripts/mojang.ps1 tests/helpers/FakeMojang.ps1 tests/mojang.Tests.ps1
git commit -m "feat: mojang.ps1 downloads the Minecraft theme assets, tested against a fake Mojang"
```

---

### Task 4: Texturas e sons do tema no widget

**Files:**
- Modify: `plugins/opaiva-code-widget/scripts/widget.ps1`
- Test: `tests/widget.Tests.ps1`

**Interfaces:**
- Consumes: `Get-MinecraftState`, `Get-MinecraftFile` (Task 1), `New-FakeMinecraftCache` (Task 3, helper).
- Produces: `Set-ThemeExtras([string]$name)`, `Set-SoundSet([string]$name)`, `Set-LookTheme([string]$name)` (todo caminho de troca de tema passa por ele); elementos `GrassTop` e `IdleDot` no XAML; o modo `-RenderSamples` usa preferências padrão.

- [ ] **Step 1: Escrever os testes que falham**

Em `tests/widget.Tests.ps1`, no `BeforeAll` de arquivo, acrescentar o dot-source do helper (depois de ler `common.ps1`): `. (Join-Path $PSScriptRoot 'helpers\FakeMojang.ps1')`. Depois, dentro do `Describe 'widget.ps1 rendering'`, acrescentar:

````powershell
    It 'ignores the prefs.json of the machine when drawing samples' {
        Add-Type -AssemblyName System.Drawing
        $data = Join-Path $TestDrive 'lightdata'
        New-Item -ItemType Directory -Path $data | Out-Null
        [IO.File]::WriteAllText((Join-Path $data 'prefs.json'), '{"theme":"light","minimal":true}')
        $out = Join-Path $TestDrive 'ignored'
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $widget -RenderSamples $samples -OutDir $out -Lang en -DataDir $data
        $LASTEXITCODE | Should -Be 0
        $bmp = New-Object System.Drawing.Bitmap (Join-Path $out 'permission.png')
        try { $c = $bmp.GetPixel(50, [int]($bmp.Height / 2)); [int](($c.R + $c.G + $c.B) / 3) | Should -BeLessThan 80 }
        finally { $bmp.Dispose() }
    }
    It 'draws the minecraft theme with the dirt frame when the cache is ready, and plain stone colors without it' {
        Add-Type -AssemblyName System.Drawing
        $cache = Join-Path $TestDrive 'mccache'
        New-Item -ItemType Directory -Path $cache | Out-Null
        New-FakeMinecraftCache $cache
        $with = Join-Path $TestDrive 'mc-with'
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $widget -RenderSamples $samples -OutDir $with -Lang en -Theme minecraft -DataDir $cache
        $LASTEXITCODE | Should -Be 0
        $bmp = New-Object System.Drawing.Bitmap (Join-Path $with 'permission.png')
        try {
            # 2x render: the 6 DIP frame starts at 14 DIP (28 px); x = 34 px is inside it, at mid height
            $c = $bmp.GetPixel(34, [int]($bmp.Height / 2))
            $c.R | Should -BeGreaterThan 200
            $c.G | Should -BeLessThan 60
            $c.B | Should -BeLessThan 60
        }
        finally { $bmp.Dispose() }
        $empty = Join-Path $TestDrive 'mcempty'
        New-Item -ItemType Directory -Path $empty | Out-Null
        $without = Join-Path $TestDrive 'mc-without'
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $widget -RenderSamples $samples -OutDir $without -Lang en -Theme minecraft -DataDir $empty
        $LASTEXITCODE | Should -Be 0
        $bmp = New-Object System.Drawing.Bitmap (Join-Path $without 'permission.png')
        try {
            # no textures: the card is the stone color #2B2723, and the frame is the plain brown #5B4332
            $card = $bmp.GetPixel(50, [int]($bmp.Height / 2))
            $card.R | Should -BeIn (40..46)
            $card.G | Should -BeIn (36..42)
            $card.B | Should -BeIn (32..38)
            $edge = $bmp.GetPixel(29, [int]($bmp.Height / 2))
            $edge.R | Should -BeGreaterThan 60
            $edge.R | Should -BeLessThan 120
        }
        finally { $bmp.Dispose() }
    }
````

Dentro do `Describe 'widget.ps1 preferences'`, acrescentar, usando o helper `Get-PillSize`-estilo já existente só para abrir e fechar (reaproveite o corpo para uma função `Start-PrefsWidget`, ou copie o padrão de início/limpeza dos outros testes):

````powershell
    It 'opens with theme minecraft with and without a cache, without errors in the log' -ForEach @(@{ withCache = $true }, @{ withCache = $false }) {
        $data = Join-Path ([IO.Path]::GetTempPath()) ('ccw-widget-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $data 'queue') | Out-Null
        [IO.File]::WriteAllText((Join-Path $data 'state.json'), '{"right":420,"bottom":220}')
        [IO.File]::WriteAllText((Join-Path $data 'prefs.json'), '{"theme":"minecraft"}')
        if ($withCache) { New-FakeMinecraftCache $data }
        $proc = Start-Process powershell.exe -PassThru -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
            '-File', ('"{0}"' -f $widget), '-DataDir', ('"{0}"' -f $data), '-Lang', 'en'
        try {
            $deadline = (Get-Date).AddSeconds(30)
            while ((Get-Date) -lt $deadline -and @([CcwTest.Windows]::Rects($proc.Id)).Count -eq 0) { Start-Sleep -Milliseconds 250 }
            @([CcwTest.Windows]::Rects($proc.Id)).Count | Should -BeGreaterThan 0
            Start-Sleep -Seconds 2
            $proc.HasExited | Should -BeFalse
            Join-Path $data 'widget.log' | Should -Not -Exist
            # opening the theme never starts a download by itself
            Join-Path (Join-Path $data 'minecraft') 'status.json' | Should -Exist:$withCache
        }
        finally {
            Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
            [void]$proc.WaitForExit(5000)
            Remove-Item -LiteralPath $data -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
````

(`Should -Exist:$withCache` não existe: troque a última asserção por `if ($withCache) { <status.json> | Should -Exist } else { <pasta minecraft> | Should -Not -Exist }`.)

Run: `powershell -NoProfile -Command "Import-Module Pester -MinimumVersion 5.5; Invoke-Pester -Path tests\widget.Tests.ps1 -FullNameFilter '*minecraft*','*prefs.json of the machine*' -Output Minimal"`
Expected: FAIL (o render ainda lê o `prefs.json` da máquina; o tema `minecraft` não pinta borda).

- [ ] **Step 2: XAML e nomes**

Em `widget.ps1`:
- Na linha do ponto da pílula (`<Ellipse Width="8" Height="8" Fill="#5FB98A" ...`), acrescentar `x:Name="IdleDot"` logo depois de `<Ellipse`.
- No `Grid` do cartão (`<Grid>` logo depois do `<Border x:Name="Card" ...>` e do seu `DropShadowEffect`), como PRIMEIRO filho do `Grid`, acrescentar:

````xml
      <Border x:Name="GrassTop" Height="8" VerticalAlignment="Top" Margin="-6,-6,-6,0"
              IsHitTestVisible="False" Visibility="Collapsed"/>
````

  (como último filho seria desenhado sobre os painéis; como primeiro, fica atrás do conteúdo; a margem negativa leva a faixa para cima da moldura de 6 DIP.)
- Na lista de `FindName` (`foreach ($n in 'Card', 'IdlePanel', ...`), acrescentar `'IdleDot', 'GrassTop'`.

- [ ] **Step 3: Preferências padrão no modo de render**

Trocar a linha `$script:prefs = Read-Prefs $Data` e a seguinte (`if ($RenderMode -and $Theme) ...`) por:

````powershell
# Preferences (prefs.json): theme, opacity, volume, scale, minimal pill. The README screenshots
# (-RenderSamples) always start from the defaults, plus -Theme.
$script:prefs = if ($RenderMode) { Get-DefaultPrefs } else { Read-Prefs $Data }
if ($RenderMode -and $Theme) { $script:prefs.theme = $Theme }
````

(e apagar o comentário antigo duplicado logo acima, se sobrar).

- [ ] **Step 4: Sons por tema, extras e `Set-LookTheme`**

1. Substituir o bloco `if (-not $RenderMode) { $script:sounds.request = ... }` (as três linhas de `New-MediaSound` do 5a) por:

````powershell
    # The sounds in use: the Windows ones, or the Minecraft ones once the theme is downloaded
    function Set-SoundSet([string]$theme) {
        if ($RenderMode) { return }
        if ($theme -eq 'minecraft' -and (Get-MinecraftState $Data) -eq 'ready') {
            $script:sounds.request = New-MediaSound (Get-MinecraftFile $Data 'sounds' 'xp.ogg')
            $script:sounds.done = New-MediaSound (Get-MinecraftFile $Data 'sounds' 'pop.ogg')
            $script:sounds.allDone = New-MediaSound (Get-MinecraftFile $Data 'sounds' 'levelup.ogg')
        }
        else {
            $script:sounds.request = New-MediaSound (Get-SchemeSound 'SystemAsterisk')
            $script:sounds.done = New-MediaSound (Join-Path $env:WINDIR 'Media\Windows Notify System Generic.wav')
            $script:sounds.allDone = New-MediaSound (Join-Path $env:WINDIR 'Media\tada.wav')
        }
    }
    Set-SoundSet 'dark'
````

   (as duas linhas com `Media\...` são as do 5a, copie-as sem mexer nos caminhos).

2. Depois da definição de `Set-Theme` (a função do 5a, dentro do bloco que define `Get-Brush`), acrescentar:

````powershell
    # Textures of the Minecraft theme (frame of dirt, strip of grass, XP orbs), only once downloaded.
    # Any other theme (or no download yet) gets the usual frame and dots back.
    $script:mcExtras = $false
    function Get-McImage([string]$file) {
        $bi = New-Object System.Windows.Media.Imaging.BitmapImage
        $bi.BeginInit()
        $bi.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
        $bi.UriSource = [Uri](Get-MinecraftFile $Data 'textures' $file)
        $bi.EndInit()
        $bi.Freeze()
        return $bi
    }
    function New-McBrush($image, [bool]$tile) {
        $b = New-Object System.Windows.Media.ImageBrush $image
        if ($tile) {
            $b.TileMode = [System.Windows.Media.TileMode]::Tile
            $b.ViewportUnits = [System.Windows.Media.BrushMappingMode]::Absolute
            $b.Viewport = New-Object System.Windows.Rect 0, 0, 32, 32
        }
        [System.Windows.Media.RenderOptions]::SetBitmapScalingMode($b, [System.Windows.Media.BitmapScalingMode]::NearestNeighbor)
        $b.Freeze()
        return $b
    }
    function Set-ThemeExtras([string]$name) {
        if ($name -eq 'minecraft' -and (Get-MinecraftState $Data) -eq 'ready') {
            try {
                $orb = New-McBrush (Get-McImage 'orb.png') $false
                $dirt = New-McBrush (Get-McImage 'dirt.png') $true
                $grass = New-McBrush (Get-McImage 'grass.png') $true
                $ui.Card.BorderBrush = $dirt
                $ui.Card.BorderThickness = New-Object System.Windows.Thickness 6
                $ui.Card.CornerRadius = New-Object System.Windows.CornerRadius 0
                $ui.GrassTop.Background = $grass
                $ui.GrassTop.Visibility = 'Visible'
                foreach ($d in 'IdleDot', 'ReqDot', 'QDot') { $ui[$d].Fill = $orb }
                $script:mcExtras = $true
                return
            } catch { Write-Log $_ }
        }
        # Back to the plain look (also the palette-only Minecraft look: square corners)
        $ui.Card.BorderBrush = Get-Brush '#34343B'
        $ui.Card.BorderThickness = New-Object System.Windows.Thickness 1
        $ui.Card.CornerRadius = New-Object System.Windows.CornerRadius $(if ($name -eq 'minecraft') { 0 } else { 14 })
        $ui.GrassTop.Visibility = 'Collapsed'
        $ui.IdleDot.Fill = Get-Brush '#5FB98A'
        $ui.ReqDot.Fill = Get-Brush '#D97757'
        $ui.QDot.Fill = Get-Brush '#7AA2F7'
        $script:mcExtras = $false
    }
    # Every way of changing the theme goes through here: colors, then textures, then sounds
    function Set-LookTheme([string]$name) {
        Set-Theme $name
        Set-ThemeExtras $name
        Set-SoundSet $name
    }
````

3. Trocar as duas chamadas `Set-Theme (Resolve-Theme ...)` (em `Set-Pref`, caso `'theme'`, e a linha inicial depois do menu) por `Set-LookTheme (Resolve-Theme $script:prefs.theme (Get-WindowsLightTheme))`.

- [ ] **Step 5: Rodar e ver passar**

Run: `powershell -NoProfile -Command "Import-Module Pester -MinimumVersion 5.5; Invoke-Pester -Path tests\widget.Tests.ps1 -Output Minimal"`
Expected: tudo passa. Se o pixel da moldura não for vermelho, meça o pixel real (`$bmp.GetPixel`) em alguns `x` entre 28 e 40 e ajuste só o `x` do teste, mantendo "dentro da moldura"; se `GrassTop` cobrir o ponto de teste (topo), lembre que o teste amostra no meio da altura.

- [ ] **Step 6: Suíte completa e commit**

Run: `powershell -NoProfile -File tools\test.ps1` -> Expected: tudo verde.

```bash
git add plugins/opaiva-code-widget/scripts/widget.ps1 tests/widget.Tests.ps1
git commit -m "feat: minecraft theme textures and sounds in the widget"
```

---

### Task 5: Menu e fluxo do download no widget

**Files:**
- Modify: `plugins/opaiva-code-widget/scripts/widget.ps1`
- Modify: `plugins/opaiva-code-widget/scripts/strings.json`
- Test: `tests/widget.Tests.ps1`, `tests/common.Tests.ps1`

**Interfaces:**
- Consumes: `Get-MinecraftState`, `Get-MinecraftMessage` (Task 1), `mojang.ps1` (Task 3), `Set-LookTheme` (Task 4).
- Produces: item Minecraft no submenu Tema; `Start-MinecraftDownload`, `Sync-MinecraftItem`, `Sync-Minecraft`, `$script:mcWaiting`.

- [ ] **Step 1: Textos**

Em `strings.json`, junto de `themeAuto`, nos dois idiomas:
- pt: `themeMinecraft` "Minecraft", `themeMinecraftDownload` "Minecraft (baixa da Mojang)", `themeMinecraftBusy` "Minecraft (baixando...)".
- en: `themeMinecraft` "Minecraft", `themeMinecraftDownload` "Minecraft (downloads from Mojang)", `themeMinecraftBusy` "Minecraft (downloading...)".

Se houver teste de paridade de chaves pt/en, ele cobre. Escrever com a ferramenta Edit/Write e conferir os acentos (nenhum aqui).

- [ ] **Step 2: Teste que falha (fluxo sem rede)**

O clique no menu não tem teste automático; o que dá para provar sem rede é que a estrutura existe e que o widget não baixa sozinho. Acrescentar a `tests/repo.Tests.ps1`, no `Describe 'repository rules'`:

````powershell
    It 'widget.ps1 starts the Minecraft download only from the menu click path' {
        $text = [IO.File]::ReadAllText((Join-Path $repo 'plugins\opaiva-code-widget\scripts\widget.ps1'))
        # exactly one place starts mojang.ps1, inside Start-MinecraftDownload
        ([regex]::Matches($text, 'mojang\.ps1')).Count | Should -Be 1
        $text | Should -Match 'function Start-MinecraftDownload'
        # and Set-Pref is the only caller of it
        ([regex]::Matches($text, 'Start-MinecraftDownload')).Count | Should -Be 2
    }
````

Run: `powershell -NoProfile -Command "Import-Module Pester -MinimumVersion 5.5; Invoke-Pester -Path tests\repo.Tests.ps1 -FullNameFilter '*Minecraft download*' -Output Minimal"` -> Expected: FAIL.

- [ ] **Step 3: Implementar**

Em `widget.ps1`, logo antes de `function Set-Pref`, acrescentar:

````powershell
    # The Minecraft theme is downloaded once, by mojang.ps1 in the background, after the first click
    $script:mcWaiting = $false
    $script:mcStarted = 0
    function Start-MinecraftDownload {
        try {
            $script = Join-Path $PSScriptRoot 'mojang.ps1'
            [void](Start-Process powershell.exe -WindowStyle Hidden -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $script), '-Dir', ('"{0}"' -f $Data))
            $script:mcWaiting = $true
            $script:mcStarted = Get-NowMs
        } catch { Write-Log $_ }
    }
    # The menu item says what clicking it does: download, wait, or just use the theme
    function Sync-MinecraftItem([string]$state) {
        $e = @($script:prefItems | Where-Object { $_.key -eq 'theme' -and $_.value -eq 'minecraft' })[0]
        if (-not $e) { return }
        $e.item.Header = switch ($state) {
            'ready' { $S.themeMinecraft }
            'downloading' { $S.themeMinecraftBusy }
            default { $(if ($script:mcWaiting) { $S.themeMinecraftBusy } else { $S.themeMinecraftDownload }) }
        }
    }
    # Called every ~2 s: follows a download that this widget started
    function Sync-Minecraft {
        $state = Get-MinecraftState $Data
        Sync-MinecraftItem $state
        if (-not $script:mcWaiting) { return }
        if ($state -eq 'ready') { $script:mcWaiting = $false; Set-Pref 'theme' 'minecraft'; Sync-MinecraftItem 'ready' }
        elseif ($state -eq 'failed' -or ($state -eq 'none' -and ((Get-NowMs) - $script:mcStarted) -gt 30000)) {
            $script:mcWaiting = $false
            Write-Log ('minecraft theme: download failed: ' + (Get-MinecraftMessage $Data))
            Sync-MinecraftItem $state
        }
    }
````

Dentro de `Set-Pref`, no começo da função (antes de `$script:prefs[$key] = $value`), acrescentar:

````powershell
        # Minecraft needs its files first: the click starts the download and changes nothing yet
        if ($key -eq 'theme' -and $value -eq 'minecraft' -and (Get-MinecraftState $Data) -ne 'ready') {
            if (-not $script:mcWaiting -and (Get-MinecraftState $Data) -ne 'downloading') { Start-MinecraftDownload }
            Sync-MinecraftItem (Get-MinecraftState $Data)
            return
        }
````

No `Add-ChoiceMenu $menu $S.menuTheme @( ... )`, acrescentar a quarta opção depois de `themeAuto`:

````powershell
        @{ label = $S.themeMinecraftDownload; key = 'theme'; value = 'minecraft' }
````

(com a vírgula/quebra de linha certa dentro do array). Depois da chamada inicial `Sync-MenuChecks` (a que fica depois do menu pronto), acrescentar `Sync-MinecraftItem (Get-MinecraftState $Data)`.

No timer (`$script:ticks % 5 -eq 0`), acrescentar dentro do bloco, depois do `try` do `Sync-Anchor`, outro: `try { Sync-Minecraft } catch { Write-Log $_ }`.

- [ ] **Step 4: Rodar e ver passar**

Run: `powershell -NoProfile -Command "Import-Module Pester -MinimumVersion 5.5; Invoke-Pester -Path tests\repo.Tests.ps1,tests\widget.Tests.ps1 -Output Minimal"`
Expected: tudo passa (o teste de estrutura espera exatamente 1 `mojang.ps1` e 2 `Start-MinecraftDownload` no `widget.ps1`: a definição e a chamada em `Set-Pref`; se o comentário que escrevi mencionar o nome, ajuste o comentário, não o teste).

- [ ] **Step 5: Suíte completa e commit**

Run: `powershell -NoProfile -File tools\test.ps1` -> verde.

```bash
git add plugins/opaiva-code-widget/scripts/widget.ps1 plugins/opaiva-code-widget/scripts/strings.json tests/repo.Tests.ps1
git commit -m "feat: Minecraft item in the theme menu, background download and follow-up"
```

---

### Task 6: Documentação, regra do repositório e versão 2.5.0

**Files:**
- Modify: `README.md`, `README.pt-BR.md`, `CHANGELOG.md`, `plugins/opaiva-code-widget/.claude-plugin/plugin.json`
- Test: `tests/repo.Tests.ps1`

- [ ] **Step 1: Regra que falha (nada da Mojang no repositório)**

Em `tests/repo.Tests.ps1`, no `Describe 'repository rules'`:

````powershell
    It 'tracks no Mojang assets: no .ogg or .wav, no image named after a game texture' {
        $files = @(& git -C $repo ls-files)
        $files | Where-Object { $_ -match '\.(ogg|wav)$' } | Should -BeNullOrEmpty
        $files | Where-Object { $_ -match '\.png$' -and $_ -match '(?i)minecraft|dirt|grass|orb|creeper' } | Should -BeNullOrEmpty
    }
    It '<name> says the Minecraft theme downloads from Mojang, and that it is the only network use' -ForEach $readmes {
        $text = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8)
        $text | Should -Match 'piston-meta\.mojang\.com'
        $text | Should -Match 'resources\.download\.minecraft\.net'
        $text | Should -Not -Match '(?i)no network calls and no telemetry\.'
    }
````

Run: `powershell -NoProfile -Command "Import-Module Pester -MinimumVersion 5.5; Invoke-Pester -Path tests\repo.Tests.ps1 -FullNameFilter '*Mojang*' -Output Minimal"`
Expected: o segundo teste falha (README ainda não cita a Mojang e ainda diz "no network calls"). Confirme que `$readmes` já existe no arquivo (os testes de README o usam) e que `$repo` e `$path`/`$name` seguem o mesmo estilo dos testes vizinhos.

- [ ] **Step 2: READMEs**

`README.md`:
- Na tabela da seção "Look and sound", na linha **Theme**, acrescentar `, or Minecraft (see below)`.
- Depois do parágrafo do volume, acrescentar:

````markdown
### Minecraft theme (downloads from Mojang)

The **Minecraft** item in the Theme menu is the only part of the widget that uses the internet, and only once, when you click it. The widget downloads about 4 MB of textures and sounds from Mojang's servers (the same ones the game launcher uses: `piston-meta.mojang.com`, `piston-data.mojang.com` and `resources.download.minecraft.net`) into the plugin data folder (`minecraft\`). The theme switches on when the download ends; if it fails, you keep your current theme and the reason goes to `widget.log`. With the theme on, the cards get square corners, a dirt frame with a strip of grass on top and XP orbs for the status dots, and the sounds change (request: XP orb, finished: item pop, all done: level up). If Windows cannot play `.ogg` files (some Windows N editions), the system sounds stay.

No file from Mojang is part of this repository, and there is no screenshot of this theme for the same reason. Minecraft is a trademark of Mojang Studios and Microsoft; this project is not affiliated with them. To remove the files, delete the `minecraft` folder in the plugin data folder.
````

- Na seção "Security", trocar a frase `Everything stays on your machine. There are no network calls and no telemetry. ...` por: `Everything stays on your machine. There is no telemetry, and the only network use is the optional Minecraft theme's one-time download from Mojang's servers (see above). The only data are files in the plugin data folder, inside your user profile.`

`README.pt-BR.md`: o mesmo, em português, com o título `### Tema Minecraft (baixa da Mojang)` e a frase de segurança `Tudo fica na sua máquina. Não há telemetria, e o único uso da rede é o download único do tema Minecraft, opcional, dos servidores da Mojang (veja acima). Os únicos dados são os arquivos na pasta de dados do plugin, dentro do seu perfil de usuário.` Conferir acentos. A linha do tema na tabela ganha `, ou Minecraft (veja abaixo)`.

- [ ] **Step 3: CHANGELOG e versão**

Entrada nova no topo de `CHANGELOG.md`:

````markdown
## 2.5.0 (2026-10-08)

- **Minecraft theme.** Pick it in the Theme menu: square corners, a dirt frame with a strip of grass, XP orbs for the status dots, and Minecraft sounds (request, finished, all done). The first click downloads about 4 MB of textures and sounds from Mojang's servers into the plugin data folder (nothing from Mojang is in this repository); the theme switches on when the download ends. It is the only part of the widget that uses the internet.
- The README screenshots are now always drawn with the default look, whatever your `prefs.json` says.
````

E `plugin.json`: `"version": "2.5.0"`.

- [ ] **Step 4: Suíte completa**

Run: `powershell -NoProfile -File tools\test.ps1` -> Expected: tudo verde.

- [ ] **Step 5: Conferência manual (registrar no ledger)**

Reiniciar o widget (`hook.ps1 -EnsureWidget`) e conferir: o item **Minecraft (baixa da Mojang)** aparece no submenu Tema; clicar muda o texto para "baixando..." e, em alguns segundos, o tema liga (moldura de terra, grama, orbes); os três sons (um pedido, um aviso de terminou, um tudo pronto) tocam os do jogo; voltar para Escuro/Claro restaura moldura e cantos; reiniciar mantém o tema; com a rede desligada, apagar `minecraft\` e clicar de novo falha só no log.

- [ ] **Step 6: Commit**

```bash
git add README.md README.pt-BR.md CHANGELOG.md plugins/opaiva-code-widget/.claude-plugin/plugin.json tests/repo.Tests.ps1
git commit -m "docs: release 2.5.0 (Minecraft theme)"
```
