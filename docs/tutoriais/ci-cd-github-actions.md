# CI/CD com GitHub Actions: Testar, Taguear e Publicar uma Imagem

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
interrompe o job e a imagem nunca chega a ser publicada. O exemplo acima autentica com usuário e
senha fixos (o jeito mais simples e mais comum). O projeto real está migrando para uma forma mais
segura de autenticar — ver 🆚 abaixo.

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
                                  [autenticar no registry] → [build + push da imagem]
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

## 🆚 Autenticar no Registry: Secrets Fixos vs OIDC

| Aspecto | Usuário/senha ou token fixo (ex: Docker Hub) | OIDC / Federação de identidade (ex: AWS) |
| --- | --- | --- |
| O que fica guardado | uma credencial de longa duração em Secrets do repo | nada de permanente — o provedor confia no token que o próprio GitHub emite pra cada execução |
| Se vazar | credencial válida até alguém revogar manualmente | token expira em minutos, é de uso único por execução |
| Configuração | mais simples: 2 secrets + `docker/login-action` | mais peças: um provedor OIDC + uma role com política de confiança no lado do cloud (ver Terraform em `iac/`) |
| Quem restringe o acesso | quem guarda a credencial certo | a própria condição da role (ex: "só de `repo:org/repo:ref:refs/heads/master`") |

OIDC (usado por `aws-actions/configure-aws-credentials` + `amazon-ecr-login`) evita guardar uma
credencial de nuvem de longa duração como Secret: a cada execução, o GitHub emite um token de
identidade assinado, e o provedor de nuvem (AWS, aqui) confia nesse token porque uma *IAM Role*
foi configurada pra aceitar apenas tokens vindos deste repositório/branch específico. Sem
credencial fixa armazenada, não há credencial fixa pra vazar.

---

## ✅ Faça / ❌ Não Faça

**✅ Guardar credenciais de longa duração como Secrets do repositório (quando não dá pra usar OIDC):**

```yaml
password: ${{ secrets.DOCKERHUB_TOKEN }}
```

**❌ Hardcodar credencial no workflow:**

```yaml
password: "minha-senha-123" # ❌ fica em texto puro no histórico do git
```

**✅ Restringir a role OIDC a este repositório/branch específico** (trecho do `iac/iam.tf`):

```hcl
"StringLike": {
  "token.actions.githubusercontent.com:sub": [
    "repo:LanPRD/estudos-ci-cd:ref:refs/heads/master"
  ]
}
```

**❌ Deixar a condição de confiança aberta demais:**

```hcl
"StringLike": {
  "token.actions.githubusercontent.com:sub": ["repo:*"] # ❌ qualquer repo do GitHub poderia assumir a role
}
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
| Checkout | `actions/checkout@v7` | Clona o repositório no runner |
| Setup Node | `actions/setup-node@v7`, `cache: npm` | Instala o Node na versão de `env.NODE_VERSION`, com cache de deps |
| Instalar deps | `npm install` | Instala as dependências do projeto |
| Testar | `npm test` | Gate de qualidade — se falhar, o job para |
| Gerar tag | 7 chars do `$GITHUB_SHA` → `$GITHUB_OUTPUT` | Cria a tag rastreável ao commit |
| Configurar credenciais AWS | `aws-actions/configure-aws-credentials@v6.2.3` | Assume a role via OIDC (ver 🆚 acima) |
| Login no ECR | `aws-actions/amazon-ecr-login@v2` | Autentica o Docker no Amazon ECR |

A role e o repositório ECR usados aqui vêm do Terraform em `iac/` (ver `iac/iam.tf` e
`iac/ecr.tf`) — o `sub` da role de confiança está atrelado a este repo e à branch `master`.

### 🔍 Onde Ver as Execuções

- **GitHub → aba Actions** do repositório: cada execução, com logs por step.
- **AWS → ECR → repositório `estudos-ci-cd`**: as imagens publicadas (quando o step de push
  existir — ver armadilha abaixo).
- **AWS → IAM → Roles → `ecr-role`**: a role assumida via OIDC e sua política de confiança.

---

## ⚠️ Armadilhas

**🚧 Migração em andamento, pipeline não publica nada no momento** — o workflow hoje testa, gera a
tag e autentica no ECR, mas não existe (ainda) um step de build+push apontando pra ECR depois do
login. `role-to-assume` na configuração de credenciais também está vazio. Os steps antigos do
Docker Hub (`docker/login-action` + `docker/build-push-action`) ficaram comentados no arquivo como
histórico da transição, não deletados — não rodam, mas também não devem ser reativados sem revisar
se ainda fazem sentido junto com a autenticação nova.

**Este workflow usa `npm install`, não `npm ci`** — o `Dockerfile` do mesmo projeto já usa
`npm ci` (mais estrito e reprodutível). Vale alinhar os dois quando a migração for finalizada.

---

## Checklist Para Replicar em Outro Projeto

1. Criar `.github/workflows/<nome>.yml` com o evento que deve disparar o pipeline
   (`on.push.branches`, `on.pull_request`, etc).
2. Definir a versão do runtime via `env` e usar a action oficial de setup com cache habilitado.
3. Instalar dependências de forma reprodutível (`npm ci`) e rodar a suíte de testes como **gate**
   antes de qualquer publicação.
4. Gerar uma tag rastreável ao commit (SHA curto), em vez de depender só de `latest`.
5. Preferir OIDC a credenciais fixas quando o provedor de nuvem suportar (AWS, GCP e Azure
   suportam); caso contrário, guardar usuário/token como **Secrets** do repositório — nunca
   hardcoded.
6. Usar uma action de login (`docker/login-action`, `amazon-ecr-login`, etc.) e uma de build+push
   em vez de `docker build`/`docker push` manuais.
7. Publicar com pelo menos duas tags: uma imutável (SHA) e uma móvel (`latest`).
8. Conferir a execução na aba **Actions** do GitHub e a imagem publicada no registry.

---

## 📝 Resumo

| Decisão | Estado atual deste projeto | Alternativa comum |
| --- | --- | --- |
| Trigger | push em `master` | `pull_request`, tags, `workflow_dispatch` |
| Instalar deps | `npm install` (inconsistente com o Dockerfile) | `npm ci` |
| Registry | migrando de Docker Hub para AWS ECR (ainda sem step de push) | GitHub Container Registry, GCP Artifact Registry |
| Autenticação | OIDC via IAM Role (`iac/iam.tf`) | Secrets fixos (usuário/token) |
| Estratégia de tag | SHA curto + `latest` | SemVer, data, ambos combinados |

## Referência

- `.github/workflows/ci.yml`
- `iac/iam.tf`, `iac/ecr.tf` — Terraform que provisiona a role OIDC e o repositório ECR usados aqui
- `Dockerfile` — a imagem que este pipeline builda (quando o step de push existir)
