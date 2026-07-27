# CI/CD com GitHub Actions: Testar, Taguear, Publicar e Deployar via Terraform

## 🤔 Como Garantir Que Só Código Testado Vira Imagem em Produção?

Buildar e publicar uma imagem Docker manualmente é fácil de esquecer um passo — rodar os testes,
lembrar a tag certa, não vazar credencial no comando. **CI/CD** automatiza isso: a cada push numa
branch específica, um pipeline testa o código e, só se passar, builda e publica a imagem — sem
depender de alguém lembrar de fazer isso certo toda vez. Este projeto vai além: o próprio deploy
também é automatizado, mas por um mecanismo que não é uma action dedicada de deploy — é o mesmo
Terraform que também gerencia a infraestrutura (ver 🏗️ abaixo pro porquê).

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
senha fixos (o jeito mais simples e mais comum). O projeto real usa OIDC pra autenticar na AWS (ver
🆚 abaixo) e, depois do push, chama `terraform apply` pra colocar a imagem nova rodando — não uma
action de deploy dedicada (ver 🏗️ abaixo).

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
SHA é imutável e rastreável a um commit específico — e é literalmente o valor usado pra fazer o
deploy (`terraform apply -var="image_tag=$SHA"`, ver 🎯 abaixo): sem ela, o Terraform não teria como
saber que uma imagem nova precisa entrar no ar.

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

**O ARN da role (`role-to-assume`) não é segredo** — é só um identificador. Quem decide se um token
consegue assumir a role é a _trust policy_ do lado da AWS (o `StringLike` no bloco ✅/❌ abaixo), não
o fato de o ARN ficar visível no workflow.

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

**✅ Restringir a role OIDC a este repositório/branch específico** (trecho do `iac/bootstrap/iam.tf`):

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

Arquivo: `.github/workflows/ci-app.yml`. Dispara em push pra `master`, mas só quando o que mudou
pode de fato afetar o build/testes/deploy:

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
      - ".github/workflows/ci-app.yml"

permissions:
  contents: write
  id-token: write
  issues: write
  pull-requests: write

env:
  NODE_VERSION: "22"
```

`paths` evita execuções desperdiçadas para mudanças que não afetam o resultado (ex: editar um
tutorial em `docs/`). `id-token: write` em `permissions` é o que autoriza o job a pedir ao GitHub
um token OIDC — sem essa permissão, `configure-aws-credentials` não teria o que apresentar pra AWS.
As outras três permissões não são deste pipeline em si — são o que o step de **Semantic Release**
precisa; ver o [tutorial dedicado](./semantic-release.md).

Job `build` (`runs-on: ubuntu-latest`):

| Step                        | Action/comando                                          | Papel                                                                                         |
| --------------------------- | ------------------------------------------------------- | --------------------------------------------------------------------------------------------- |
| Checkout                    | `actions/checkout@v7`, `fetch-depth: 0`                 | Clona o repositório com histórico completo no runner                                          |
| Setup Node                  | `actions/setup-node@v7`, `cache: npm`                   | Instala o Node na versão de `env.NODE_VERSION`, com cache de deps                             |
| Instalar deps               | `npm install`                                           | Instala as dependências do projeto                                                            |
| Testar                      | `npm test`                                              | Gate de qualidade — se falhar, o job para                                                     |
| Semantic Release            | `cycjimmy/semantic-release-action@v6`                   | Calcula versão, gera changelog/tag/release (ver [tutorial dedicado](./semantic-release.md))   |
| Gerar tag                   | 7 chars do `$GITHUB_SHA` → `$GITHUB_OUTPUT`             | Cria a tag da **imagem Docker**, rastreável ao commit                                         |
| Credenciais AWS (ECR)       | `aws-actions/configure-aws-credentials@v6.2.3`          | Assume `arn:aws:iam::958157975241:role/ecr-role` via OIDC                                     |
| Login no ECR                | `aws-actions/amazon-ecr-login@v2`                       | Autentica o Docker no Amazon ECR                                                              |
| Build + Push                | `docker build` / `docker push` (comandos manuais)       | Builda a imagem e publica `$ECR_REGISTRY/estudos-ci-cd:$TAG` e `:latest`                      |
| Credenciais AWS (Terraform) | `aws-actions/configure-aws-credentials@v6.2.3` (2ª vez) | Assume `arn:aws:iam::958157975241:role/tf-role` via OIDC — troca de identidade no meio do job |
| Terraform Init              | `terraform init` em `iac/service`                       | Conecta no backend S3 daquela camada                                                          |
| Deploy                      | `terraform apply -auto-approve -var="image_tag=$TAG"`   | Atualiza `aws_ecs_express_gateway_service` pra rodar a imagem recém-publicada                 |

A role e o repositório ECR usados aqui vêm do Terraform em `iac/` — `iac/bootstrap/iam.tf` (as
roles), `iac/infra/ecr.tf` (o repositório), `iac/service/ecs.tf` (o serviço) — ver o
[tutorial de IaC](./iac-terraform-aws.md). O registry vem do output do step de login
(`steps.login-ecr.outputs.registry`), e a tag é a gerada no step "Gerar tag" — a imagem final fica
`<registry>/estudos-ci-cd:<sha>`, e é exatamente esse `$TAG` que vira `var.image_tag` no
`terraform apply` final, sem hardcode duplicado.

**Duas tags diferentes, dois propósitos diferentes**: a tag do semantic-release (`vX.Y.Z`, num
commit no git) versiona o _código_; a tag `$SHA` versiona a _imagem Docker_ e é o valor que o
Terraform usa pra saber qual imagem colocar no ar. Elas não precisam (nem costumam) coincidir.

**Duas identidades OIDC no mesmo job** — repare que `configure-aws-credentials` roda **duas vezes**:
primeiro assumindo `ecr-role` (só o suficiente pra dar push no ECR), depois `tf-role` (só o
suficiente pra rodar Terraform). Cada chamada sobrescreve as credenciais ativas no runner — é assim
que um único job consegue operar com duas identidades de privilégio mínimo diferentes, em vez de uma
role só com permissão de ECR **e** de infraestrutura ao mesmo tempo.

### 🔍 Onde Ver as Execuções

- **GitHub → aba Actions** do repositório: cada execução, com logs por step.
- **AWS → ECR → repositório `estudos-ci-cd`**: as imagens publicadas, uma tag por SHA.
- **AWS → IAM → Roles → `ecr-role`/`tf-role`**: as roles assumidas via OIDC e suas trust policies.

---

## 🏗️ Três Pipelines Separados: App, Infra e Service

Este projeto tem **três** workflows, cada um disparado por mudanças em pastas diferentes,
autenticando com a role OIDC certa pra cada um — e dois deles (`ci-app` e `ci-service`) acabam
aplicando **a mesma** camada Terraform, por motivos diferentes:

```text
push pra master
   │
   ├── mudou src/, test/, package.json, Dockerfile...  ──►  ci-app.yml (assume ecr-role, depois tf-role)
   │                                                          testa → versiona → builda → publica →
   │                                                          terraform apply em iac/service (-var image_tag=<sha>)
   │
   ├── mudou iac/infra/**  ───────────────────────────►  ci-infra.yml (assume tf-role)
   │                                                          terraform plan → apply em iac/infra
   │
   └── mudou iac/service/**  ─────────────────────────►  ci-service.yml (assume tf-role)
                                                              terraform plan → apply em iac/service (sem -var)
```

| Aspecto                                   | `ci-app.yml`                                                | `ci-infra.yml`                            | `ci-service.yml`                          |
| ----------------------------------------- | ----------------------------------------------------------- | ----------------------------------------- | ----------------------------------------- |
| Dispara em mudanças em                    | `src/`, `test/`, `package.json`, `Dockerfile`...            | `iac/infra/**`                            | `iac/service/**`                          |
| Role(s) OIDC assumida(s)                  | `ecr-role` → `tf-role`                                      | `tf-role`                                 | `tf-role`                                 |
| O que faz                                 | Testa, versiona, builda, publica no ECR, **e** faz o deploy | `terraform fmt -check` → `plan` → `apply` | `terraform fmt -check` → `plan` → `apply` |
| `terraform apply` passa `-var image_tag`? | Sim — o SHA que acabou de ser publicado                     | N/A (não é essa camada)                   | Não — usa o default `"latest"`            |
| Working directory                         | raiz do repo (steps de Terraform: `iac/service`)            | `iac/infra`                               | `iac/service`                             |

**Por que `ci-app` e `ci-service` aplicam a mesma pasta (`iac/service`)**: existem dois motivos
diferentes que podem exigir atualizar o serviço ECS, e cada um vira um gatilho:

- **Código novo** (`ci-app.yml`) → precisa colocar a imagem nova rodando → `terraform apply -var
image_tag=<sha>`.
- **Definição do serviço mudou direto** (`ci-service.yml` — ex: alguém editou `cpu`/`memory` em
  `iac/service/ecs.tf` sem mudar nenhum código) → reaplica a estrutura, sem trocar a imagem.

Isso só é possível porque decidimos que o **Terraform é o único mecanismo de deploy** do serviço —
nenhuma action externa mexe nele. A alternativa mais comum (usar uma action de deploy dedicada,
tipo `amazon-ecs-deploy-express-service`, por fora do Terraform) evitaria esse acoplamento entre
dois workflows, mas reintroduziria o problema original: duas ferramentas competindo pelo mesmo
recurso, sem se conhecerem — ver o raciocínio completo no
[tutorial de IaC](./iac-terraform-aws.md#-por-que-dividir-em-camadas-com-states-separados-não-só-arquivos-separados).

Separar em pipelines/roles por responsabilidade segue o mesmo raciocínio de menor privilégio do
tutorial de IaC: um bug ou dependência comprometida no pipeline de aplicação não tem, por
construção, permissão pra alterar `iac/infra/` diretamente por conta própria — e mudar um `.tf` de
infra não dispara rebuild/republish da aplicação por engano.

---

## ⚠️ Armadilhas

**🐛 `AssumeRoleWithWebIdentity` nega mesmo com a trust policy "certa"** — desde 15/07/2026, o
GitHub emite o claim `sub` do token OIDC num formato diferente pra repositórios **criados,
renomeados ou transferidos a partir dessa data**: em vez do formato clássico
`repo:OWNER/REPO:ref:refs/heads/BRANCH`, o `sub` passa a incluir os IDs imutáveis de owner e repo —
`repo:OWNER@OWNER_ID/REPO@REPO_ID:ref:refs/heads/BRANCH`. Repos mais antigos continuam no formato
clássico até você optar pelo novo — mas qualquer repo novo, como este (`estudos-ci-cd`, criado em
25/07/2026), já nasce no formato novo. Uma trust policy escrita copiando o formato clássico de um
tutorial nunca bate, e a AWS nega o `AssumeRoleWithWebIdentity` sem apontar o motivo.

Pra pegar os dois IDs **antes** de escrever a trust policy pela primeira vez:

```bash
curl -s https://api.github.com/repos/<owner>/<repo> | jq '{repo_id: .id, owner_id: .owner.id}'
```

Se já tiver uma execução falhando e quiser confirmar o `sub` real que está sendo enviado, um step
temporário decodifica o token (remova depois):

```yaml
- name: Debug OIDC claims
  run: |
    IDTOKEN=$(curl -sSL -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
      "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=sts.amazonaws.com" | jq -r '.value')
    echo "$IDTOKEN" | cut -d. -f2 | base64 -d 2>/dev/null | jq .
```

_(Fonte: [changelog oficial do GitHub sobre immutable subject claims](https://github.blog/changelog/2026-04-23-immutable-subject-claims-for-github-actions-oidc-tokens/).)_

**`ci-service.yml` sem `-var image_tag` pode "voltar" a imagem pra `latest`** — se alguém editar
`iac/service/*.tf` (ex: mudar `cpu`) sem que nenhum código tenha mudado, esse workflow roda
`terraform apply` sem passar `image_tag`, então usa o default (`"latest"`). Na prática isso não
quebra nada — `ci-app.yml` sempre mantém a tag `:latest` apontando pra build mais recente no ECR —
mas o serviço passa a referenciar a imagem pela tag móvel em vez do SHA exato do último deploy. Não
compensa resolver isso agora (exigiria persistir o último SHA usado em algum lugar), mas é bom saber
que existe.

**Build + push manuais em vez de uma action dedicada** — o step de build roda `docker build` e
`docker push` diretamente. Funciona, mas uma action como `docker/build-push-action` (não existe um
equivalente oficial específico pra ECR, mas dá pra compor com `amazon-ecr-login`) cuida de cache de
camadas e evita erros de digitação — considere migrar se o pipeline crescer.

**Este workflow usa `npm install`, não `npm ci`** — o `Dockerfile` do mesmo projeto já usa
`npm ci` (mais estrito e reprodutível). Vale alinhar os dois quando a migração for finalizada.

**Workflow de Terraform sem `working-directory` não encontra os `.tf`** — `terraform init`/`plan`/
`apply` rodam, por padrão, na raiz do checkout — não na pasta da camada. Sem
`defaults.run.working-directory: iac/<camada>` no job (`ci-infra.yml`/`ci-service.yml`) ou
`working-directory:` em cada step (como em `ci-app.yml`, que só aplica Terraform em 2 dos seus
steps, junto com outros que precisam rodar na raiz), os comandos falham por não encontrar nenhum
arquivo `.tf`.

---

## Checklist Para Replicar em Outro Projeto

1. Criar `.github/workflows/<nome>.yml` com o evento que deve disparar o pipeline
   (`on.push.branches`, `on.pull_request`, etc). Restrinja com `on.push.paths` pra não rodar em
   mudanças que não afetam o build (ex: só documentação).
2. Definir a versão do runtime via `env` e usar a action oficial de setup com cache habilitado.
3. Instalar dependências de forma reprodutível (`npm ci`) e rodar a suíte de testes como **gate**
   antes de qualquer publicação.
4. Gerar uma tag rastreável ao commit (SHA curto), em vez de depender só de `latest`.
5. Preferir OIDC a credenciais fixas quando o provedor de nuvem suportar; caso contrário, guardar
   usuário/token como **Secrets** do repositório — nunca hardcoded.
6. Se o deploy também for gerenciado por Terraform (em vez de uma action de deploy dedicada),
   decidir explicitamente: qual pipeline aplica a camada de deploy, com qual `-var`, e o que
   acontece se **outro** pipeline aplicar a mesma camada sem esse `-var` (ver armadilha acima).
7. Um pipeline por responsabilidade (app / infra / camada de deploy), cada um com sua própria role
   OIDC de privilégio mínimo — não uma role/pipeline "faz-tudo".
8. Conferir a execução na aba **Actions** do GitHub e o resultado no destino final (registry, AWS
   console, etc).

---

## 📝 Resumo

| Decisão           | Estado atual deste projeto                                                   | Alternativa comum                                                                      |
| ----------------- | ---------------------------------------------------------------------------- | -------------------------------------------------------------------------------------- |
| Trigger           | push em `master`, filtrado por `paths`, 3 workflows                          | `pull_request`, tags, `workflow_dispatch`                                              |
| Instalar deps     | `npm install` (inconsistente com o Dockerfile)                               | `npm ci`                                                                               |
| Registry          | AWS ECR                                                                      | GitHub Container Registry, GCP Artifact Registry                                       |
| Autenticação      | OIDC via IAM Role, 2 roles diferentes num mesmo job (`ci-app.yml`)           | Secrets fixos (usuário/token)                                                          |
| Estratégia de tag | SHA curto (imagem) + SemVer via semantic-release (release)                   | SemVer só, data, ambos combinados                                                      |
| Deploy            | `terraform apply -var image_tag=<sha>` em `iac/service`, sem action dedicada | Action de deploy dedicada (ex: `amazon-ecs-deploy-express-service`), fora do Terraform |
| Infra como código | 3 pipelines/camadas (`ci-infra`, `ci-service`, mais `bootstrap` manual)      | `terraform apply` local, sem CI, ou 1 pipeline só pra tudo                             |

## Referência

- `.github/workflows/ci-app.yml` — pipeline de aplicação (testa, versiona, builda, publica, deploya)
- `.github/workflows/ci-infra.yml` — aplica `iac/infra/`
- `.github/workflows/ci-service.yml` — aplica `iac/service/` quando a definição do serviço muda
- `iac/bootstrap/`, `iac/infra/`, `iac/service/` — Terraform em camadas (ver
  [tutorial de IaC](./iac-terraform-aws.md))
- `.releaserc.json` — configuração do semantic-release (ver [tutorial dedicado](./semantic-release.md))
- `Dockerfile` — a imagem que este pipeline builda e publica
