# tinnovatech/actions

Biblioteca central de **CI/CD da Tinnova** para GitHub Actions — módulos próprios, versionados,
reutilizáveis por todos os repos da org. Nasceu da migração das pipelines do Bitbucket.

> **Regra de ouro:** um repo de aplicação **não** escreve lógica de pipeline. Ele só *chama*
> um módulo daqui. Toda a lógica (build, test, deploy, infra) vive aqui, num lugar só.

> 🏃 **Runner self-hosted + deploy ECS + fallback pro `ubuntu-latest`:** guia ponta a ponta (infra
> Terraform, `pick-runner`, `java-ecs-deploy`, operação) em **[`docs/self-hosted-runner-cicd.md`](docs/self-hosted-runner-cicd.md)**.

---

## Índice

1. [Conceitos](#1-conceitos) — workflow reutilizável × composite action × Taskfile
2. [Quick start](#2-quick-start) — o `ci.yml` mínimo
3. [Arquitetura](#3-arquitetura) — como as peças se encaixam
4. [Reusable workflows](#4-reusable-workflows) — 1 por stack
5. [Composite actions](#5-composite-actions) — blocos + seus Taskfiles
6. [Secrets & variables](#6-secrets--variables)
7. [Ambientes (dev/qas/prd)](#7-ambientes)
8. [Pré-requisito AWS OIDC](#8-pré-requisito-aws-oidc)
9. [Versionamento](#9-versionamento)
10. [Como adicionar um módulo novo](#10-como-adicionar-um-módulo-novo)

---

## 1. Conceitos

Três tipos de peça, do mais alto ao mais baixo nível:

| Peça | O que é | Onde fica | Como se usa |
|------|---------|-----------|-------------|
| **Reusable workflow** | Um pipeline inteiro (jobs build→test→deploy) parametrizável | `.github/workflows/*.yml` | `uses: tinnovatech/actions/.github/workflows/<x>.yml@v1` (nível de `job`) |
| **Composite action** | Um passo composto (ex: login OIDC, deploy S3) | `<nome>/action.yml` | `uses: tinnovatech/actions/<nome>@v1` (nível de `step`) |
| **Taskfile** | O shell de verdade, organizado em tasks | `<nome>/Taskfile.yml` | chamado pelo composite via `task -t ... <target>` |

**Por que Taskfile?** Regra da Tinnova: shell não fica solto em bloco `run:` gigante no YAML.
Cada composite carrega um `Taskfile.yml` com as etapas nomeadas (`sync-assets`, `invalidate`, …),
testável isolado e legível. O composite só instala o `task` e roda o alvo.

---

## 2. Quick start

Crie **um** arquivo no seu repo: `.github/workflows/ci.yml`. Escolha o módulo da sua stack.

**Serviço Java/Gradle** (build + test + sonar + push Docker):
```yaml
name: ci
on:
  push: { branches: [develop, main] }
  pull_request: { branches: [develop, main] }
  workflow_dispatch:
jobs:
  ci:
    uses: tinnovatech/actions/.github/workflows/java-gradle-ci.yml@v1
    with:
      push: ${{ github.ref == 'refs/heads/develop' || startsWith(github.ref, 'refs/tags/') }}
      registry: ecr
      image-name: "458709605159.dkr.ecr.us-east-2.amazonaws.com/orkestral/payment-service"
    secrets: inherit
```

**Frontend → S3 + CloudFront:**
```yaml
jobs:
  deploy:
    uses: tinnovatech/actions/.github/workflows/node-frontend-s3-cf.yml@v1
    with:
      package-manager: bun
      build-cmd: "bun run build"
      dist-dir: dist
      environment: ${{ github.ref_name == 'main' && 'prd' || 'dev' }}
      # Guard-rails (recomendado sempre em prd) — evita publicar build quebrado:
      site-url: ${{ github.ref_name == 'main' && 'https://cravabrasil.com.br' || '' }}
      marker: "<title>Crava"
    secrets: inherit
```

> **Guard-rails do `deploy-frontend`** (blindam contra o incidente de site fora):
> - **preflight** — valida o build ANTES de tocar no S3 (`index.html` presente + tamanho sadio + tem `marker` + há assets `.js/.css`). Build vazio/errado **nunca** sobe.
> - **smoke** — depois do deploy, faz `curl` no `site-url` e exige `200` + `marker` (com retry p/ propagação). Se falhar, o **deploy falha** (não passa silencioso).
> - **rollback** — `task -t deploy-frontend/Taskfile.yml rollback` restaura o `index.html` da versão anterior (S3 versioning) + invalida cache. Recuperação imediata.
>
> `site-url`/`marker` são opcionais — sem eles o smoke é pulado (compatível com repos que ainda não configuraram). **Em prd, sempre configure.**
>
> **Ligar por repo SEM mexer no ci.yml** — o smoke lê `vars.SMOKE_URL` / `vars.SMOKE_MARKER` como
> fallback quando os inputs estão vazios. Basta setar 2 variáveis (repo ou environment `prd`):
> ```bash
> gh variable set SMOKE_URL    --repo tinnovatech/<repo> --env prd --body "https://meusite.com.br"
> gh variable set SMOKE_MARKER --repo tinnovatech/<repo> --env prd --body "<title>MeuApp"
> ```
> **Comportamento seguro:** sem as variáveis, o smoke fica **desligado** e só o `preflight` roda —
> nenhum deploy quebra. O `preflight` protege **todo** frontend automaticamente via `@v1`, sem config.
>
> **Apps atrás de login (retornam 403/302 em `/`):** NÃO aponte `SMOKE_URL` pra raiz — o smoke espera
> `200`. Use uma rota pública/health (ex: `/health`, `/login`, `/favicon.ico`) ou deixe só o preflight.

`secrets: inherit` passa os secrets da org/repo/environment automaticamente. Pronto.

---

## 3. Arquitetura

```
 repo de app: .github/workflows/ci.yml
        │  uses:
        ▼
 REUSABLE WORKFLOW  (ex: node-frontend-s3-cf.yml)
   job build   → checkout → setup → build → upload-artifact
   job deploy  → download-artifact
                 └─ uses: aws-oidc-login   (composite)   ── autentica na AWS (OIDC)
                 └─ uses: deploy-frontend   (composite)
                              └─ instala `task`
                              └─ task -t deploy-frontend/Taskfile.yml deploy
                                   ├─ sync-assets   (aws s3 sync)
                                   ├─ upload-index  (aws s3 cp)
                                   └─ invalidate    (aws cloudfront)
```

O shell (aws s3/cloudfront) mora no **Taskfile**, não no workflow. Trocar a lógica de deploy =
editar 1 Taskfile, e todos os fronts herdam.

---

## 4. Reusable workflows

Todos aceitam `secrets: inherit`. Secrets ausentes **não** quebram o build (são `required: false`) —
só o passo que precisa deles falha.

### `java-gradle-ci.yml`
Build + test + SonarCloud, e (opcional) build & push de imagem Docker (ECR ou DigitalOcean).

| input | default | descrição |
|-------|---------|-----------|
| `java-version` | `17` | JDK |
| `gradle-args` | `clean build -x test --no-daemon` | build |
| `run-sonar` | `true` | roda SonarCloud |
| `push` | `false` | build & push da imagem |
| `registry` | `ecr` | `ecr` \| `digitalocean` \| `none` |
| `image-name` | `""` | caminho da imagem (sem tag) |
| `aws-region` | `us-east-2` | região ECR |

Secrets: `SONAR_TOKEN`, `AWS_OIDC_ROLE_ARN` (ecr), `DIGITALOCEAN_ACCESS_TOKEN` (do).

### `java-ecs-deploy.yml`
Java/Gradle → build → **deploy ECS** (branch→conta/env) rodando em **runner self-hosted com fallback
automático** pro `ubuntu-latest`. Deploy self-contained (sem artifact). É a evolução do `java-gradle-ci`
para serviços que rolam ECS em múltiplas contas e querem runner próprio (economia de cota).
📖 **Doc completo ponta a ponta: [`docs/self-hosted-runner-cicd.md`](docs/self-hosted-runner-cicd.md).**

| input | default | descrição |
|-------|---------|-----------|
| `image-name` | — | repo ECR + prefixo do service (ex.: `crava-auth`) |
| `dockerfile` | `Dockerfile` | caminho do Dockerfile |
| `java-version` | `21` | JDK (toolchain do projeto) |
| `gradle-build-args` | `clean build -x test -x ktlint… --no-daemon` | build |
| `aws-region` | `us-east-1` | |
| `runner-label` | `""` | label do runner self-hosted (ex.: `crava`). Vazio = sempre `ubuntu-latest` |
| `runner-org` | `tinnovatech` | org p/ o picker |
| `cluster-prefix` | `crava` | `cluster = <prefix>-<env>`; service = `<image-name>-<env>-service` |
| `run-sonar` | `false` | roda SonarCloud no PR |
| `circuit-breaker` | `true` | liga ECS deployment circuit breaker + rollback (rollout self-heal server-side) |
| `wait` | `false` | bloquear o job até o rollout terminar. Default **fire-and-trust**; `true` só em runner estável/não-spot |
| `wait-timeout` | `900` | segundos máximos observando o rollout (só vale com `wait=true`) |

Branch → env: `develop`→dev, `stage`→qas, `main`→prd. Secrets: `RUNNERS_PAT`, `AWS_OIDC_ROLE_ARN`, `SONAR_TOKEN`.

> **Deploy resiliente a runner spot** — o `deploy-ecs` **entrega o rollout ao ECS e sai verde** (fire-and-trust),
> em vez de bloquear o runner esperando `services-stable`. Com o circuit breaker ligado, o ECS conduz
> `COMPLETED`/rollback sozinho, server-side. Runner spot reclamado no meio **não** marca mais falha num deploy
> que subiu OK. Histórico técnico completo do incidente e da correção logo abaixo em
> [**§4.1 Jornada: deploy ficava vermelho com ECS OK**](#41-jornada-deploy-ficava-vermelho-com-ecs-ok).

#### 4.1 Jornada: deploy ficava vermelho com ECS OK

> Incidente real no `crava-auth` (2026-07-09). Documentado aqui porque a causa e a correção valem
> para **todo** repo que usa `java-ecs-deploy` / `deploy-ecs`.

**Sintoma.** Deploys intermitentemente vermelhos no GitHub, **mas o ECS deployava certinho** (QAS/dev
subiam na versão nova). O job parava em:

```
task: [rollout] aws ecs update-service --cluster "$CLUSTER" --service "$SERVICE" --force-new-deployment
waiting for crava-auth-qas-service to stabilize...
Error: The operation was canceled.
```

Além disso, o job `pick-runner` às vezes ficava `Queued` eternamente com annotations:
```
The job was not acquired by Runner of type hosted even after multiple attempts
Internal server error. Correlation ID: a801ac69-e929-4a1a-9a7c-2a030af0f9f1
```

**Diagnóstico — dois problemas distintos, nenhum era bug de código:**

1. **`pick-runner` travado** = incidente do **lado do GitHub** nos runners *hosted* (o `pick-runner`
   roda em `ubuntu-latest`). O `Correlation ID` + `Internal server error` são a prova. Transiente,
   auto-resolve. Não é a nossa infra.

2. **`deploy` vermelho com ECS OK** = o job de deploy roda no **runner self-hosted spot** (ASG
   `crava-prd-github-runner`, spot diversificado). A sequência era:
   - `aws ecs update-service --force-new-deployment` → **dispara o rollout server-side** ✅
   - `aws ecs wait services-stable` → fica **bloqueado** minutos esperando steady state
   - o runner spot é **reclamado no meio da espera** → `##[error]The runner has received a shutdown signal`
     → `The operation was canceled.` → job vermelho.
   - Como o `update-service` já tinha disparado, o **ECS terminou o rollout sozinho** → deploy OK,
     mas o job ficou vermelho porque o *step de espera* morreu antes de ver o steady state.

**Iterações da correção (o que o teste com deploy real de dev ensinou):**

| # | Tentativa | Resultado |
|---|-----------|-----------|
| 1 | Trocar `wait services-stable` por poll do `rolloutState` + ligar circuit breaker | Rodou certo (`rolloutState=IN_PROGRESS…`), mas o runner spot foi reclamado no meio de novo → job vermelho igual. **Provou: nada que roda no runner spot sobrevive ao reclaim.** |
| 2 | **Fire-and-trust**: `update-service` (síncrono) liga o circuit breaker e **entrega pro ECS**; job sai verde na hora | ✅ `deploy: success em 166s`. ECS conduz `COMPLETED`/rollback sozinho, server-side. |

**Design final (`deploy-ecs`):**

- **Deployment circuit breaker + rollback** ligado em todo deploy (`CIRCUIT_BREAKER=true`, idempotente,
  preserva `maximumPercent`/`minimumHealthyPercent` existentes). O ECS completa **ou** faz rollback pro
  último task set saudável **server-side**, independente do runner viver.
- **Fire-and-trust** (`WAIT=false` default): o job publica a imagem, chama `update-service` (que é
  síncrono — quando retorna, o ECS já aceitou a nova deployment) e **sai verde**. Não fica bloqueado
  num runner efêmero — que é justamente o que provocava o reclaim no meio.
- **`wait=true` vira opt-in**, só faz sentido em runner **estável/não-spot** (ou hosted). Lá o job
  bloqueia observando o `rolloutState` da deployment `PRIMARY` e falha rápido em `FAILED`.

```bash
# rollout (resumo do deploy-ecs/Taskfile.yml)
aws ecs update-service --cluster "$CLUSTER" --service "$SERVICE" \
  --force-new-deployment \
  --deployment-configuration "deploymentCircuitBreaker={enable=true,rollback=true},maximumPercent=$MAXP,minimumHealthyPercent=$MINP"
# WAIT=false (default): "rollout handed off to ECS (circuit breaker owns completion/rollback) — not blocking this runner" → exit 0
# WAIT=true (opt-in): poll rolloutState → COMPLETED=ok | FAILED=exit 1
```

**Trade-off honesto.** Pipeline verde = *"imagem publicada + rollout entregue ao ECS"*, não *"rollout
terminou com sucesso"*. Se a imagem for ruim, o **circuit breaker faz rollback sozinho** (prod segue
na versão saudável) e o job fica verde mesmo assim. Quem quiser um **gate bloqueante** de verdade liga
`wait: true` — mas **num runner não-spot**, senão volta a flakar por reclaim.

**Sobre trocar o runner pra on-demand.** Foi considerado (mata a classe toda de reclaim), mas **não é
necessário** depois do fire-and-trust: o job de deploy agora é curto (~166s) e sai verde antes de qualquer
espera. On-demand custa ~3× o spot e só cobriria o caso raro de reclaim *durante o build/push* — que é um
job genuinamente incompleto (re-rodar resolve), não um falso-vermelho. Mantido **spot**. Reconsiderar só
se reclaim no meio de build de PR começar a incomodar (antes disso, subir `runner_count` ajuda).

**Guia de infra do runner (ASG spot, schedule, SSM):** [`docs/self-hosted-runner-cicd.md`](docs/self-hosted-runner-cicd.md).

### `java-maven-ci.yml`
Igual ao gradle, para repos Maven (`pom.xml`). Input extra: `maven-args` (default `clean verify`).

### `node-frontend-s3-cf.yml`
Build (npm **ou** bun) → deploy S3 + invalidação CloudFront via OIDC.

| input | default | descrição |
|-------|---------|-----------|
| `package-manager` | `npm` | `npm` \| `bun` |
| `node-version` | `22` | |
| `build-cmd` | `npm run build` | comando de build |
| `dist-dir` | `dist` | saída do build |
| `aws-region` | `us-east-1` | |
| `environment` | `""` | dev/qas/prd (secrets + reviewers) |

Secrets: `AWS_OIDC_ROLE_ARN`, `S3_BUCKET`, `CF_DISTRIBUTION_ID`.

### `go-lambda.yml`
Build de Go Lambda (arm64 `bootstrap` + zip) → `aws lambda update-function-code`.

| input | default | descrição |
|-------|---------|-----------|
| `go-version` | `1.23` | |
| `function-name` | — | nome da função Lambda |
| `deploy` | `false` | faz o deploy |
| `environment` | `""` | dev/qas/prd |

Secret: `AWS_OIDC_ROLE_ARN`.

### `serverless-deploy.yml`
`serverless deploy --stage <stage>` com OIDC. Inputs: `node-version`, `stage`, `service-path`, `environment`.

### `terraform-terragrunt.yml`
fmt → tflint → checkov → `terragrunt run-all plan` → (opcional) `apply`.

| input | default | descrição |
|-------|---------|-----------|
| `tf-version` | `1.9` | |
| `tg-version` | `0.67.0` | |
| `working-dir` | `env` | dir dos units |
| `apply` | `false` | roda apply (prd = aprovação no environment) |

Secret: `AWS_OIDC_ROLE_ARN`.

### `k8s-apply.yml`
`kubectl apply` num cluster — **DOKS** (DigitalOcean, via `doctl`) ou **EKS** (AWS, via OIDC).

| input | default | descrição |
|-------|---------|-----------|
| `provider` | — | `doks` \| `eks` |
| `cluster` | — | nome do cluster |
| `manifest-dir` | — | dir aplicado com `-R -f` |
| `namespace-file` | `""` | manifest de namespace aplicado antes |
| `aws-region` | `us-east-1` | (EKS) |

Secrets: `DIGITALOCEAN_ACCESS_TOKEN` (doks) ou `AWS_OIDC_ROLE_ARN` (eks).

### `docker-image.yml`
Build & push de imagem base/tooling (DO ou ECR). Inputs: `registry`, `context`, `image`, `aws-region`.

---

## 5. Composite actions

Blocos reutilizáveis usados pelos workflows acima. Os 4 de deploy carregam **Taskfile próprio**.

### `pick-runner`
Decide o `runs-on`: se há runner self-hosted com `<label>` **online** na org → self-hosted; senão →
`ubuntu-latest` (créditos GitHub). Usado no job `pick-runner` dos reusables. `inputs: label, org, token`;
`output: labels` (usar com `fromJSON` em `runs-on`). Ver [`docs/self-hosted-runner-cicd.md`](docs/self-hosted-runner-cicd.md).

### `aws-oidc-login`
Assume role IAM via OIDC (keyless). `inputs: role-arn, aws-region`. Wrapper do `configure-aws-credentials`.

### `do-registry-login`
Login no registry DigitalOcean. `inputs: do-token, registry`.

### `sonar-scan`
SonarCloud/SonarQube. `inputs: sonar-token, sonar-host, args`.

### `deploy-frontend` &nbsp;→&nbsp; `deploy-frontend/Taskfile.yml`
Deploy S3 + CloudFront. `inputs: dist-dir, bucket, distribution-id`.
```yaml
# deploy-frontend/Taskfile.yml (resumo)
tasks:
  deploy: [sync-assets, upload-index, invalidate]
  sync-assets:  aws s3 sync "$DIST" "s3://$BUCKET" --delete --exclude index.html --cache-control "…immutable"
  upload-index: aws s3 cp "$DIST/index.html" "s3://$BUCKET/index.html" --cache-control "no-cache"
  invalidate:   aws cloudfront create-invalidation --distribution-id "$CF_ID" --paths "/*"
```

### `deploy-k8s` &nbsp;→&nbsp; `deploy-k8s/Taskfile.yml`
kubeconfig (DOKS/EKS) + `kubectl apply`. `inputs: provider, cluster, manifest-dir, namespace-file, aws-region`.
```yaml
tasks:
  apply: [kubeconfig, apply-namespace, apply-manifests]
  kubeconfig:      doctl … kubeconfig save $CLUSTER  |  aws eks update-kubeconfig …
  apply-manifests: kubectl apply -R -f "$MANIFEST_DIR"
```

### `build-lambda` &nbsp;→&nbsp; `build-lambda/Taskfile.yml`
Build arm64 `bootstrap` + zip. `inputs: goarch, entry, zip`.
```yaml
tasks:
  build:
    - go mod download && go mod verify
    - GOOS=linux CGO_ENABLED=0 GOARCH=$GOARCH_IN go build -tags lambda.norpc -o bootstrap $ENTRY
    - zip $ZIP bootstrap
```

### `run-terraform` &nbsp;→&nbsp; `run-terraform/Taskfile.yml`
`terragrunt run-all plan|apply`. `inputs: working-dir, action, tg-version`.
```yaml
tasks:
  run:
    dir: "{{.WORKDIR}}"
    cmd: terragrunt run-all "${TG_ACTION:-plan}" --terragrunt-non-interactive
```

> **Como o composite acha o Taskfile:** ele roda `task -t "${{ github.action_path }}/Taskfile.yml" <target>`.
> `github.action_path` é a pasta do próprio composite no runner — o Taskfile viaja junto.

---

## 6. Secrets & variables

| Nome | Tipo | Escopo | Usado por |
|------|------|--------|-----------|
| `SONAR_TOKEN` | secret | org | java-* |
| `DIGITALOCEAN_ACCESS_TOKEN` | secret | org | java (DO), k8s (doks), docker-image |
| `AWS_OIDC_ROLE_ARN` | secret | repo/env | todo deploy AWS |
| `S3_BUCKET`, `CF_DISTRIBUTION_ID` | secret | repo/env | frontend |

Setar via `gh`:
```bash
gh secret set SONAR_TOKEN --org tinnovatech --visibility all --body '<valor>'
gh secret set AWS_OIDC_ROLE_ARN --repo tinnovatech/<repo> --env dev --body 'arn:aws:iam::…:role/…'
```

> **Chaves AWS estáticas (`AWS_ACCESS_KEY_ID`/`SECRET`) NÃO são usadas.** Autenticação é 100% OIDC.

---

## 7. Ambientes

Deploys usam GitHub **Environments** (`dev`/`qas`/`prd`) para: secrets escopados por env e
**reviewers obrigatórios** (aprovação manual antes de aplicar em prd). O caller mapeia a branch:
```yaml
with:
  environment: ${{ github.ref_name == 'main' && 'prd' || 'dev' }}
```
Configure os reviewers em *Settings → Environments → prd* de cada repo.

---

## 8. Pré-requisito AWS OIDC

Para os jobs de deploy AWS autenticarem, cada conta precisa confiar no GitHub:
- OIDC provider `token.actions.githubusercontent.com`
- Trust policy da role aceitando `repo:tinnovatech/*`

Isso é criado pelo Terraform `github-oidc` (contas dev `458709605159`, prd `606096000461`, crava).
Sem isso, `aws-oidc-login` falha. Build/test rodam normalmente antes.

---

## 9. Versionamento

Use sempre a tag de major: `@v1`. Atualizações compatíveis movem `v1`. Breaking change → `v2`.
Actions de terceiro são fixadas por tag de major (`@v4`) dentro dos módulos.

---

## 10. Como adicionar um módulo novo

1. Reusable workflow novo? Crie `.github/workflows/<x>.yml` com `on: workflow_call`.
2. Shell de deploy? Crie um composite `<nome>/action.yml` + `<nome>/Taskfile.yml` e chame o Taskfile
   com `task -t "${{ github.action_path }}/Taskfile.yml" <target>` (regra: shell no Taskfile, não no YAML).
3. Actions de terceiro por tag de major (`@vN`).
4. `permissions:` mínimo (`id-token: write` só onde há deploy AWS).
5. Bump da tag `v1` e teste com um repo piloto via `workflow_dispatch`.
```

