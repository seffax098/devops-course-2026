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

## 7. Доменное имя

- Хост (Windows): `C:\Windows\System32\drivers\etc\hosts` — `192.168.109.101   devops.local`.
- Сервер: `/etc/hosts` — `127.0.1.1 devops-vm.devops.local devops-vm`; `hostname -f` → `devops-vm.devops.local`.

## 8. Снимки состояния

| Снимок | Момент создания | Состояние |
|---|---|---|
| 01-clean-install | 20.10.2026 13:20 | чистая установка, `apt upgrade`, ВМ выключена |
| 02-keys-configured | 20.10.2026 14:06 | пользователь devops в группе sudo, ключевая аутентификация, `~/.ssh/config` |
| 03-ssh-hardened | 20.10.2026 14:11 | 99-hardening.conf, порт 2222, ssh.service, проброс 2222→2222 |

## 9. Контроль

`scripts/audit.sh` — 6 проверок (root, пароли, порт ≠ 22, MaxAuthTries = 3, UFW активен, deny incoming);
код возврата 0 — все проверки пройдены, 1 — есть нарушения.
