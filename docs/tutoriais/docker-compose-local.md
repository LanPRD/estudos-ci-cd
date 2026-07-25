# Docker Compose Local: Orquestrando API + Banco de Dados

## 🤔 Como Um Serviço Acha o Outro Sem Hardcodar IP?

Rodar uma API e um banco juntos localmente sem Docker normalmente significa instalar o banco na
máquina, ou lembrar de subir um container manualmente antes da API, com `localhost` e uma porta
fixa na connection string. Isso quebra assim que alguém mais roda o projeto numa máquina diferente
ou numa porta já ocupada.

**Docker Compose** resolve isso com um único comando (`docker-compose up`) que sobe todos os
serviços definidos num `docker-compose.yml`, e — o ponto central — coloca todos numa rede virtual
onde cada serviço enxerga os outros **pelo nome**, não por IP ou `localhost`.

---

## 🎯 Resposta Rápida

```yaml
services:
  db:
    image: postgres:16
    environment:
      - POSTGRES_PASSWORD=postgres
    networks: [app-network]

  api:
    build: .
    depends_on: [db]
    networks: [app-network]

networks:
  app-network:
    driver: bridge
```

Dentro da rede `app-network`, o serviço `api` resolve o hostname `db` automaticamente — é assim
que a connection string da aplicação deve apontar (`host: "db"`), nunca `localhost`.

---

## 📚 Como Funciona

```text
docker-compose up
        │
        ├── serviço "db"     (ex: postgres/mysql)
        │     nome do serviço = hostname resolvível pelos outros serviços
        │     volume nomeado persiste os dados entre reinícios
        │
        └── serviço "api"    (build a partir de um Dockerfile local)
              depends_on: db   (só espera o container INICIAR, não o banco ficar pronto)

        ambos na mesma network (bridge)
        → "api" resolve "db" pelo nome do serviço, nunca por localhost
```

Cada serviço dentro de uma network custom do Compose ganha um registro DNS interno com o próprio
nome do serviço (ou o `container_name`, se definido). É esse nome — não `localhost`, não IP fixo —
que a aplicação usa no `host` da sua conexão.

### Por que uma network custom (não a `default`)

O Compose já cria uma network `default` automaticamente para os serviços do arquivo. Definir uma
network nomeada explicitamente (`driver: bridge`) só passa a importar quando você quer conectar
serviços de *outros* `docker-compose.yml` na mesma rede, ou deixar claro no arquivo qual é o
domínio de rede do projeto — em um compose de um serviço só, a `default` já resolveria.

---

## 🆚 Estratégias Para Esperar o Banco Ficar Pronto

`depends_on` simples só garante *ordem de start dos containers*, não que o banco já aceita
conexões — MySQL/Postgres levam alguns segundos para inicializar depois que o container "roda".
Três formas comuns de lidar com isso:

| Estratégia | Como funciona | Trade-off |
| --- | --- | --- |
| `depends_on` simples | só espera o container iniciar | mais simples; falha intermitente se a app conectar rápido demais |
| `depends_on` + `condition: service_healthy` | espera um `healthcheck` do serviço dependido passar | mais robusto; exige definir `healthcheck` no serviço do banco |
| Retry na própria aplicação | app tenta reconectar até o banco responder | funciona em qualquer orquestrador, não só Compose; mais código na app |

---

## ✅ Faça / ❌ Não Faça

**✅ Usar o nome do serviço como host, nunca `localhost`, quando a app roda dentro do compose:**

```yaml
environment:
  - DATABASE_HOST=db  # ✅ nome do serviço
```

**❌ Hardcodar `localhost` na app pensando no ambiente de desenvolvimento fora do Docker:**

```yaml
environment:
  - DATABASE_HOST=localhost  # ❌ só funcionaria rodando fora do compose
```

**✅ Persistir dados do banco em volume nomeado:**

```yaml
volumes:
  - db-data:/var/lib/mysql
```

**❌ Deixar o banco sem volume:**

```yaml
# sem volumes: — cada `docker-compose down` apaga o banco inteiro
```

---

## 🎯 Exemplo do Projeto

Arquivo: `docker-compose.yml`. Dois serviços — `database` (MySQL) e `api-rocket` (build local) —
numa network bridge dedicada chamada `primeira-network`:

```yaml
database:
  image: mysql:8
  container_name: database
  volumes:
    - db:/var/lib/mysql
  ports:
    - 3306:3306
  environment:
    - MYSQL_ROOT_PASSWORD=root
    - MYSQL_DATABASE=rocketseat-db
    - MYSQL_USER=admin
    - MYSQL_PASSWORD=root
  networks:
    - primeira-network

api-rocket:
  build:
    context: .
  container_name: api-rocket
  ports:
    - 3000:3000
  depends_on:
    - database
  networks:
    - primeira-network
```

A ponta que fecha o ciclo é `src/app.module.ts`, que usa exatamente o `container_name` do serviço
`database` como `host` da conexão TypeORM:

```ts
TypeOrmModule.forRoot({
  type: "mysql",
  host: "database", // == container_name do serviço no docker-compose.yml
  port: 3306,
  username: "admin",
  password: "root",
  database: "rocketseat-db",
  entities: [],
  synchronize: true,
}),
```

`host: "database"` só resolve porque existe um serviço com esse nome na mesma network do compose.
Rodar a API fora do compose (`npm run start:dev` direto na máquina) quebra essa conexão — seria
preciso trocar `host` para `localhost`, o que só funciona porque a porta 3306 também está exposta
pro host (`ports: - 3306:3306`).

---

## ⚠️ Armadilhas

**`depends_on` não espera o MySQL ficar pronto para aceitar conexões** — neste projeto isso
raramente quebra porque o NestJS tenta a conexão em runtime (não em build-time) e geralmente há
tempo suficiente, mas em ambientes mais lentos vale trocar por
`depends_on: { database: { condition: service_healthy } }` com um `healthcheck` no serviço
`database` (ver tabela de estratégias acima).

**Credenciais hardcoded em dois lugares** — usuário/senha/banco aparecem duplicados no
`docker-compose.yml` e direto no código (`app.module.ts`), sem variáveis de ambiente. Funciona
para estudo, mas num projeto real isso deveria vir de `.env` + `ConfigModule`, tanto pra evitar a
duplicação quanto pra não commitar segredo em texto puro.

`synchronize: true` no TypeORM (fora do escopo deste tutorial, mas relevante aqui) também é um
padrão só de desenvolvimento — recria o schema automaticamente a partir das entities, arriscado em
produção.

---

## Checklist Para Replicar em Outro Projeto

1. Escolher a imagem oficial do banco (`postgres`, `mysql`, `mongo`, etc.) — geralmente não
   precisa de Dockerfile próprio.
2. Dar um `container_name` (ou usar o nome do serviço) que sirva como hostname estável — é esse
   valor que vai no `host` da connection string da aplicação.
3. Persistir os dados num volume nomeado, montado no diretório de dados do banco.
4. Colocar app e banco na mesma `network` custom (bridge é suficiente para um único host).
5. Na config de conexão da aplicação, usar o nome do serviço/container como `host` — nunca
   `localhost` — sempre que ela também roda dentro do compose.
6. Expor a porta do banco pro host apenas se precisar acessar de fora (cliente SQL local,
   migrations rodadas fora do container); não é necessário para os serviços se comunicarem entre
   si.
7. Decidir a estratégia de espera de prontidão (ver tabela 🆚 acima) em vez de confiar cegamente
   em `depends_on` simples.
8. Validar com `docker-compose up` e conferir nos logs se a aplicação conecta no banco.

---

## 📝 Resumo

| Decisão | Escolha deste projeto | Alternativa comum |
| --- | --- | --- |
| Banco | MySQL 8 | Postgres, MongoDB — mesma lógica de rede se aplica |
| Descoberta de serviço | nome do `container_name` (`database`) | nome do serviço, se `container_name` não for definido |
| Espera de prontidão | `depends_on` simples (sem healthcheck) | `condition: service_healthy` ou retry na app |
| Credenciais | hardcoded no `docker-compose.yml` e no código | `.env` + `ConfigModule` |

## Referência

- `docker-compose.yml`
- `src/app.module.ts`
- `Dockerfile` — usado pelo `build: context: .` do serviço `api-rocket`
