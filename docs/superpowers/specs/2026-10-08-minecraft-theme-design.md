# Tema Minecraft (bloco 5b)

Data: 2026-10-08 · Versão alvo: 2.5.0 · Status: aguardando revisão

## Contexto e objetivo

Segunda metade do bloco visual. Acrescenta o tema **Minecraft** ao menu de tema do 5a (que já tem o mecanismo de mapa de cores). As texturas e os sons **não vão no repositório**: o widget os baixa dos servidores da Mojang (os mesmos que o launcher do jogo usa) na primeira vez que o usuário escolhe o tema, como o Claude Monitor faz.

## Decisões (com o usuário)

| Item | Decisão |
|---|---|
| Visual | Cores de pedra e verde, cantos retos, **moldura de terra** com **faixa de grama** no topo e o ponto de status vira **orbe de XP**. Sem fonte do jogo, sem botões de pedra, sem mobs. |
| Sons | Fazem parte do tema: pedido e pergunta tocam o orbe de XP, "terminou" toca o pop de pegar item, "tudo pronto" toca o level up. O volume do menu continua valendo. |
| Download | Só depois do clique em **Minecraft (baixa da Mojang)** no submenu Tema; troca só quando termina; se falhar, fica o tema atual e vai para o log. Nada acontece na rede antes do clique. |
| Fonte dos arquivos | Servidores da Mojang, nunca o repositório (já decidido no bloco 4). O README deixa de dizer "sem rede" para este tema. |

## Fatos conferidos antes de escrever (servidor da Mojang, 2026-10-08)

- **Sons:** o índice de assets da versão traz cada arquivo com seu hash SHA-1; o arquivo está em `https://resources.download.minecraft.net/<2 primeiras letras>/<hash>`. São `.ogg`. O `MediaPlayer` do WPF toca `.ogg` onde o pacote Microsoft Web Media Extensions está instalado (vem com o Windows 10/11 comum, não nas edições N). Quando não toca, o `MediaFailed` do 5a cai no som do sistema.
- **Texturas:** estão no `client.jar` da versão (41 MB, formato zip). O servidor aceita pedidos de faixa (Range), então dá para ler só o índice do zip (3,5 MB) e depois cada textura (200 a 400 bytes). Caminhos usados: `assets/minecraft/textures/block/dirt.png`, `block/grass_block_top.png` (cinza, o jogo pinta de verde) e `entity/experience/experience_orb.png` (folha 64x64 de orbes 16x16, também cinza).
- **Total:** cerca de 4 MB na primeira vez, uma vez só.

## O que muda

### Novo `scripts/mojang.ps1` (o download)

Roda como processo separado e escondido (`powershell.exe -File mojang.ps1 -Dir <pasta de dados>`), então o widget nunca trava. Também pode ser lido por `.` (sem `-Dir`) para os testes usarem as funções.

1. Lê o manifesto de versões e pega a versão `latest.release`; lê o JSON da versão (URL do índice de assets e do `client.jar`) e o índice.
2. **Sons:** `random/orb.ogg` -> `xp.ogg`, `random/pop.ogg` -> `pop.ogg`, `random/levelup.ogg` -> `levelup.ogg`. Cada um é conferido contra o SHA-1 do índice (hash errado = falha) e limitado a 2 MB.
3. **Texturas:** lê o índice do zip por faixas (fim do arquivo, depois o diretório central), acha as 3 entradas, lê cada uma por faixa, descomprime (deflate) e confere tamanho e CRC32 (limite de 2 MB por arquivo). Grava `dirt.png` como veio; `grass.png` multiplicada por `#79C05A`; `orb.png` recortada no quadro (0,0,16,16) e multiplicada por `#C8FF20`.
4. **Só grava depois de ter tudo:** os seis arquivos vão para `<dados>\minecraft\sounds\` e `textures\` (cada um por arquivo temporário + renomear), e por último `status.json` com `ready`. Qualquer falha antes disso deixa `status.json` com `failed` e a mensagem, e nenhum arquivo novo pela metade.
5. `status.json`: `{ state: downloading|ready|failed, message, version, pid, at }`, sempre gravado inteiro de uma vez.

Segurança: as URLs que vêm dos JSON só são seguidas se forem `https` e de `piston-meta.mojang.com`, `piston-data.mojang.com`, `launchermeta.mojang.com` ou `resources.download.minecraft.net`. Nada baixado é executado; só vira PNG ou OGG. Para teste, `CLAUDE_WIDGET_MOJANG=http://127.0.0.1:porta` troca a Mojang por um servidor falso local (e libera qualquer URL só nesse modo). Zip64 não é suportado (falha limpa).

### `common.ps1`

- `Read-Prefs` passa a aceitar `theme = minecraft`; `Resolve-Theme 'minecraft'` devolve `minecraft`; `Get-ColorMap 'minecraft'` devolve o mapa (marrons e verdes; mesmas regras de unicidade do 5a).
- `Get-MinecraftState([string]$Dir)` -> `none`, `downloading`, `ready` ou `failed`: lê `status.json`; `downloading` só vale se o processo do `pid` ainda existe (senão `failed`); `ready` só vale se os seis arquivos existem (senão `none`). `Get-MinecraftMessage([string]$Dir)` devolve a mensagem de falha.

### `widget.ps1`

- XAML: `GrassTop` (faixa de 8 DIP, `IsHitTestVisible=False`, escondida) e nome `IdleDot` no ponto da pílula.
- `Set-ThemeExtras`: com tema `minecraft` **e** estado `ready`, a moldura (`BorderBrush` com `ImageBrush` em mosaico, 32 DIP, ampliação sem suavizar) vira terra com espessura 6 e cantos retos, `GrassTop` aparece e os três pontos (`IdleDot`, `ReqDot`, `QDot`) usam o orbe. Sem estado `ready`, o tema `minecraft` usa só a paleta (cantos retos, sem texturas). Qualquer outro tema restaura moldura, cantos (14) e cores dos pontos.
- `Set-SoundSet`: com `minecraft` + `ready`, `request`, `done` e `allDone` usam `xp.ogg`, `pop.ogg` e `levelup.ogg`; senão, os de antes (som de esquema do Windows, `Notify` e `tada`). Se o Windows não toca o `.ogg`, vale o fallback do 5a (som do sistema).
- `Set-LookTheme` junta `Set-Theme`, `Set-ThemeExtras` e `Set-SoundSet`; o início do widget e `Set-Pref 'theme'` passam por ele.
- Menu: o submenu Tema ganha **Minecraft**. O texto muda com o estado: `Minecraft (baixa da Mojang)` (nenhum/falhou), `Minecraft (baixando...)` (baixando), `Minecraft` (pronto). Clicar sem estado `ready` inicia `mojang.ps1` (sem trocar nada) e passa a acompanhar; quando o estado vira `ready` o widget aplica e grava o tema; se virar `failed` (ou 30 s sem nenhum status), registra a mensagem no `widget.log` e fica como estava. O acompanhamento roda junto do ciclo de ~2 s que já existe.
- Modo `-RenderSamples` passa a usar sempre as preferências padrão em vez do `prefs.json` do desenvolvedor (corrige o menor 2 da revisão do 5a); `-Theme` e `-DataDir` continuam valendo.

### Textos e documentação

- `strings.json` (pt e en): `themeMinecraft`, `themeMinecraftDownload`, `themeMinecraftBusy`.
- READMEs: linha do tema Minecraft na tabela de aparência; um parágrafo dizendo que **este tema, e só ele, usa a internet**, uma vez, ao ser escolhido: baixa cerca de 4 MB de `piston-meta.mojang.com`, `piston-data.mojang.com` e `resources.download.minecraft.net` para a pasta de dados do plugin; que nenhum arquivo da Mojang está neste repositório; que Minecraft é marca da Mojang/Microsoft e o projeto não tem vínculo com elas; como apagar (`minecraft\` na pasta de dados). Onde o README diz que o widget não usa rede, passa a dizer "exceto o tema Minecraft".
- **Sem print do tema Minecraft** no repositório: seria uma cópia de texturas da Mojang.
- `CHANGELOG.md` 2.5.0 e `plugin.json` 2.5.0.

## Riscos aceitos

- **Mudança na Mojang:** um arquivo renomeado numa versão nova faz o download falhar limpo (mensagem no log); o tema continua só com cores. Corrigir é trocar o caminho no script.
- **Custo do download:** 3,5 MB do índice do jar a cada primeira instalação do tema, mais ou menos 5 a 10 segundos de leitura do diretório em PowerShell, em segundo plano.
- **Marca registrada:** o aviso fica no README; o repositório não contém nada da Mojang.
- **`.ogg` no Windows N:** sem os Web Media Extensions o tema fica com a aparência e os sons do sistema.
- **O `pid` do download pode ser reaproveitado** pelo Windows: no pior caso um `downloading` antigo parece vivo; vira `failed` quando o processo some.
- **Testes:** a aparência real e o som não têm teste automático (as texturas de teste são imagens sintéticas); a leitura do zip, o tingimento, o download completo contra um servidor falso, a recusa de hash errado e a janela com o cache falso têm.

## Testes e verificação

1. `common.Tests.ps1`: `theme = minecraft` em `Read-Prefs` e `Resolve-Theme`; `Get-ColorMap 'minecraft'` com valores únicos e disjuntos das chaves (e fora das cores nativas); `Get-MinecraftState` nos quatro estados, incluindo `downloading` com processo morto e `ready` com arquivo faltando.
2. `mojang.Tests.ps1` (novo): `Get-Crc32` contra valores conhecidos; `Read-ZipIndex` e `Get-ZipEntryBytes` contra um zip montado no teste (deflate e armazenado, CRC errado, entrada grande demais, zip64); tingimento e recorte com imagens sintéticas; URL permitida e proibida; **download completo** contra um servidor falso local (`HttpListener`, com suporte a Range): arquivos e `status.json ready`, sem arquivo pela metade quando um som tem hash errado, falha limpa com 404 e com servidor ignorando Range.
3. `widget.Tests.ps1` (Desktop): o print com `-Theme minecraft -DataDir <cache falso>` tem a borda da cor da textura falsa (terra vermelha sólida) e, sem cache, a paleta de pedra sem textura; o print padrão ignora um `prefs.json` com tema claro; widget real com `theme = minecraft` e cache falso (e sem cache) abre sem erro no `widget.log`.
4. `repo.Tests.ps1`: nenhum `.ogg` ou `.wav` rastreado, e nenhuma imagem rastreada com nome de textura do jogo.
5. À mão: escolher Minecraft no menu, ver o texto virar "baixando...", a troca ao terminar, a moldura de terra e a grama, o orbe, os três sons, voltar para escuro/claro (moldura de volta), reiniciar mantendo o tema, e desconectar a rede e tentar de novo (falha só no log).

## Fora do escopo

Fonte do jogo, botões de pedra, mobs e animações, o Ender Dragon, outras versões do jogo, atualizar as texturas depois de baixadas, desinstalar pelo menu (apagar a pasta `minecraft\` à mão).
