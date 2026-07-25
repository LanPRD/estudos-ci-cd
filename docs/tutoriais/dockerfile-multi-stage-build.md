# Build multi-stage com Docker para apps Node/Nest

## Quando usar isso

Quando você quer uma imagem Docker de produção enxuta para uma aplicação Node (aqui, um app
NestJS): sem devDependencies, sem código-fonte TypeScript, só o necessário pra rodar
`node dist/main`. Multi-stage evita carregar na imagem final toda a toolchain de build
(TypeScript, `@nestjs/cli`, etc.), que só é necessária durante a compilação.

```text
FROM node:22-alpine AS base   imagem comum + WORKDIR
        │
        ▼
FROM base AS build            npm ci → copia código → npm run build → prune dev deps
        │        (o estágio final só herda o que for copiado explicitamente)
        ▼
FROM base AS deploy           COPY --from=build (node_modules podado + dist)
                               EXPOSE 3000 · CMD ["node", "dist/main"]
```

## Como foi feito neste projeto

### 1. Estágio `base`

`FROM node:22-alpine AS base` + `WORKDIR /usr/src/app`. Imagem comum reaproveitada pelos outros
dois estágios, evita repetir `FROM`/`WORKDIR`.

### 2. Estágio `build`

`FROM base AS build` — instala e compila:

```dockerfile
COPY package*.json ./
RUN npm ci
COPY . .
RUN npm run build
RUN npm prune --omit=dev
```

Copiar só `package*.json` antes do `npm ci` aproveita o cache de camadas do Docker: se só o
código-fonte mudar (não as dependências), essa camada não precisa reinstalar nada. Depois do
build, `npm prune --omit=dev` remove as devDependencies do `node_modules`, deixando só o que é
necessário em runtime.

### 3. Estágio `deploy`

`FROM base AS deploy` — parte de `base` novamente, **não** de `build`:

```dockerfile
COPY --from=build /usr/src/app/node_modules ./node_modules
COPY --from=build /usr/src/app/dist ./dist
COPY package*.json ./
EXPOSE 3000
CMD [ "node", "dist/main" ]
```

Só o `node_modules` (já podado) e o `dist/` (já compilado) atravessam pro estágio final — nenhum
arquivo `.ts`, nenhum `devDependency`, nenhuma ferramenta de build.

| Estágio  | Papel                                                 | O que segue pro próximo estágio    |
| -------- | ----------------------------------------------------- | ---------------------------------- |
| `base`   | imagem comum (`node:22-alpine` + `WORKDIR`)           | —                                  |
| `build`  | instala deps completas, compila TS→JS, remove devDeps | `node_modules` (sem dev) e `dist/` |
| `deploy` | imagem final, só runtime                              | _(é a imagem final)_               |

## Checklist para replicar em outro projeto

1. Escolher uma imagem base leve compatível com a stack (ex: `node:XX-alpine`).
2. Criar um estágio `base` só com `FROM` + `WORKDIR`.
3. Criar um estágio de build a partir de `base`: copiar primeiro os arquivos de lock
   (`package*.json` ou equivalente) e instalar com um comando reprodutível (`npm ci`, não
   `npm install`).
4. Copiar o restante do código e rodar o build (`npm run build`, `tsc`, etc.).
5. Remover dependências de desenvolvimento antes de copiar pro estágio final
   (`npm prune --omit=dev`, ou instalar deps de produção num passo separado).
6. Criar o estágio final **a partir de `base`**, não do estágio de build, e copiar só os
   artefatos necessários com `COPY --from=<stage>`.
7. Definir `EXPOSE <porta>` e `CMD`/`ENTRYPOINT` apontando pro artefato já compilado.
8. Validar com `docker build .` local e comparar o tamanho da imagem (`docker images`) — deve ser
   bem menor que uma imagem single-stage equivalente.

## Armadilhas e decisões importantes

⚠️ Repare que o estágio `deploy` parte de `base`, não de `build`. `build` carrega toda a toolchain
de compilação; se você trocar para `FROM build AS deploy`, a imagem final volta a herdar tudo que
o estágio de build usou, incluindo devDependencies e código-fonte.

A versão do Node da imagem (`node:22-alpine`) é a mesma usada pelo workflow de CI (ver
[tutorial de CI/CD](./ci-cd-github-actions-docker-hub.md)) — mantenha as duas alinhadas quando
atualizar uma delas, pra evitar testar num ambiente e rodar em produção noutro.

## Referência

- `Dockerfile` (raiz do projeto)
- `docker-compose.yml` — usa este Dockerfile para construir o serviço `api-rocket`
