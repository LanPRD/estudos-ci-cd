# Infraestrutura AWS via Terraform em Camadas: Bootstrap, OIDC/IAM e ECS Express Mode

## 🤔 Por Que Não Só Um `iac/` Com Tudo Dentro?

Uma role IAM, um provider OIDC, um repositório ECR, um serviço ECS — dá pra descrever tudo isso
num único diretório Terraform, com um `terraform.tfstate` só. Funciona até o projeto crescer um
pouco: qualquer `apply` passa a recalcular o plano do projeto inteiro (lento, e arriscado — um erro
de sintaxe num arquivo de infraestrutura que muda uma vez por ano pode travar o deploy de um código
que muda toda hora), e existe um problema de ovo-e-galinha real: o bucket S3 que guarda o
`tfstate` remoto não pode ser criado pelo mesmo Terraform que o usa como backend — ele precisaria
existir antes de existir.

Este tutorial documenta o padrão que resolve os dois problemas: dividir a infraestrutura em
**camadas** (`bootstrap` / `infra` / `service`), cada uma com seu próprio state, agrupadas por
**frequência de mudança** — não por tipo de recurso — e aplicadas por processos diferentes
(manual vs CI). Cobre também OIDC + IAM Roles (a ponte de confiança GitHub Actions ↔ AWS) e o
Amazon ECS Express Mode (onde a aplicação roda).

---

## 🎯 Resposta Rápida

```hcl
# 1. GitHub confia nesse provider pra emitir tokens de identidade
resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
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

Isso vale pra **uma** camada. A pergunta "onde esse `resource` deveria morar — bootstrap, infra ou
service?" é o assunto central deste tutorial, coberto no diagrama e no aprofundamento abaixo.

---

## 📚 As 3 Camadas: Dependência e Quem Aplica Cada Uma

```text
┌─────────────────────────────────────────────────────────────────────┐
│ bootstrap/  (state LOCAL — aplicado manualmente, na sua máquina)    │
│                                                                     │
│   • bucket S3 (guarda o state de infra/ e service/)                 │
│   • OIDC provider                                                   │
│   • tf-role, ecr-role  (as roles que a CI vai assumir)              │
└────────────────────────────────┬────────────────────────────────────┘
                                 │ agora existe bucket + role pra CI autenticar
                                 ▼
┌─────────────────────────────────────────────────────────────────────┐
│ infra/  (state remoto no S3 — aplicado pela CI, assumindo tf-role)  │
│                                                                     │
│   • repositório ECR                                                 │
│   • log group do CloudWatch                                         │
│   • ecs-execution-role, ecs-express-infrastructure-role             │
└────────────────────────────────┬────────────────────────────────────┘
                                 │ agora existem os recursos que o serviço referencia
                                 ▼
┌─────────────────────────────────────────────────────────────────────┐
│ service/  (state remoto no S3 — aplicado pela CI, assumindo tf-role)│
│                                                                     │
│   • o serviço ECS Express em si (a imagem que roda de fato)         │
└─────────────────────────────────────────────────────────────────────┘
```

A ordem **importa** e é uma dependência real, não só organização: `service/` faz `data` lookups
por nome nos recursos de `infra/` (ver seção própria abaixo) — se `infra/` nunca foi aplicada, esses
lookups falham com "not found". E nada em `infra/`/`service/` funciona antes de `bootstrap/` existir,
porque é de lá que vem o bucket do backend e a role que a CI assume.

**Critério de divisão: frequência de mudança, não tipo de recurso.** `bootstrap` quase nunca muda
(só se você trocar de conta AWS ou girar credenciais); `infra` muda ocasionalmente (nova permissão,
novo repositório); `service` muda a **cada deploy de aplicação**. Misturar os três num state só
significa que um `terraform plan` de rotina (novo deploy) recalcula recursos que não têm nada a ver
com o que mudou.

---

## 🔧 Pré-requisito Manual: `bootstrap/` Nunca Roda na CI

Existe um problema de ovo-e-galinha, e ele é o motivo de `bootstrap/` existir separado: a role que
o GitHub Actions assume pra rodar Terraform (`tf-role`) só existe **depois** de alguém já ter rodado
`terraform apply` em `bootstrap/`. Esse `apply` — e qualquer outro feito depois nessa mesma camada —
precisa de credenciais AWS de um usuário real, configuradas localmente (`aws configure`, com
Access Key ID + Secret Access Key de **AWS → IAM → Users → seu usuário → Security credentials**):

```bash
aws sts get-caller-identity   # confirma que você está autenticado como quem deveria
cd iac/bootstrap
terraform init      # sem backend "s3" — state fica local, de propósito (ver seção abaixo)
terraform apply
```

Depois que `tf-role`/`ecr-role` existem, `infra/` e `service/` passam a ser aplicadas pela CI via
OIDC — nenhuma credencial de longa duração fica salva como Secret do GitHub pra isso. O único
Secret AWS que este projeto usa é zero: o `GH_TOKEN` que existe é do semantic-release, não da AWS —
ver o [tutorial de versionamento](./semantic-release.md#-pr%C3%A9-requisito-manual-criando-e-configurando-o-gh_token).

**`bootstrap/main.tf` não tem `backend "s3"` de propósito** — é exatamente essa camada quem _cria_
o bucket. Se ela tentasse guardar o próprio state dentro do bucket que ela mesma está criando,
seria o mesmo ciclo impossível de resolver (o bucket precisa existir antes do `init`, mas só existe
depois do `apply`). Por isso o state de `bootstrap/` fica **local** — um arquivo `.tfstate` que só
existe em quem rodou o `apply`, coberto pelo `.gitignore`. Consequência prática: não perca esse
arquivo (ver ⚠️ abaixo).

---

## 🔍 Aprofundamento: As Peças do Padrão

### OIDC Provider — por que ele existe

`aws_iam_openid_connect_provider` registra na AWS que ela deve confiar em tokens assinados pelo
emissor `https://token.actions.githubusercontent.com` (o serviço do próprio GitHub que assina
tokens OIDC pra cada execução de workflow). Sem esse resource, não existe `Federated` válido pra
nenhuma trust policy apontar. Um único provider serve **todos** os repositórios do GitHub — quem
restringe qual repo pode assumir qual role é a `Condition` de cada Role individualmente.

### A cadeia de confiança, passo a passo

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
logar mas falhar em cada chamada de API específica — é exatamente o que teria acontecido aqui se
`tf-role` tivesse ficado sem nenhuma policy anexada (ver ⚠️ abaixo).

### O claim `sub`: o gotcha dos IDs imutáveis

O formato clássico documentado (inclusive pela própria AWS) é `repo:OWNER/REPO:ref:refs/heads/BRANCH`.
Repositórios criados a partir de **15/07/2026** (mudança anunciada pelo GitHub em 23/04/2026)
recebem um formato diferente, com os IDs imutáveis do owner e do repositório embutidos:
`repo:OWNER@OWNER_ID/REPO@REPO_ID:ref:refs/heads/BRANCH`. É proteção contra reaproveitamento de
nome (repo deletado/renomeado e o nome antigo reusado por outra conta não herda a confiança). Para
qualquer repositório novo, copiar o formato clássico de um tutorial resulta numa `Condition` que
nunca bate — e o erro não menciona "sub" nem "formato", só nega o `AssumeRoleWithWebIdentity`.
Aprofundado, com passo a passo de debug, no
[tutorial de CI/CD](./ci-cd-github-actions.md#%EF%B8%8F-armadilhas).

### `managed_policy_arns` vs `aws_iam_role_policy_attachment`

O argumento `managed_policy_arns` dentro de `aws_iam_role` é **deprecated** no provider
`hashicorp/aws`. Use o resource separado:

```hcl
resource "aws_iam_role_policy_attachment" "exemplo" {
  role       = aws_iam_role.exemplo.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}
```

Vantagem prática: cada anexo vira um resource independente no state, então adicionar/remover uma
policy não força recriar a role inteira, e o `plan` mostra exatamente qual anexo mudou.

### App Runner → ECS Express Mode

AWS App Runner entrou em modo de manutenção em 31/03/2026 e parou de aceitar novos clientes em
30/04/2026. A AWS recomenda oficialmente o **Amazon ECS Express Mode** (re:Invent, novembro/2025)
como substituto: mesma simplicidade de "só preciso rodar uma imagem" (provisiona sozinho load
balancer, security groups, auto scaling, logging), mas usando ECS/Fargate por baixo. A diferença
que mais aparece no Terraform: App Runner usava uma role de serviço; ECS Express Mode separa em
**duas**, com principals diferentes:

| Role                | Quem assume (`Principal.Service`) | Pra quê                                                                                 | Managed policy                                         |
| ------------------- | --------------------------------- | --------------------------------------------------------------------------------------- | ------------------------------------------------------ |
| Execution role      | `ecs-tasks.amazonaws.com`         | Puxar a imagem do ECR, mandar logs pro CloudWatch                                       | `AmazonECSTaskExecutionRolePolicy`                     |
| Infrastructure role | `ecs.amazonaws.com`               | Criar/gerenciar load balancer, target groups, security groups, auto scaling em seu nome | `AmazonECSInfrastructureRoleforExpressGatewayServices` |

`infrastructure_role_arn` não pode ser trocado depois de criado — muda-lo força recriar o serviço
inteiro (`ForceNew`).

### Por que dividir em camadas com states separados (não só arquivos separados)

Separar `.tf` em arquivos por domínio (`iam.tf`, `ecr.tf`...) já ajuda a navegação humana, mas
Terraform lê **todos** os `.tf` de um diretório como um arquivo só — não isola nada de verdade.
Quem isola é ter **um diretório = um `terraform {}` = um backend = um state** por camada. Os
ganhos práticos:

- **Raio de impacto contido**: um erro/`destroy` acidental em `service/` não consegue tocar em nada
  de `infra/` ou `bootstrap/` — eles nem aparecem no state daquele comando.
- **`plan`/`apply` rápidos e focados**: mudar `cpu`/`memory` do serviço não recalcula se o
  repositório ECR ou as roles do bootstrap ainda batem com o código — Terraform nem olha pra eles.
- **Permissão da role de CI pode ser mais granular**: nada te impede de dar à `tf-role` menos
  acesso pra aplicar `service/` do que pra aplicar `infra/`, se algum dia isso importar (este
  projeto usa a mesma role/policy pras duas por simplicidade — ver Resumo).

### Como as camadas se comunicam: `data` sources, não `terraform_remote_state`

O jeito "óbvio" de uma camada ler o output de outra é `terraform_remote_state` — um `data` source
que lê o arquivo `.tfstate` de outra configuração. Aqui isso **não funciona pra referenciar
`bootstrap/`**: o state dela é local, só existe na máquina de quem aplicou, e a CI (que aplica
`infra/`/`service/`) não tem acesso a esse arquivo.

A alternativa usada: `data` sources que consultam a **API da AWS diretamente por nome**, em vez de
ler o state de ninguém:

```hcl
# iac/service/data.tf
data "aws_iam_role" "ecs-execution-role" {
  name = "ecs-execution-role"          # criado em infra/, mas consultado aqui por nome
}

data "aws_ecr_repository" "estudos-ci-cd" {
  name = "estudos-ci-cd"               # idem
}
```

```hcl
# iac/service/ecs.tf
resource "aws_ecs_express_gateway_service" "api" {
  execution_role_arn = data.aws_iam_role.ecs-execution-role.arn        # não resource.arn — data.arn
  # ...
  primary_container {
    image = "${data.aws_ecr_repository.estudos-ci-cd.repository_url}:${var.image_tag}"
  }
}
```

Isso funciona pra **qualquer** recurso da AWS com um `data` source correspondente (roles, buckets,
repositórios, VPCs, subnets...), não só pros exemplos acima. Repetido no Resumo comparativo abaixo.

---

## 🆚 Tabelas Comparativas

**State único vs State em camadas**

| Aspecto                      | State único (`iac/` com tudo)               | State em camadas (`bootstrap`/`infra`/`service`)                       |
| ---------------------------- | ------------------------------------------- | ---------------------------------------------------------------------- |
| Raio de impacto de um erro   | Todo o projeto                              | Só a camada onde o comando rodou                                       |
| Velocidade de `plan`/`apply` | Recalcula tudo sempre                       | Só a camada tocada                                                     |
| Complexidade pra montar      | Menor — 1 diretório, 1 backend              | Maior — N diretórios, backends e ordem de apply                        |
| Bootstrap do backend remoto  | Problema de ovo-e-galinha sem solução limpa | Resolvido: camada dedicada com state local                             |
| Quando faz sentido           | Projeto pequeno, poucos recursos, 1 pessoa  | Recursos com frequência de mudança muito diferente, ou CI real no meio |

**`data` source vs `terraform_remote_state` pra referenciar outra camada**

| Aspecto                                  | `data` source (consulta a AWS por nome)             | `terraform_remote_state` (lê o `.tfstate` de outra config)       |
| ---------------------------------------- | --------------------------------------------------- | ---------------------------------------------------------------- |
| O que precisa existir                    | Só o recurso já criado na AWS, com nome conhecido   | Acesso de leitura ao backend do state da outra camada            |
| Funciona com state local em outra camada | ✅ sim — não lê state nenhum                        | ❌ não, se quem consulta não tem acesso ao arquivo/backend       |
| Acoplamento entre camadas                | Fraco — só precisa saber o nome do recurso          | Mais forte — precisa saber backend, bucket, key da outra camada  |
| Exposição de dados                       | Só os atributos daquele recurso específico          | Potencialmente o state inteiro da outra camada (via outputs)     |
| Quando usar                              | Cross-camada, camadas com donos/backends diferentes | Mesma pessoa/pipeline controla as duas pontas, backend acessível |

**App Runner vs ECS Express Mode**

| Aspecto                                      | AWS App Runner                                       | Amazon ECS Express Mode                        |
| -------------------------------------------- | ---------------------------------------------------- | ---------------------------------------------- |
| Status (2026)                                | Modo manutenção, sem novos clientes desde 30/04/2026 | Recomendado pela AWS, em desenvolvimento ativo |
| Roles necessárias                            | 1 (role de acesso/build)                             | 2 (execution + infrastructure)                 |
| Resource Terraform                           | `aws_apprunner_service`                              | `aws_ecs_express_gateway_service`              |
| Acesso ao ECS "completo" se precisar crescer | ❌ não, é outro serviço                              | ✅ sim, é ECS por baixo                        |

---

## ✅ Faça / ❌ Não Faça

**✅ Camada de bootstrap com state local, aplicada manualmente:**

```hcl
# bootstrap/main.tf — SEM backend "s3"
terraform {
  required_providers { aws = { source = "hashicorp/aws", version = "6.56.0" } }
}
```

**❌ O mesmo Terraform gerenciando o bucket que ele usa como backend:**

```hcl
terraform {
  backend "s3" { bucket = "meu-bucket" }   # ❌ precisa existir antes do init...
}
resource "aws_s3_bucket" "este_mesmo" {    # ❌ ...mas só existe depois do apply
  bucket = "meu-bucket"
}
```

**✅ `data` source pra referenciar recurso de outra camada:**

```hcl
data "aws_ecr_repository" "app" { name = "estudos-ci-cd" }
```

**❌ `terraform_remote_state` apontando pra um backend que a CI não alcança:**

```hcl
data "terraform_remote_state" "bootstrap" {
  backend = "local"
  config  = { path = "../bootstrap/terraform.tfstate" }  # ❌ esse arquivo só existe na sua máquina
}
```

**✅ Uma role dedicada por responsabilidade de CI:**

```hcl
resource "aws_iam_role" "tf-role"  { ... } # aplica infra/ e service/ via Terraform
resource "aws_iam_role" "ecr-role" { ... } # builda/publica a imagem da app
```

**❌ Uma única role "faz-tudo" compartilhada entre pipelines diferentes:**

```hcl
resource "aws_iam_role" "role-unica-pra-tudo" { ... } # ❌ CI de app ganha permissão de infra, e vice-versa
```

---

## 🎯 Exemplo do Projeto

Estrutura real (region `sa-east-1`, conta `958157975241`):

```text
iac/
├── destroy.sh              # destrói as 3 camadas na ordem correta (service → infra → bootstrap)
├── bootstrap/               # state LOCAL — terraform apply manual
│   ├── main.tf                # terraform {} + provider, sem backend
│   ├── state.tf                # aws_s3_bucket + aws_s3_bucket_versioning (o backend de infra/service)
│   ├── oidc.tf                  # aws_iam_openid_connect_provider
│   ├── iam.tf                    # tf-role, ecr-role (só as que a CI assume)
│   ├── iam-policies.tf            # tf-role-permission, ecr-role-permission
│   └── outputs.tf                  # ARNs das roles + nome do bucket (referência)
├── infra/                   # state remoto (state/infra/terraform.tfstate) — aplicado pela CI
│   ├── main.tf
│   ├── ecr.tf                 # aws_ecr_repository (com force_delete = true)
│   ├── logs.tf                 # aws_cloudwatch_log_group
│   ├── iam.tf                   # ecs-execution-role, ecs-express-infrastructure-role
│   └── iam-policies.tf           # os attachments dessas 2 roles
└── service/                 # state remoto (state/service/terraform.tfstate) — aplicado pela CI
    ├── main.tf
    ├── variables.tf            # var.image_tag (default "latest")
    ├── data.tf                  # lookups em infra/ e bootstrap/ por nome
    ├── ecs.tf                    # aws_ecs_express_gateway_service.api
    └── outputs.tf                  # api_ingress_paths
```

**Por que `ecs-execution-role`/`ecs-express-infrastructure-role` estão em `infra/`, não em
`bootstrap/`**: só `tf-role`/`ecr-role` sofrem do problema de ovo-e-galinha (a CI precisa delas pra
existir antes de rodar qualquer coisa). As duas roles do ECS são assumidas por **serviços da AWS**
em runtime (`ecs-tasks.amazonaws.com`, `ecs.amazonaws.com`), não pela CI — uma vez que `tf-role`
existe, a CI cria essas duas normalmente, sem ciclo nenhum.

`tf-role-permission` (`bootstrap/iam-policies.tf`) precisa cobrir **tudo** que `infra/` e
`service/` vão pedir pra criar, porque é a mesma role usada nas duas camadas:

```hcl
resource "aws_iam_role_policy" "tf-role-permission" {
  role = aws_iam_role.tf-role.name
  policy = jsonencode({
    Statement = [
      { Sid = "TerraformState", Action = ["s3:GetObject", "s3:PutObject", "s3:ListBucket", ...] },
      { Sid = "IamManagement", Action = ["iam:CreateRole", "iam:GetRole", ...] },      # GetRole = usado pelos data sources
      { Sid = "EcrRepository", Action = ["ecr:CreateRepository", ...] },
      { Sid = "CloudWatchLogs", Action = ["logs:CreateLogGroup", ...] },               # cria o log group — não escreve nele
      { Sid = "EcsExpressService", Action = ["ecs:CreateExpressGatewayService", ...] },
      { Sid = "PassRoleAndServiceLinked", Action = ["iam:PassRole", "iam:CreateServiceLinkedRole"] },
    ]
  })
}
```

O serviço em si (`iac/service/ecs.tf`), consultando as outras camadas via `data`:

```hcl
resource "aws_ecs_express_gateway_service" "api" {
  service_name            = "estudos-ci-cd"
  execution_role_arn      = data.aws_iam_role.ecs-execution-role.arn
  infrastructure_role_arn = data.aws_iam_role.ecs-express-infrastructure-role.arn
  cpu                      = "256"
  memory                    = "512"

  primary_container {
    image          = "${data.aws_ecr_repository.estudos-ci-cd.repository_url}:${var.image_tag}"
    container_port = 3000

    aws_logs_configuration {
      log_group         = data.aws_cloudwatch_log_group.api.name
      log_stream_prefix = "ecs"
    }
  }
}
```

`container_port = 3000` porque é a porta que `src/main.ts` usa em `app.listen(3000)`. `var.image_tag`
recebe o SHA do commit a cada deploy — ver o [tutorial de CI/CD](./ci-cd-github-actions.md) pra como
isso é passado (`-var="image_tag=..."`) e por que **dois** workflows diferentes aplicam essa mesma
camada.

### 🔍 Onde Ver o Estado Aplicado

- **AWS → IAM → Roles**: as 4 roles e suas trust policies/anexos.
- **AWS → ECS → Clusters → Services**: o serviço Express Mode rodando, com o endpoint público.
- **`terraform output`** em `iac/service/`: mostra `api_ingress_paths` depois de um `apply`.
- **`terraform output`** em `iac/bootstrap/`: mostra os ARNs das roles e o nome do bucket.

---

## ⚠️ Armadilhas

**🐛 `apply` falha com `missing required field ... LogStreamPrefix`** — o bloco
`aws_logs_configuration` dentro de `primary_container` tem `log_group` opcional na documentação do
provider, mas a própria API do ECS exige `log_stream_prefix`. `terraform validate` não pega, porque
sintaticamente o HCL está correto — só falha no `apply`, contra a API real:

```hcl
aws_logs_configuration {
  log_group         = data.aws_cloudwatch_log_group.api.name
  log_stream_prefix = "ecs" # obrigatório pra API, mesmo — qualquer string serve
}
```

**Rodar `service/` antes de `infra/` existir dá erro de "not found" nos `data` sources** — diferente
de um `resource` (que cria o que falta), um `data` source **exige que o recurso já exista**. Se você
aplicar `service/` antes de `infra/` ter rodado (ex: numa conta nova, do zero), o `plan` já falha
tentando resolver `data.aws_iam_role.ecs-execution-role`. A ordem bootstrap → infra → service não é
sugestão, é obrigatória na primeira vez.

**`prevent_destroy = true` no bucket de state bloqueia o `destroy` de `bootstrap/`** — de propósito
(é uma rede de segurança contra apagar o state sem querer), mas significa que `terraform destroy`
em `bootstrap/` **falha** nesse recurso específico enquanto a lifecycle estiver lá. Pra destruir de
verdade, remova temporariamente o bloco `lifecycle { prevent_destroy = true }` em
`bootstrap/state.tf` antes.

**ECR sem `force_delete = true` trava o `destroy` de `infra/`** — se o repositório tiver alguma
imagem (e sempre vai ter, a CI dá push a cada deploy), `terraform destroy` falha com "repository not
empty" a menos que o resource tenha `force_delete = true`.

**CloudWatch na `tf-role-permission` é sobre _gerenciar_ o log group, não sobre _escrever_ nele** —
fácil de confundir as duas coisas: `logs:CreateLogGroup`/`PutRetentionPolicy` (control plane, dono é
`tf-role`, usado só quando `infra/` aplica) são diferentes de `logs:PutLogEvents` (data plane —
escrever linhas de log em runtime, dono é `ecs-execution-role`, via
`AmazonECSTaskExecutionRolePolicy`). Sem a segunda, o container simplesmente não consegue mandar
log nenhum pro CloudWatch, mesmo com o log group existindo perfeitamente.

**Perder o `.tfstate` local de `bootstrap/` é recuperável, mas chato** — como não é versionado (nem
deveria ser — pode conter dados sensíveis), se sumir você precisa `terraform import` cada recurso de
volta pro state, um por um, usando os nomes/ARNs reais já existentes na AWS. Os nomes são
determinísticos (`tf-role`, `ecr-role`, etc.), então é possível, só manual.

**A conta AWS é literal, não uma referência** — os ARNs neste projeto têm a conta (`958157975241`)
escrita diretamente nas strings, tanto no Terraform quanto nos workflows. Funciona, mas duplica o
número em vários lugares; numa infraestrutura maior isso normalmente vira
`data "aws_caller_identity" "current"` + `"arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/..."`.

---

## Checklist Para Replicar em Outro Projeto

1. Decidir os limites das camadas pela **frequência de mudança**, não pelo tipo de recurso: o que
   quase nunca muda (identidade da CI, backend do state) vira `bootstrap`; o que muda ocasionalmente
   vira uma camada própria; o que muda a cada deploy vira outra.
2. `bootstrap` sempre com state **local**, aplicado manualmente, contendo só: o bucket/mecanismo de
   state remoto + o(s) `aws_iam_openid_connect_provider` + a(s) role(s) que a CI vai assumir.
   Nenhuma outra camada tem backend remoto até `bootstrap` já ter sido aplicado uma vez.
3. Antes de escrever qualquer trust policy, confirmar o formato exato do claim `sub` que o seu CI
   emite hoje (ver gotcha acima) — não copiar de um tutorial sem checar.
4. Camadas seguintes usam backend remoto com a **mesma bucket, keys diferentes**
   (`state/<camada>/terraform.tfstate`), aplicadas via CI assumindo a role criada no bootstrap.
5. Camadas posteriores referenciam recursos de camadas anteriores via `data` source (lookup por
   nome), nunca via `terraform_remote_state` apontando pra um backend local que a CI não alcança.
6. A policy da role de CI precisa cobrir **tudo** que qualquer camada aplicada por ela vai criar —
   incluindo `iam:PassRole`/`CreateServiceLinkedRole` se alguma camada passar roles pra um serviço
   AWS, e as ações de leitura (`Get*`/`Describe*`) que os `data` sources das camadas seguintes vão
   precisar.
7. Documentar/scriptar a ordem de `apply` (e a ordem **inversa** de `destroy`) — ver `iac/destroy.sh`
   como exemplo: destrua sempre da camada mais dependente pra menos dependente.
8. Rodar `terraform fmt` e `terraform validate` em cada camada antes de cada `apply`.

---

## 📝 Resumo

| Decisão                      | Estado atual deste projeto                                  | Alternativa comum                                                                                                      |
| ---------------------------- | ----------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------- |
| Autenticação do CI com a AWS | OIDC (`aws_iam_openid_connect_provider` + roles)            | Access key/secret key fixos em Secrets                                                                                 |
| Estrutura do Terraform       | 3 camadas (`bootstrap`/`infra`/`service`), states separados | State único, ou módulos Terraform reutilizáveis dentro de um state                                                     |
| Backend do state             | Local (`bootstrap`) + S3 remoto (`infra`, `service`)        | S3 + DynamoDB (lock) em todas as camadas, incluindo bootstrap num backend "gerenciado à mão" fora do próprio Terraform |
| Comunicação entre camadas    | `data` sources (lookup por nome na AWS)                     | `terraform_remote_state`, SSM Parameter Store, Terragrunt                                                              |
| Compute pra rodar a API      | Amazon ECS Express Mode                                     | ECS/Fargate "clássico", EKS, App Runner (deprecated)                                                                   |
| Anexo de managed policy      | `aws_iam_role_policy_attachment`                            | `managed_policy_arns` (deprecated)                                                                                     |

## Referência

- `iac/bootstrap/` — bucket de state, OIDC, `tf-role`/`ecr-role` (aplicado manualmente)
- `iac/infra/` — ECR, log group, roles do ECS (aplicado por `.github/workflows/ci-infra.yml`)
- `iac/service/` — o serviço ECS Express (aplicado por `ci-service.yml` e por `ci-app.yml`)
- `iac/destroy.sh` — destrói as 3 camadas na ordem correta
- [Tutorial de CI/CD com GitHub Actions](./ci-cd-github-actions.md) — os 3 workflows que aplicam
  estas camadas, e o mergulho completo no gotcha do claim `sub`
