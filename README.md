# Delegar ao Cursor CLI

Skill para o [Claude Code](https://docs.claude.com/en/docs/claude-code) e script PowerShell que despacham tarefas para o `cursor-agent` em modo headless.

O trabalho roda na **cota da Cursor**. A janela de 5h da Anthropic fica para orquestrar: recortar o brief, ler o sidecar de HANDOFF e decidir se aceita, retoma ou escala. O pai não implementa.

Versão da skill: **1.2.0**.

## Quando usar

- Análise de repo, varredura e comparação de docs
- Edição mecânica em lote (rename, boilerplate, aplicar spec pronta)
- Implementação que cabe num enunciado autocontido
- Plano de longa duração tocado entre sessões

Fica no Claude Code o que depende do contexto vivo da sessão, de decisão de arquitetura já discutida, ou de revisão do que vai para produção.

## Requisitos

- Windows + PowerShell 5.1+
- [Cursor CLI](https://cursor.com/docs/cli) autenticado (`agent status`)
- Claude Code, se for usar como orquestrador (skill em `~/.claude/skills/`)

Instalar o CLI, se faltar:

```powershell
irm 'https://cursor.com/install?win32=true' | iex
```

Binário esperado: `%LOCALAPPDATA%\cursor-agent\agent.cmd`.

## Instalação

```powershell
git clone https://github.com/manchini/delegar-cursor.git "$env:USERPROFILE\.claude\skills\delegar-cursor"
```

O Claude Code carrega a skill a partir de `SKILL.md`. O comando curto documentado lá é `/delegar`; o ponto de entrada real é o script abaixo.

## Uso

```powershell
$d = "$env:USERPROFILE\.claude\skills\delegar-cursor\scripts\delegar-cursor.ps1"

# análise read-only no repo atual
& $d -Perfil analise -Tarefa "Compare os docs de arquitetura em docs/"

# implementação com brief versionado
& $d -Repo "C:\dev\projeto" -Perfil implementar -Arquivo .delegacao/briefs/fase-01.md -Rotulo fase01 -SoLog

# follow-up no mesmo worker (enunciado curto; não reenvie o brief)
& $d -Perfil implementar -Continuar -Rotulo fase01 -Tarefa "O HANDOFF pediu o teste de mapa. Só isso."

# volume mecânico com spec já decidida
& $d -Perfil lote -Tarefa "Renomeie X para Y em todos os módulos de src/"

# acompanhar a resposta se formando no terminal (humano)
& $d -Perfil analise -AoVivo -Tarefa "Audite o mapa de tags"
```

Em despacho por agente, use `-SoLog` e **não** use `-AoVivo`. O stdout do script é só o caminho do sidecar `*.handoff.md`. O humano acompanha o `.live`:

```powershell
Get-Content -Wait <repo>\.delegacao\logs\<arquivo>.md.live
```

## Perfis e cota

A cota da Cursor não é uniforme:

| Pool | Modelos | Uso |
|---|---|---|
| **abrangente** | `composer-2.5`, `cursor-grok-4.6-*` | liberal (o default) |
| **premium** | opus, Codex, GPT-5.x, Sonnet, Fable | cota paga; exige `-Premium` |

Dentro do abrangente, esforço não custa cota — custa latência. O default é o teto (`xhigh`). Modelo desconhecido é tratado como premium (falha segura).

| Perfil | Modelo | Pool | Acesso | Para quê |
|---|---|---|---|---|
| `varredura` | grok-4.6-high | abrangente | read-only | trivial e com pressa |
| `analise` | grok-4.6-xhigh | abrangente | read-only | entender, comparar, auditar |
| `plano` | grok-4.6-xhigh | abrangente | read-only | design e fases |
| `lote` | composer-2.5 | abrangente | escrita | volume mecânico |
| `implementar` | grok-4.6-xhigh | abrangente | escrita | implementação com raciocínio |
| `critico` | opus-5-thinking-high | premium | read-only | revisão de alto impacto |
| `debug` | codex-5.3-high | premium | escrita | bug que o abrangente não resolveu |

Não use `--mode plan` em `-p`: em headless ele não emite stdout. O perfil `plano` roda em `ask`.

Escalonamento para premium é **run novo** com `-Premium`, não `-Continuar`. O gatilho é evidência no sidecar (`Bloqueios` preenchido ou revisão reprovada), não palpite.

## Handoff

Todo despacho injeta um preâmbulo: ler `CLAUDE.md` / `AGENTS.md` / `.cursorrules` da raiz, proibir `git add`/`commit`/`push` e servidor que não termina, e exigir:

```text
## HANDOFF
- Feito:
- Arquivos tocados:
- Pendente:
- Proximo passo:
- Bloqueios:
```

Depois do run o script grava um sidecar `*.handoff.md` com esse bloco e, nos perfis de escrita, `git status --short` e `git diff --stat` medidos no checkout.

| Exit | Significado |
|---|---|
| 0 | HANDOFF presente, Bloqueios vazio/nenhum, CLI ok |
| 1 | CLI/run quebrou |
| 2 | terminou, mas HANDOFF ausente ou Bloqueios preenchido |

O pai lê o sidecar. O `.md` completo é trilha para o humano.

## Preparar um repo alvo

1. Autenticação: `agent status` (uma vez por máquina).
2. Permissões em `<repo>/.cursor/cli.json` — copie `referencia/cli-json-template.json` (Unix) ou `referencia/cli-json-template.windows.json` (Windows, sem `find.exe`). Sem isso, `lote`/`implementar` escrevem mas podem não se verificar.
3. `.delegacao/logs/` no `.gitignore`; `.delegacao/briefs/` versionado. Copie `referencia/gitignore-snippet`. Não ignore a pasta `.delegacao/` inteira.

`deny` tem precedência sobre `allow`. Não use `--yolo` em repo com scripts de deploy. O worker não fecha commit nem deixa processo no ar.

## Layout

```text
SKILL.md                 playbook do orquestrador (Claude Code)
scripts/delegar-cursor.ps1
referencia/cli-json-template.json
referencia/cli-json-template.windows.json
referencia/gitignore-snippet
```

Detalhe operacional (playbook do pai, streaming, códigos de saída) está em [`SKILL.md`](SKILL.md).
