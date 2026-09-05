# Parse do contrato HANDOFF. Dot-sourced por delegar-cursor.ps1 e pelos testes.
# Isolado de proposito: a matriz de contrato roda sem gastar cota.

function Convert-TextoSemMarkdown([string] $s) {
    if ($null -eq $s) { return '' }
    # Nao stripa '_': quebraria NEEDS_CONTEXT. Negrito de worker e '**', nao underline.
    return (($s -replace '\*{1,2}', '' -replace '`', '') -replace '\s+', ' ').Trim()
}

function Get-CampoHandoff {
    param(
        [string] $Handoff,
        [Parameter(Mandatory = $true)]
        [string] $Rotulo
    )
    if (-not $Handoff) { return $null }
    $esc = [regex]::Escape($Rotulo)
    foreach ($linha in ($Handoff -split '\r?\n')) {
        $t = Convert-TextoSemMarkdown $linha
        $t = $t -replace '^[-*]\s+', ''
        if ($t -match ("^(?i)$esc\s*:\s*(.*)$")) {
            return $Matches[1].Trim()
        }
    }
    return $null
}

function Get-BlocoHandoff([string] $texto) {
    if (-not $texto) { return $null }
    $m = [regex]::Match($texto, '(?ms)^## HANDOFF\s*\r?\n.*')
    if ($m.Success) { return $m.Value.TrimEnd() }
    return $null
}

function Get-TextoBloqueios([string] $handoff) {
    return Get-CampoHandoff -Handoff $handoff -Rotulo 'Bloqueios'
}

function Get-StatusHandoff([string] $handoff) {
    $raw = Get-CampoHandoff -Handoff $handoff -Rotulo 'Status'
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    $norm = (Convert-TextoSemMarkdown $raw).Trim().TrimEnd('.').Trim()
    $norm = ($norm -replace '\s+', '_').ToUpperInvariant()
    switch ($norm) {
        'DONE' { return 'DONE' }
        'DONE_WITH_CONCERNS' { return 'DONE_WITH_CONCERNS' }
        'BLOCKED' { return 'BLOCKED' }
        'NEEDS_CONTEXT' { return 'NEEDS_CONTEXT' }
        default { return $null }
    }
}

function Test-BloqueiosNenhum([string] $valor) {
    if ($null -eq $valor) { return $false }
    $norm = (Convert-TextoSemMarkdown $valor).Trim().TrimEnd('.').Trim()
    if ($norm -eq '') { return $false }
    return [bool] ($norm -match '^(?i:nenhum[ao]?|n/?a|none|-|—|nenhum(?:a)?\s+bloqueios?|sem\s+bloqueios?|nada(?:\s+a\s+reportar)?)$')
}

function Test-TemVerificacao([string] $texto) {
    if (-not $texto) { return $false }
    return [bool] ($texto -match '(?im)^##\s*Verifica[cç][aã]o\s*$')
}

function Resolve-CodigoSaida {
    param(
        [bool] $ErroRun = $false,
        [bool] $Timeout = $false,
        [string] $BlocoHandoff
    )
    # Timeout vence erro de processo: matar a arvore costuma sair com exit != 0,
    # mas pode haver edicao pela metade — o pai decide (saida 2), nao trata como CLI morto.
    if ($Timeout) { return 2 }
    if ($ErroRun) { return 1 }
    if ([string]::IsNullOrEmpty($BlocoHandoff)) { return 2 }

    $status = Get-StatusHandoff $BlocoHandoff
    $bloq = Get-TextoBloqueios $BlocoHandoff
    $nenhum = Test-BloqueiosNenhum $bloq

    if ($status -eq 'BLOCKED' -or $status -eq 'NEEDS_CONTEXT') { return 2 }
    if ($status -eq 'DONE' -or $status -eq 'DONE_WITH_CONCERNS') {
        if ($nenhum) { return 0 }
        return 2
    }
    # Status ausente ou desconhecido: regra antiga (so Bloqueios). Nunca 2 por ausencia de Status.
    if (-not $nenhum) { return 2 }
    return 0
}
