# Padrão de Ambientes — Tinnova (dev / qas / prd)

Padrão **obrigatório** para todo projeto deployável da org. Um branch por ambiente,
um GitHub Environment por ambiente, secrets escopados por ambiente.

## Modelo branch → environment

| Branch    | Environment | Uso                        |
|-----------|-------------|----------------------------|
| `develop` | `dev`       | Integração / desenvolvimento (branch de entrada / default) |
| `stage`   | `qas`       | Homologação / QA           |
| `main`    | `prd`       | Produção (protegida, PR-only) |

`feature/*`, `hotfix/*` e qualquer outro branch → `dev`.

O mapeamento é **centralizado nos workflows reutilizáveis** (`tinnovatech/actions@v1`):
o app **não** escreve essa lógica. Todos os reusable workflows de deploy derivam o
environment do branch quando o caller não passa `environment` explícito:

- `node-frontend-s3-cf.yml` — job `resolve` deriva o env e expõe `DEPLOY_ENV` pro build (`--mode $DEPLOY_ENV`).
- `go-lambda.yml`, `serverless-deploy.yml`, `k8s-apply.yml`, `terraform-terragrunt.yml` — env derivado como fallback.

Serviços com ci.yml próprio (ex: `crava-auth`, que roda ECS em contas diferentes) usam a
mesma expressão 3-way:

```yaml
environment: ${{ github.ref_name == 'main' && 'prd' || github.ref_name == 'stage' && 'qas' || 'dev' }}
```

## Checklist para deixar um repo no padrão

Por repo deployável:

1. **Branches**: `develop`, `stage`, `main` (main protegida, PR-only).
2. **GitHub Environments**: `dev`, `qas`, `prd`.
3. **Secrets por environment** (mesmos nomes nos 3, valores por ambiente):
   - Frontend S3+CF: `AWS_OIDC_ROLE_ARN`, `S3_BUCKET`, `CF_DISTRIBUTION_ID`
   - Backend ECS/Lambda/K8s: `AWS_OIDC_ROLE_ARN` (+ o que o composite exigir)
4. **ci.yml triggers**: `on.push.branches: [develop, stage, main]`.
5. **Infra qas existe** na AWS: bucket/CF (front) ou cluster/service (back) + role OIDC
   que confie no repo (`repo:tinnovatech/<repo>:*`).

> **Regra de segurança:** só ligar `stage`/`qas` num repo depois que a infra qas existir.
> Environment `qas` sem secrets, ou secrets apontando pra infra inexistente, **quebra o deploy**.

## OIDC (por que `stage` já funciona sem mexer no IAM)

Os roles OIDC do GitHub Actions confiam em `token.actions.githubusercontent.com:sub =
repo:tinnovatech/<repo>:*`. O `:*` no fim aceita **qualquer ref** (branch/tag/environment),
então `stage` assume o role sem mudança de trust policy. Se um role for restrito a refs
específicas, incluir `refs/heads/stage`.

## Rollout

Use `scripts/standardize-repo.sh` (neste repo) para levar um repo ao padrão de uma vez:
cria branch `stage`, cria environment `qas`, seta os secrets e ajusta triggers.

```bash
# exemplo (frontend)
scripts/standardize-repo.sh \
  --repo tinnovatech/tamoios-front --type frontend \
  --qas-role  arn:aws:iam::<acct>:role/<qas-oidc-role> \
  --qas-bucket <bucket-qas> --qas-cf <cf-dist-id-qas> \
  --qas-url https://<qas-domain> --marker '<title>Tamoios'
```

## Estado atual (auditoria 2026-07-07)

Conformes: `crava-web`, `crava-auth`.
Pendentes (falta qas + stage): aptalog-frontend, cpf-contabil-terms-and-conditions,
crava-infra, iplanrio-{card-register,conciliation,monitoring-portal},
{recover,store,delete}-token-function-go-lang, sls-api-uappi, tamoios-front,
taxes-embras-{checkout,conciliation}, test-checkout.

Cada pendente precisa da **infra qas do respectivo cliente** antes do rollout.
