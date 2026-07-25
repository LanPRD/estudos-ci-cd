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
senha fixos (o jeito mais simples e mais comum). O projeto real usa uma forma mais segura de
autenticar (OIDC) — ver 🆚 abaixo.

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

| Aspecto                 | Usuário/senha ou token fixo (ex: Docker Hub)       | OIDC / Federação de identidade (ex: AWS)                                                                     |
| ----------------------- | -------------------------------------------------- | ------------------------------------------------------------------------------------------------------------ |
| O que fica guardado     | uma credencial de longa duração em Secrets do repo | nada de permanente — o provedor confia no token que o próprio GitHub emite pra cada execução                 |
| Se vazar                | credencial válida até alguém revogar manualmente   | token expira em minutos, é de uso único por execução                                                         |
| Configuração            | mais simples: 2 secrets + `docker/login-action`    | mais peças: um provedor OIDC + uma role com política de confiança no lado do cloud (ver Terraform em `iac/`) |
| Quem restringe o acesso | quem guarda a credencial certo                     | a própria condição da role (ex: "só de `repo:org/repo:ref:refs/heads/master`")                               |

OIDC (usado por `aws-actions/configure-aws-credentials` + `amazon-ecr-login`) evita guardar uma
credencial de nuvem de longa duração como Secret: a cada execução, o GitHub emite um token de
identidade assinado, e o provedor de nuvem (AWS, aqui) confia nesse token porque uma _IAM Role_
foi configurada pra aceitar apenas tokens vindos deste repositório/branch específico. Sem
credencial fixa armazenada, não há credencial fixa pra vazar.

**O ARN da role (`role-to-assume`) não é segredo** — é só um identificador, como um nome de
usuário. Quem decide se um token consegue assumir a role é a _trust policy_ do lado da AWS (o
`StringLike` no bloco ✅/❌ abaixo), não o fato de o ARN ficar visível no workflow. Publicar o ARN
em texto puro não abre acesso a mais ninguém; guardá-lo como Secret é só conveniência (evita
editar o YAML se a role mudar), não uma exigência de segurança.

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
    "repo:LanPRD@76744839/estudos-ci-cd@1311551142:ref:refs/heads/master"
  ]
}
```

(o `@76744839`/`@1311551142` são os IDs imutáveis do owner e do repo — ver 🐛 abaixo antes de
copiar só o formato `repo:OWNER/REPO:ref:...` de um tutorial mais antigo.)

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

Arquivo: `.github/workflows/ci.yml`. Dispara em push pra `master`, mas só quando o que mudou pode
de fato afetar o build/testes/deploy:

```yaml
on:
  push:
    branches:
      - master
    paths:
      - "src/**"
      - "test/**"
      - "package.json"
      - "package-lock.json"
      - "Dockerfile"
      - "docker-compose.yml"
      - "tsconfig.json"
      - "tsconfig.build.json"
      - "nest-cli.json"
      - ".github/workflows/ci.yml"

permissions:
  contents: read
  id-token: write

env:
  NODE_VERSION: "22"
```

`paths` evita execuções desperdiçadas para mudanças que não afetam o resultado (ex: editar um
tutorial em `docs/`). `id-token: write` em `permissions` é o que autoriza o job a pedir ao GitHub
um token OIDC — sem essa permissão, `configure-aws-credentials` não teria o que apresentar pra AWS
(ver 🆚 acima).

Job `build` (`runs-on: ubuntu-latest`):

| Step                       | Action/comando                                 | Papel                                                             |
| -------------------------- | ---------------------------------------------- | ----------------------------------------------------------------- |
| Checkout                   | `actions/checkout@v7`                          | Clona o repositório no runner                                     |
| Setup Node                 | `actions/setup-node@v7`, `cache: npm`          | Instala o Node na versão de `env.NODE_VERSION`, com cache de deps |
| Instalar deps              | `npm install`                                  | Instala as dependências do projeto                                |
| Testar                     | `npm test`                                     | Gate de qualidade — se falhar, o job para                         |
| Gerar tag                  | 7 chars do `$GITHUB_SHA` → `$GITHUB_OUTPUT`    | Cria a tag rastreável ao commit                                   |
| Configurar credenciais AWS | `aws-actions/configure-aws-credentials@v6.2.3` | Assume `arn:aws:iam::958157975241:role/ecr-role` via OIDC         |
| Login no ECR               | `aws-actions/amazon-ecr-login@v2`              | Autentica o Docker no Amazon ECR                                  |
| Build + Push                | `docker build` / `docker push` (manual)        | Builda a imagem e publica em `$ECR_REGISTRY/estudos-ci-cd:$TAG`   |

A role e o repositório ECR usados aqui vêm do Terraform em `iac/` (ver `iac/iam.tf` e
`iac/ecr.tf`) — o `sub` da role de confiança está atrelado a este repo e à branch `master`. O
registry vem do output do próprio step de login (`steps.login-ecr.outputs.registry`), e a tag é a
gerada no step "Gerar tag" — a imagem final fica `<registry>/estudos-ci-cd:<sha>`.

### 🔍 Onde Ver as Execuções

- **GitHub → aba Actions** do repositório: cada execução, com logs por step.
- **AWS → ECR → repositório `estudos-ci-cd`**: as imagens publicadas, uma tag por SHA.
- **AWS → IAM → Roles → `ecr-role`**: a role assumida via OIDC e sua política de confiança.

---

## ⚠️ Armadilhas

**🐛 `AssumeRoleWithWebIdentity` nega mesmo com a trust policy "certa"** — desde 15/07/2026, o
GitHub emite o claim `sub` do token OIDC num formato diferente pra repositórios **criados,
renomeados ou transferidos a partir dessa data**: em vez do formato clássico
`repo:OWNER/REPO:ref:refs/heads/BRANCH`, o `sub` passa a incluir os IDs imutáveis de owner e repo —
`repo:OWNER@OWNER_ID/REPO@REPO_ID:ref:refs/heads/BRANCH`. É uma proteção contra reaproveitamento de
nome (repo deletado/renomeado e o nome antigo reusado por outra conta não herda a confiança). Repos
mais antigos continuam no formato clássico até você optar pelo novo — mas qualquer repo novo, como
este (`estudos-ci-cd`, criado em 25/07/2026), já nasce no formato novo. Uma trust policy escrita
copiando o formato clássico de um tutorial (inclusive documentação mais antiga da própria AWS)
nunca bate, e a AWS nega o `AssumeRoleWithWebIdentity` sem apontar o motivo — não há erro
mencionando "sub" ou "formato".

Pra pegar os dois IDs **antes** de escrever a trust policy pela primeira vez (sem depender de rodar
a pipeline e ver ela falhar):

```bash
curl -s https://api.github.com/repos/<owner>/<repo> | jq '{repo_id: .id, owner_id: .owner.id}'
```

Se já tiver uma execução falhando e quiser confirmar o `sub` real que está sendo enviado, um step
temporário decodifica o token (remova depois — não é pra ficar rodando permanentemente):

```yaml
- name: Debug OIDC claims
  run: |
    IDTOKEN=$(curl -sSL -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
      "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=sts.amazonaws.com" | jq -r '.value')
    echo "$IDTOKEN" | cut -d. -f2 | base64 -d 2>/dev/null | jq .
```

_(Fonte: [changelog oficial do GitHub sobre immutable subject claims](https://github.blog/changelog/2026-04-23-immutable-subject-claims-for-github-actions-oidc-tokens/).)_

**Build + push manuais em vez de uma action dedicada** — o step final roda `docker build` e
`docker push` diretamente (ver checklist item 6 abaixo, que recomenda o contrário). Funciona, mas
uma action como `docker/build-push-action` (equivalente pra ECR não existe oficial, mas dá pra
compor build-push-action + login-ecr) cuida de cache de camadas e evita erros de digitação nos
comandos manuais — considere migrar se o pipeline crescer.

Ainda sobra um step comentado órfão no fim do arquivo (`# - name: Push image`, um resquício da
versão Docker Hub) — não afeta a execução, mas é candidato a limpeza junto dos outros comentários
que já foram removidos.

**Este workflow usa `npm install`, não `npm ci`** — o `Dockerfile` do mesmo projeto já usa
`npm ci` (mais estrito e reprodutível). Vale alinhar os dois quando a migração for finalizada.

---

## Checklist Para Replicar em Outro Projeto

1. Criar `.github/workflows/<nome>.yml` com o evento que deve disparar o pipeline
   (`on.push.branches`, `on.pull_request`, etc). Considere restringir com `on.push.paths` pra não
   rodar o pipeline em mudanças que não afetam o build (ex: só documentação).
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

| Decisão           | Estado atual deste projeto                                   | Alternativa comum                                |
| ----------------- | ------------------------------------------------------------ | ------------------------------------------------ |
| Trigger           | push em `master`, filtrado por `paths`                       | `pull_request`, tags, `workflow_dispatch`        |
| Instalar deps     | `npm install` (inconsistente com o Dockerfile)               | `npm ci`                                         |
| Registry          | AWS ECR (migrado de Docker Hub)                               | GitHub Container Registry, GCP Artifact Registry |
| Autenticação      | OIDC via IAM Role (`iac/iam.tf`)                             | Secrets fixos (usuário/token)                    |
| Estratégia de tag | SHA curto + `latest`                                         | SemVer, data, ambos combinados                   |

## Referência

- `.github/workflows/ci.yml`
- `iac/iam.tf`, `iac/ecr.tf` — Terraform que provisiona a role OIDC e o repositório ECR usados aqui
- `Dockerfile` — a imagem que este pipeline builda e publica
