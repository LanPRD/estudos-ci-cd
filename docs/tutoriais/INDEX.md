# Tutoriais

Tutoriais extraídos da implementação real deste projeto, focados em um padrão por vez, pensados
para você consultar depois e replicar em qualquer outro projeto — não são documentação de
referência sobre o comportamento atual deste repositório.

| Tutorial                                                               | Descrição                                                                                                                     |
| ---------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------- |
| [Dockerfile multi-stage build](./dockerfile-multi-stage-build.md)      | Como montar uma imagem Docker enxuta de produção para apps Node/Nest usando múltiplos estágios                                |
| [CI/CD com GitHub Actions](./ci-cd-github-actions.md)                  | 3 pipelines (app, infra, service) via OIDC — testa, versiona, builda, publica no ECR e deploya via `terraform apply` |
| [Infraestrutura AWS via Terraform em camadas](./iac-terraform-aws.md)  | Terraform dividido em 3 camadas (bootstrap/infra/service) com states separados, OIDC + IAM, ECS Express Mode e `data` sources entre camadas |
| [Versionamento automático com semantic-release](./semantic-release.md) | Calcular a próxima versão, gerar changelog e publicar release a partir de mensagens de commit (Conventional Commits)          |
| [Docker Compose local](./docker-compose-local.md)                      | Orquestrar API + MySQL localmente: network, volume, e como o hostname do serviço vira o `host` da conexão do banco            |
