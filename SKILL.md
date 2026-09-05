---
name: delegar-cursor
description: Delegar trabalho do Claude Code para o Cursor CLI (agent) em modo headless, com roteamento de modelo consciente de custo e contrato de handoff. Use quando quiser poupar a janela de 5h da Anthropic, despachar trabalho mecanico ou de analise em lote, tocar planos de longa duracao entre sessoes, ou quando o usuario falar em delegar, cursor-agent, economizar cota, offload de tarefa.
version: 1.3.0
source: session-knowledge
---

# Delegar ao Cursor CLI

Despacha tarefas para o `cursor-agent` headless. O trabalho roda **na cota da
Cursor**, preservando a janela de 5h da assinatura Anthropic.

**Pai = Claude Code, Opus, thinking low.** O orquestrador recorta, escreve o
brief, lê o sidecar de HANDOFF e decide se retoma ou escala. Não implementa.
Thinking alto no pai gasta a janela sem melhorar o worker.

Quando falar com o humano, **credite o executor**. Cite `perfil:` e `modelo:`
(slug) do sidecar — opcionalmente `pool:`. O pai orquestrou; quem analisou ou
editou foi aquele modelo, na cota da Cursor. Frase do tipo "implementei" ou
"alterei" sem nomear o worker é crédito errado.

Script: `scripts/delegar-cursor.ps1` (nesta skill). Funciona em qualquer repo
via `-Repo`. Diagnostico: `-Doctor`. Brief: `referencia/brief-template.md`.

## Playbook do pai (Opus low)

Este é o loop. Não improvise — improvisar, para o Opus, costuma ser reler o log.

1. **Escreva o brief em arquivo**, não inline. Destino versionado:
   `<repo>/.delegacao/briefs/<rotulo>.md`. Use o molde em
   `referencia/brief-template.md`. Recorte: ~5 passos, ~10 arquivos, 1 camada.
   O enunciado tem que ser autocontido: o worker não vê esta sessão.
2. **Dispare em background**, sem `-AoVivo`:
   ```powershell
   $d = "$env:USERPROFILE\.claude\skills\delegar-cursor\scripts\delegar-cursor.ps1"
   & $d -Perfil implementar -Arquivo .delegacao/briefs/<rotulo>.md -Rotulo <rotulo> -SoLog
   ```
   `-SoLog` é redundante quando o stdout já está redirecionado (Claude Code),
   mas deixe explícito. O stdout do script é **só o caminho do sidecar**
   `*.handoff.md`.
3. **Não polle.** O humano acompanha o `.live`:
   `Get-Content -Wait <repo>\.delegacao\logs\<arquivo>.md.live`
4. **Ao terminar, leia só o sidecar** (`*.handoff.md`). Nunca o `.md` completo
   — ele entra na janela de 5h e anula a economia.
5. **Decida com evidência, não com prosa** (leia só o sidecar):
   - `saida: 0` + `status: DONE` + `Bloqueios: nenhum` + `git status` batendo com `Arquivos tocados` → aceitar.
   - `saida: 0` + `status: DONE_WITH_CONCERNS` → **não** é aceite mudo. Leia `Pendente` e `## Verificacao` no sidecar.
   - `saida: 2` + `timeout: sim` → confira `git status` antes de `-Continuar`; pode haver edição pela metade.
   - `saida: 2` ou `Bloqueios` preenchido ou `status: BLOCKED`/`NEEDS_CONTEXT` → follow-up curto com `-Continuar` no **mesmo** `-Rotulo`, ou `-Premium` num **run novo** (não misture perfil no `--resume`).
   - `saida: 1` → o CLI quebrou; leia `## STDERR` no sidecar, não o log inteiro.
6. **Credite o executor na resposta ao humano**, com os campos do sidecar, não
   com o nome do pai. Exemplo: `perfil=implementar modelo=cursor-grok-4.6-xhigh
   pool=abrangente`. Sem slug no sidecar (`modelo:` vazio) → diga só o perfil e
   que o worker foi o Cursor CLI.
7. **Thinking medium no pai** só quando o *brief* é o trabalho difícil (vários
   docs, trade-off já discutido nesta sessão). High no Claude Code quase nunca:
   se o problema pede isso, o run certo é `-Perfil critico -Premium`.

**Dois writers no mesmo checkout não.** Um `-Rotulo` writer por conjunto de
paths. Fase com Proxy e cliente em paralelo = dois briefs, paths disjuntos
(`crates/` vs `apps/client`). Se os paths se sobrepõem, serialize.

Não peça ao worker `cargo run` / `npm run dev` deixados no ar. Verificação
headless é teste e build que **terminam**. Servidor no ar é do operador humano.

## Quando delegar

O corte **não** é por dificuldade — é por **onde está o contexto**.

| Fica no Claude Code | Vai para o Cursor |
|---|---|
| Depende do contexto vivo da sessão | Cabe num enunciado autocontido |
| Decisão de arquitetura com histórico acumulado | Análise de repo, varredura, comparação de docs |
| Revisão do que vai para produção | Edição mecânica em lote, aplicar spec pronta |
| Julgamento sobre trade-off já discutido | Rascunho de plano a partir de fontes nomeadas |

Se você precisa explicar meia sessão de contexto para o enunciado fazer sentido,
não delegue — o custo de montar o enunciado supera a economia.

## Os dois pools (o ponto central)

A cota da Cursor **não é capacidade uniforme**:

- **abrangente** (uso liberal): `composer-2.5`, `cursor-grok-4.6-*`
- **premium** (cota paga): `claude-opus-5-*`, `gpt-5.3-codex-*`, `gpt-5.6-*`, `sonnet-5`, `fable-5`

O CLI **não expõe quota agregada**. Cada run devolve o próprio consumo no
frontmatter do sidecar (`tokens_in`, `tokens_out`, `cache_read`). Controle =
política no despacho + medição por despacho.

**A única fronteira que importa é a do pool.** Dentro do abrangente, esforço não
custa cota — custa **latência**. Racionar qualidade ali não economiza nada, só
entrega resposta pior de graça. Por isso o default é o **teto (`xhigh`)**, e
`varredura` existe apenas para quando a tarefa é trivial e você quer a resposta
rápido.

## Perfis

| Perfil | Modelo | Pool | Acesso | Para quê |
|---|---|---|---|---|
| `varredura` | grok-4.6-**high** | abrangente | read-only | trivial e com pressa |
| `analise` | grok-4.6-**xhigh** | abrangente | read-only | entender, comparar, auditar |
| `plano` | grok-4.6-**xhigh** | abrangente | read-only | design e fases |
| `lote` | composer-2.5 | abrangente | **escrita** | volume mecânico: rename, boilerplate, aplicar spec pronta |
| `implementar` | grok-4.6-**xhigh** | abrangente | **escrita** | implementação que exige raciocínio |
| `critico` | claude-opus-5-thinking-high | **premium** | read-only | revisão de alto impacto |
| `debug` | gpt-5.3-codex-high | **premium** | **escrita** | bug que o abrangente não resolveu |

**Escrita: `lote` vs `implementar`.** O `composer-2.5` é rápido e bom em aplicar
uma spec já decidida em volume. Quando a implementação exige raciocínio — decidir
estrutura, resolver uma interação não óbvia, escrever algo que ainda não foi
projetado em detalhe — use `implementar` (grok no teto). Ambos custam o mesmo.

Não use as variantes `-fast`: pagam prêmio por latência sem ganho de qualidade, e
delegação assíncrona não precisa disso.

**Nunca use `--mode plan` em `-p`.** Ele é feito para a TUI interativa, onde o
plano vai para aprovação na interface; em headless não emite nada no stdout
(verificado: 232s de run, saída vazia, nenhum arquivo em `.cursor/plans/`). Por
isso `plano` roda em `ask` — o que define que é um plano é o enunciado, não a flag.

O script valida o slug contra `agent --list-models` (cache 12h). Se o lineup
mudou e o perfil aponta para um id morto, o despacho aborta **antes** da chamada
cara, com instrução de atualizar a tabela.

## Portão de custo

Premium exige `-Premium` explícito — sem ele o script aborta **antes de qualquer
chamada**, custo zero. A classificação é allowlist de prefixo, então **modelo
desconhecido é tratado como premium** (falha segura): modelo novo e caro nasce
bloqueado em vez de vazar.

## Regra de escalonamento

Não escale por palpite. O gatilho é evidência:

> Rode no pool abrangente primeiro — e ele já roda no teto de esforço, então um
> run que falha ali falhou com a melhor tentativa disponível, não com uma versão
> economizada. Follow-up no **mesmo** worker: `-Continuar`. Só escale para
> premium quando o sidecar voltar com `Bloqueios` preenchido (exit 2), ou quando
> a revisão reprovar a saída. Escalação premium é **run novo**, não `--resume`.

`-Continuar` lê `sessao:` no log mais recente daquele `-Rotulo`. Logs antigos
sem esse campo não retomam — aí é run novo.

Isso é o que torna a regra honesta: se o default fosse esforço baixo, um bloqueio
não significaria "precisa de premium", significaria "precisa de mais esforço".

Deliberadamente **não automatizado**: escalonamento automático em cima de um
sinal auto-declarado pelo próprio modelo é uma bomba de gastar cota. O
`-Premium` passa por um humano.

## Contrato de handoff

Todo despacho injeta um preâmbulo que:

1. Manda ler **todos** os `CLAUDE.md` / `AGENTS.md` / `.cursorrules` da raiz do
   repo alvo que existirem — inclusive as regras de encoding legado.
2. Proíbe `git add` / `commit` / `push` / `checkout` / `reset` e servidor que
   não termina.
3. Manda **parar e declarar `Bloqueios`** em vez de entregar trabalho incerto.
4. Exige a seção final:

```
## HANDOFF
- Status: DONE | DONE_WITH_CONCERNS | BLOCKED | NEEDS_CONTEXT
- Feito:
- Arquivos tocados:
- Pendente:
- Proximo passo:
- Bloqueios:
## Verificacao
- <comandos que terminam, ou 'nenhum'>
```

Nits vão em `Pendente` com `DONE_WITH_CONCERNS`, não em `Bloqueios`.

O script **não acredita só nisso**. Depois do run ele grava um sidecar
`*.handoff.md` com o bloco HANDOFF +, nos perfis de escrita, `git status --short`
e `git diff --stat` medidos no checkout. Códigos:

| Exit | Significado |
|---|---|
| 0 | HANDOFF presente, Bloqueios vazio/nenhum, CLI ok (`DONE` ou `DONE_WITH_CONCERNS`) |
| 1 | CLI/run quebrou |
| 2 | o pai decide: HANDOFF ausente, Bloqueios, BLOCKED/NEEDS_CONTEXT, ou TIMEOUT |

Status ausente cai na regra antiga (só Bloqueios) — não vira 2 por ausência.
TIMEOUT reusa 2 (`timeout: sim` no frontmatter), não cria código 3.

O pai lê o sidecar. O `.md` completo é trilha para o humano. Ao resumir o
run, o pai nomeia o `modelo:` do frontmatter — não fala como se tivesse
escrito o diff.

## Uso

```powershell
$d = "$env:USERPROFILE\.claude\skills\delegar-cursor\scripts\delegar-cursor.ps1"

# análise read-only no repo atual
& $d -Perfil analise -Tarefa "Compare os docs de arquitetura em docs/"

# implementação com raciocínio, brief versionado
& $d -Repo "C:\dev\projeto" -Perfil implementar -Arquivo .delegacao/briefs/fase-01.md -Rotulo fase01 -SoLog

# follow-up no mesmo worker (enunciado curto; nao reenvie o brief)
& $d -Perfil implementar -Continuar -Rotulo fase01 -Tarefa "O HANDOFF pediu o teste de mapa. So isso."

# volume mecânico com spec já decidida
& $d -Perfil lote -Tarefa "Renomeie X para Y em todos os modulos de src/"

# diagnostico (nao despacha, nao gasta cota)
& $d -Doctor -Repo "C:\dev\projeto"

# acompanhando a resposta se formar no terminal (humano)
& $d -Perfil analise -AoVivo -Tarefa "Audite o mapa de tags"

# escalonamento consciente, APOS bloqueio real — run novo, nao -Continuar
& $d -Perfil critico -Premium -Arquivo .delegacao/logs/<sidecar-anterior>.handoff.md -Rotulo fase01-rev
```

Pasta:

| Caminho | Git | Papel |
|---|---|---|
| `.delegacao/briefs/` | versionado | enunciados do pai |
| `.delegacao/logs/` | gitignored | `*.md` completo, `*.handoff.md`, `.live` durante o run |

O sidecar traz `pool:`, `modelo:`, `duracao_s:`, `tokens_*`, `sessao:`, `saida:`,
`status:`, `timeout:`, `verificacao:`, `bloqueios:`. Se o run falhar, o sidecar é
gravado mesmo assim (`erro: sim` + `## STDERR`).

## Saída parcial (streaming)

O despacho roda com `stream-json --stream-partial-output`, então a resposta chega
em fragmentos.

- Fragmentos de texto e chamadas de ferramenta vão ao vivo para
  `<log>.md.live`. Acompanhe com `Get-Content -Wait`. O `.live` some quando o
  `.md` definitivo é gravado — se sobrar um, o run foi interrompido.
- `-AoVivo` ecoa no console (raciocínio em cinza, ferramentas em ciano).

A trilha de ferramentas é o progresso real num run de escrita:

```
Vou ler `sub/dados.txt` e gerar `sub/dados_ord.txt` ordenado.

  > read sub/dados.txt
  > edit sub/dados_ord.txt
Criei `sub/dados_ord.txt` com as linhas de Z para A.
```

**`-AoVivo` é opt-in de propósito.** Quando quem despacha é um agente, o console
vira contexto: o NDJSON amplifica o texto em ~50x (medido: 21.375 bytes de
eventos para 403 bytes de resposta), e a saída de uma ferramenta só chega ao
agente quando o processo **termina**. Quem ganha com o eco é o humano no
terminal.

O par que funciona: o agente despacha em background sem `-AoVivo`; o humano
acompanha o `.live`; o pai lê o sidecar.

## Preparar um repo novo

1. Autenticação: `agent status` (uma vez por máquina).
2. Permissões em `<repo>/.cursor/cli.json` — copie
   `referencia/cli-json-template.json` (Unix) ou
   `referencia/cli-json-template.windows.json` (Windows, sem `find.exe`). Ajuste
   ao stack. Sem isso, `lote`/`implementar` escrevem mas não se verificam; o
   script avisa.
3. `.delegacao/logs/` no `.gitignore`; `.delegacao/briefs/` versionado. Copie
   `referencia/gitignore-snippet`. Não ignore a pasta `.delegacao/` inteira.

`deny` tem precedência sobre `allow`. Nunca use `--yolo` em repo com scripts de
deploy ou empacotamento. `git add`/`commit`/`push` e servidores (`npm run dev`)
ficam no deny de propósito: o worker não fecha commit nem deixa processo no ar.

## Instalação do CLI (se faltar)

```powershell
irm 'https://cursor.com/install?win32=true' | iex
```

Binário em `%LOCALAPPDATA%\cursor-agent\agent.cmd`. Em `-p` o Cursor exige
`--trust` a cada execução (não persiste) — o script já passa.
