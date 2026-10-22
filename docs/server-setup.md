# Конфигурация виртуальной машины devops-vm

Ubuntu Server 24.04.5 LTS, гипервизор Oracle VirtualBox 7.x (хост — Windows).
Документ позволяет восстановить конфигурацию после отката на снимок `01-clean-install`.

## 1. Параметры машины

| Параметр | Значение |
|---|---|
| Имя ВМ / имя узла | devops-vm (FQDN `devops-vm.devops.local`) |
| Тип | Linux / Ubuntu (64-bit) |
| Оперативная память | 2048 МБ |
| Процессоры | 2 ядра |
| Диск | 25 ГБ, VDI, динамически расширяемый |
| Установка | Ubuntu Server (не minimized), Use an entire disk (LVM), OpenSSH server, без snaps |

## 2. Сетевые интерфейсы

| Адаптер ВМ | Интерфейс | Тип VirtualBox | Адрес | Назначение |
|---|---|---|---|---|
| Адаптер 1 | enp0s3 | NAT | 10.0.2.15/24 (DHCP) | выход в Интернет (репозитории пакетов), SSH через проброс порта |
| Адаптер 2 | enp0s8 | Host-only, `VirtualBox Host-Only Ethernet Adapter #2` (хост 192.168.109.1/24, DHCP 192.168.109.101–254) | 192.168.109.101/24 (DHCP) | прямой доступ с хоста: веб-сервер (ПР №6), имя devops.local |

Примечание: исходный адаптер `VirtualBox Host-Only Ethernet Adapter` (192.168.56.1) на хосте неработоспособен
(ошибка `VERR_INTNET_FLT_IF_NOT_FOUND` при запуске ВМ), поэтому создан адаптер #2 с подсетью 192.168.109.0/24.

## 3. Правило проброса портов

| Имя | Протокол | Адрес хоста | Порт хоста | Адрес гостя | Порт гостя |
|---|---|---|---|---|---|
| ssh | TCP | 127.0.0.1 | 2222 | — | 2222 (до задания 2 — 22) |

## 4. Учётные записи

| Имя | UID | Группы | Аутентификация |
|---|---|---|---|
| student | 1000 | student, sudo (администратор, созданный установщиком) | пароль (только локальная консоль; по SSH вход запрещён `AllowUsers devops`) |
| devops | 1001 | devops, sudo, users | только ключ ED25519 `~/.ssh/devops_vm` (хост) → `/home/devops/.ssh/authorized_keys` (права 700/600) |

Создание:

```bash
sudo adduser devops
sudo usermod -aG sudo devops
# с хоста (без BOM!):
ssh-keygen -t ed25519 -C "devops-vm-key" -f ~/.ssh/devops_vm
ssh-copy-id -i ~/.ssh/devops_vm.pub -p 2222 devops@127.0.0.1
```

`~/.ssh/config` на хосте:

```
Host devops
    HostName 127.0.0.1
    Port 2222
    User devops
    IdentityFile ~/.ssh/devops_vm
    IdentitiesOnly yes

Host devops.local
    HostName devops.local
    Port 2222
    User devops
    IdentityFile ~/.ssh/devops_vm
    IdentitiesOnly yes
```

## 5. Служба SSH

Файл: `/etc/ssh/sshd_config.d/99-hardening.conf` (основной `sshd_config` не изменяется, копия — `/etc/ssh/sshd_config.backup`).

```
Port 2222
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
PermitEmptyPasswords no
MaxAuthTries 3
LoginGraceTime 30
AllowUsers devops
X11Forwarding no
ClientAliveInterval 300
ClientAliveCountMax 2
```

Дополнительно:

- в `/etc/ssh/sshd_config.d/50-cloud-init.conf` закомментирована строка `PasswordAuthentication yes`
  (иначе она, как первая встреченная, перекрывает значение из 99-hardening.conf);
- активация по сокету отключена: `sudo systemctl disable --now ssh.socket && sudo systemctl enable --now ssh.service && sudo systemctl restart ssh`;
- проверка: `sudo sshd -t`, `sudo sshd -T | grep -Ei "^(port|permitrootlogin|passwordauthentication|maxauthtries|allowusers)"`,
  `sudo ss -tlnp | grep sshd` → `0.0.0.0:2222`.

## 6. Правила межсетевого экрана (UFW)

```bash
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw limit 2222/tcp comment 'SSH rate-limited'
sudo ufw allow 80/tcp  comment 'HTTP'
sudo ufw allow 443/tcp comment 'HTTPS'
sudo ufw logging medium
sudo ufw enable
```

Итог (`sudo ufw status verbose`): Status active; Logging on (medium); Default: deny (incoming), allow (outgoing),
disabled (routed); правила: 80/tcp ALLOW IN, 443/tcp ALLOW IN, 2222/tcp LIMIT IN (IPv4 и IPv6).

## 7. Снимки состояния

| Снимок | Момент создания | Состояние |
|---|---|---|
| 01-clean-install | 20.10.2026 13:20 | чистая установка, `apt upgrade`, ВМ выключена |
| 02-keys-configured | 20.10.2026 14:06 | пользователь devops в группе sudo, ключевая аутентификация, `~/.ssh/config` |
| 03-ssh-hardened | 20.10.2026 14:11 | 99-hardening.conf, порт 2222, ssh.service, проброс 2222→2222 |
| 04-nginx-https | 20.10.2026 | ПР6: nginx, ресурс devops-site, HTTPS с самоподписанным сертификатом, перенаправление HTTP → HTTPS |
| 05-docker-compose | 22.10.2026 | ПР7: Docker Engine, проект ~/app (приложение + PostgreSQL) в docker compose |

## 8. Веб-сервер

| Параметр | Значение |
|---|---|
| Пакет | `nginx` (Ubuntu 24.04, nginx/1.24.0), служба `nginx.service`, enabled |
| Процессы | главный — `root`, рабочие — `www-data` |
| Конфигурация ресурса | `/etc/nginx/sites-available/devops-site`, ссылка в `/etc/nginx/sites-enabled/`; стандартный `default` отключён (ссылка удалена, файл сохранён) |
| Каталог ресурса | `/var/www/devops-site`, владелец `devops:devops`, каталоги `755`, файлы `644` (доставка `scripts/deploy.sh`, rsync `--chmod=D755,F644`) |
| Сертификат | `/etc/ssl/certs/devops.crt`, `root:root`, `644`; CN и SAN `DNS:devops.local`; срок действия 365 дней (до 20.10.2027) |
| Закрытый ключ | `/etc/ssl/private/devops.key`, `root:root`, `600` (читает только главный процесс) |
| Журналы | `/var/log/nginx/devops-site.access.log`, `/var/log/nginx/devops-site.error.log` |

Формирование сертификата:

```bash
sudo openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout /etc/ssl/private/devops.key \
  -out /etc/ssl/certs/devops.crt \
  -subj "/CN=devops.local" \
  -addext "subjectAltName=DNS:devops.local"
```

Создание каталога ресурса:

```bash
sudo mkdir -p /var/www/devops-site
sudo chown -R devops:devops /var/www/devops-site
```

`/etc/nginx/sites-available/devops-site`:

```nginx
server {
    listen 80;
    listen [::]:80;
    server_name devops.local;
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name devops.local;

    ssl_certificate     /etc/ssl/certs/devops.crt;
    ssl_certificate_key /etc/ssl/private/devops.key;
    ssl_protocols       TLSv1.2 TLSv1.3;

    root /var/www/devops-site;
    index index.html;

    location / {
        try_files $uri $uri/ =404;
    }

    error_page 404 /404.html;

    access_log /var/log/nginx/devops-site.access.log;
    error_log  /var/log/nginx/devops-site.error.log;
}
```

Применение:

```bash
sudo ln -s /etc/nginx/sites-available/devops-site /etc/nginx/sites-enabled/
sudo rm /etc/nginx/sites-enabled/default
sudo nginx -t && sudo systemctl reload nginx
```

Клиент (хост, WSL): сертификат скопирован в `~/devops.crt` (`scp devops:/etc/ssl/certs/devops.crt ~/devops.crt`), доставка содержимого — `scripts/deploy.sh`.

## 9. Контейнеризация

| Параметр | Значение |
|---|---|
| Docker Engine | из официального репозитория `download.docker.com` (пакеты `docker-ce`, `docker-ce-cli`, `containerd.io`, `docker-buildx-plugin`, `docker-compose-plugin`), версия 29.9.2, Compose v5.6.1; пакет `docker.io` не используется |
| Группа `docker` | `devops` (единственный участник; учётная запись имеет право sudo — участник группы docker фактически получает права root) |
| Проект | `/home/devops/app` (`~/app`), доставляется с хоста: `rsync -avz --delete --exclude=.env app/ devops:app/`; имя проекта Compose — `app` |
| Сервисы | `app` — образ `devops-app:1.0` (python:3.12-slim, пользователь `app`, gunicorn на 0.0.0.0:5000 внутри контейнера); `db` — `postgres:16-alpine`, healthcheck `pg_isready` |
| Файл `.env` | `/home/devops/app/.env`, владелец `devops`, права `600`; создаётся только на сервере из `.env.example`, пароль — `openssl rand -hex 16`; в репозиторий не добавляется (`.gitignore`) |
| Публикуемые порты | `127.0.0.1:5000` → `app:5000`; порт СУБД 5432 не публикуется |
| Сеть | `app_backend` (bridge), имя `db` разрешается встроенным DNS Docker |
| Именованный том | `app_db_data` → `/var/lib/postgresql/data` |

Установка Docker Engine:

```bash
for pkg in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc; do sudo apt-get remove -y $pkg; done
sudo apt-get update && sudo apt-get install -y ca-certificates curl
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}") stable" | sudo tee /etc/apt/sources.list.d/docker.list
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo usermod -aG docker devops      # затем новая SSH-сессия
```
Развёртывание проекта:

```bash
# хост
rsync -avz --delete --exclude=.env app/ devops:app/
# сервер
cd ~/app
cp .env.example .env && chmod 600 .env
sed -i "s/^POSTGRES_PASSWORD=.*/POSTGRES_PASSWORD=$(openssl rand -hex 16)/" .env
docker compose up -d --build
docker compose ps        # db — (healthy)
```

Обратный прокси — в блоке `server` для `listen 443 ssl` файла `/etc/nginx/sites-available/devops-site` перед `error_page`:

```nginx
    location /app/ {
        proxy_pass http://127.0.0.1:5000/;
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
```

Применение: `sudo nginx -t && sudo systemctl reload nginx`. Приложение доступно по `https://devops.local/app/`, статический ресурс `https://devops.local/` сохраняется.

## 10. Доменное имя

- Хост (Windows): `C:\Windows\System32\drivers\etc\hosts` — `192.168.109.101   devops.local`.
- Сервер: `/etc/hosts` — `127.0.1.1 devops-vm.devops.local devops-vm`; `hostname -f` → `devops-vm.devops.local`.

## 11. Контроль

`scripts/audit.sh` — 14 проверок: SSH (root, пароли, порт ≠ 22, MaxAuthTries = 3), UFW (активен, deny incoming), веб-сервер (nginx активен, `nginx -t`, срок сертификата ≥ 30 дн., нет файлов с записью для всех и права ключа 600), контейнеризация (docker активен, СУБД healthy, порты 5000/5432 только на 127.0.0.1, права `~/app/.env` 600);
код возврата 0 — все проверки пройдены, 1 — есть нарушения.
