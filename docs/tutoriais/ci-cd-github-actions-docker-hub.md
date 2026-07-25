# CI/CD com GitHub Actions: Testar, Taguear e Publicar no Docker Hub

## 🤔 Como Garantir Que Só Código Testado Vira Imagem em Produção?

Buildar e publicar uma imagem Docker manualmente é fácil de esquecer um passo — rodar os testes,
lembrar a tag certa, não vazar credencial no comando. **CI/CD** automatiza isso: a cada push numa
branch específica, um pipeline testa o código e, só se passar, builda e publica a imagem — sem
depender de alguém lembrar de fazer isso certo toda vez.

---

## 🎯 Resposta Rápida

```yaml
on:
  push:
    branches: [main]

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with: { node-version: "22", cache: npm }
      - run: npm ci
      - run: npm test # ← gate: se falhar, nada abaixo roda
      - uses: docker/login-action@v3
        with:
          username: ${{ secrets.DOCKERHUB_USERNAME }}
          password: ${{ secrets.DOCKERHUB_TOKEN }}
      - uses: docker/build-push-action@v5
        with: { push: true, tags: user/repo:latest }
```

O `npm test` antes do build/push é o que transforma isso num **gate de qualidade**: uma falha
interrompe o job e a imagem nunca chega a ser publicada.

---

## 📚 Como Funciona

```text
push → branch monitorada
   │
   ▼
[checkout] → [setup runtime] → [instalar deps] → [rodar testes]
                                                        │
                                                        ▼  (só se os testes passarem)
                                  [gerar tag rastreável ao commit]
                                                        │
                                                        ▼
                                  [login no registry] → [build + push da imagem]
                                                          tags: <sha curto> e latest
```

### Por que `env` para a versão do runtime

```yaml
env:
  NODE_VERSION: "22"
```

Centralizar a versão numa variável do workflow (reaproveitada no `setup-node`) evita que ela fique
hardcoded em múltiplos lugares do arquivo — e, mais importante, é o mesmo valor que deveria estar
no `Dockerfile` do projeto (ver [tutorial de multi-stage build](./dockerfile-multi-stage-build.md)):
testar numa versão e rodar em produção noutra é uma fonte clássica de bugs "só acontece em prod".

### Tags: imutável (SHA) vs móvel (`latest`)

Publicar só com `latest` significa que você não consegue distinguir qual código gerou a imagem
que está rodando agora, nem voltar pra uma versão anterior sem rebuildar do zero. Gerar também uma
tag com o SHA curto do commit resolve isso:

```bash
SHA=$(echo $GITHUB_SHA | head -c7)
echo "sha=$SHA" >> $GITHUB_OUTPUT
```

`latest` sempre aponta pro build mais recente (conveniente pra "me dá a versão atual"); a tag de
SHA é imutável e rastreável a um commit específico (necessária pra "preciso voltar exatamente pra
essa versão").

---

## 🆚 `npm ci` vs `npm install` em CI

| Aspecto | `npm ci` | `npm install` |
| --- | --- | --- |
| Fonte da instalação | só o `package-lock.json` | `package.json`, pode reescrever o lock |
| Se lock e package.json divergem | **falha** | reescreve o lock silenciosamente |
| Velocidade | mais rápido (sem resolução de deps) | mais lento |
| Uso recomendado | CI, builds reprodutíveis | desenvolvimento local, ao adicionar/remover deps |

Em CI o objetivo é reproduzir exatamente o que está no lockfile — uma divergência silenciosa é
exatamente o tipo de coisa que só aparece quando já é tarde.

---

## ✅ Faça / ❌ Não Faça

**✅ Guardar credenciais de registry como Secrets do repositório:**

```yaml
password: ${{ secrets.DOCKERHUB_TOKEN }}
```

**❌ Hardcodar credencial no workflow:**

```yaml
password: "minha-senha-123" # ❌ fica em texto puro no histórico do git
```

**✅ Rodar os testes como gate antes de publicar:**

```yaml
- run: npm test
- run: docker build ... # só chega aqui se o passo anterior passou
```

**❌ Publicar a imagem sem testar (ou testar depois de já ter publicado):**

```yaml
- run: docker push ... # ❌ nenhuma garantia de que o código funciona
- run: npm test
```

---

## 🎯 Exemplo do Projeto

Arquivo: `.github/workflows/ci.yml`. Dispara só em push direto pra `master`:

```yaml
on:
  push:
    branches:
      - master

env:
  NODE_VERSION: "22"
```

Job `build` (`runs-on: ubuntu-latest`):

| Step | Action/comando | Papel |
| --- | --- | --- |
| Checkout | `actions/checkout@v4` | Clona o repositório no runner |
| Setup Node | `actions/setup-node@v4`, `cache: npm` | Instala o Node na versão de `env.NODE_VERSION`, com cache de deps |
| Instalar deps | `npm install` | Instala as dependências do projeto |
| Testar | `npm test` | Gate de qualidade — se falhar, o job para |
| Gerar tag | 7 chars do `$GITHUB_SHA` → `$GITHUB_OUTPUT` | Cria a tag rastreável ao commit |
| Login | `docker/login-action@v3` | Autentica no Docker Hub via secrets |
| Build + Push | `docker/build-push-action@v5`, `push: true` | Builda e publica com 2 tags |

```yaml
tags: lanprd/estudos-ci-cd:${{ steps.generate_tag.outputs.sha }},lanprd/estudos-ci-cd:latest
```

### 🔍 Onde Ver as Execuções

- **GitHub → aba Actions** do repositório: cada execução, com logs por step — útil pra depurar um
  `npm test` ou `docker login` que falhou.
- **Docker Hub → `hub.docker.com/r/<usuário>/<repo>/tags`**: as imagens publicadas, uma por SHA,
  mais a `latest`.
- **Secrets do repositório**: `Settings → Secrets and variables → Actions` — onde
  `DOCKERHUB_USERNAME`/`DOCKERHUB_TOKEN` são configurados; nunca aparecem nos logs do workflow.

---

## ⚠️ Armadilhas

**Este workflow usa `npm install`, não `npm ci`** — o `Dockerfile` do mesmo projeto já usa
`npm ci` (mais estrito, ver tabela 🆚 acima); o `ci.yml` ficou inconsistente com isso. Vale
alinhar os dois.

**Steps mortos comentados no arquivo** — logo abaixo do `docker/build-push-action@v5` existem
dois steps comentados (`docker build`/`docker push` manuais). *(Inferência: parecem ter sido
deixados como referência de como seria a versão manual do mesmo passo — o histórico do arquivo
não confirma essa razão.)* Não afetam a execução, mas são candidatos a limpeza.

---

## Checklist Para Replicar em Outro Projeto

1. Criar `.github/workflows/<nome>.yml` com o evento que deve disparar o pipeline
   (`on.push.branches`, `on.pull_request`, etc).
2. Definir a versão do runtime via `env` e usar a action oficial de setup com cache habilitado.
3. Instalar dependências de forma reprodutível (`npm ci`) e rodar a suíte de testes como **gate**
   antes de qualquer publicação.
4. Gerar uma tag rastreável ao commit (SHA curto), em vez de depender só de `latest`.
5. Guardar usuário/token do registry como **Secrets** do repositório — nunca hardcoded.
6. Usar uma action de login (`docker/login-action` ou equivalente) e uma de build+push
   (`docker/build-push-action`) em vez de `docker build`/`docker push` manuais.
7. Publicar com pelo menos duas tags: uma imutável (SHA) e uma móvel (`latest`).
8. Conferir a execução na aba **Actions** do GitHub e a imagem publicada no registry.

---

## 📝 Resumo

| Decisão | Escolha deste projeto | Alternativa comum |
| --- | --- | --- |
| Trigger | push em `master` | `pull_request`, tags, `workflow_dispatch` |
| Instalar deps | `npm install` (inconsistente com o Dockerfile) | `npm ci` |
| Registry | Docker Hub | GitHub Container Registry, AWS ECR, GCP Artifact Registry |
| Estratégia de tag | SHA curto + `latest` | SemVer, data, ambos combinados |

## Referência

- `.github/workflows/ci.yml`
- `Dockerfile` — buildado automaticamente pelo `docker/build-push-action`
