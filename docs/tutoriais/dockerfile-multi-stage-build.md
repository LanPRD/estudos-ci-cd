# Docker Multi-Stage Build: Imagens de Produção Enxutas para Node/Nest

## 🤔 Por Que Não Usar um Dockerfile de Estágio Único?

Um Dockerfile "simples" — `FROM node`, `COPY .`, `npm install`, `npm run build`, `CMD` — funciona,
mas carrega pra produção tudo que só foi necessário durante a compilação: o TypeScript compiler,
o `@nestjs/cli`, as devDependencies inteiras, o código-fonte `.ts`. Isso infla a imagem, aumenta a
superfície de ataque (mais pacotes = mais CVEs possíveis) e deixa o deploy mais lento.

**Multi-stage build** resolve isso: você usa vários `FROM` no mesmo Dockerfile, cada um é um
"estágio" isolado, e só copia explicitamente pro estágio final o que ele realmente precisa pra
rodar. Toolchain de build fica pra trás.

---

## 🎯 Resposta Rápida

```dockerfile
FROM node:22-alpine AS build
WORKDIR /app
COPY package*.json ./
RUN npm ci
COPY . .
RUN npm run build && npm prune --omit=dev

FROM node:22-alpine AS deploy
WORKDIR /app
COPY --from=build /app/node_modules ./node_modules
COPY --from=build /app/dist ./dist
CMD ["node", "dist/main"]
```

Dois estágios: um builda (`build`), outro só roda o que já foi buildado (`deploy`). O estágio
final nunca teve TypeScript, `@nestjs/cli` ou devDependencies instalados nele.

---

## 📚 Como Funciona

```text
FROM <imagem> AS build          ← estágio 1: tem TUDO (deps completas, toolchain, código-fonte)
    │
    │  RUN npm ci
    │  RUN npm run build         (gera dist/)
    │  RUN npm prune --omit=dev  (remove devDependencies do node_modules)
    │
    ▼
FROM <imagem> AS deploy          ← estágio 2: começa do ZERO, imagem limpa
    │
    │  COPY --from=build /app/node_modules ./node_modules   ← só isso atravessa
    │  COPY --from=build /app/dist ./dist                   ← e isso
    │
    ▼
CMD ["node", "dist/main"]        ← imagem final: sem .ts, sem devDeps, sem toolchain de build
```

O ponto-chave é `COPY --from=<nome-do-estágio>`: ele copia arquivos de dentro de outro estágio da
mesma build, não da máquina host. Cada estágio começa "vazio" (a não ser que herde de outro
estágio via `FROM <estágio-anterior> AS ...`) — nada passa de um pro outro a menos que você use
`COPY --from`.

### Cache de camadas: por que copiar `package*.json` antes do código

```dockerfile
COPY package*.json ./
RUN npm ci
COPY . .
```

O Docker cacheia camadas por hash do conteúdo. Se `package*.json` não mudou, a camada do `npm ci`
é reaproveitada do cache mesmo que o código-fonte tenha mudado — reinstalar dependências é
normalmente o passo mais lento de um build. Inverter a ordem (`COPY . .` antes do `npm ci`) faz
qualquer mudança de código invalidar o cache de instalação também, mesmo sem nenhuma dependência
ter mudado.

---

## 🆚 Variações Comuns de Imagem Base

A escolha da imagem base do estágio final muda o trade-off entre tamanho, segurança e
depurabilidade:

| Imagem base | Tamanho aprox. | Tem shell? | Quando usar |
| --- | --- | --- | --- |
| `node:XX` (padrão, Debian) | ~1 GB | ✅ sim | Dev/debug local; não recomendado pra produção |
| `node:XX-alpine` | ~150 MB | ✅ sim (`sh`) | Bom equilíbrio: pequena, mas ainda dá pra `exec` e depurar |
| `gcr.io/distroless/nodejs` | ~120 MB | ❌ não | Produção com foco máximo em segurança; sem shell, sem package manager, superfície de ataque mínima |

Alpine é o meio-termo mais comum: bem menor que a imagem padrão, mas ainda permite `docker exec -it <container> sh` pra investigar um problema em produção — algo que distroless não oferece.

---

## ✅ Faça / ❌ Não Faça

**✅ Estágio final parte de uma imagem base limpa, não do estágio de build:**

```dockerfile
FROM node:22-alpine AS build
# ... instala tudo, compila ...

FROM node:22-alpine AS deploy   # ✅ imagem nova, não herda nada do build
COPY --from=build /app/dist ./dist
```

**❌ Estágio final herdando direto do estágio de build:**

```dockerfile
FROM build AS deploy   # ❌ herda TUDO: devDeps, .ts, toolchain de compilação
CMD ["node", "dist/main"]
```

Isso anula o propósito do multi-stage — a imagem final fica do mesmo tamanho que o estágio de
build.

**✅ Podar devDependencies antes de copiar pro estágio final:**

```dockerfile
RUN npm run build && npm prune --omit=dev
```

**❌ Copiar `node_modules` sem podar:**

```dockerfile
COPY --from=build /app/node_modules ./node_modules   # ❌ ainda tem devDeps dentro
```

---

## 🎯 Exemplo do Projeto

Arquivo: `Dockerfile` (raiz do projeto). Usa três estágios, não dois — um estágio `base`
intermediário reaproveitado pelos outros dois, pra não repetir `FROM`/`WORKDIR`:

```dockerfile
FROM node:22-alpine AS base
WORKDIR /usr/src/app

# ----------

FROM base AS build
COPY package*.json ./
RUN npm ci
COPY . .
RUN npm run build
RUN npm prune --omit=dev

# ----------

FROM base AS deploy
COPY --from=build /usr/src/app/node_modules ./node_modules
COPY --from=build /usr/src/app/dist ./dist
COPY package*.json ./
EXPOSE 3000
CMD [ "node", "dist/main" ]
```

| Estágio | Papel | O que segue pro próximo |
| --- | --- | --- |
| `base` | imagem comum (`node:22-alpine` + `WORKDIR`) | — |
| `build` | instala deps completas, compila TS→JS, remove devDeps | `node_modules` (sem dev) e `dist/` |
| `deploy` | imagem final, só runtime | *(é a imagem final)* |

`deploy` parte de `base`, não de `build` — mesma lógica do bloco ✅/❌ acima, só que com um
estágio comum no meio em vez de repetir `FROM node:22-alpine` duas vezes.

A versão do Node (`node:22-alpine`) é a mesma usada pelo workflow de CI (ver
[tutorial de CI/CD](./ci-cd-github-actions-docker-hub.md)) — mantenha as duas alinhadas quando
atualizar uma delas, pra não testar num ambiente e rodar em produção noutro.

---

## ⚠️ Armadilhas

**Trocar `FROM base AS deploy` por `FROM build AS deploy`** — parece uma simplificação inofensiva,
mas volta a herdar toda a toolchain de build na imagem final (ver bloco ✅/❌ acima).

**Esquecer o `npm prune --omit=dev`** — sem isso, mesmo copiando só o `node_modules` do estágio de
build, ele ainda carrega as devDependencies inteiras.

**Path do `COPY --from` errado** — o caminho depois de `--from=build` é o caminho *dentro* do
estágio de build (aqui, `/usr/src/app/...`, porque foi o `WORKDIR` definido em `base`), não um
caminho relativo ao Dockerfile.

---

## Checklist Para Replicar em Outro Projeto

1. Escolher uma imagem base leve compatível com a stack (`node:XX-alpine`, `python:X-slim`, etc).
2. Criar um estágio de build: copiar primeiro os arquivos de lock (`package*.json` ou equivalente)
   e instalar com um comando reprodutível (`npm ci`, não `npm install`) — isso mantém o cache de
   camadas útil.
3. Copiar o restante do código e rodar o build.
4. Remover dependências de desenvolvimento antes de copiar pro estágio final
   (`npm prune --omit=dev`, ou instalar deps de produção num passo separado).
5. Criar o estágio final a partir de uma imagem **limpa** (a mesma base, ou distroless) — nunca a
   partir do estágio de build — e copiar só os artefatos necessários com `COPY --from=<estágio>`.
6. Definir `EXPOSE <porta>` e `CMD`/`ENTRYPOINT` apontando pro artefato já compilado.
7. Validar com `docker build .` e comparar o tamanho da imagem (`docker images`) contra uma versão
   single-stage equivalente.

---

## 📝 Resumo

| Decisão | Escolha deste projeto | Alternativa comum |
| --- | --- | --- |
| Imagem base | `node:22-alpine` | `distroless` (mais seguro, sem shell) |
| Nº de estágios | 3 (`base` → `build` → `deploy`) | 2 (`build` → `deploy`, sem estágio comum) |
| O que atravessa pro final | `node_modules` podado + `dist/` | idem, ou um binário único (Go, Rust) |

Para a maioria dos projetos Node/Nest, o padrão de 2-3 estágios com `alpine` já entrega a maior
parte do ganho (tamanho pequeno, sem toolchain de build) sem a rigidez de distroless (sem shell
pra debugar).

## Referência

- `Dockerfile` (raiz do projeto)
- `docker-compose.yml` — usa este Dockerfile para construir o serviço `api-rocket`
