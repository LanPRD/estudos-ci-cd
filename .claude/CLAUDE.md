# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project purpose

This is a study/practice repository (`estudos-ci-cd`) for learning CI/CD pipelines. The application itself is an unmodified NestJS starter — the actual focus of the repo is `.github/workflows/ci.yml`, `Dockerfile`, and `docker-compose.yml`, not application features.

## Commands

```bash
npm run start:dev      # run with hot reload
npm run start:debug    # run with debugger + hot reload
npm run build           # compile via nest build -> dist/
npm run start:prod       # run compiled output (node dist/main)

npm run lint             # eslint --fix on src/apps/libs/test
npm run format           # prettier --write on src/ and test/

npm test                 # unit tests (jest, rootDir: src)
npm run test:watch
npm run test:cov
npm run test:e2e         # e2e tests (jest --config ./test/jest-e2e.json)
npm run test:debug
```

To run a single unit test file: `npx jest src/app.controller.spec.ts`.
To run a single test by name: `npx jest -t "test name"`.

## Architecture

- Standard minimal NestJS structure: `AppModule` (`src/app.module.ts`) wires a single `AppController` / `AppService` pair. There are no additional modules, controllers, or entities yet.
- `AppModule` registers `TypeOrmModule.forRoot(...)` with hardcoded MySQL connection settings (host `database`, db `rocketseat-db`, user `admin`) matching the `docker-compose.yml` `database` service — this only works when run via docker-compose, since `database` is a service hostname, not `localhost`. `entities: []` — no TypeORM entities are defined yet, and `synchronize: true` is set (dev-only pattern, not safe for production data).
- `docker-compose.yml` defines two services: `database` (MySQL 8) and `api-rocket` (built from the local `Dockerfile`), joined on a bridge network `primeira-network`.
- `Dockerfile` is a multi-stage build: `build` stage runs `npm ci` + `npm run build` + prunes dev deps, `deploy` stage copies only `node_modules` and `dist` into a slim final image and runs `node dist/main`.
- CI (`.github/workflows/ci.yml`) triggers on push to `master`: installs deps, runs `npm test`, then builds and pushes a Docker image to Docker Hub as `lanprd/estudos-ci-cd:<short-sha>` and `:latest`, authenticating via `DOCKERHUB_USERNAME`/`DOCKERHUB_TOKEN` secrets.
- `@semantic-release/*` packages are present in devDependencies but there is no `.releaserc`/semantic-release config or CI step wired up yet — treat this as unfinished setup, not an active release pipeline.
- TypeScript config relaxes several strict checks (`strictNullChecks: false`, `noImplicitAny: false`) — match this looseness rather than introducing strict-mode-only patterns.
