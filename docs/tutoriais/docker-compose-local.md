# Orquestração local com Docker Compose (API + MySQL)

## Quando usar isso

Quando você quer subir localmente, com um único comando, uma aplicação e seu banco de dados —
sem instalar o banco na máquina e sem hardcodar `localhost` no código. Dentro de um Docker Compose,
os serviços se enxergam pelo nome uns dos outros, não por `localhost`.

```text
docker-compose up
        │
        ├── database   (mysql:8)
        │     container_name = hostname resolvível pelos outros serviços
        │     porta 3306 também exposta pro host
        │     volume nomeado "db" persiste os dados entre reinícios
        │
        └── api-rocket (build: Dockerfile local)
              depends_on: database   (só espera o container INICIAR, não o MySQL ficar pronto)
              porta 3000 exposta pro host

        ambos na mesma network "primeira-network" (bridge)
        → api-rocket resolve "database" pelo nome do serviço, nunca por localhost
```

## Como foi feito neste projeto

### Serviço `database`

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
```

- `image: mysql:8` — usa a imagem oficial, sem Dockerfile próprio.
- `container_name: database` — não é só um rótulo: dentro da network do compose, esse nome também
  funciona como hostname resolvível pelos outros serviços. É o valor que `app.module.ts` usa como
  `host` da conexão (ver abaixo).
- `volumes: db:/var/lib/mysql` — grava os dados do MySQL num volume nomeado (`db`, declarado no
  topo do arquivo), não no filesystem descartável do container. Sem isso, cada `docker-compose
  down` apagaria o banco inteiro.
- As variáveis `MYSQL_*` criam o usuário `admin`/senha `root` e o banco `rocketseat-db` na
  primeira inicialização do container.

### Serviço `api-rocket`

```yaml
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

- `build: context: .` — builda a imagem a partir do
  [Dockerfile multi-stage deste projeto](./dockerfile-multi-stage-build.md), em vez de puxar uma
  imagem pronta.
- `depends_on: [database]` — só garante a ordem de start dos containers; não espera o MySQL
  terminar de subir e aceitar conexões (ver armadilha abaixo).

### Rede compartilhada

```yaml
networks:
  primeira-network:
    driver: bridge
```

Uma network bridge dedicada faz os dois serviços se enxergarem pelo nome (`database`,
`api-rocket`) sem precisar publicar portas entre eles.

### A ponta que fecha o ciclo: `src/app.module.ts`

```ts
TypeOrmModule.forRoot({
  type: "mysql",
  host: "database",
  port: 3306,
  username: "admin",
  password: "root",
  database: "rocketseat-db",
  entities: [],
  synchronize: true,
}),
```

`host: "database"` só resolve porque existe um serviço chamado `database` na mesma network do
compose. Rodar a API fora do compose (ex: `npm run start:dev` direto na máquina) faz essa conexão
falhar — seria preciso trocar `host` para `localhost`, o que só funciona porque a porta 3306 do
MySQL também está exposta pro host.

## Checklist para replicar em outro projeto

1. Escolher a imagem oficial do banco (`postgres`, `mysql`, `mongo`, etc.) — geralmente não
   precisa de Dockerfile próprio.
2. Dar um `container_name` (ou usar o nome do serviço) que sirva como hostname estável — é esse
   valor que vai no `host` da connection string da aplicação.
3. Persistir os dados num volume nomeado, montado no diretório de dados do banco — sem isso, os
   dados somem a cada `down`.
4. Colocar app e banco na mesma `network` custom (bridge é suficiente para um único host).
5. Na config de conexão da aplicação, usar o nome do serviço/container como `host` — nunca
   `localhost` — sempre que ela também roda dentro do compose.
6. Expor a porta do banco pro host apenas se você precisa acessar de fora (cliente SQL local,
   migrations rodadas fora do container); não é necessário para os serviços se comunicarem entre
   si.
7. Usar `depends_on` sabendo da sua limitação (só ordem de start, não "pronto pra aceitar
   conexões") — ver armadilha abaixo para como lidar com isso.
8. Validar com `docker-compose up` e conferir nos logs se a aplicação conecta no banco.

## Armadilhas e decisões importantes

⚠️ **`depends_on` não espera o banco ficar pronto**: o MySQL leva alguns segundos pra aceitar
conexões depois do container "iniciar". Se a aplicação tentar conectar antes disso, a primeira
tentativa pode falhar. Neste projeto isso raramente quebra porque o NestJS tenta a conexão em
runtime, não em build-time — mas em ambientes mais lentos vale adicionar um `healthcheck` no
`database` e trocar `depends_on: [database]` por
`depends_on: { database: { condition: service_healthy } }`.

⚠️ **Credenciais hardcoded em dois lugares**: usuário/senha/banco aparecem duplicados no
`docker-compose.yml` e direto no código (`app.module.ts`), sem variáveis de ambiente. Funciona
para estudo, mas num projeto real isso deveria vir de variáveis de ambiente (`.env` +
`ConfigModule`), tanto para evitar a duplicação quanto para não commitar segredo em texto puro.

`synchronize: true` no TypeORM (fora do escopo deste tutorial, mas relevante aqui) também é um
padrão só de desenvolvimento — recria o schema automaticamente a partir das entities, o que é
arriscado em produção.

## Referência

- `docker-compose.yml`
- `src/app.module.ts`
- `Dockerfile` — usado pelo `build: context: .` do serviço `api-rocket`
