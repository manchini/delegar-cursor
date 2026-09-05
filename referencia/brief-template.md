# Brief para o worker

O pai escreve isto em `<repo>/.delegacao/briefs/<rotulo>.md` e despacha com
`-Arquivo`. O worker **nao ve** a sessao do Claude Code: o enunciado tem que
ser autocontido.

Nao repita o que o preambulo ja injeta (git, servidor que nao termina, formato
do HANDOFF). Duplicar instrucao incha o enunciado e o worker perde o sinal.

## Recorte

Um brief cabe quando tem no maximo ~5 passos, ~10 arquivos e **uma** camada
(ex. so `crates/` ou so `apps/client`). Se nao cabe, quebre em fases e
delegue so a fase 1. Dois writers no mesmo checkout nao: paths disjuntos ou
serialize.

## Secoes

### Objetivo

Uma frase. O que fica pronto ao final deste run, nao a visao do produto.

### Contexto do repo

Onde olhar. Caminhos, arquivos de convencao, decisoes ja tomadas. Nao cole
logs.

### Criterio de aceite

Lista objetiva. Cada item e verificavel por comando que **termina** (teste,
build, diff). Sem "ficar bom" / "seguir o padrao".

### Arquivos no escopo

O que pode mudar. Fora disto, nao tocar.

### Como verificar

Comandos concretos, na ordem. Se o shell do Cursor falhar no Windows, o
humano/pai reroda a partir do sidecar `## Verificacao`.

### Nao faca

Fronteira negativa. Escopo alucinado quase nunca vem de falta de objetivo;
vem de falta disto. Exemplos tipicos:

- nao mexer em lockfile
- nao renomear API publica
- nao "corrigir" falha de teste que ja existia — reporte em Bloqueios
- nao subir servidor / nao commitar
