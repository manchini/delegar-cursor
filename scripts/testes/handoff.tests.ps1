# Matriz do contrato HANDOFF. Sem Pester, sem cota.
# powershell -NoProfile -File scripts/testes/handoff.tests.ps1

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path (Split-Path $here -Parent) 'handoff-parse.ps1')

$script:passou = 0
$script:falhou = 0

function Ok([string] $nome) {
    $script:passou++
    Write-Host "OK  $nome" -ForegroundColor Green
}

function Falha([string] $nome, $obtido, $esperado) {
    $script:falhou++
    Write-Host "FAIL $nome" -ForegroundColor Red
    Write-Host "     obtido=$obtido esperado=$esperado" -ForegroundColor DarkRed
}

function Assert-Eq($obtido, $esperado, [string] $nome) {
    if ("$obtido" -eq "$esperado") { Ok $nome }
    else { Falha $nome $obtido $esperado }
}

function Handoff([string] $corpo) {
    return @"
## HANDOFF
$corpo
"@
}

# --- Bloqueios: formatos que hoje davam exit 2 falso --------------------------

Assert-Eq (Resolve-CodigoSaida -BlocoHandoff (Handoff '- Bloqueios: nenhum')) 0 'Bloqueios nenhum'
Assert-Eq (Resolve-CodigoSaida -BlocoHandoff (Handoff '- **Bloqueios:** nenhum')) 0 'Bloqueios negrito'
Assert-Eq (Resolve-CodigoSaida -BlocoHandoff (Handoff '- **Bloqueios**: nenhum')) 0 'Bloqueios negrito fora do colon'
Assert-Eq (Resolve-CodigoSaida -BlocoHandoff (Handoff '- Bloqueios: Nenhum bloqueio.')) 0 'Nenhum bloqueio ponto'
Assert-Eq (Resolve-CodigoSaida -BlocoHandoff (Handoff '- Bloqueios: sem bloqueios')) 0 'sem bloqueios'
Assert-Eq (Resolve-CodigoSaida -BlocoHandoff (Handoff '- Bloqueios: nada')) 0 'nada'
Assert-Eq (Resolve-CodigoSaida -BlocoHandoff (Handoff '- Bloqueios: nada a reportar')) 0 'nada a reportar'
Assert-Eq (Resolve-CodigoSaida -BlocoHandoff (Handoff '- Bloqueios: none')) 0 'none'
Assert-Eq (Resolve-CodigoSaida -BlocoHandoff (Handoff '- Bloqueios: n/a')) 0 'n/a'
Assert-Eq (Resolve-CodigoSaida -BlocoHandoff (Handoff '- Bloqueios: falta decidir o schema')) 2 'Bloqueios preenchido'

# --- Status + precedencia pessimista ------------------------------------------

Assert-Eq (Resolve-CodigoSaida -BlocoHandoff (Handoff "- Status: DONE`n- Bloqueios: nenhum")) 0 'DONE + nenhum'
Assert-Eq (Resolve-CodigoSaida -BlocoHandoff (Handoff "- Status: DONE`n- Feito: x")) 2 'DONE sem campo Bloqueios'
Assert-Eq (Resolve-CodigoSaida -BlocoHandoff (Handoff "- **Status:** DONE_WITH_CONCERNS`n- Bloqueios: nenhum")) 0 'DONE_WITH_CONCERNS negrito'
Assert-Eq (Resolve-CodigoSaida -BlocoHandoff (Handoff "- Status: DONE`n- Bloqueios: falta decidir o schema")) 2 'DONE contradiz Bloqueios'
Assert-Eq (Resolve-CodigoSaida -BlocoHandoff (Handoff "- Status: BLOCKED`n- Bloqueios: nenhum")) 2 'BLOCKED vence nenhum'
Assert-Eq (Resolve-CodigoSaida -BlocoHandoff (Handoff "- Status: NEEDS_CONTEXT`n- Bloqueios: nenhum")) 2 'NEEDS_CONTEXT'
Assert-Eq (Resolve-CodigoSaida -BlocoHandoff (Handoff "- Status: done`n- Bloqueios: nenhum")) 0 'DONE minusculo'
Assert-Eq (Resolve-CodigoSaida -BlocoHandoff (Handoff "- Status: DONE WITH CONCERNS`n- Bloqueios: nenhum")) 0 'DONE WITH CONCERNS espacos'
Assert-Eq (Resolve-CodigoSaida -BlocoHandoff (Handoff "- Status: DESCONHECIDO`n- Bloqueios: nenhum")) 0 'Status desconhecido cai na regra antiga'
Assert-Eq (Resolve-CodigoSaida -BlocoHandoff (Handoff "- Status: DESCONHECIDO`n- Bloqueios: falta X")) 2 'Status desconhecido + Bloqueios'

# --- Contrato antigo: sem Status nao vira 2 por ausencia ----------------------

Assert-Eq (Resolve-CodigoSaida -BlocoHandoff (Handoff '- Bloqueios: nenhum')) 0 'sem Status + nenhum'
Assert-Eq (Resolve-CodigoSaida -BlocoHandoff (Handoff '- Feito: x')) 2 'sem Status e sem Bloqueios'

# --- Ausencia de HANDOFF / CLI / timeout --------------------------------------

Assert-Eq (Resolve-CodigoSaida -BlocoHandoff $null) 2 'sem HANDOFF'
Assert-Eq (Resolve-CodigoSaida -BlocoHandoff '') 2 'HANDOFF vazio'
Assert-Eq (Resolve-CodigoSaida -ErroRun $true -BlocoHandoff (Handoff '- Bloqueios: nenhum')) 1 'CLI quebrou'
Assert-Eq (Resolve-CodigoSaida -ErroRun $true -Timeout $true -BlocoHandoff (Handoff '- Bloqueios: nenhum')) 2 'timeout vence erro de processo'
Assert-Eq (Resolve-CodigoSaida -Timeout $true -BlocoHandoff $null) 2 'timeout sem HANDOFF'

# --- Get-StatusHandoff / Verificacao ------------------------------------------

$blocoVer = @"
## HANDOFF
- Status: DONE
- Bloqueios: nenhum
## Verificacao
- cargo test
"@
Assert-Eq (Get-StatusHandoff $blocoVer) 'DONE' 'extrai Status'
Assert-Eq (Test-TemVerificacao $blocoVer) $true 'Verificacao presente'
Assert-Eq (Test-TemVerificacao (Handoff '- Bloqueios: nenhum')) $false 'Verificacao ausente'
Assert-Eq ([bool](Get-BlocoHandoff $blocoVer)) $true 'bloco greedy inclui o resto'
Assert-Eq ((Get-BlocoHandoff $blocoVer) -match '## Verificacao') $true 'Verificacao cai no bloco greedy'

# --- markdown no valor de Status ----------------------------------------------

Assert-Eq (Get-StatusHandoff (Handoff '- Status: NEEDS_CONTEXT')) 'NEEDS_CONTEXT' 'extrai NEEDS_CONTEXT sem comer underscore'

Write-Host ''
Write-Host "passou=$($script:passou) falhou=$($script:falhou)"
if ($script:falhou -gt 0) { exit 1 }
exit 0
