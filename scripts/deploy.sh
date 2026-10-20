#!/usr/bin/env bash
# Доставка статического ресурса на devops-vm
# Использование: scripts/deploy.sh [--dry-run]
set -euo pipefail

REMOTE="devops"                      # псевдоним из ~/.ssh/config (ПР № 5, шаг 1.6)
REMOTE_DIR="/var/www/devops-site"
SITE_URL="https://devops.local"
CA_CERT="${HOME}/devops.crt"
# корень репозитория определяется по расположению сценария — запуск из любого каталога
REPO_ROOT="$(git -C "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" rev-parse --show-toplevel)"
LOCAL_DIR="${REPO_ROOT}/site/"
SSH_CMD="ssh -o BatchMode=yes -o ConnectTimeout=5"   # без интерактивного запроса пароля

die() { echo "deploy: ОШИБКА: $*" >&2; exit 1; }

# 1. Разбор аргумента --dry-run
DRY_RUN=0
case "${1:-}" in
    "")         ;;
    --dry-run)  DRY_RUN=1 ;;
    *)          echo "Использование: $0 [--dry-run]" >&2; exit 2 ;;
esac

# 2. Проверки по требованиям 4 и 5
[[ -f "${LOCAL_DIR}index.html" ]] || die "нет файла site/index.html — доставка не выполняется"
if [[ -n "$(git -C "$REPO_ROOT" status --porcelain)" ]]; then
    git -C "$REPO_ROOT" status --short >&2
    die "в репозитории есть незафиксированные изменения — доставка не выполняется"
fi
COMMIT="$(git -C "$REPO_ROOT" rev-parse --short HEAD)"

# 3. Синхронизация: точная копия site/ с правами 755/644, одно SSH-соединение
RSYNC_OPTS=(-avz --delete --chmod=D755,F644 -e "$SSH_CMD")
(( DRY_RUN )) && RSYNC_OPTS+=(--dry-run)
rsync "${RSYNC_OPTS[@]}" "$LOCAL_DIR" "${REMOTE}:${REMOTE_DIR}/" || die "rsync завершился с ошибкой"

# 4. При --dry-run — завершение без проверки доступности
if (( DRY_RUN )); then
    echo "deploy: пробный запуск, коммит ${COMMIT}; сервер не изменялся"
    exit 0
fi

# 5. Проверка доступности с проверкой сертификата (без -k)
[[ -r "$CA_CERT" ]] || die "нет сертификата ${CA_CERT}"
if ! curl -fsS --cacert "$CA_CERT" --max-time 10 -o /dev/null "${SITE_URL}/"; then
    die "ресурс ${SITE_URL} недоступен после синхронизации (коммит ${COMMIT})"
fi
echo "deploy: доставлен коммит ${COMMIT}, ${SITE_URL} доступен"
