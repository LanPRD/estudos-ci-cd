# estudos-ci-cd

Repositório de estudo/prática de pipelines de CI/CD. A aplicação é um starter NestJS sem muita lógica própria — o foco real está nos workflows do GitHub Actions, no Dockerfile e na infraestrutura como código (Terraform) em `iac/`.

## Stack

- NestJS + TypeScript
- MySQL (via `docker-compose.yml`)
- Docker (build multi-stage)
- Terraform (AWS: ECR, ECS Express Mode, IAM/OIDC)
- GitHub Actions

## Rodando localmente

```bash
docker-compose up
```

Ou, sem Docker:

```bash
npm install
npm run start:dev
```

## Comandos úteis

```bash
npm run build         # compila para dist/
npm run start:prod    # roda o build compilado
npm test              # testes unitários (Jest)
npm run test:e2e      # testes e2e
npm run lint          # eslint --fix
```

## Estrutura

- `src/` — código da aplicação (NestJS)
- `Dockerfile` / `docker-compose.yml` — build e ambiente local
- `iac/` — Terraform, dividido em 3 camadas por frequência de mudança:
  - `bootstrap/` — bucket de state, OIDC provider e IAM roles (aplicado manualmente, fora da CI)
  - `infra/` — repositório ECR e log group (aplicado pela CI)
  - `service/` — serviço ECS Express que roda a aplicação (aplicado pela CI a cada deploy)
- `.github/workflows/` — pipelines de CI:
  - `ci-app.yml` — testa, versiona (semantic-release), builda e publica a imagem, e faz o deploy via Terraform em `iac/service`
  - `ci-infra.yml` — aplica mudanças em `iac/infra`
  - `ci-service.yml` — aplica mudanças estruturais em `iac/service`
