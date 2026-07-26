# Tutoriais

Tutoriais extraídos da implementação real deste projeto, focados em um padrão por vez, pensados
para você consultar depois e replicar em qualquer outro projeto — não são documentação de
referência sobre o comportamento atual deste repositório.

| Tutorial                                                               | Descrição                                                                                                                     |
| ---------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------- |
| [Dockerfile multi-stage build](./dockerfile-multi-stage-build.md)      | Como montar uma imagem Docker enxuta de produção para apps Node/Nest usando múltiplos estágios                                |
| [CI/CD com GitHub Actions](./ci-cd-github-actions.md)                  | Pipeline de app (testa, versiona, builda, publica no ECR, faz deploy) e o pipeline separado de infraestrutura, ambos via OIDC |
| [Infraestrutura AWS via Terraform](./iac-terraform-aws.md)             | OIDC + IAM roles/policies, ECR e ECS Express Mode (substituto do App Runner) provisionados como código em `iac/`              |
| [Versionamento automático com semantic-release](./semantic-release.md) | Calcular a próxima versão, gerar changelog e publicar release a partir de mensagens de commit (Conventional Commits)          |
| [Docker Compose local](./docker-compose-local.md)                      | Orquestrar API + MySQL localmente: network, volume, e como o hostname do serviço vira o `host` da conexão do banco            |
