#!/usr/bin/env bash
set -uo pipefail

PASS=0; FAIL=0

check() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$actual" == "$expected" ]]; then
        echo "  [OK]   $desc"; ((PASS++))
    else
        echo "  [FAIL] $desc (ожидалось: '$expected', получено: '$actual')"; ((FAIL++))
    fi
}

echo "Аудит конфигурации: $(hostname -f), $(date '+%Y-%m-%d %H:%M')"

echo "[1] Служба SSH"
check "Вход от имени root запрещён"        "no"  "$(sudo sshd -T | awk '/^permitrootlogin/{print $2}')"
check "Парольная аутентификация отключена" "no"  "$(sudo sshd -T | awk '/^passwordauthentication/{print $2}')"
# TODO 1: значение параметра port отлично от 22
SSH_PORT="$(sudo sshd -T | awk '/^port /{print $2}' | head -n 1)"
check "Порт SSH отличен от 22 (port=$SSH_PORT)" "yes" "$([[ -n "$SSH_PORT" && "$SSH_PORT" != "22" ]] && echo yes || echo no)"
# TODO 2: значение параметра maxauthtries равно 3
check "MaxAuthTries равно 3"               "3"   "$(sudo sshd -T | awk '/^maxauthtries/{print $2}')"

echo "[2] Межсетевой экран"
check "Межсетевой экран активен" "active" "$(sudo ufw status | awk '/^Status:/{print $2}')"
# TODO 3: политика по умолчанию для входящего трафика равна deny
#         источник данных: sudo ufw status verbose | grep Default
check "Входящий трафик по умолчанию запрещён" "deny" "$(sudo ufw status verbose | awk '/^Default:/{print $2}')"

echo "[3] Учётные записи"
awk -F: '$3>=1000 && $3<65534 {printf "    %s (uid=%s)\n",$1,$3}' /etc/passwd

echo "[4] Веб-сервер"
CERT=/etc/ssl/certs/devops.crt
CERT_MIN_DAYS="${CERT_MIN_DAYS:-30}"
check "Служба nginx активна" "active" "$(systemctl is-active nginx 2>/dev/null)"
check "Конфигурация nginx корректна" "0" "$(sudo nginx -t >/dev/null 2>&1; echo $?)"
check "Сертификат действителен ещё ${CERT_MIN_DAYS} дн." "0" \
      "$(sudo openssl x509 -in "$CERT" -noout -checkend $((CERT_MIN_DAYS * 86400)) >/dev/null 2>&1; echo $?)"
WW="$(sudo find /var/www/devops-site -perm -o+w | wc -l)"
check "Нет файлов ресурса с записью для всех; ключ 600" "0 600" \
      "${WW} $(sudo stat -c '%a' /etc/ssl/private/devops.key)"

echo "[5] Контейнеризация"
APP_DIR="${APP_DIR:-/home/devops/app}"
check "Служба docker активна" "active" "$(systemctl is-active docker 2>/dev/null)"
check "Контейнер СУБД в состоянии healthy" "healthy" \
      "$(sudo docker inspect -f '{{.State.Health.Status}}' app-db-1 2>/dev/null)"
EXPOSED="$(sudo ss -tlnH | awk '{print $4}' | grep -E ':(5000|5432)$' | grep -v '^127\.0\.0\.1:' | sort -u | tr '\n' ' ' | sed 's/ $//')"
check "Порты 5000 и 5432 прослушиваются только на 127.0.0.1" "" "$EXPOSED"
check "Права файла ${APP_DIR}/.env равны 600" "600" "$(sudo stat -c '%a' "${APP_DIR}/.env" 2>/dev/null)"

echo "Пройдено: $PASS, не пройдено: $FAIL"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
