# Infraestrutura AWS via Terraform: OIDC, IAM e ECS Express Mode

## 🤔 Por Que Não Criar Isso Tudo Direto no Console da AWS?

Uma role IAM, uma trust policy, um provider OIDC, um repositório ECR — dá pra criar tudo isso
clicando no console da AWS uma vez. O problema aparece depois: ninguém lembra exatamente o que foi
clicado, não há histórico de "por que essa policy tem essa permissão", e reproduzir o mesmo setup
num ambiente novo (ou depois de destruir tudo sem querer) vira arqueologia.

**Terraform** resolve isso descrevendo a infraestrutura como código: cada `resource` no `.tf` é uma
peça da AWS, o estado atual fica registrado (`terraform.tfstate`), e `terraform plan`/`apply` calcula
e aplica só a diferença entre o que existe e o que o código descreve. Este projeto usa isso pra
provisionar a ponte de confiança entre o GitHub Actions e a AWS (OIDC + IAM Roles), o repositório de
imagens (ECR) e onde a aplicação roda (ECS Express Mode).

---

## 🔧 Pré-requisito Manual: Credenciais AWS Para o Primeiro `apply`

Terraform não se autentica na AWS sozinho, e existe um problema de ovo-e-galinha aqui: a Role OIDC
que o GitHub Actions usa pra rodar `terraform apply` (`tf-role`) só existe **depois** que alguém já
tiver rodado `terraform apply` uma primeira vez. Esse primeiro `apply` — e qualquer `apply` manual
feito depois, direto da sua máquina — precisa de credenciais AWS de um usuário/conta real,
configuradas localmente (ex: `aws configure`, com um Access Key ID + Secret Access Key gerados em
**AWS → IAM → Users → seu usuário → Security credentials**). Confirme que está autenticado como
quem deveria antes de aplicar:

```bash
aws sts get-caller-identity
```

Depois que `tf-role` existir, o pipeline (`ci-terraform.yml`) passa a assumi-la via OIDC — nenhuma
credencial de longa duração fica salva como Secret do GitHub pra isso. O único Secret do GitHub que
este projeto usa é `GH_TOKEN`, e é pro semantic-release, não pra AWS — ver o
[tutorial de versionamento](./semantic-release.md#-pr%C3%A9-requisito-manual-criando-e-configurando-o-gh_token).

---

## 🎯 Resposta Rápida

```hcl
# 1. GitHub confia nesse provider pra emitir tokens de identidade
resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
}

# 2. A AWS confia numa role, mas só se o token vier deste repo/branch
resource "aws_iam_role" "ci" {
  name = "ci-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRoleWithWebIdentity"
      Principal = { Federated = aws_iam_openid_connect_provider.github.arn }
      Condition = {
        StringEquals = { "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com" }
        StringLike   = { "token.actions.githubusercontent.com:sub" = "repo:OWNER/REPO:ref:refs/heads/main" }
      }
    }]
  })
}

# 3. A role só pode fazer o que a policy anexada permitir
resource "aws_iam_role_policy_attachment" "ci_ecr" {
  role       = aws_iam_role.ci.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPowerUser"
}
```

Sem credencial de longa duração salva em Secret nenhuma. O GitHub Actions pede um token ao GitHub,
apresenta pra AWS, e a `Condition` da trust policy decide se aceita.

---

## 📚 Cadeia de Confiança: Como o GitHub Vira uma Sessão na AWS

```text
GitHub Actions (job rodando)
   │  pede um token de identidade assinado pelo GitHub
   ▼
Token OIDC (JWT curto, expira em minutos)
   │  claims: iss, aud, sub, repository, ref...
   ▼
aws sts AssumeRoleWithWebIdentity ──────────────► AWS IAM
   │                                                 │
   │                                     ┌───────────┴───────────┐
   │                                     │  aws_iam_openid_      │  1. confia no emissor (iss)?
   │                                     │  connect_provider     │
   │                                     └───────────┬───────────┘
   │                                                 │
   │                                     ┌───────────┴───────────┐
   │                                     │  trust policy da Role │  2. aud/sub batem com a Condition?
   │                                     │  (assume_role_policy) │
   │                                     └───────────┬───────────┘
   │                                                 │ sim
   ▼                                                 ▼
Credenciais temporárias (~1h)  ◄──────────  Role assumida
   │
   ▼
Chamadas à AWS autorizadas pelas policies ANEXADAS à role (não pela trust policy)
```

Duas verificações distintas, fáceis de confundir: a **trust policy** (`assume_role_policy`) decide
_quem_ pode virar a role; as **policies anexadas** decidem _o que_ a role, já assumida, pode fazer.
Errar a primeira barra o login inteiro (`AssumeRoleWithWebIdentity` negado); errar a segunda deixa
logar mas falhar em cada chamada de API específica.

---

## 🔍 Aprofundamento: As Peças do Padrão

### OIDC Provider — por que ele existe

`aws_iam_openid_connect_provider` registra na AWS que ela deve confiar em tokens assinados pelo
emissor `https://token.actions.githubusercontent.com` (o serviço do próprio GitHub que assina
tokens OIDC pra cada execução de workflow). Sem esse resource, não existe `Federated` válido pra
nenhuma trust policy apontar.

Um único provider serve **todos** os repositórios do GitHub — quem restringe qual repo pode assumir
qual role é a `Condition` de cada Role individualmente, não o provider.

### O claim `sub`: o gotcha dos IDs imutáveis

O formato clássico documentado (inclusive pela própria AWS) é:

```text
repo:OWNER/REPO:ref:refs/heads/BRANCH
```

Repositórios criados a partir de **15/07/2026** (mudança anunciada pelo GitHub em 23/04/2026)
recebem um formato diferente, com os IDs imutáveis do owner e do repositório embutidos:

```text
repo:OWNER@OWNER_ID/REPO@REPO_ID:ref:refs/heads/BRANCH
```

É uma proteção contra reaproveitamento de nome: se um repositório for deletado ou renomeado e o
nome antigo for reusado por outra conta, uma trust policy escrita com o formato clássico continuaria
confiando erroneamente nesse "novo dono" do nome. Repos criados antes da mudança continuam no
formato clássico até migrarem — mas para **qualquer repositório novo**, escrever a trust policy
copiando o formato clássico de um tutorial (ou da documentação mais antiga da AWS) resulta numa
`Condition` que nunca bate, e o erro que a AWS devolve não menciona "sub" nem "formato" —
simplesmente nega o `AssumeRoleWithWebIdentity`. Isso está aprofundado, com o passo a passo de
debug, no [tutorial de CI/CD](./ci-cd-github-actions.md#%EF%B8%8F-armadilhas).

### `managed_policy_arns` vs `aws_iam_role_policy_attachment`

O resource `aws_iam_role` tem um argumento `managed_policy_arns` que parece conveniente — anexa as
policies direto dentro do bloco da role:

```hcl
resource "aws_iam_role" "exemplo" {
  name                = "exemplo"
  managed_policy_arns = ["arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"] # ❌ deprecated
}
```

Esse argumento está **deprecated** no provider `hashicorp/aws` — o aviso oficial recomenda o
resource separado `aws_iam_role_policy_attachment` (um resource por policy anexada):

```hcl
resource "aws_iam_role_policy_attachment" "exemplo" {
  role       = aws_iam_role.exemplo.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}
```

A vantagem prática de separar: cada anexo vira um resource independente no state, então
adicionar/remover uma policy não força recriar a role inteira, e dá pra ver no `plan` exatamente
qual anexo mudou. Existe ainda um terceiro resource, `aws_iam_role_policy_attachments_exclusive`,
para quando você quer que o Terraform seja a _única_ fonte de verdade dos anexos de uma role
(remove qualquer anexo feito fora do Terraform) — não usado neste projeto, mas vale saber que existe.

### App Runner → ECS Express Mode

O AWS App Runner (serviço "cole a imagem e ele cuida do resto") entrou em modo de manutenção em
31/03/2026 e parou de aceitar novos clientes em 30/04/2026. A AWS recomenda oficialmente o **Amazon
ECS Express Mode** (lançado no re:Invent, novembro/2025) como substituto: ele entrega a mesma
simplicidade de "só preciso rodar uma imagem" — provisiona sozinho load balancer, security groups,
auto scaling e logging — mas usando ECS/Fargate por baixo, com acesso ao ecossistema ECS completo
se um dia você precisar sair do modo simplificado.

A diferença que mais aparece no Terraform: App Runner usava **uma única role** de serviço; ECS
Express Mode separa em **duas**, com principals de confiança diferentes:

| Role                | Quem assume (`Principal.Service`) | Pra quê                                                                                 | Managed policy                                         |
| ------------------- | --------------------------------- | --------------------------------------------------------------------------------------- | ------------------------------------------------------ |
| Execution role      | `ecs-tasks.amazonaws.com`         | Puxar a imagem do ECR, mandar logs pro CloudWatch                                       | `AmazonECSTaskExecutionRolePolicy`                     |
| Infrastructure role | `ecs.amazonaws.com`               | Criar/gerenciar load balancer, target groups, security groups, auto scaling em seu nome | `AmazonECSInfrastructureRoleforExpressGatewayServices` |

O resource Terraform correspondente é o `aws_ecs_express_gateway_service` (suportado desde a
v6.23.0 do provider `hashicorp/aws`):

```hcl
resource "aws_ecs_express_gateway_service" "example" {
  execution_role_arn      = aws_iam_role.execution.arn
  infrastructure_role_arn = aws_iam_role.infrastructure.arn

  primary_container {
    image          = "my-app:latest"
    container_port = 8080
  }
}
```

`infrastructure_role_arn` não pode ser alterado depois de criado — mudar esse valor força recriar o
service inteiro (`ForceNew`), então vale acertar a role certa antes do primeiro `apply`.

### Organização dos arquivos `.tf`: convenção por domínio

Um único `iam.tf` gigante misturando OIDC, roles, policies e (sem querer) o serviço em si fica
difícil de navegar depois de algumas iterações. A convenção usada aqui é separar por **domínio de
responsabilidade**, não por tipo de sintaxe:

| Arquivo           | Responsabilidade                                                                                                    |
| ----------------- | ------------------------------------------------------------------------------------------------------------------- |
| `main.tf`         | `terraform {}` (versão do provider) + bloco `provider "aws"`                                                        |
| `oidc.tf`         | O provider OIDC (a "porta de entrada" da confiança)                                                                 |
| `iam.tf`          | Só as roles (`aws_iam_role`) — **quem** pode assumir o quê                                                          |
| `iam-policies.tf` | Policies inline e anexos (`aws_iam_role_policy`, `aws_iam_role_policy_attachment`) — **o que** cada role pode fazer |
| `ecr.tf`          | Repositório de imagens                                                                                              |
| `ecs.tf`          | O serviço rodando de fato (log group + `aws_ecs_express_gateway_service`)                                           |
| `variables.tf`    | Inputs parametrizáveis (ex: tag da imagem)                                                                          |
| `outputs.tf`      | Valores úteis pós-`apply` (ex: endpoint público gerado)                                                             |

Terraform não exige nenhuma dessas separações — ele lê todos os `.tf` de um diretório como se
fossem um arquivo só. A divisão é puramente pra navegação humana; o critério "separar `iam.tf` de
`iam-policies.tf`" espelha de propósito a distinção Role vs Policy: quem abre o arquivo errado
percebe na hora que está no lugar errado.

---

## 🆚 App Runner vs ECS Express Mode

| Aspecto                                      | AWS App Runner                                       | Amazon ECS Express Mode                                                                       |
| -------------------------------------------- | ---------------------------------------------------- | --------------------------------------------------------------------------------------------- |
| Status (2026)                                | Modo manutenção, sem novos clientes desde 30/04/2026 | Recomendado pela AWS, em desenvolvimento ativo                                                |
| Roles necessárias                            | 1 (role de acesso/build)                             | 2 (execution + infrastructure)                                                                |
| Resource Terraform                           | `aws_apprunner_service`                              | `aws_ecs_express_gateway_service`                                                             |
| Configuração mínima                          | Imagem + role                                        | Imagem + execution role + infrastructure role                                                 |
| Acesso ao ECS "completo" se precisar crescer | ❌ não, é outro serviço                              | ✅ sim, é ECS por baixo                                                                       |
| Complexidade percebida                       | Menor (abstrai quase tudo)                           | Um pouco maior (duas roles, dois principals), mas ainda muito mais simples que ECS "clássico" |

---

## ✅ Faça / ❌ Não Faça

**✅ Buscar os IDs imutáveis do repo antes de escrever a trust policy pela primeira vez:**

```bash
curl -s https://api.github.com/repos/OWNER/REPO | jq '{repo_id: .id, owner_id: .owner.id}'
```

**❌ Copiar o formato clássico `repo:OWNER/REPO:ref:...` de um tutorial sem verificar:**

```hcl
"StringLike": { "token.actions.githubusercontent.com:sub": ["repo:OWNER/REPO:ref:refs/heads/main"] } # ❌ pode nunca bater em repo novo
```

**✅ Uma role dedicada por responsabilidade de CI (ex: uma pra gerenciar infra, outra pra publicar app):**

```hcl
resource "aws_iam_role" "tf-role"  { ... } # gerencia o próprio Terraform state/infra
resource "aws_iam_role" "ecr-role" { ... } # builda/publica/faz deploy da aplicação
```

**❌ Uma única role "faz-tudo" compartilhada entre pipelines diferentes:**

```hcl
resource "aws_iam_role" "role-unica-pra-tudo" { ... } # ❌ CI de app ganha permissão de mexer no state do Terraform, e vice-versa
```

Roles separadas por responsabilidade limitam o raio de dano: se o pipeline de app for
comprometido, ele não tem como também alterar/destruir infraestrutura.

**✅ `aws_iam_role_policy_attachment` pra anexar managed policy:**

```hcl
resource "aws_iam_role_policy_attachment" "exec" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}
```

**❌ `managed_policy_arns` dentro do `aws_iam_role` (deprecated):**

```hcl
resource "aws_iam_role" "execution" {
  managed_policy_arns = ["arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"] # ❌
}
```

---

## 🎯 Exemplo do Projeto

Estrutura real em `iac/` (region `sa-east-1`, conta `958157975241`):

```text
iac/
├── main.tf              # terraform {} + provider "aws"
├── oidc.tf               # aws_iam_openid_connect_provider.oidc-git
├── iam.tf                 # 4 roles: tf-role, ecr-role, ecs-execution-role, ecs-express-infrastructure-role
├── iam-policies.tf        # policy inline da ecr-role + attachments das roles de execução/infra
├── ecr.tf                  # aws_ecr_repository.estudos-ci-cd
├── ecs.tf                   # log group + aws_ecs_express_gateway_service.api
├── variables.tf             # var.image_tag (default "latest")
└── outputs.tf                # output do endpoint público (ingress_paths)
```

Duas roles OIDC, cada uma com sua própria `Condition` restrita a este repositório e à branch
`master` (`iac/iam.tf`), mas usadas por pipelines diferentes:

```hcl
resource "aws_iam_role" "tf-role" {
  name        = "tf-role"
  description = "IAM role for GitHub Actions to access Terraform state"
  # assume_role_policy: mesma Condition de sub/aud, usada pelo .github/workflows/ci-terraform.yml
}

resource "aws_iam_role" "ecr-role" {
  name        = "ecr-role"
  description = "IAM role for GitHub Actions to access ECR"
  # assume_role_policy: mesma Condition, usada pelo .github/workflows/ci.yml
}
```

O serviço rodando de fato (`iac/ecs.tf`), com a imagem publicada no ECR e as duas roles do ECS Express:

```hcl
resource "aws_ecs_express_gateway_service" "api" {
  service_name             = "estudos-ci-cd"
  execution_role_arn       = aws_iam_role.ecs-execution-role.arn
  infrastructure_role_arn  = aws_iam_role.ecs-express-infrastructure-role.arn
  cpu                      = "256"
  memory                   = "512"

  primary_container {
    image          = "${aws_ecr_repository.estudos-ci-cd.repository_url}:${var.image_tag}"
    container_port = 3000

    aws_logs_configuration {
      log_group         = aws_cloudwatch_log_group.api.name
      log_stream_prefix = "ecs"
    }
  }
}
```

`container_port = 3000` porque é a porta que `src/main.ts` usa em `app.listen(3000)`. `cpu`/`memory`
no menor tier do Fargate (256/512) — suficiente para uma API de estudo, e mais barato que o default
do resource (1024/2048). `network_configuration` foi deixado de fora de propósito: sem ele, o
Express Mode provisiona a rede sozinho na VPC default — é o que mantém a promessa de simplicidade
do App Runner.

A `ecr-role` (usada pelo pipeline de app, não pelo de infra) precisa de permissão pra **chamar** a
API do ECS Express — isso não vem de nenhuma policy gerenciada da AWS, é uma policy inline em
`iam-policies.tf`:

```hcl
Action = [
  "ecs:CreateCluster",
  "ecs:RegisterTaskDefinition",
  "ecs:CreateExpressGatewayService",
  "ecs:UpdateExpressGatewayService",
  "ecs:DescribeExpressGatewayService",
  # ...
]
```

Essa lista veio direto dos requisitos documentados da action `aws-actions/amazon-ecs-deploy-express-service`,
usada no `.github/workflows/ci.yml` (ver [tutorial de CI/CD](./ci-cd-github-actions.md)) — sem essas
permissões, o step de deploy do pipeline de app falharia com `AccessDenied`, mesmo com o
`AssumeRoleWithWebIdentity` funcionando perfeitamente (é a mesma distinção do diagrama acima: passar
na trust policy não garante passar nas policies anexadas).

### 🔍 Onde Ver o Estado Aplicado

- **AWS → IAM → Roles**: as 4 roles e suas trust policies/anexos.
- **AWS → ECS → Clusters → Services**: o serviço Express Mode rodando, com o endpoint público.
- **`terraform output`** no diretório `iac/`: mostra `api_ingress_paths` depois de um `apply`.

---

## ⚠️ Armadilhas

**🐛 `apply` falha com `missing required field ... LogStreamPrefix`** — o bloco
`aws_logs_configuration` dentro de `primary_container` tem `log_group` opcional na documentação do
provider, mas a própria API do ECS exige `log_stream_prefix` (usado como prefixo dos nomes dos
log streams dentro do log group). Sem ele, o `apply` chega a tentar criar o serviço na AWS e falha
só nesse momento — `terraform validate` não pega, porque sintaticamente o HCL está correto:

```hcl
aws_logs_configuration {
  log_group         = aws_cloudwatch_log_group.api.name
  log_stream_prefix = "ecs" # obrigatório pra a API, mesmo — qualquer string serve
}
```

**A conta AWS é literal, não uma referência** — os ARNs neste projeto têm a conta
(`958157975241`) escrita diretamente nas strings (`arn:aws:iam::958157975241:role/...`), tanto no
Terraform quanto nos workflows do GitHub Actions. Funciona, mas duplica o número em vários lugares;
numa infraestrutura maior, isso normalmente vira um `data "aws_caller_identity" "current"` e
`"arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/..."`, ou uma variable — evita
digitar (ou errar) o account ID toda vez que uma role nova é criada.

**`infrastructure_role_arn` força recriação se mudar** — como o próprio resource documenta, trocar
essa role depois do serviço já existir recria o `aws_ecs_express_gateway_service` inteiro (não é um
update in-place). Vale garantir que a role certa está lá antes do primeiro `apply` em produção.

**State local, não remoto** — este projeto usa o `terraform.tfstate` local (não versionado no git,
nem backend S3/DynamoDB configurado). Funciona para um projeto de estudo rodado por uma pessoa só,
mas um `terraform apply` disparado pela pipeline (`ci-terraform.yml`) a partir de um runner efêmero
do GitHub Actions, sem backend remoto, não tem de onde ler o estado anterior a cada execução — é um
ponto que normalmente precisa de atenção antes de depender disso em produção.

---

## Checklist Para Replicar em Outro Projeto

1. Criar o `aws_iam_openid_connect_provider` apontando pro emissor OIDC do seu provedor de CI
   (`token.actions.githubusercontent.com` pro GitHub Actions; cada CI tem o seu).
2. Antes de escrever qualquer trust policy, confirmar o formato exato do claim `sub` que o seu CI
   emite hoje — não copiar de um tutorial sem checar (ver seção do gotcha acima).
3. Criar uma role por responsabilidade/pipeline (não uma role compartilhada), cada uma com sua
   `Condition` restrita ao repositório/branch que deveria poder assumi-la.
4. Anexar permissões via resource dedicado (`aws_iam_role_policy_attachment` para managed policies,
   `aws_iam_role_policy` para inline) — nunca via argumento deprecated dentro do `aws_iam_role`.
5. Se for rodar containers, escolher o serviço de compute pelo nível de abstração que você
   realmente precisa (App Runner/ECS Express Mode para "só rodar uma imagem"; ECS/EKS "clássico"
   quando precisar de controle fino).
6. Separar os `.tf` por domínio de responsabilidade assim que o arquivo começar a ficar difícil de
   escanear — não é obrigatório do dia 1, mas vale migrar antes de virar um arquivo de centenas de
   linhas.
7. Rodar `terraform fmt` e `terraform validate` antes de cada `apply`.

---

## 📝 Resumo

| Decisão                      | Estado atual deste projeto                               | Alternativa comum                                      |
| ---------------------------- | -------------------------------------------------------- | ------------------------------------------------------ |
| Autenticação do CI com a AWS | OIDC (`aws_iam_openid_connect_provider` + roles)         | Access key/secret key fixos em Secrets                 |
| Compute pra rodar a API      | Amazon ECS Express Mode                                  | ECS/Fargate "clássico", EKS, App Runner (deprecated)   |
| Anexo de managed policy      | `aws_iam_role_policy_attachment`                         | `managed_policy_arns` (deprecated)                     |
| Organização dos `.tf`        | Um arquivo por domínio (`iam.tf`, `ecr.tf`, `ecs.tf`...) | Um `main.tf` único, ou módulos Terraform reutilizáveis |
| Backend do state             | Local                                                    | S3 + DynamoDB (lock remoto)                            |

## Referência

- `iac/main.tf`, `iac/oidc.tf`, `iac/iam.tf`, `iac/iam-policies.tf`, `iac/ecr.tf`, `iac/ecs.tf`,
  `iac/variables.tf`, `iac/outputs.tf`
- `.github/workflows/ci-terraform.yml` — pipeline que aplica esta infraestrutura
- [Tutorial de CI/CD com GitHub Actions](./ci-cd-github-actions.md) — como as roles daqui são
  consumidas pelos workflows, e o mergulho completo no gotcha do claim `sub`
