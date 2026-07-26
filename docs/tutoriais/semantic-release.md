# Versionamento Automático com semantic-release

## 🤔 Quem Decide Qual é a Próxima Versão?

Decidir manualmente se um merge é `1.2.0` ou `1.2.1` ou `2.0.0` depende de alguém lembrar a
convenção, olhar o que mudou, editar `package.json`, escrever o changelog à mão e criar a tag —
fácil de esquecer um passo, fácil de duas pessoas decidirem números diferentes pro mesmo tipo de
mudança.

**semantic-release** automatiza isso a partir das próprias mensagens de commit: se os commits
seguem o padrão **Conventional Commits** (`fix:`, `feat:`, `feat!:`/`BREAKING CHANGE:`), a
ferramenta consegue calcular sozinha o próximo número de versão (Semantic Versioning), gerar o
changelog, criar a tag e publicar uma release no GitHub — tudo dentro do pipeline de CI, sem
intervenção manual.

---

## 🎯 Resposta Rápida

`.releaserc.json` na raiz do projeto:

```json
{
  "branches": ["main"],
  "plugins": [
    "@semantic-release/commit-analyzer",
    "@semantic-release/release-notes-generator",
    ["@semantic-release/changelog", { "changelogFile": "CHANGELOG.md" }],
    ["@semantic-release/git", { "assets": ["CHANGELOG.md"] }],
    "@semantic-release/github"
  ]
}
```

Step no workflow, **depois** dos testes passarem:

```yaml
permissions:
  contents: write # cria commits, tags e releases
  issues: write # comenta em issues referenciadas nos commits
  pull-requests: write # idem, em PRs

steps:
  - uses: actions/checkout@v7
    with:
      fetch-depth: 0 # semantic-release precisa do histórico completo, não de um clone raso

  - run: npm test

  - name: Semantic Release
    uses: cycjimmy/semantic-release-action@v6
    env:
      GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
```

Sem commits que sigam a convenção desde a última release, o step **não falha** — ele só decide que
não há nada pra liberar e termina normalmente.

---

## 📚 Como Funciona: Da Mensagem de Commit à Release

```text
commits desde a última tag
   │
   ▼
[commit-analyzer] ──── lê os tipos de commit (fix/feat/BREAKING CHANGE) → decide patch/minor/major
   │
   ▼  (só continua se houver ao menos 1 commit que gere release)
[release-notes-generator] ──── monta o texto da release a partir dos commits
   │
   ▼
[changelog] ──── escreve/atualiza CHANGELOG.md no disco
   │
   ▼
[git] ──── commita CHANGELOG.md (+ outros assets), cria a tag da nova versão, faz push
   │
   ▼
[github] ──── publica a GitHub Release com as notas geradas
```

Cada plugin cobre uma fase do ciclo de vida de uma release (`verifyConditions` → `analyzeCommits` →
`verifyRelease` → `generateNotes` → `prepare` → `publish` → `success`/`fail`), e a **ordem no
array `plugins` importa**: `changelog` precisa rodar antes de `git`, porque é o `git` que vai
commitar o arquivo que o `changelog` acabou de escrever.

---

## 🔍 Conventional Commits: o Que Cada Prefixo Decide

| Prefixo do commit                                        | Bump de versão            | Exemplo                                       |
| -------------------------------------------------------- | ------------------------- | --------------------------------------------- |
| `fix:`                                                   | patch (`1.2.0` → `1.2.1`) | `fix: corrige timeout na conexão com o banco` |
| `feat:`                                                  | minor (`1.2.0` → `1.3.0`) | `feat: adiciona endpoint de health check`     |
| `feat!:` ou rodapé `BREAKING CHANGE:`                    | major (`1.2.0` → `2.0.0`) | `feat!: remove suporte a Node 16`             |
| `docs:`, `chore:`, `refactor:`, `test:`, `style:`, `ci:` | nenhum (por padrão)       | não geram release sozinhos                    |

Essa tabela é a configuração **padrão** do `@semantic-release/commit-analyzer` (baseada no preset
`angular` do Conventional Commits). Ela é customizável — dá pra mudar quais tipos geram release, ou
adotar outro preset de convenção — mas mudar isso sem necessidade tira a vantagem de ser um padrão
reconhecido pelo ecossistema (outras ferramentas, como geradores de changelog e linters de commit,
já entendem esse formato).

### O ecossistema de plugins vai além do que este projeto usa

Os cinco plugins do `.releaserc.json` cobrem o fluxo "GitHub + changelog em arquivo", mas existem
outros comuns:

- **`@semantic-release/npm`** — publica o pacote no npm registry (irrelevante aqui, já que este
  projeto não é uma lib publicada).
- **`@semantic-release/exec`** — roda comandos shell arbitrários em qualquer fase (ex: buildar um
  artefato antes de publicar).
- **`@semantic-release/gitlab`** — equivalente ao `@semantic-release/github`, para quem hospeda no
  GitLab.

---

## ✅ Faça / ❌ Não Faça

**✅ Rodar o semantic-release depois do gate de testes:**

```yaml
- run: npm test
- uses: cycjimmy/semantic-release-action@v6 # só chega aqui se os testes passaram
```

**❌ Publicar uma release antes de saber se o código funciona:**

```yaml
- uses: cycjimmy/semantic-release-action@v6 # ❌ pode taguear/publicar código quebrado
- run: npm test
```

**✅ Checkout com histórico completo:**

```yaml
- uses: actions/checkout@v7
  with:
    fetch-depth: 0
```

**❌ Checkout raso (o default do `actions/checkout`) antes do semantic-release:**

```yaml
- uses: actions/checkout@v7 # ❌ fetch-depth default é 1 — semantic-release não enxerga a tag/commits anteriores
```

**✅ Dar ao `GITHUB_TOKEN` (ou token equivalente) permissão de escrita:**

```yaml
permissions:
  contents: write
  issues: write
  pull-requests: write
```

**❌ Deixar as permissions no padrão somente leitura:**

```yaml
permissions:
  contents: read # ❌ semantic-release não consegue criar commit/tag/release
```

---

## 🎯 Exemplo do Projeto

`.releaserc.json` (raiz do projeto):

```json
{
  "branches": ["master"],
  "plugins": [
    "@semantic-release/commit-analyzer",
    "@semantic-release/release-notes-generator",
    ["@semantic-release/changelog", { "changelogFile": "CHANGELOG.md" }],
    ["@semantic-release/git", { "assets": ["CHANGELOG.md"] }],
    "@semantic-release/github"
  ]
}
```

Step no `.github/workflows/ci.yml`, logo após `npm test` e antes de qualquer step de build/deploy:

```yaml
- name: Semantic Release
  uses: cycjimmy/semantic-release-action@v6
  env:
    GITHUB_TOKEN: ${{ secrets.GH_TOKEN }}
```

Posicionado assim de propósito: se os testes falharem, o job para antes de chegar aqui (nenhuma
release é criada pra código quebrado); e como ele roda **antes** dos steps de build/push/deploy, uma
tag/release já existe associada ao commit antes da imagem correspondente ser publicada.

O `permissions` do job precisou crescer além do mínimo do pipeline de build (que só precisava de
`id-token: write` pra OIDC — ver [tutorial de CI/CD](./ci-cd-github-actions.md)):

```yaml
permissions:
  contents: write
  id-token: write
  issues: write
  pull-requests: write
```

`contents: write` é o que permite ao semantic-release commitar o `CHANGELOG.md`, criar a tag e
publicar a release; `issues`/`pull-requests: write` permitem que ele comente automaticamente em
issues/PRs referenciados nos commits incluídos na release.

**Usa `secrets.GH_TOKEN`, não o `GITHUB_TOKEN` automático do Actions** — o token padrão que o
GitHub injeta em cada execução (`${{ secrets.GITHUB_TOKEN }}`, sem precisar criar nada) normalmente
já é suficiente para o que o semantic-release faz neste setup. O uso de um secret nomeado à parte
(`GH_TOKEN`) sugere um Personal Access Token criado à mão — possivelmente pra contornar alguma
limitação específica (ex: workflows disparados por esse token não re-disparam outros workflows, o
que o token automático não faz por padrão). O motivo exato não está registrado no código; ao
replicar este padrão, comece com o `GITHUB_TOKEN` automático e só troque por um PAT se esbarrar
numa limitação concreta.

### 🔧 Pré-requisito Manual: Criando e Configurando o `GH_TOKEN`

Nada no código cria esse token — é o único passo deste pipeline que precisa ser feito manualmente,
uma vez, por quem administra o repositório:

1. **Criar o token**: GitHub → avatar (canto superior direito) → **Settings** → **Developer
   settings** (final do menu à esquerda) → **Personal access tokens** → **Tokens (classic)** (ou
   **Fine-grained tokens**) → **Generate new token**.
   - Escopo mínimo pra um token clássico: `repo` (acesso de escrita a conteúdo, issues e PRs — é o
     que o semantic-release usa pra commitar o changelog, criar tag/release e comentar).
   - Copie o valor assim que gerado — o GitHub não mostra de novo depois.
2. **Guardar como Secret do repositório**: no repositório → **Settings** → **Secrets and
   variables** → **Actions** → aba **Secrets** → **New repository secret**.
   - Nome: `GH_TOKEN` — tem que bater exatamente com `secrets.GH_TOKEN` referenciado no `ci.yml`;
     um nome diferente faz o step rodar sem token, e ele falha na autenticação.
   - Valor: o token copiado no passo 1.

Sem esse secret, o step "Semantic Release" falha logo na fase de `verifyConditions` (autenticação),
antes de analisar qualquer commit. Nenhum outro Secret do GitHub é necessário pra este projeto — a
autenticação com a AWS usa OIDC, não credenciais salvas (ver
[tutorial de IaC](./iac-terraform-aws.md)); `GH_TOKEN` é o único.

### 🔍 Onde Ver o Resultado

- **GitHub → aba Releases** do repositório: cada release publicada, com as notas geradas.
- **`CHANGELOG.md`** na raiz: histórico legível, atualizado a cada release.
- **Tags do repositório**: uma tag por versão (`vX.Y.Z`), criada pelo plugin `git`.

---

## ⚠️ Armadilhas

**Chave de configuração com nome errado falha em silêncio** — a config original deste projeto
tinha `"changeLogFile"` (com `L` maiúsculo) em vez de `"changelogFile"` (nome real da opção do
plugin `@semantic-release/changelog`). Plugins do semantic-release **ignoram silenciosamente**
opções que não reconhecem — não há erro nem warning. Isso só não quebrou nada aqui porque o valor
era exatamente o default (`CHANGELOG.md`); o efeito real é que a opção nunca fez nada, e trocar o
caminho do changelog editando essa chave errada simplesmente não teria efeito, sem nenhum sinal de
que algo estava errado.

**Checkout raso quebra o cálculo de versão** — sem `fetch-depth: 0`, o `actions/checkout` traz só o
último commit. O `commit-analyzer` não consegue enxergar a tag da release anterior nem os commits
desde então, o que compromete o cálculo de qual deveria ser a próxima versão.

**Nenhum commit "releasable" não é erro** — se todos os commits desde a última tag forem `docs:`,
`chore:` etc (que não geram bump por padrão), o step termina com sucesso e simplesmente não publica
nada. Não confundir com falha: vale olhar o log do step pra confirmar se uma release era esperada.

**Branch errada no `branches`** — o `.releaserc.json` só libera releases a partir das branches
listadas em `"branches"` (aqui, só `master`). Rodar o step numa branch de feature sem estar listada
não gera erro, só não publica nada — mesmo comportamento do ponto anterior.

---

## Checklist Para Replicar em Outro Projeto

1. Adotar Conventional Commits nas mensagens de commit (`fix:`, `feat:`, `feat!:`/`BREAKING CHANGE:`
   no rodapé) — sem isso, o `commit-analyzer` não tem o que analisar.
2. Instalar `semantic-release` + os plugins necessários como devDependencies.
3. Criar `.releaserc.json` (ou equivalente) listando as branches que devem gerar release e os
   plugins na ordem correta (`changelog` antes de `git`, por exemplo).
4. No workflow de CI: `fetch-depth: 0` no checkout, rodar o step **depois** do gate de testes, e
   dar ao token permissões de escrita (`contents`, e `issues`/`pull-requests` se quiser os
   comentários automáticos).
5. Confirmar que o nome de cada chave de configuração dos plugins está exatamente certo — erros de
   digitação não geram warning, só fazem a opção ser ignorada.
6. Rodar uma vez e conferir: tag criada, `CHANGELOG.md` atualizado, release publicada no GitHub.

---

## 📝 Resumo

| Decisão                | Estado atual deste projeto                                            | Alternativa comum                                               |
| ---------------------- | --------------------------------------------------------------------- | --------------------------------------------------------------- |
| Convenção de commit    | Conventional Commits (preset `angular`, default do `commit-analyzer`) | Preset customizado, ou nenhuma convenção (versionamento manual) |
| Onde publica a release | GitHub Releases (`@semantic-release/github`)                          | npm registry, GitLab Releases                                   |
| Changelog              | Arquivo `CHANGELOG.md` versionado no repo                             | Só nas GitHub Releases, sem arquivo separado                    |
| Token usado no CI      | Secret nomeado (`GH_TOKEN`)                                           | `GITHUB_TOKEN` automático do Actions                            |

## Referência

- `.releaserc.json`
- `.github/workflows/ci.yml` — step "Semantic Release"
- [Tutorial de CI/CD com GitHub Actions](./ci-cd-github-actions.md) — onde este step se encaixa no
  pipeline completo
