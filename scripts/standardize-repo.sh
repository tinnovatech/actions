#!/usr/bin/env bash
# Leva um repo ao padrao de ambientes dev/qas/prd (ver ENVIRONMENTS.md).
# Cria branch `stage`, environment `qas`, seta secrets do qas e ajusta triggers do ci.yml.
# Idempotente. NAO cria infra AWS — a infra qas (bucket/CF ou cluster/service + role) deve existir antes.
#
# Uso:
#   frontend: standardize-repo.sh --repo tinnovatech/<r> --type frontend \
#               --qas-role <arn> --qas-bucket <b> --qas-cf <id> [--qas-url <url> --marker <m>]
#   ecs:      standardize-repo.sh --repo tinnovatech/<r> --type ecs \
#               --qas-role <arn>   (cluster/service derivados no ci.yml do repo)
#
# Requer: gh autenticado com escopo repo+admin na org (GH_TOKEN).
set -euo pipefail

REPO=""; TYPE=""; QAS_ROLE=""; QAS_BUCKET=""; QAS_CF=""; QAS_URL=""; MARKER=""
while [ $# -gt 0 ]; do case "$1" in
  --repo) REPO="$2"; shift 2;;
  --type) TYPE="$2"; shift 2;;
  --qas-role) QAS_ROLE="$2"; shift 2;;
  --qas-bucket) QAS_BUCKET="$2"; shift 2;;
  --qas-cf) QAS_CF="$2"; shift 2;;
  --qas-url) QAS_URL="$2"; shift 2;;
  --marker) MARKER="$2"; shift 2;;
  *) echo "arg desconhecido: $1"; exit 1;;
esac; done
[ -n "$REPO" ] && [ -n "$TYPE" ] && [ -n "$QAS_ROLE" ] || { echo "faltam --repo/--type/--qas-role"; exit 1; }
: "${GH_TOKEN:?exporte GH_TOKEN (pass show tinnova/github/token)}"

echo "==> [$REPO] 1. environment qas + secrets"
gh api -X PUT "repos/$REPO/environments/qas" --silent
printf '%s' "$QAS_ROLE" | gh secret set AWS_OIDC_ROLE_ARN --env qas --repo "$REPO"
if [ "$TYPE" = "frontend" ]; then
  [ -n "$QAS_BUCKET" ] && printf '%s' "$QAS_BUCKET" | gh secret set S3_BUCKET --env qas --repo "$REPO"
  [ -n "$QAS_CF" ]     && printf '%s' "$QAS_CF"     | gh secret set CF_DISTRIBUTION_ID --env qas --repo "$REPO"
  if [ -n "$QAS_URL" ]; then
    gh variable set SMOKE_URL --env qas --repo "$REPO" --body "$QAS_URL"
    [ -n "$MARKER" ] && gh variable set SMOKE_MARKER --env qas --repo "$REPO" --body "$MARKER"
  fi
fi

echo "==> [$REPO] 2. branch stage (a partir de develop)"
if gh api "repos/$REPO/git/refs/heads/stage" >/dev/null 2>&1; then
  echo "    stage ja existe"
else
  DEV=$(gh api "repos/$REPO/git/refs/heads/develop" --jq .object.sha)
  gh api -X POST "repos/$REPO/git/refs" -f ref="refs/heads/stage" -f sha="$DEV" --silent
  echo "    stage criada"
fi

echo "==> [$REPO] 3. triggers do ci.yml (develop -> add stage)"
for br in develop stage; do
  raw=$(gh api "repos/$REPO/contents/.github/workflows/ci.yml?ref=$br" --jq .content 2>/dev/null | base64 -d 2>/dev/null || true)
  [ -n "$raw" ] || { echo "    ($br) sem ci.yml"; continue; }
  if printf '%s' "$raw" | grep -q "stage"; then echo "    ($br) ja tem stage"; continue; fi
  new=$(printf '%s' "$raw" | sed -E 's/\[develop, ?main\]/[develop, stage, main]/g')
  if [ "$new" = "$raw" ]; then echo "    ($br) trigger nao casou padrao [develop, main] — ajuste manual"; continue; fi
  sha=$(gh api "repos/$REPO/contents/.github/workflows/ci.yml?ref=$br" --jq .sha)
  printf '%s' "$new" | base64 | tr -d '\n' > /tmp/_ci.b64
  gh api -X PUT "repos/$REPO/contents/.github/workflows/ci.yml" \
    -f message="ci: add stage->qas ao trigger (padrao de ambientes)" \
    -f content="$(cat /tmp/_ci.b64)" -f sha="$sha" -f branch="$br" --silent
  echo "    ($br) trigger atualizado"
done
echo "==> [$REPO] OK. Confira um push em stage e o run em Actions."
