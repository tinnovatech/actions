# Self-hosted runners + `java-ecs-deploy` — CI/CD ponta a ponta

Documento técnico e didático da esteira que **não depende da cota do GitHub-hosted** (nem minutos, nem
storage de artifact) e que ainda **cai automaticamente pro `ubuntu-latest`** se o runner próprio estiver fora.

Nasceu do caso **crava-auth**: produção parada + cota do GitHub Actions esgotada. A solução virou padrão
reutilizável por qualquer serviço Java/ECS da Tinnova.

> **Regra de ouro (recap):** o repo da aplicação não escreve lógica de pipeline. Ele chama um reusable
> daqui. Muda aqui = vale pros 50 repos.

---

## Índice

1. [O problema](#1-o-problema)
2. [Visão geral da solução](#2-visão-geral-da-solução)
3. [Peça 1 — infraestrutura do runner (Terraform)](#3-peça-1--infraestrutura-do-runner-terraform)
4. [Peça 2 — `pick-runner` (fallback)](#4-peça-2--pick-runner-fallback)
5. [Peça 3 — reusable `java-ecs-deploy`](#5-peça-3--reusable-java-ecs-deploy)
6. [Peça 4 — o caller no repo](#6-peça-4--o-caller-no-repo)
7. [Fluxos](#7-fluxos)
8. [Operação do dia a dia](#8-operação-do-dia-a-dia)
9. [Contas AWS e acesso](#9-contas-aws-e-acesso)
10. [Adotar num repo novo](#10-adotar-num-repo-novo)
11. [Troubleshooting (lições aprendidas)](#11-troubleshooting-lições-aprendidas)

---

## 1. O problema

A conta GitHub da org bateu **duas cotas** ao mesmo tempo:

- **Minutos de Actions** (GitHub-hosted) esgotados → jobs não rodavam.
- **Storage de artifact** esgotado → `actions/upload-artifact` falhava (`Artifact storage quota has been hit`).

Resultado: a esteira do crava-auth não buildava nem deployava, e **produção ficou parada**.

Comprar mais minuto/armazenamento resolve o sintoma, não a causa: builds pesados de serviço rodando em
runner alugado do GitHub custam caro e recorrente. A saída sustentável é **runner self-hosted próprio**.

---

## 2. Visão geral da solução

Quatro peças, de baixo (infra) pra cima (o repo):

```
┌─────────────────────────────────────────────────────────────────────┐
│ repo (crava-auth)  .github/workflows/ci.yml  → 13 linhas, só "uses:"  │  Peça 4
├─────────────────────────────────────────────────────────────────────┤
│ reusable  tinnovatech/actions/.github/workflows/java-ecs-deploy.yml   │  Peça 3
│   jobs: pick-runner → build-test (PR) / deploy (push)                 │
├─────────────────────────────────────────────────────────────────────┤
│ composite  tinnovatech/actions/pick-runner  (self-hosted vs hosted)   │  Peça 2
├─────────────────────────────────────────────────────────────────────┤
│ infra  terraform-modules/github-runner  → EC2 ASG spot na conta prod  │  Peça 1
│   (registra runner no group "crava" do GitHub)                        │
└─────────────────────────────────────────────────────────────────────┘
```

**Como se conectam:** a infra (Peça 1) sobe uma EC2 que se registra como runner self-hosted com o label
`crava`. O reusable (Peça 3) começa pelo `pick-runner` (Peça 2), que decide o `runs-on`: se existe runner
`crava` online → usa ele (grátis); senão → `ubuntu-latest` (créditos GitHub). O repo (Peça 4) só aponta.

---

## 3. Peça 1 — infraestrutura do runner (Terraform)

> Vive em **`tinnovatech/terraform-modules`** → `modules/github-runner` (módulo genérico, versionado).
> Consumido pelo **`crava-infra`** via Terragrunt em `env/prd-899/github-runner/`.

### O que o módulo cria

- **Auto Scaling Group + Launch Template** (não é uma instância fixa — é gado, auto-curável).
- **Amazon Linux 2023**, **SSM Session Manager** (sem SSH, sem keypair, SG só egress).
- No boot (`user_data`): instala Docker + aws-cli + go-task, cria usuário `runner`, lê um **PAT** do
  **SSM Parameter Store (SecureString)**, gera um `registration-token` e registra o runner via `config.sh`.

### Decisões-chave (e por quê)

| Decisão | Por quê |
|---|---|
| **ASG** em vez de `aws_instance` | auto-heal: se a spot for interrompida, a ASG sobe outra na hora (instância fixa spot ficaria órfã) |
| **Spot diversificado** (`capacity_type: spot` + vários `instance_types`, `price-capacity-optimized`) | ~70% mais barato; diversificar pools torna indisponibilidade rara (é o "fallback" na prática). A estratégia `price-capacity-optimized` (recomendada AWS) prioriza o pool **mais barato** entre os de boa capacidade |
| **`runner_count`** (1..20) | escala N runners numa variável — cada instância registra 1 runner |
| **Nome sequencial** (`crava-prd-github-runner-01`, `-02`, …) | legível ao escalar; userdata pega o menor índice livre entre os online |
| **Scheduled scaling** (`aws_autoscaling_schedule`) | liga 08:00 / desliga 20:00 (America/Sao_Paulo) → fora do horário **0 instância = custo zero de compute** |
| **SSM, sem SSH** | acesso sem chave, auditável, SG fechado |
| **PAT em SSM SecureString** | segredo não fica no user_data nem no estado versionado |
| **Runner group `crava`** (org, `visibility: selected`) | restringe o runner aos repos crava (`crava-auth/web/app/infra`) — serve **todos os crava e só eles** |
| **LT por `latest_version`** | mudança no user_data altera a ASG e dispara `instance_refresh` (rollout automático) |

### Economia combinada

`spot (~70% off)` **×** `12h/dia (08-20)` ≈ **~85% mais barato** que uma t3.large on-demand 24/7.

### Como escalar / mexer

Editar o manifesto `crava-infra/manifests/prd/github-runner.yaml` (spec CRD) e `terragrunt apply`:

```yaml
spec:
  runner_count: 2            # 2 runners em paralelo
  capacity_type: "spot"      # ou "on-demand" p/ garantia dura
  spot_allocation_strategy: "price-capacity-optimized"  # prioriza pool mais barato c/ boa capacidade
  instance_types: ["t3.large","t3a.large","t2.large","m5a.large"]
  enable_schedule: true
  schedule_start_cron: "0 8 * * *"
  schedule_stop_cron:  "0 20 * * *"
  schedule_timezone: "America/Sao_Paulo"
```

---

## 4. Peça 2 — `pick-runner` (fallback)

Composite action **`tinnovatech/actions/pick-runner`**. Decide **onde** o pipeline roda.

- Consulta a API de runners da org procurando um runner **online** com o label dado.
- Tem runner → devolve `["self-hosted","linux","x64","<label>"]` (usado com `fromJSON` em `runs-on`).
- Não tem (ou sem PAT/label) → devolve `"ubuntu-latest"`.

| input | default | descrição |
|-------|---------|-----------|
| `label` | `""` | label do runner self-hosted (ex.: `crava`). Vazio = sempre `ubuntu-latest` |
| `org` | `tinnovatech` | org p/ consultar runners |
| `token` | `""` | PAT com permissão de listar runners da org |

**output:** `labels` (JSON p/ `runs-on` via `fromJSON`).

> **Por que é um job separado?** `runs-on` é avaliado antes dos steps rodarem. Então o picker precisa ser
> um **job** cuja saída alimenta o `runs-on` dos jobs seguintes — não dá pra decidir dentro do próprio job.
> A **lógica** mora no composite (1 arquivo); cada reusable só tem um job `pick-runner` de 4 linhas que o chama.

### Comportamento quando não há runner

`runs-on: [self-hosted, …]` **nunca** cai sozinho pro hosted — sem o picker, o job **fica na fila** (teto
24h, depois falha) e **não gasta crédito**. O `pick-runner` é o que dá o **fallback real** pro `ubuntu-latest`.

> Nuance: o job `pick-runner` roda no `ubuntu-latest` (segundos). Se a cota hosted estiver em **zero
> absoluto**, nem ele roda. Minutos resetam mensal e 10s é desprezível — na prática funciona.

---

## 5. Peça 3 — reusable `java-ecs-deploy`

**`tinnovatech/actions/.github/workflows/java-ecs-deploy.yml`** — o pipeline inteiro, parametrizado.

Jobs:

1. **`pick-runner`** — chama o composite (Peça 2) e exporta `labels`.
2. **`build-test`** (só em `pull_request`) — `runs-on` dinâmico; setup-java + gradle build + test (+sonar opcional). **Sem artifact.**
3. **`deploy`** (só em `push` a `develop`/`stage`/`main`) — `runs-on` dinâmico; `environment` por branch;
   builda o tar **no mesmo job** (sem `upload/download-artifact`), faz **OIDC login** e roda `deploy-ecs`.

Mapeamento de branch → ambiente/recursos:

| branch | env | cluster | service | tag |
|--------|-----|---------|---------|-----|
| `develop` | dev | `<cluster-prefix>-dev` | `<image-name>-dev-service` | `dev` |
| `stage` | qas | `<cluster-prefix>-qas` | `<image-name>-qas-service` | `qas` |
| `main` | prd | `<cluster-prefix>-prd` | `<image-name>-prd-service` | `prd` |

Inputs principais:

| input | default | descrição |
|-------|---------|-----------|
| `image-name` | — (obrigatório) | repo ECR + prefixo do service (ex.: `crava-auth`) |
| `dockerfile` | `Dockerfile` | caminho do Dockerfile |
| `java-version` | `21` | JDK (toolchain do projeto) |
| `gradle-build-args` | `clean build -x test -x ktlint… --no-daemon` | build |
| `aws-region` | `us-east-1` | |
| `runner-label` | `""` | label do runner self-hosted (`crava`). Vazio = sempre hosted |
| `runner-org` | `tinnovatech` | org p/ o picker |
| `cluster-prefix` | `crava` | `cluster = <prefix>-<env>` |
| `run-sonar` | `false` | roda SonarCloud no PR |

Secrets (via `secrets: inherit`): `RUNNERS_PAT` (picker), `AWS_OIDC_ROLE_ARN` (por environment), `SONAR_TOKEN`.

---

## 6. Peça 4 — o caller no repo

`crava-auth/.github/workflows/ci.yml` inteiro:

```yaml
name: ci
on:
  push:         { branches: [develop, stage, main] }
  pull_request: { branches: [develop, stage, main] }

permissions:
  contents: read
  id-token: write          # OIDC (o caller limita o que o reusable pode)

jobs:
  ci:
    uses: tinnovatech/actions/.github/workflows/java-ecs-deploy.yml@main
    with:
      image-name: crava-auth
      dockerfile: infra/Dockerfile
      java-version: "21"
      runner-label: crava
      cluster-prefix: crava
    secrets: inherit
```

Era 102 linhas de lógica inline. Virou **13 linhas** que só apontam. Toda a lógica está no reusable.

---

## 7. Fluxos

**Push em `main` (deploy prod), com runner online:**
```
push main → pick-runner (hosted, ~10s) → "tem runner crava" → deploy roda em crava-prd-github-runner-01
          → setup-java 21 → gradle build → OIDC login (conta prd) → deploy-ecs
          → docker build → push ECR 899 → ecs update-service --force-new-deployment → wait stable
```

**PR (build/test):**
```
PR → pick-runner → build-test roda no runner escolhido → gradle build + test (sem deploy)
```

**Fallback (runner desligado, ex.: fora do horário):**
```
push/PR → pick-runner → "sem runner crava" → runs-on = ubuntu-latest → roda no hosted (créditos GitHub)
```

---

## 8. Operação do dia a dia

Comandos na conta prod (899) — ver [seção 9](#9-contas-aws-e-acesso) pra obter credencial.

```bash
ASG=crava-prd-github-runner

# rodar algo à noite (fora da janela 08-20): sobe 1 runner sob demanda
aws autoscaling set-desired-capacity --auto-scaling-group-name $ASG --desired-capacity 1
# (o schedule das 20h zera de novo)

# escalar runners: editar runner_count no manifest + terragrunt apply

# acessar a instância (SSM, sem SSH)
aws ssm start-session --target "$(aws ec2 describe-instances \
  --filters "Name=tag:aws:autoscaling:groupName,Values=$ASG" "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)"

# ver runners registrados no GitHub
gh api orgs/tinnovatech/actions/runners --jq '.runners[]|select(.name|startswith("crava"))|"\(.name) \(.status)"'
```

- **Interrupção de spot:** a ASG lança outra instância (novo runner com o mesmo `-0N`); a antiga fica
  `offline` no GitHub (removida automaticamente após ~14 dias). Um job que estava rodando na spot
  interrompida **falha** e precisa de re-run; jobs na fila pegam a nova.
- **Job disparado sem runner** (fora do horário) → o `pick-runner` manda pro `ubuntu-latest` (crédito).

---

## 9. Contas AWS e acesso

| Ambiente | Conta | Como acessa |
|---|---|---|
| dev / qas | `876225478379` (cravabrasil) | SSO direto `cravabrasil/AdministratorAccess` |
| **prd (runner mora aqui)** | `899147036200` | **assume-role** (sem SSO direto) |
| management/payer | `343866288744` | SSO `PowerUserAccess` |

A conta prod `899` não tem SSO direto pro usuário. Acesso via `OrganizationAccountAccessRole` a partir da
management (343, PowerUserAccess). No `crava-infra` há o script `crava-auth/scripts/prd-assume.sh` que
exporta as credenciais temporárias da 899.

O **deploy via OIDC** funciona no runner self-hosted normalmente — o token OIDC vem do GitHub, não da EC2.
O runner **não** precisa de credencial AWS estática pro deploy (o `aws-oidc-login` assume a role por env).

---

## 10. Adotar num repo novo

Para um serviço Java/Gradle que deploya em ECS:

1. **Runner** (uma vez por "família" de repos): garantir um runner self-hosted com o label desejado e o
   runner group da org restrito aos repos certos (via `terraform-modules/github-runner`). Se o serviço já
   é da família `crava`, o runner `crava` já atende.
2. **Secret `RUNNERS_PAT`** no repo (ou org): PAT com permissão de listar runners da org (pro picker).
   ```bash
   echo "$PAT" | gh secret set RUNNERS_PAT --repo tinnovatech/<repo>
   ```
3. **Environments** `dev`/`qas`/`prd` no repo, cada um com o secret `AWS_OIDC_ROLE_ARN` da conta certa.
4. **OIDC role** por conta confiando no repo (ver seção OIDC do README principal).
5. **Caller** `.github/workflows/ci.yml` (o de 13 linhas da [seção 6](#6-peça-4--o-caller-no-repo)),
   ajustando `image-name`, `dockerfile`, `runner-label`, `cluster-prefix`.

Pronto. Nada de lógica no repo.

---

## 11. Troubleshooting (lições aprendidas)

| Sintoma | Causa | Correção |
|---|---|---|
| `Cannot find a Java installation matching {languageVersion=21}` | workflow usava JDK 17, projeto exige 21 (`build.gradle`) | `java-version: "21"` (no ubuntu-latest funcionava por acaso — a imagem já tinha 21) |
| `Artifact storage quota has been hit` | deploy passava o build via `upload/download-artifact` | deploy **self-contained**: builda o tar no próprio job, sem artifact |
| `install: cannot create '/usr/local/bin/task': Permission denied` | runner roda como usuário não-root; actions instalam binários em `/usr/local/bin` | userdata dá sudo NOPASSWD + `/usr/local/bin` gravável + pré-instala `go-task` |
| Job fica **queued** e nunca roda | `runs-on: [self-hosted,…]` sem runner online; GitHub não cai sozinho pro hosted | usar o `pick-runner` (fallback pro `ubuntu-latest`) |
| Mudei o `user_data` mas a instância não trocou | ASG referenciava `$Latest` do LT (o recurso ASG não "mudava") | referenciar `latest_version` → altera a ASG → dispara `instance_refresh` |
| `Unexpected symbol: '...'` ao carregar o composite | descrição de output com `${{ … }}` literal (o GitHub avalia) | texto puro na `description`; `${{ }}` só no `value` |
| Runner nomeado por IP (`…-ip-10-0-10-247`) | userdata usava `hostname` | nome sequencial `-01/-02` (menor índice livre entre os online) |

---

**Repos envolvidos:**
`tinnovatech/actions` (este) · `tinnovatech/terraform-modules` (módulo `github-runner`) ·
`crava-infra` (terragrunt `env/prd-899/github-runner`) · `crava-auth` (caller).
