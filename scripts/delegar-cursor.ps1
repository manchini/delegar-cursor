<#
.SYNOPSIS
  Despacha uma tarefa para o Cursor CLI (agent) em modo headless, com roteamento
  de modelo consciente de custo. Agnostico de repositorio.

.DESCRIPTION
  Delega trabalho para a cota da Cursor, poupando a janela de 5h da Anthropic.
  Cliente principal: Claude Code (Opus, thinking low) como orquestrador.

  POOLS (conta Pro+):
    abrangente : composer-2.5 e cursor-grok-4.x-*  -> uso liberal
    premium    : opus-5, codex-5.3, gpt-5.6, sonnet-5, fable-5 -> cota paga

  O CLI da Cursor NAO expoe comando de quota agregada (verificado em --help e
  about) - nao da para perguntar "quanto sobrou do mes". Mas com
  --output-format stream-json o evento final 'result' traz usage POR RUN
  (inputTokens/outputTokens/cache*), e o script grava isso no frontmatter do
  log e do sidecar de HANDOFF. Controle de gasto: POLITICA no despacho +
  MEDICAO por despacho.

    1. O default e SEMPRE pool abrangente.
    2. DENTRO do pool abrangente, esforco nao custa cota - custa LATENCIA. Nao
       existe razao para racionar qualidade ali: o default e o teto (xhigh).
    3. A unica fronteira que importa e a do pool. Qualquer modelo fora do
       abrangente exige -Premium explicito. Modelo desconhecido e tratado como
       premium (falha segura).

  ESCALONAMENTO (deliberadamente nao automatizado):
    Rode no pool abrangente primeiro - e ele ja roda no teto de esforco. So
    escale quando o sidecar de HANDOFF voltar com Bloqueios preenchido, ou
    quando a revisao reprovar a saida. Follow-up no mesmo worker: -Continuar.
    Escalacao premium e um RUN NOVO, nao -Continuar.

  SAIDA PARA O PAI (Claude Code):
    Quando o stdout esta redirecionado (despacho por agente) e nao ha -AoVivo,
    o default e imprimir so o caminho do sidecar *.handoff.md - o pai le isso,
    nao o log completo. -SoLog forca o mesmo em terminal. -AoVivo ecoa o
    stream para o humano; nao use quando quem despacha e um agente.

  CODIGOS DE SAIDA:
    0  run ok, HANDOFF presente, Bloqueios vazio/nenhum
    1  falha do CLI / run
    2  run terminou mas HANDOFF ausente ou Bloqueios preenchido

.PARAMETER Repo
  Raiz do repositorio alvo. Default: repo git do diretorio atual.

.PARAMETER Perfil
  varredura   : grok-4.6-high  | read-only | trivial e com pressa (unico degrau abaixo do teto)
  analise     : grok-4.6-xhigh | read-only | entender, comparar, auditar
  plano       : grok-4.6-xhigh | read-only | design e fases
  lote        : composer-2.5   | ESCRITA   | volume mecanico: rename, boilerplate, aplicar spec pronta
  implementar : grok-4.6-xhigh | ESCRITA   | implementacao que exige raciocinio
  critico     : opus-5-thinking| read-only | PREMIUM - revisao de alto impacto
  debug       : codex-5.3-high | ESCRITA   | PREMIUM - bug que o pool abrangente nao resolveu

.PARAMETER Premium
  Libera modelo do pool pago. Obrigatorio para -Perfil critico/debug ou
  -Modelo fora do pool abrangente.

.PARAMETER Continuar
  Retoma a sessao mais recente com o mesmo -Rotulo (frontmatter sessao:).
  O enunciado deve ser o follow-up curto, nao o brief original.

.PARAMETER Sessao
  Id de sessao explicito para --resume. Tem precedencia sobre -Continuar.

.PARAMETER AoVivo
  Ecoa os fragmentos no console conforme chegam. Use ao rodar de um terminal
  humano. NAO use quando quem despacha e um agente.

.PARAMETER SoLog
  Imprime apenas o caminho do sidecar de HANDOFF. Forca o modo agente mesmo
  em terminal interativo. Em stdout redirecionado isso ja e o default.

.EXAMPLE
  .\delegar-cursor.ps1 -Perfil analise -Tarefa "Compare os docs de arquitetura"

.EXAMPLE
  .\delegar-cursor.ps1 -Perfil implementar -Arquivo .delegacao/briefs/fase-01.md -Rotulo fase01 -SoLog

.EXAMPLE
  .\delegar-cursor.ps1 -Perfil implementar -Continuar -Rotulo fase01 -Tarefa "O HANDOFF pediu o teste de mapa. So isso."
#>
[CmdletBinding()]
param(
    [Parameter(ParameterSetName = 'Inline', Mandatory = $true)]
    [string] $Tarefa,

    [Parameter(ParameterSetName = 'Arquivo', Mandatory = $true)]
    [string] $Arquivo,

    [string] $Repo,

    [ValidateSet('varredura', 'analise', 'plano', 'lote', 'implementar', 'critico', 'debug')]
    [string] $Perfil = 'analise',

    [string] $Modelo,

    [switch] $Premium,

    [string] $Rotulo = 'tarefa',

    [string] $DirLog,

    [switch] $SemLog,

    [switch] $AoVivo,

    [switch] $SoLog,

    [switch] $Continuar,

    [string] $Sessao
)

$ErrorActionPreference = 'Stop'

# --- tabela de roteamento ----------------------------------------------------
# Dentro do pool abrangente o esforco NAO custa cota - custa latencia. Por isso
# o default e o teto (xhigh); 'varredura' existe so para quando a resposta
# precisa voltar rapido e a tarefa e trivial.
$rotas = @{
    'varredura'    = @{ modelo = 'cursor-grok-4.6-high';        acesso = 'ask'   }
    'analise'      = @{ modelo = 'cursor-grok-4.6-xhigh';       acesso = 'ask'   }
    # NAO use acesso='plan' aqui: --mode plan e feito para a TUI interativa
    # (o plano vai para aprovacao na interface) e em -p headless nao emite NADA
    # no stdout - verificado, 232s de run com saida vazia. Rascunho de plano e
    # analise read-only que devolve markdown; quem define que e plano e o
    # enunciado, nao a flag.
    'plano'        = @{ modelo = 'cursor-grok-4.6-xhigh';       acesso = 'ask'   }
    'lote'         = @{ modelo = 'composer-2.5';                acesso = 'write' }
    'implementar'  = @{ modelo = 'cursor-grok-4.6-xhigh';       acesso = 'write' }
    'critico'      = @{ modelo = 'claude-opus-5-thinking-high'; acesso = 'ask'   }
    'debug'        = @{ modelo = 'gpt-5.3-codex-high';          acesso = 'write' }
}

$rota = $rotas[$Perfil]
if (-not $Modelo) { $Modelo = $rota.modelo }
$acesso = $rota.acesso

# --- classificacao de pool (falha segura: desconhecido = premium) ------------
function Get-Pool([string] $m) {
    if ($m -match '^(composer-|cursor-grok-)' -or $m -eq 'auto') { return 'abrangente' }
    return 'premium'
}
$pool = Get-Pool $Modelo

if ($pool -eq 'premium' -and -not $Premium) {
    Write-Host ''
    Write-Host "  BLOQUEADO: '$Modelo' esta no pool PREMIUM (cota paga da Cursor)." -ForegroundColor Yellow
    Write-Host ''
    Write-Host '  O pool abrangente ja roda no teto de esforco. Tente primeiro:' -ForegroundColor Gray
    Write-Host '    -Perfil implementar  (grok-4.6-xhigh, ESCRITA)' -ForegroundColor Gray
    Write-Host '    -Perfil analise      (grok-4.6-xhigh, read-only)' -ForegroundColor Gray
    Write-Host ''
    Write-Host '  Follow-up no mesmo worker: -Continuar (nao e escalonamento).' -ForegroundColor Gray
    Write-Host '  Se realmente precisa de premium, repita o comando com -Premium.' -ForegroundColor Gray
    Write-Host ''
    throw 'Uso de modelo premium exige -Premium explicito.'
}

# --- binario -----------------------------------------------------------------
$agentExe = Join-Path $env:LOCALAPPDATA 'cursor-agent\agent.cmd'
if (-not (Test-Path $agentExe)) {
    throw "Cursor CLI nao encontrado em $agentExe. Instale com: irm 'https://cursor.com/install?win32=true' | iex"
}

# --- raiz do repo (antes da validacao lenta de slug e do --resume) -----------
if ($Repo) {
    if (-not (Test-Path $Repo)) { throw "Repo nao encontrado: $Repo" }
    $repoRaiz = (Resolve-Path $Repo).Path
} else {
    $repoRaiz = (& git rev-parse --show-toplevel 2>$null)
    if (-not $repoRaiz) { $repoRaiz = (Get-Location).Path }
}
$repoRaiz = $repoRaiz -replace '/', '\'
if (-not $DirLog) { $DirLog = Join-Path $repoRaiz '.delegacao\logs' }

function Get-SessaoAnterior {
    param([string[]] $Dirs, [string] $RotuloBusca)
    foreach ($d in $Dirs) {
        if (-not $d -or -not (Test-Path $d)) { continue }
        $cands = Get-ChildItem -Path $d -File -Filter "*-$RotuloBusca.md" -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -notlike '*.handoff.md' -and $_.Name -notlike '*.live' } |
            Sort-Object Name -Descending
        foreach ($f in @($cands)) {
            $head = Get-Content -Path $f.FullName -TotalCount 30 -Encoding UTF8 -ErrorAction SilentlyContinue
            foreach ($linha in @($head)) {
                if ($linha -match '^sessao:\s*(\S+)\s*$' -and $Matches[1] -and $Matches[1] -ne '') {
                    return $Matches[1]
                }
            }
        }
    }
    return $null
}

$sessaoResume = $null
if ($Sessao) {
    $sessaoResume = $Sessao.Trim()
} elseif ($Continuar) {
    if ($Rotulo -eq 'tarefa') {
        Write-Host '[delegar] AVISO: -Continuar com -Rotulo default (tarefa) pode retomar a sessao errada.' -ForegroundColor Yellow
    }
    $sessaoResume = Get-SessaoAnterior -Dirs @($DirLog, (Join-Path $repoRaiz '.delegacao\logs'), (Join-Path $repoRaiz '.delegacao')) -RotuloBusca $Rotulo
    if (-not $sessaoResume) {
        throw "Nenhuma sessao anterior com rotulo '$Rotulo' em $DirLog. Rode sem -Continuar primeiro."
    }
}

# --- validacao de slug (cache 12h; so recarrega em miss ou cache velho) ------
function Get-ModelosConhecidos {
    param([string] $Exe, [switch] $Forcar)
    $cache = Join-Path $env:TEMP 'delegar-cursor-models.txt'
    $preciso = $Forcar
    if (-not $preciso -and (Test-Path $cache)) {
        $idadeH = ((Get-Date) - (Get-Item $cache).LastWriteTime).TotalHours
        if ($idadeH -ge 12) { $preciso = $true }
    } elseif (-not (Test-Path $cache)) {
        $preciso = $true
    }
    if ($preciso) {
        $pref = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $raw = & $Exe --list-models 2>$null
            $ids = New-Object System.Collections.Generic.List[string]
            foreach ($linha in @($raw)) {
                $s = [string] $linha
                if ($s -match '^([A-Za-z0-9][A-Za-z0-9._:-]*)\s+-\s+') {
                    [void] $ids.Add($Matches[1])
                }
            }
            if ($ids.Count -gt 0) {
                $ids | Set-Content -Path $cache -Encoding ASCII
            }
        } catch {
            # offline / CLI mudou: segue sem validar
        } finally {
            $ErrorActionPreference = $pref
        }
    }
    if (Test-Path $cache) {
        return @(Get-Content -Path $cache -Encoding ASCII)
    }
    return @()
}

$idsConhecidos = Get-ModelosConhecidos -Exe $agentExe
if ($idsConhecidos.Count -gt 0 -and ($idsConhecidos -notcontains $Modelo)) {
    $idsConhecidos = Get-ModelosConhecidos -Exe $agentExe -Forcar
    if ($idsConhecidos.Count -gt 0 -and ($idsConhecidos -notcontains $Modelo)) {
        Write-Host ''
        Write-Host "  BLOQUEADO: '$Modelo' nao aparece em agent --list-models." -ForegroundColor Yellow
        Write-Host '  O slug envelheceu ou foi digitado errado. Rode:' -ForegroundColor Gray
        Write-Host '    agent --list-models' -ForegroundColor Gray
        Write-Host '  e atualize o perfil na skill delegar-cursor.' -ForegroundColor Gray
        Write-Host ''
        throw "Modelo '$Modelo' indisponivel nesta conta Cursor."
    }
} elseif ($idsConhecidos.Count -eq 0) {
    Write-Host '[delegar] aviso: nao deu para validar o slug (cache vazio / --list-models falhou). Seguindo.' -ForegroundColor DarkYellow
}

# --- cli.json: escrita sem allowlist nao consegue se verificar ---------------
$cliJson = Join-Path $repoRaiz '.cursor\cli.json'
if ($acesso -eq 'write' -and -not (Test-Path $cliJson)) {
    Write-Host '[delegar] AVISO: sem .cursor/cli.json neste repo.' -ForegroundColor Yellow
    Write-Host '  lote/implementar escrevem arquivos, mas cargo/npm/git de verificacao podem ser bloqueados.' -ForegroundColor Yellow
    Write-Host '  Copie referencia/cli-json-template.json (ou .windows.json) da skill.' -ForegroundColor Yellow
}

# --- contexto do repo: TODOS os arquivos de convencao, nao so o primeiro -----
$arqsConvencao = @('CLAUDE.md', 'AGENTS.md', '.cursorrules') |
    ForEach-Object { Join-Path $repoRaiz $_ } |
    Where-Object { Test-Path $_ }

if ($arqsConvencao) {
    $nomesConv = ($arqsConvencao | ForEach-Object { Split-Path $_ -Leaf }) -join ', '
    $blocoConvencao = @"
Este repositorio tem convencoes proprias em: $nomesConv (raiz). LEIA cada um
desses arquivos antes de qualquer alteracao e siga o que determinam sobre
encoding, estrutura e padrao de commit. Se indicarem arquivos com encoding
legado (ANSI/Windows-1252 ou UTF-8 com BOM), NAO reescreva esses arquivos via
redirecionamento de shell - use edicao pontual.
"@
} else {
    $blocoConvencao = @"
Este repositorio nao tem arquivo de convencoes na raiz. Siga o estilo do codigo
existente ao redor do que voce alterar.
"@
}

# --- tarefa ------------------------------------------------------------------
if ($PSCmdlet.ParameterSetName -eq 'Arquivo') {
    $caminhoTarefa = if ([System.IO.Path]::IsPathRooted($Arquivo)) { $Arquivo } else { Join-Path $repoRaiz $Arquivo }
    if (-not (Test-Path $caminhoTarefa)) { throw "Arquivo de tarefa nao encontrado: $caminhoTarefa" }
    $corpo = Get-Content -Path $caminhoTarefa -Raw -Encoding UTF8
    $origem = (Resolve-Path $caminhoTarefa).Path
} else {
    $corpo = $Tarefa
    $origem = '(inline)'
}

# --- caminhos de saida -------------------------------------------------------
$carimbo    = Get-Date -Format 'yyyyMMdd-HHmmss'
$arqLog     = Join-Path $DirLog "$carimbo-$Perfil-$Rotulo.md"
$arqHandoff = Join-Path $DirLog "$carimbo-$Perfil-$Rotulo.handoff.md"
$arqLive    = "$arqLog.live"

# --- preambulo ---------------------------------------------------------------
$blocoGit = @"
NAO execute git add, git commit, git push, git checkout, git reset nem git clean.
O commit fica a cargo de quem despachou. Voce so edita arquivos e roda
verificacao (test, build, fmt, clippy) que TERMINA.
Nao suba servidor de longa duracao (cargo run em foreground, npm run dev,
vite dev). Se a tarefa pedir um processo no ar, declare isso em Bloqueios
em vez de deixa-lo rodando.
"@

$blocoHandoff = @"
Se a tarefa exceder o que voce consegue resolver com confianca, PARE e declare
isso em 'Bloqueios' em vez de entregar trabalho incerto. O bloqueio e o que
dispara escalonamento para um modelo maior; trabalho incerto disfarcado de
pronto sai mais caro que a parada.

Ao terminar, encerre a resposta com uma secao exatamente assim:

## HANDOFF
- Feito: <o que foi concluido>
- Arquivos tocados: <lista de caminhos, ou 'nenhum'>
- Pendente: <o que ficou faltando>
- Proximo passo: <acao unica e concreta>
- Bloqueios: <o que exige decisao humana ou modelo maior, ou 'nenhum'>
"@

if ($sessaoResume) {
    $preambulo = @"
Continuacao da mesma sessao. Nao releia o repositorio do zero: use o contexto
ja carregado. So faca o que o follow-up pede.

$blocoGit

Responda em portugues do Brasil.

$blocoHandoff

--- TAREFA ---
$corpo
"@
} else {
    $preambulo = @"
$blocoConvencao

$blocoGit

Responda em portugues do Brasil.

$blocoHandoff

--- TAREFA ---
$corpo
"@
}

# --- flags -------------------------------------------------------------------
# stream-json + stream-partial-output: da fragmentos ao vivo E o evento 'result'
# final com usage por run. --stream-partial-output SO funciona com -p e
# stream-json; com --output-format text nao ha fragmento nenhum.
$flags = @('-p', '--trust', '--output-format', 'stream-json', '--stream-partial-output', '--model', $Modelo)
if ($sessaoResume) { $flags += @('--resume', $sessaoResume) }
if ($acesso -ne 'write') { $flags += @('--mode', $acesso) }

# --- stdout do pai: sidecar quando nao ha TTY --------------------------------
$saidaRedirecionada = $false
try { $saidaRedirecionada = [Console]::IsOutputRedirected } catch { }
$modoAgente = [bool] $SoLog -or (-not $AoVivo -and $saidaRedirecionada)

$semBom = New-Object System.Text.UTF8Encoding($false)
if (-not $SemLog -and -not (Test-Path $DirLog)) {
    New-Item -ItemType Directory -Path $DirLog -Force | Out-Null
}

$cor = if ($pool -eq 'premium') { 'Yellow' } else { 'Cyan' }
Write-Host "[delegar] perfil=$Perfil modelo=$Modelo pool=$pool acesso=$acesso" -ForegroundColor $cor
Write-Host "[delegar] repo=$repoRaiz origem=$origem" -ForegroundColor DarkGray
if ($sessaoResume) { Write-Host "[delegar] resume=$sessaoResume" -ForegroundColor DarkGray }
if (-not $SemLog) { Write-Host "[delegar] ao vivo: Get-Content -Wait '$arqLive'" -ForegroundColor DarkGray }

# --- executar e consumir o stream --------------------------------------------
$acumulado  = New-Object System.Text.StringBuilder
$script:textoFinal = $null
$script:sessao     = $null
$script:usoIn = $null; $script:usoOut = $null
$script:usoCacheR = $null; $script:usoCacheW = $null
$script:durApi  = $null
$script:erroRun = $false
$script:acumulado = $acumulado
$script:erros = New-Object System.Text.StringBuilder

$escritorLive = $null
if (-not $SemLog) {
    $escritorLive = New-Object System.IO.StreamWriter($arqLive, $false, $semBom)
    $escritorLive.AutoFlush = $true
}
$script:escritorLive = $escritorLive
$mostrar = [bool] $AoVivo
$script:mostrar = $mostrar
$script:bufMsg  = New-Object System.Text.StringBuilder
$script:raiz    = $repoRaiz

# Emite no .live e, se -AoVivo, no console. Unico ponto de saida do stream.
function Write-Fluxo([string] $texto, [string] $corConsole) {
    if ($script:escritorLive) { $script:escritorLive.Write($texto) }
    if ($script:mostrar) {
        if ($corConsole) { Write-Host $texto -NoNewline -ForegroundColor $corConsole }
        else             { Write-Host $texto -NoNewline }
    }
}

# O nome da ferramenta e a chave que termina em 'ToolCall' (readToolCall,
# editToolCall, ...). Extracao generica de proposito: ferramenta nova aparece
# com o nome cru em vez de sumir da trilha.
function Get-ResumoFerramenta($tc) {
    $chave = $tc.PSObject.Properties.Name | Where-Object { $_ -like '*ToolCall' } | Select-Object -First 1
    if (-not $chave) { return $null }
    $nome = $chave -replace 'ToolCall$', ''
    # NAO usar $args: e variavel automatica do PowerShell.
    $argumentos = $tc.$chave.args
    $alvo = ''
    foreach ($campo in @('path', 'filePath', 'command', 'query', 'pattern', 'globPattern', 'url')) {
        if ($argumentos -and ($argumentos.PSObject.Properties.Name -contains $campo)) {
            $alvo = [string] $argumentos.$campo
            break
        }
    }
    # Ferramenta desconhecida: cai no primeiro argumento textual, em vez de sair
    # sem alvo nenhum.
    if (-not $alvo -and $argumentos) {
        foreach ($prop in $argumentos.PSObject.Properties) {
            if ($prop.Value -is [string] -and $prop.Value) { $alvo = $prop.Value; break }
        }
    }
    # -replace ja e case-insensitive, entao diferenca de caixa nao atrapalha.
    if ($alvo -and $script:raiz) {
        $alvo = $alvo -replace [regex]::Escape($script:raiz + '\'), ''
    }
    # Se ainda sobrou caminho absoluto, o prefixo nao casou - nome curto 8.3,
    # junction, drive mapeado. Em vez de despejar a raiz inteira, mostra so as
    # ultimas partes: o que identifica o arquivo esta no fim, nao no comeco.
    if ($alvo -match '^[A-Za-z]:\\') {
        $partes = $alvo.Split('\')
        if ($partes.Count -gt 3) { $alvo = '...\' + ($partes[-3..-1] -join '\') }
    }
    $alvo = ($alvo -replace '\s+', ' ').Trim()
    # Trunca pela ESQUERDA pelo mesmo motivo: o fim e o que informa.
    if ($alvo.Length -gt 100) { $alvo = '...' + $alvo.Substring($alvo.Length - 97) }
    if ($alvo) { return "$nome $alvo" } else { return $nome }
}

$inicio = Get-Date
$codigoSaida = 0
$prefAntes = $ErrorActionPreference
Push-Location $repoRaiz
try {
    # Em PS 5.1 o stderr de um exe nativo vira ErrorRecord no pipeline, e com
    # ErrorActionPreference='Stop' isso ABORTA o run - inclusive por um aviso
    # inofensivo do proprio CLI. Redirecionar com '2>arquivo' NAO resolve
    # (verificado: continua lancando e o arquivo sai vazio). Entao: 'Continue'
    # local, '2>&1' para trazer tudo, e classificacao item a item aqui dentro.
    $ErrorActionPreference = 'Continue'
    $preambulo | & $agentExe @flags 2>&1 | ForEach-Object {
        if ($_ -is [System.Management.Automation.ErrorRecord]) {
            [void] $script:erros.AppendLine([string] $_)
            return
        }
        $linha = [string] $_
        if (-not $linha.StartsWith('{')) { return }

        try { $evt = $linha | ConvertFrom-Json } catch { return }
        $temTs = $evt.PSObject.Properties.Name -contains 'timestamp_ms'

        switch ($evt.type) {
            'system' {
                if ($evt.subtype -eq 'init') { $script:sessao = $evt.session_id }
            }
            'thinking' {
                if ($evt.subtype -eq 'delta' -and $mostrar) {
                    Write-Host $evt.text -NoNewline -ForegroundColor DarkGray
                }
            }
            'tool_call' {
                # Num run de escrita quase todo o tempo e ferramenta; sem isso a
                # trilha ao vivo fica so com a narracao entre as chamadas.
                # Renderiza em 'started' - o valor e ver o que esta rodando
                # AGORA, nao depois que terminou.
                if ($evt.subtype -ne 'started') { return }
                $resumo = Get-ResumoFerramenta $evt.tool_call
                if (-not $resumo) { return }
                if ($script:bufMsg.Length -gt 0) { Write-Fluxo "`n" $null }
                Write-Fluxo "`n  > $resumo`n" 'DarkCyan'
                [void] $script:bufMsg.Clear()
            }
            'assistant' {
                # DOIS tipos de repeticao existem, e ambos duplicariam o texto:
                #  1. o evento final da resposta inteira, SEM timestamp_ms;
                #  2. o ultimo fragmento de CADA mensagem, que repete a mensagem
                #     completa e COM timestamp_ms (verificado em run de escrita
                #     multi-turno). Por isso nao da para filtrar so por ts:
                #     compara-se o fragmento com o que ja foi acumulado na
                #     mensagem corrente.
                if (-not $temTs) { [void] $script:bufMsg.Clear(); return }
                $frag = $evt.message.content[0].text
                if ($null -eq $frag) { return }
                if ($script:bufMsg.Length -gt 0 -and $frag -eq $script:bufMsg.ToString()) {
                    [void] $script:bufMsg.Clear()
                    return
                }
                [void] $script:bufMsg.Append($frag)
                [void] $script:acumulado.Append($frag)
                Write-Fluxo $frag $null
            }
            'result' {
                $script:textoFinal = $evt.result
                $script:durApi     = $evt.duration_api_ms
                if ($evt.is_error) { $script:erroRun = $true }
                if ($evt.usage) {
                    $script:usoIn     = $evt.usage.inputTokens
                    $script:usoOut    = $evt.usage.outputTokens
                    $script:usoCacheR = $evt.usage.cacheReadTokens
                    $script:usoCacheW = $evt.usage.cacheWriteTokens
                }
            }
        }
    }
    $codigoSaida = $LASTEXITCODE
} finally {
    $ErrorActionPreference = $prefAntes
    Pop-Location
    if ($escritorLive) { $escritorLive.Dispose() }
}
$dur = [int]((Get-Date) - $inicio).TotalSeconds
if ($mostrar) { Write-Host '' }

# 'result' e a fonte da verdade do texto final; os fragmentos sao o fallback
# para o caso de o run morrer antes de emitir o evento final.
$saida = if ($script:textoFinal) { $script:textoFinal } else { $acumulado.ToString() }

$erroTexto = $script:erros.ToString().Trim()
if ($null -ne $codigoSaida -and $codigoSaida -ne 0) { $script:erroRun = $true }
# Sem texto final E com stderr: o run morreu antes de responder.
if (-not $saida -and $erroTexto) { $script:erroRun = $true }

if ($script:erroRun) {
    Write-Host "[delegar] FALHA (exit=$codigoSaida)" -ForegroundColor Red
    if ($erroTexto) { Write-Host $erroTexto.Trim() -ForegroundColor DarkRed }
}

# --- HANDOFF medido (nao so auto-declarado) ----------------------------------
function Get-BlocoHandoff([string] $texto) {
    if (-not $texto) { return $null }
    $m = [regex]::Match($texto, '(?ms)^## HANDOFF\s*\r?\n.*')
    if ($m.Success) { return $m.Value.TrimEnd() }
    return $null
}

function Get-TextoBloqueios([string] $handoff) {
    if (-not $handoff) { return $null }
    $m = [regex]::Match($handoff, '(?im)^(?:[-*]\s*)?Bloqueios:\s*(.+)$')
    if ($m.Success) { return $m.Groups[1].Value.Trim() }
    return $null
}

function Test-BloqueiosNenhum([string] $valor) {
    if ($null -eq $valor) { return $false }
    $norm = $valor.Trim().TrimEnd('.').Trim()
    return [bool] ($norm -match '^(?i:nenhum[ao]?|n/?a|none|-|—)$')
}

function Get-EvidenciaGit([string] $raiz) {
    $status = ''
    $diff = ''
    $pref = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    Push-Location $raiz
    try {
        $status = ((& git status --short 2>$null) | Out-String).TrimEnd()
        $diff   = ((& git diff --stat 2>$null) | Out-String).TrimEnd()
    } catch {
        $status = '(git status indisponivel)'
    } finally {
        Pop-Location
        $ErrorActionPreference = $pref
    }
    if (-not $status) { $status = '(limpo)' }
    if (-not $diff) { $diff = '(sem diff staged/unstaged em arquivos rastreados)' }
    return @{ status = $status; diff = $diff }
}

$blocoHandoffOut = Get-BlocoHandoff $saida
$textoBloqueios  = Get-TextoBloqueios $blocoHandoffOut
$bloqueiosNenhum = Test-BloqueiosNenhum $textoBloqueios
$codigoHandoff   = 0
if (-not $script:erroRun) {
    if (-not $blocoHandoffOut) {
        $codigoHandoff = 2
        Write-Host '[delegar] HANDOFF ausente (exit=2)' -ForegroundColor Yellow
    } elseif (-not $bloqueiosNenhum) {
        $codigoHandoff = 2
        Write-Host "[delegar] Bloqueios: $textoBloqueios (exit=2)" -ForegroundColor Yellow
    }
}

$evidencia = $null
if ($acesso -eq 'write' -and -not $SemLog) {
    $evidencia = Get-EvidenciaGit $repoRaiz
}

$resumoUso = if ($null -ne $script:usoIn) { "tokens_in=$($script:usoIn) tokens_out=$($script:usoOut) cache_r=$($script:usoCacheR)" } else { 'usage=indisponivel' }
Write-Host "[delegar] $dur s | pool=$pool | $resumoUso" -ForegroundColor DarkGray

$sessaoLog = $script:sessao
if (-not $sessaoLog -and $sessaoResume) { $sessaoLog = $sessaoResume }

$bloqueiosFm = if ($null -ne $textoBloqueios -and $textoBloqueios -ne '') { $textoBloqueios } else { '(ausente)' }

if (-not $SemLog) {
    $cabecalho = @"
---
data: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
perfil: $Perfil
modelo: $Modelo
pool: $pool
acesso: $acesso
duracao_s: $dur
duracao_api_ms: $($script:durApi)
tokens_in: $($script:usoIn)
tokens_out: $($script:usoOut)
cache_read: $($script:usoCacheR)
cache_write: $($script:usoCacheW)
sessao: $sessaoLog
resume: $(if ($sessaoResume) { $sessaoResume } else { '' })
erro: $(if ($script:erroRun) { 'sim' } else { 'nao' })
saida: $(if ($script:erroRun) { '1' } elseif ($codigoHandoff -eq 2) { '2' } else { '0' })
bloqueios: $bloqueiosFm
repo: $repoRaiz
origem: $origem
rotulo: $Rotulo
---

"@
    $corpoLog = $cabecalho + "`n" + $saida
    if ($script:erroRun -and $erroTexto) {
        $corpoLog += "`n`n## STDERR`n`n" + '```' + "`n" + $erroTexto.Trim() + "`n" + '```' + "`n"
    }
    # UTF-8 SEM BOM: Out-File -Encoding utf8 no PS 5.1 grava BOM, e o BOM antes
    # do '---' quebra parser de frontmatter que venha a ler esta trilha.
    [System.IO.File]::WriteAllText($arqLog, $corpoLog, $semBom)

    $corpoHandoff = $cabecalho
    $corpoHandoff += "`n"
    if ($blocoHandoffOut) {
        $corpoHandoff += $blocoHandoffOut.TrimEnd() + "`n"
    } else {
        $corpoHandoff += "## HANDOFF`n`n(ausente na resposta do worker)`n"
    }
    if ($evidencia) {
        $cerca = '```'
        $corpoHandoff += "`n## Evidencia git`n`n"
        $corpoHandoff += "Medido no checkout depois do run, nao o que o worker declarou.`n`n"
        $corpoHandoff += "### git status --short`n`n" + $cerca + "`n" + $evidencia.status + "`n" + $cerca + "`n`n"
        $corpoHandoff += "### git diff --stat`n`n" + $cerca + "`n" + $evidencia.diff + "`n" + $cerca + "`n"
    }
    if ($script:erroRun -and $erroTexto) {
        $corpoHandoff += "`n## STDERR`n`n" + '```' + "`n" + $erroTexto.Trim() + "`n" + '```' + "`n"
    }
    [System.IO.File]::WriteAllText($arqHandoff, $corpoHandoff, $semBom)

    # O .live so existia para acompanhamento durante o run; o .md e o registro.
    Remove-Item $arqLive -Force -ErrorAction SilentlyContinue
    Write-Host "[delegar] handoff: $arqHandoff" -ForegroundColor DarkGray
    Write-Host "[delegar] log: $arqLog" -ForegroundColor DarkGray
}

if ($SemLog) {
    if (-not $mostrar) { Write-Output $saida }
} elseif ($modoAgente) {
    Write-Output $arqHandoff
} elseif (-not $mostrar) {
    Write-Output $saida
}

# Sinaliza ao chamador sem estourar excecao: os arquivos ja foram gravados.
# 1 = run quebrou; 2 = terminou mas o pai precisa decidir (bloqueio / sem HANDOFF).
if ($script:erroRun) { exit 1 }
if ($codigoHandoff -eq 2) { exit 2 }
