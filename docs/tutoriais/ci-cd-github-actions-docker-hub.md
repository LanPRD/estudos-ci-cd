# Pipeline de CI com GitHub Actions: testar, taguear e publicar no Docker Hub

## Quando usar isso

Quando você quer que, a cada push numa branch específica (aqui, `master`), o projeto seja testado
automaticamente e, só se passar, uma imagem Docker seja construída e publicada num registry
(Docker Hub) com uma tag rastreável ao commit.

```text
push → master
   │
   ▼
[checkout] → [setup node] → [npm install] → [npm test]
                                                │
                                                ▼  (só se os testes passarem)
                          [gera tag = 7 chars do SHA]
                                                │
                                                ▼
                          [login Docker Hub] → [build + push imagem]
                                                 tags: <sha curto> e latest
```

## Como foi feito neste projeto

Arquivo: `.github/workflows/ci.yml`.

### Trigger e configuração

- `on.push.branches: [master]` — o workflow só dispara em push direto pra `master`. Não roda em
  pull requests, outras branches ou tags.
- `env.NODE_VERSION: "22"` — versão do Node centralizada numa variável do workflow, reaproveitada
  no step de setup.

### Job `build` (`runs-on: ubuntu-latest`)

| Step          | Action/comando                                        | Papel                                                                                 |
| ------------- | ----------------------------------------------------- | ------------------------------------------------------------------------------------- |
| Checkout      | `actions/checkout@v4`                                 | Clona o repositório no runner                                                         |
| Setup Node    | `actions/setup-node@v4`, `cache: npm`                 | Instala o Node na versão do `env.NODE_VERSION`, com cache de deps npm entre execuções |
| Instalar deps | `npm install`                                         | Instala as dependências do projeto                                                    |
| Testar        | `npm test`                                            | **Gate de qualidade** — se falhar, o job para e nenhuma imagem é publicada            |
| Gerar tag     | 7 primeiros chars de `$GITHUB_SHA` → `$GITHUB_OUTPUT` | Cria uma tag rastreável ao commit (`steps.generate_tag.outputs.sha`)                  |
| Login         | `docker/login-action@v3`                              | Autentica no Docker Hub via secrets `DOCKERHUB_USERNAME`/`DOCKERHUB_TOKEN`            |
| Build + Push  | `docker/build-push-action@v5`, `push: true`           | Builda a imagem a partir do `Dockerfile` e publica com 2 tags                         |

O step de geração de tag:

```bash
SHA=$(echo $GITHUB_SHA | head -c7)
echo "sha=$SHA" >> $GITHUB_OUTPUT
```

O step de build+push publica em duas tags:

```yaml
tags: lanprd/estudos-ci-cd:${{ steps.generate_tag.outputs.sha }},lanprd/estudos-ci-cd:latest
```

`<sha>` é imutável e rastreável a um commit específico; `latest` sempre aponta pro build mais
recente que passou no pipeline.

## Onde ver as execuções

- **GitHub → aba Actions** do repositório: lista cada execução do workflow por push, com os logs
  de cada step (útil pra depurar um `npm test` ou `docker login` que falhou).
- **Docker Hub → `hub.docker.com/r/<usuário>/<repo>/tags`**: mostra as imagens publicadas, uma por
  SHA, mais a `latest`.
- **Secrets do repositório**: `Settings → Secrets and variables → Actions` — é onde
  `DOCKERHUB_USERNAME` e `DOCKERHUB_TOKEN` são configurados; não aparecem nos logs do workflow.

## Checklist para replicar em outro projeto

1. Criar `.github/workflows/<nome>.yml` com o evento que deve disparar o pipeline
   (`on.push.branches`, `on.pull_request`, etc).
2. Definir a versão do runtime via `env` e usar a action oficial de setup (`setup-node`,
   `setup-go`, ...) com cache habilitado.
3. Instalar dependências de forma reprodutível — prefira `npm ci` a `npm install` em CI — e rodar
   a suíte de testes como **gate** antes de qualquer publicação.
4. Gerar uma tag rastreável ao commit (ex: SHA curto), em vez de depender só de `latest`.
5. Guardar usuário/token do registry como **Secrets** do repositório — nunca hardcoded no
   workflow.
6. Usar uma action de login do registry (`docker/login-action` ou equivalente) e uma action de
   build+push (`docker/build-push-action`) em vez de `docker build`/`docker push` manuais — menos
   boilerplate e melhor cache de camadas.
7. Publicar com pelo menos duas tags: uma imutável (SHA) e uma móvel (`latest`), pra permitir
   identificar e reverter facilmente pra uma versão anterior.
8. Conferir a execução na aba **Actions** do GitHub e a imagem publicada no registry.

## Armadilhas e decisões importantes

A versão do Node usada pra testar (`env.NODE_VERSION: "22"`) é a mesma do `Dockerfile`
(`node:22-alpine`, ver [tutorial do Dockerfile](./dockerfile-multi-stage-build.md)) — mantenha as
duas alinhadas quando atualizar uma delas, pra não testar num ambiente e rodar em produção noutro.

⚠️ **`npm install` vs `npm ci`**: o workflow usa `npm install`, que pode reescrever o
`package-lock.json` silenciosamente se ele estiver desalinhado com o `package.json`. `npm ci` é
mais estrito — instala exatamente o que está no lockfile e falha se houver divergência — e é o
que o próprio `Dockerfile` já usa. Mais seguro pra CI.

O arquivo também tem dois steps comentados (build/push manual via `docker build`/`docker push`)
logo abaixo do `docker/build-push-action@v5`. *(Inferência: parecem ter sido deixados como
referência de como seria a versão manual do mesmo passo — o histórico do arquivo não confirma essa
razão.)* Não afetam a execução, mas são candidatos a limpeza.

## Referência

- `.github/workflows/ci.yml`
- `Dockerfile` — buildado automaticamente pelo `docker/build-push-action`
