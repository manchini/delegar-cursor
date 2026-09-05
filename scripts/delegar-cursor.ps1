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
       (Status DONE ou DONE_WITH_CONCERNS, ou contrato antigo sem Status)
    1  falha do CLI / run
    2  terminou mas o pai decide: HANDOFF ausente, Bloqueios preenchido,
       Status BLOCKED/NEEDS_CONTEXT, contradicao Status/Bloqueios, ou TIMEOUT

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

.PARAMETER TimeoutMin
  Teto de relogio em minutos. 0 desliga. Default por perfil (varredura 10,
  analise/plano 25, lote 45, implementar 90, critico 30, debug 60).
  -Continuar usa o mesmo default do perfil.

.PARAMETER Doctor
  Diagnostico: auth, slugs de todos os perfis, cli.json, gitignore, .live orfao.
  Nao despacha. Sai 0 se ok, 1 se houver falha.

.PARAMETER Notificar
  Toast/som Windows ao terminar. Nunca escreve no stdout.

.EXAMPLE
  .\delegar-cursor.ps1 -Perfil analise -Tarefa "Compare os docs de arquitetura"

.EXAMPLE
  .\delegar-cursor.ps1 -Perfil implementar -Arquivo .delegacao/briefs/fase-01.md -Rotulo fase01 -SoLog

.EXAMPLE
  .\delegar-cursor.ps1 -Perfil implementar -Continuar -Rotulo fase01 -Tarefa "O HANDOFF pediu o teste de mapa. So isso."
#>
[CmdletBinding(DefaultParameterSetName = 'Inline')]
param(
    [Parameter(ParameterSetName = 'Inline', Mandatory = $true)]
    [string] $Tarefa,

    [Parameter(ParameterSetName = 'Arquivo', Mandatory = $true)]
    [string] $Arquivo,

    [Parameter(ParameterSetName = 'Doctor', Mandatory = $true)]
    [switch] $Doctor,

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

    [string] $Sessao,

    [int] $TimeoutMin = -1,

    [switch] $Notificar
)

$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptDir 'handoff-parse.ps1')

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

$timeoutPadrao = @{
    'varredura'   = 10
    'analise'     = 25
    'plano'       = 25
    'lote'        = 45
    'implementar' = 90
    'critico'     = 30
    'debug'       = 60
}

if ($TimeoutMin -lt -1) { throw '-TimeoutMin deve ser -1 (default), 0 (desligado) ou um inteiro positivo.' }

function Get-Pool([string] $m) {
    if ($m -match '^(composer-|cursor-grok-)' -or $m -eq 'auto') { return 'abrangente' }
    return 'premium'
}

$rota = $null
$acesso = $null
$pool = $null
if (-not $Doctor) {
    $rota = $rotas[$Perfil]
    if (-not $Modelo) { $Modelo = $rota.modelo }
    $acesso = $rota.acesso
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
if (-not $Doctor) {
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

function Invoke-DelegarDoctor {
    $problemas = New-Object System.Collections.Generic.List[string]
    $avisos = New-Object System.Collections.Generic.List[string]

    Write-Host "[doctor] repo=$repoRaiz" -ForegroundColor Cyan

    if (-not (Test-Path $agentExe)) {
        $problemas.Add("Cursor CLI ausente: $agentExe")
    } else {
        Write-Host "  ok CLI $agentExe" -ForegroundColor DarkGray
        $pref = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        $statusOut = (& $agentExe status 2>&1 | Out-String)
        $statusCode = $LASTEXITCODE
        $ErrorActionPreference = $pref
        if ($statusCode -ne 0 -or $statusOut -notmatch '(?i)logged in') {
            $problemas.Add("agent status nao autenticou (exit=$statusCode). Rode: agent login")
        } else {
            Write-Host '  ok agent status' -ForegroundColor DarkGray
        }
    }

    $ids = @(Get-ModelosConhecidos -Exe $agentExe -Forcar)
    if ($ids.Count -eq 0) {
        $avisos.Add('--list-models vazio; nao deu para validar slugs dos perfis')
    } else {
        foreach ($nome in @($rotas.Keys | Sort-Object)) {
            $slug = $rotas[$nome].modelo
            if ($ids -notcontains $slug) {
                $problemas.Add("perfil ${nome}: slug '$slug' nao aparece em --list-models")
            } else {
                Write-Host "  ok perfil $nome -> $slug" -ForegroundColor DarkGray
            }
        }
    }

    $cliJsonPath = Join-Path $repoRaiz '.cursor\cli.json'
    if (-not (Test-Path $cliJsonPath)) {
        $problemas.Add("sem .cursor/cli.json em $repoRaiz (copie referencia/cli-json-template.windows.json)")
    } else {
        $rawCli = Get-Content -Path $cliJsonPath -Raw -Encoding UTF8
        $denyFaltando = New-Object System.Collections.Generic.List[string]
        foreach ($d in @('git:add', 'git:commit', 'git:push', 'git:checkout', 'git:reset')) {
            if ($rawCli -notmatch [regex]::Escape($d)) { [void]$denyFaltando.Add($d) }
        }
        if ($denyFaltando.Count -gt 0) {
            $problemas.Add("cli.json sem deny contendo: $($denyFaltando -join ', ')")
        } else {
            Write-Host '  ok cli.json denies criticos' -ForegroundColor DarkGray
        }
    }

    $giPath = Join-Path $repoRaiz '.gitignore'
    if (-not (Test-Path $giPath)) {
        $problemas.Add('sem .gitignore (logs de .delegacao/ vazariam)')
    } else {
        $giText = Get-Content -Path $giPath -Raw -Encoding UTF8
        if ($giText -notmatch '\.delegacao/\*') {
            $problemas.Add('.gitignore nao ignora .delegacao/* — copie referencia/gitignore-snippet')
        }
        if ($giText -notmatch '!\.delegacao/briefs/') {
            $problemas.Add('.gitignore nao re-inclui .delegacao/briefs/')
        }
        if ($giText -match '\.delegacao/\*' -and $giText -match '!\.delegacao/briefs/') {
            Write-Host '  ok gitignore .delegacao' -ForegroundColor DarkGray
        }
    }

    $logDirDoc = Join-Path $repoRaiz '.delegacao\logs'
    if (Test-Path $logDirDoc) {
        $orf = @(Get-ChildItem -Path $logDirDoc -File -Filter '*.live' -ErrorAction SilentlyContinue)
        if ($orf.Count -gt 0) {
            $avisos.Add("live orfao (run interrompido): $($orf.Name -join ', ')")
        }
    }

    foreach ($a in $avisos) { Write-Host "[doctor] aviso: $a" -ForegroundColor Yellow }
    foreach ($p in $problemas) { Write-Host "[doctor] falha: $p" -ForegroundColor Red }
    if ($problemas.Count -gt 0) { exit 1 }
    Write-Host '[doctor] ok' -ForegroundColor Green
    exit 0
}

if ($Doctor) { Invoke-DelegarDoctor }

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

Status:
- DONE — pronto, sem ressalva.
- DONE_WITH_CONCERNS — pronto, mas ha nits. Nits vao em Pendente, NAO em Bloqueios.
- BLOCKED — nao da para concluir; preencha Bloqueios.
- NEEDS_CONTEXT — falta informacao que so o humano/pai tem.

Ao terminar, encerre a resposta com estas duas secoes, nesta ordem, e nada depois:

## HANDOFF
- Status: DONE | DONE_WITH_CONCERNS | BLOCKED | NEEDS_CONTEXT
- Feito: <o que foi concluido>
- Arquivos tocados: <lista de caminhos, ou 'nenhum'>
- Pendente: <nits ou o que ficou faltando>
- Proximo passo: <acao unica e concreta>
- Bloqueios: <o que exige decisao humana ou modelo maior, ou 'nenhum'>
## Verificacao
- <comandos que terminam e que o humano deve rerodar, ou 'nenhum'>
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
$timeoutEfetivo = if ($TimeoutMin -ge 0) { $TimeoutMin } else { [int]$timeoutPadrao[$Perfil] }
if ($timeoutEfetivo -gt 0) {
    Write-Host "[delegar] timeout=${timeoutEfetivo}min" -ForegroundColor DarkGray
}
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
    if (-not $alvo -and $argumentos) {
        foreach ($prop in $argumentos.PSObject.Properties) {
            if ($prop.Value -is [string] -and $prop.Value) { $alvo = $prop.Value; break }
        }
    }
    if ($alvo -and $script:raiz) {
        $alvo = $alvo -replace [regex]::Escape($script:raiz + '\'), ''
    }
    if ($alvo -match '^[A-Za-z]:\\') {
        $partes = $alvo.Split('\')
        if ($partes.Count -gt 3) { $alvo = '...\' + ($partes[-3..-1] -join '\') }
    }
    $alvo = ($alvo -replace '\s+', ' ').Trim()
    if ($alvo.Length -gt 100) { $alvo = '...' + $alvo.Substring($alvo.Length - 97) }
    if ($alvo) { return "$nome $alvo" } else { return $nome }
}

function Receive-EventoLinha([string] $linha) {
    if (-not $linha -or -not $linha.StartsWith('{')) { return }
    try { $evt = $linha | ConvertFrom-Json } catch { return }
    $temTs = $evt.PSObject.Properties.Name -contains 'timestamp_ms'

    switch ($evt.type) {
        'system' {
            if ($evt.subtype -eq 'init') { $script:sessao = $evt.session_id }
        }
        'thinking' {
            if ($evt.subtype -eq 'delta' -and $script:mostrar) {
                Write-Host $evt.text -NoNewline -ForegroundColor DarkGray
            }
        }
        'tool_call' {
            if ($evt.subtype -ne 'started') { return }
            $resumo = Get-ResumoFerramenta $evt.tool_call
            if (-not $resumo) { return }
            if ($script:bufMsg.Length -gt 0) { Write-Fluxo "`n" $null }
            Write-Fluxo "`n  > $resumo`n" 'DarkCyan'
            [void] $script:bufMsg.Clear()
        }
        'assistant' {
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

function Stop-ArvoreProcesso([int] $ProcessId) {
    $pref = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { & taskkill.exe /PID $ProcessId /T /F 2>&1 | Out-Null } catch { }
    $ErrorActionPreference = $pref
}

$inicio = Get-Date
$codigoSaida = 0
$script:timeoutEstourou = $false
$prefAntes = $ErrorActionPreference
$procAgent = $null
$fsOut = $null
$tempDirRun = $null
Push-Location $repoRaiz
try {
    $ps1Agent = Join-Path (Split-Path $agentExe) 'cursor-agent.ps1'
    if (-not (Test-Path $ps1Agent)) {
        throw "cursor-agent.ps1 nao encontrado ao lado de $agentExe"
    }

    $tempDirRun = Join-Path $env:TEMP ('delegar-cursor-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $tempDirRun -Force | Out-Null
    $inFile = Join-Path $tempDirRun 'in.md'
    $outFile = Join-Path $tempDirRun 'out.ndjson'
    $errFile = Join-Path $tempDirRun 'err.txt'
    [System.IO.File]::WriteAllText($inFile, $preambulo, $semBom)
    [System.IO.File]::WriteAllText($outFile, '', $semBom)
    [System.IO.File]::WriteAllText($errFile, '', $semBom)

    $arquivoArg = $ps1Agent
    if ($ps1Agent -match '\s') { $arquivoArg = '"{0}"' -f $ps1Agent }
    $argParts = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $arquivoArg) + $flags
    $procAgent = Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
        -ArgumentList $argParts `
        -WorkingDirectory $repoRaiz `
        -RedirectStandardInput $inFile `
        -RedirectStandardOutput $outFile `
        -RedirectStandardError $errFile `
        -NoNewWindow -PassThru

    $fsOut = [System.IO.FileStream]::new($outFile, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    $parcial = New-Object System.Text.StringBuilder
    $deadline = if ($timeoutEfetivo -gt 0) { (Get-Date).AddMinutes($timeoutEfetivo) } else { [datetime]::MaxValue }

    while (-not $procAgent.HasExited) {
        $n = $fsOut.Length - $fsOut.Position
        if ($n -gt 0) {
            $buf = New-Object byte[] ([int]$n)
            $lido = $fsOut.Read($buf, 0, $n)
            if ($lido -gt 0) { [void]$parcial.Append($semBom.GetString($buf, 0, $lido)) }
            $txt = $parcial.ToString()
            $linhas = $txt -split '\r?\n', -1
            if ($linhas.Count -gt 0) {
                $ultimo = $linhas.Count - 1
                for ($i = 0; $i -lt $ultimo; $i++) {
                    Receive-EventoLinha $linhas[$i]
                }
                $parcial = New-Object System.Text.StringBuilder
                [void]$parcial.Append($linhas[$ultimo])
            }
        }
        if ((Get-Date) -ge $deadline) {
            $script:timeoutEstourou = $true
            Write-Host "[delegar] TIMEOUT apos $timeoutEfetivo min - matando a arvore (PID $($procAgent.Id))" -ForegroundColor Yellow
            Stop-ArvoreProcesso $procAgent.Id
            break
        }
        Start-Sleep -Milliseconds 80
    }
    if (-not $procAgent.HasExited) { [void]$procAgent.WaitForExit(60000) }
    Start-Sleep -Milliseconds 200
    $n = $fsOut.Length - $fsOut.Position
    if ($n -gt 0) {
        $buf = New-Object byte[] ([int]$n)
        $lido = $fsOut.Read($buf, 0, $n)
        if ($lido -gt 0) { [void]$parcial.Append($semBom.GetString($buf, 0, $lido)) }
    }
    $resto = $parcial.ToString()
    foreach ($ln in ($resto -split '\r?\n')) { Receive-EventoLinha $ln }
    $errTxt = ''
    if (Test-Path $errFile) { $errTxt = [System.IO.File]::ReadAllText($errFile, $semBom).Trim() }
    if ($errTxt) { [void]$script:erros.AppendLine($errTxt) }
    if ($procAgent.HasExited) { $codigoSaida = $procAgent.ExitCode }
    else { $codigoSaida = -1 }
} finally {
    $ErrorActionPreference = $prefAntes
    if ($fsOut) { $fsOut.Dispose() }
    if ($procAgent) { $procAgent.Dispose() }
    Pop-Location
    if ($escritorLive) { $escritorLive.Dispose() }
    if ($tempDirRun -and (Test-Path $tempDirRun)) {
        Remove-Item -LiteralPath $tempDirRun -Recurse -Force -ErrorAction SilentlyContinue
    }
}
$dur = [int]((Get-Date) - $inicio).TotalSeconds
if ($mostrar) { Write-Host '' }

# 'result' e a fonte da verdade do texto final; os fragmentos sao o fallback
# para o caso de o run morrer antes de emitir o evento final.
$saida = if ($script:textoFinal) { $script:textoFinal } else { $acumulado.ToString() }

$erroTexto = $script:erros.ToString().Trim()
if (-not $script:timeoutEstourou) {
    if ($null -ne $codigoSaida -and $codigoSaida -ne 0) { $script:erroRun = $true }
    if (-not $saida -and $erroTexto) { $script:erroRun = $true }
}

if ($script:timeoutEstourou) {
    Write-Host '[delegar] TIMEOUT — confira git status antes de -Continuar; pode haver edicao pela metade.' -ForegroundColor Yellow
} elseif ($script:erroRun) {
    Write-Host "[delegar] FALHA (exit=$codigoSaida)" -ForegroundColor Red
    if ($erroTexto) { Write-Host $erroTexto.Trim() -ForegroundColor DarkRed }
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
$codigoHandoff   = Resolve-CodigoSaida -ErroRun $script:erroRun -Timeout $script:timeoutEstourou -BlocoHandoff $blocoHandoffOut
$statusHandoff   = Get-StatusHandoff $blocoHandoffOut
if ($script:timeoutEstourou) { $statusHandoff = 'TIMEOUT' }
$temVerificacao  = Test-TemVerificacao $saida

if ($codigoHandoff -eq 2 -and -not $script:timeoutEstourou -and -not $script:erroRun) {
    if (-not $blocoHandoffOut) {
        Write-Host '[delegar] HANDOFF ausente (exit=2)' -ForegroundColor Yellow
    } elseif ($statusHandoff -eq 'BLOCKED' -or $statusHandoff -eq 'NEEDS_CONTEXT') {
        Write-Host "[delegar] Status: $statusHandoff (exit=2)" -ForegroundColor Yellow
    } else {
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
$statusFm = if ($statusHandoff) { $statusHandoff } else { '(ausente)' }

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
timeout: $(if ($script:timeoutEstourou) { 'sim' } else { 'nao' })
status: $statusFm
verificacao: $(if ($temVerificacao) { 'sim' } else { 'nao' })
saida: $codigoHandoff
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

function Show-DelegarNotificacao {
    param([string] $Titulo, [string] $Corpo)
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        Add-Type -AssemblyName System.Drawing -ErrorAction Stop
        $ni = New-Object System.Windows.Forms.NotifyIcon
        $ni.Icon = [System.Drawing.SystemIcons]::Information
        $ni.Visible = $true
        $ni.BalloonTipTitle = $Titulo
        $ni.BalloonTipText = $Corpo
        $ni.ShowBalloonTip(4000)
        Start-Sleep -Milliseconds 800
        $ni.Dispose()
    } catch {
        try { [System.Media.SystemSounds]::Asterisk.Play() } catch { }
    }
}

if ($Notificar) {
    $titulo = if ($script:timeoutEstourou) { 'delegar-cursor: timeout' }
              elseif ($codigoHandoff -eq 0) { 'delegar-cursor: ok' }
              elseif ($codigoHandoff -eq 1) { 'delegar-cursor: falha' }
              else { 'delegar-cursor: bloqueio' }
    $resumo = "perfil=$Perfil saida=$codigoHandoff status=$statusFm"
    Show-DelegarNotificacao -Titulo $titulo -Corpo $resumo
    Write-Host "[delegar] notificado: $titulo" -ForegroundColor DarkGray
}

# Sinaliza ao chamador sem estourar excecao: os arquivos ja foram gravados.
# 1 = run quebrou; 2 = terminou mas o pai precisa decidir (bloqueio / timeout / sem HANDOFF).
if ($codigoHandoff -eq 1) { exit 1 }
if ($codigoHandoff -eq 2) { exit 2 }
