#!/usr/bin/env bash
# Destroi as 3 camadas na ordem inversa da criação: service -> infra -> bootstrap.
# Precisa rodar local, com credenciais AWS que tenham permissão nas 3 camadas.
set -euo pipefail

cd "$(dirname "$0")"

echo "== service =="
(cd service && terraform init -input=false && terraform destroy -auto-approve)

echo
echo "== infra =="
(cd infra && terraform init -input=false && terraform destroy -auto-approve)

echo
echo "Falta bootstrap/ (bucket de state, OIDC provider, tf-role, ecr-role)."
echo "Se iac/bootstrap/state.tf ainda tiver 'prevent_destroy = true' no aws_s3_bucket,"
echo "o destroy vai falhar nesse recurso -- remova essa lifecycle antes de continuar."
read -r -p "Destruir bootstrap/ agora? [y/N] " confirm
if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
  (cd bootstrap && terraform init -input=false && terraform destroy -auto-approve)
else
  echo "bootstrap/ não foi destruído. Rode manualmente quando quiser: cd bootstrap && terraform destroy"
fi
