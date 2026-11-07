#!/usr/bin/env bash
# Remnawave node + nginx self-steal.
# Xray (Reality) слушает 443 и для чужих клиентов проксирует на собственный nginx: target = 127.0.0.1:8443.
#
# Запуск (домен и SECRET_KEY скрипт спросит сам):
#   sudo bash setup-node.sh
# Или сразу параметрами:
#   sudo bash setup-node.sh -d node1.example.com -k 'eyJub2Rl...'  [-e me@mail.com] [-p 2222] [-y]
# Без вопросов вообще (для программы-установщика): все параметры + -y, или через переменные окружения
#   DOMAIN, SECRET_KEY, EMAIL, NODE_PORT, ASSUME_YES=1.
set -euo pipefail

DOMAIN="${DOMAIN:-}"
SECRET_KEY="${SECRET_KEY:-}"
EMAIL="${EMAIL:-}"
NODE_PORT="${NODE_PORT:-2222}"
ASSUME_YES="${ASSUME_YES:-0}"
SITE_PORT=8443
NODE_DIR="/opt/remnanode"

log()  { echo -e "\e[1;32m[+]\e[0m $*"; }
warn() { echo -e "\e[1;33m[!]\e[0m $*"; }
die()  { echo -e "\e[1;31m[x]\e[0m $*" >&2; exit 1; }

usage() {
  cat <<EOF
Использование: sudo bash $0 [-d домен] [-k SECRET_KEY] [-e email] [-p NODE_PORT] [-y]
  -d  домен ноды (A-запись на IP этого сервера, в Cloudflare — серое облако)
  -k  SECRET_KEY из панели Remnawave (Nodes → нода → docker-compose.yml)
  -e  почта для Let's Encrypt (необязательно)
  -p  NODE_PORT, по умолчанию 2222
  -y  ничего не спрашивать: на предупреждения отвечать «да»
Чего нет в параметрах, скрипт спросит интерактивно.
EOF
  exit 0
}

while getopts ":d:k:e:p:yh" opt; do
  case "$opt" in
    d) DOMAIN="$OPTARG" ;;
    k) SECRET_KEY="$OPTARG" ;;
    e) EMAIL="$OPTARG" ;;
    p) NODE_PORT="$OPTARG" ;;
    y) ASSUME_YES=1 ;;
    h) usage ;;
    :) die "Ключ -$OPTARG требует значение" ;;
    *) die "Неизвестный ключ -$OPTARG (см. -h)" ;;
  esac
done

[[ $EUID -eq 0 ]] || die "Запусти от root: sudo bash $0"
command -v apt-get >/dev/null || die "Скрипт рассчитан на Debian/Ubuntu (apt)"

# ---------------------------------------------------------------- 0. Ввод параметров
# Читаем из /dev/tty, чтобы работало и при запуске через curl | bash.
# read -e (readline) не упирается в лимит длины строки терминала, ключ бывает длинный.
has_tty() { { : </dev/tty; } 2>/dev/null; }
ask() {
  local __var="$1" __prompt="$2" __val
  has_tty || die "Нет терминала, чтобы спросить: ${__prompt%: }. Передай значение параметром (см. -h)"
  read -e -r -p "$__prompt" __val </dev/tty
  printf -v "$__var" '%s' "$__val"
}

while [[ -z "$DOMAIN" ]]; do ask DOMAIN "Домен ноды (например, node1.example.com): "; done
DOMAIN="${DOMAIN,,}"
DOMAIN="${DOMAIN#http://}"; DOMAIN="${DOMAIN#https://}"; DOMAIN="${DOMAIN%%/*}"
[[ "$DOMAIN" =~ ^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}$ ]] || die "Некорректный домен: $DOMAIN"

while [[ -z "$SECRET_KEY" ]]; do ask SECRET_KEY "SECRET_KEY из панели: "; done
# Принимаем и голый ключ, и строку целиком вида  - SECRET_KEY="..."
SECRET_KEY="$(printf '%s' "$SECRET_KEY" | tr -d ' \r\n\t')"
SECRET_KEY="${SECRET_KEY#-}"; SECRET_KEY="${SECRET_KEY#SECRET_KEY=}"
SECRET_KEY="${SECRET_KEY#\"}"; SECRET_KEY="${SECRET_KEY%\"}"
SECRET_KEY="${SECRET_KEY#\'}"; SECRET_KEY="${SECRET_KEY%\'}"
printf '%s' "$SECRET_KEY" | base64 -d 2>/dev/null | grep -q '"nodeCertPem"' \
  || die "Это не похоже на SECRET_KEY Remnawave: ключ должен быть base64 с полем nodeCertPem"

[[ "$NODE_PORT" =~ ^[0-9]+$ ]] || die "NODE_PORT должен быть числом"

WEBROOT="/var/www/${DOMAIN}"
NGX_CONF="/etc/nginx/sites-available/${DOMAIN}.conf"
CERT_DIR="/etc/letsencrypt/live/${DOMAIN}"

# ---------------------------------------------------------------- 1. Пакеты
# Lock::Timeout: если apt занят (например, автообновлениями), ждём освобождения блокировки до 10 минут.
APT=(apt-get -y -o DPkg::Lock::Timeout=600)

log "Устанавливаю nginx, certbot и утилиты"
export DEBIAN_FRONTEND=noninteractive
"${APT[@]}" update
"${APT[@]}" install nginx certbot curl ca-certificates openssl

# ---------------------------------------------------------------- 2. Проверка DNS
SERVER_IP="${SERVER_IP:-$(curl -4 -fsS --max-time 5 https://api.ipify.org 2>/dev/null || curl -4 -fsS --max-time 5 https://ifconfig.me 2>/dev/null || true)}"
RESOLVED="$(getent ahostsv4 "$DOMAIN" | awk 'NR==1{print $1}' || true)"
log "IP сервера: ${SERVER_IP:-не определён}, $DOMAIN → ${RESOLVED:-не резолвится}"
if [[ -z "$RESOLVED" || ( -n "$SERVER_IP" && "$RESOLVED" != "$SERVER_IP" ) ]]; then
  warn "$DOMAIN должен указывать на IP этого сервера (${SERVER_IP:-?})."
  warn "В Cloudflare у A-записи нужен режим 'DNS only' (серое облако): иначе не выпустится сертификат и Reality будет палиться."
  if [[ "$ASSUME_YES" == 1 ]]; then
    warn "Продолжаю (-y)"
  else
    ask ans "Продолжить всё равно? [y/N] "
    [[ "$ans" =~ ^[Yy]$ ]] || exit 1
  fi
fi

# ---------------------------------------------------------------- 3. Сайт (личный блог)
# Старую заглушку «Tippa Cloud» заменяем, свой index.html (если ты его положил) не трогаем.
log "Создаю сайт в $WEBROOT"
mkdir -p "$WEBROOT"
if [[ ! -f "$WEBROOT/index.html" ]] || grep -q 'Tippa Cloud' "$WEBROOT/index.html"; then
cat > "$WEBROOT/index.html" <<'HTML'
<!doctype html>
<html lang="ru">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Заметки на полях</title>
<meta name="description" content="Личный блог: домашний сервер, Linux, бэкапы и мелкие утилиты.">
<link rel="icon" href="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 32 32'%3E%3Crect width='32' height='32' rx='7' fill='%23b4532a'/%3E%3Cpath d='M9 22V10h3l4 7 4-7h3v12h-3v-7l-4 6.5L12 15v7z' fill='%23fff'/%3E%3C/svg%3E">
<style>
  :root {
    --bg: #faf8f4; --text: #24211d; --muted: #6f685f; --line: #e6e0d6;
    --accent: #b4532a; --code: #f0ebe2;
    color-scheme: light dark;
  }
  @media (prefers-color-scheme: dark) {
    :root { --bg: #17181a; --text: #e7e4de; --muted: #9a958d; --line: #2c2d30;
            --accent: #e08a5c; --code: #222327; }
  }
  * { box-sizing: border-box; }
  body { margin: 0; background: var(--bg); color: var(--text);
         font: 18px/1.7 Georgia, "Times New Roman", serif; }
  .wrap { max-width: 680px; margin: 0 auto; padding: 0 20px; }
  header { padding: 56px 0 28px; border-bottom: 1px solid var(--line); }
  header h1 { margin: 0; font-size: 32px; line-height: 1.2; letter-spacing: -.01em; }
  header h1 a { color: inherit; text-decoration: none; }
  header p { margin: 8px 0 0; color: var(--muted); font: 16px/1.5 system-ui, -apple-system, "Segoe UI", Roboto, sans-serif; }
  nav { margin-top: 18px; font: 15px system-ui, -apple-system, "Segoe UI", Roboto, sans-serif; }
  nav a { color: var(--muted); margin-right: 18px; text-decoration: none; }
  nav a:hover { color: var(--accent); }
  article { padding: 40px 0; border-bottom: 1px solid var(--line); }
  article h2 { margin: 0 0 6px; font-size: 25px; line-height: 1.3; }
  time { display: block; margin-bottom: 18px; color: var(--muted);
         font: 14px system-ui, -apple-system, "Segoe UI", Roboto, sans-serif; }
  p { margin: 0 0 16px; }
  a { color: var(--accent); }
  code { background: var(--code); padding: 1px 6px; border-radius: 4px; font: .85em ui-monospace, Consolas, monospace; }
  pre { background: var(--code); padding: 14px 16px; border-radius: 8px; overflow-x: auto; font: 14px/1.5 ui-monospace, Consolas, monospace; }
  pre code { background: none; padding: 0; }
  ul { padding-left: 22px; margin: 0 0 16px; }
  #about { border-bottom: 0; }
  footer { padding: 28px 0 56px; color: var(--muted); font: 14px system-ui, -apple-system, "Segoe UI", Roboto, sans-serif; }
</style>
</head>
<body>
<div class="wrap">
  <header>
    <h1><a href="/">Заметки на полях</a></h1>
    <p>Домашний сервер, Linux, бэкапы и мелкие утилиты. Пишу, когда что-то сломалось и починилось.</p>
    <nav><a href="#posts">Записи</a><a href="#about">Обо мне</a></nav>
  </header>

  <main id="posts">
    <article id="homelab-year">
      <h2>Домашний сервер на старом ноутбуке: год спустя</h2>
      <time datetime="2026-10-02">2 октября 2026</time>
      <p>Год назад я поставил Debian на ноутбук, который пылился в шкафу, закрыл крышку и забыл про него. Сейчас на нём живут медиатека, синхронизация заметок и пара ботов. Подвёл он ровно один раз, когда умер блок питания.</p>
      <p>Главный вывод: старый ноутбук хорош как сервер, потому что у него есть встроенный ИБП, то есть батарея. Если в доме моргает свет, он этого даже не замечает. А вот диск в нём я бы поменял на SSD сразу: родной HDD за год начал сыпать ошибками в SMART.</p>
      <p>Что бы я сделал иначе: сразу завёл бы мониторинг. Пару недель сервер стоял с заполненным диском, а я узнал об этом только тогда, когда перестала работать синхронизация.</p>
    </article>

    <article id="dotfiles">
      <h2>Почему я перестал держать dotfiles в одном репозитории</h2>
      <time datetime="2026-08-17">17 августа 2026</time>
      <p>Долго у меня был один большой репозиторий с конфигами для всего: рабочего ноутбука, сервера, виртуалок. В итоге на сервер приезжали настройки для графического окружения, а на ноутбук какие-то серверные алиасы.</p>
      <p>Сейчас схема проще: общая база и небольшие файлы для каждой машины, которые подключаются по имени хоста.</p>
      <pre><code>[ -f ~/.config/shell/$(hostname).sh ] &amp;&amp; . ~/.config/shell/$(hostname).sh</code></pre>
      <p>Одна строчка в <code>.bashrc</code>, и больше никаких веток под каждую машину.</p>
    </article>

    <article id="backups">
      <h2>Бэкапы, которые реально восстанавливаются</h2>
      <time datetime="2026-06-05">5 июня 2026</time>
      <p>Бэкап, который ни разу не восстанавливали, это не бэкап, а надежда. Я понял это, когда попытался достать старый архив и обнаружил, что пароль от него хранился в том же архиве.</p>
      <p>Теперь у меня три правила:</p>
      <ul>
        <li>раз в месяц восстанавливаю случайную папку в отдельный каталог и сравниваю с оригиналом;</li>
        <li>ключи от бэкапов лежат отдельно, в менеджере паролей и на бумаге;</li>
        <li>одна копия всегда вне дома.</li>
      </ul>
      <p>Звучит скучно, но именно скучные вещи и спасают данные.</p>
    </article>

    <article id="tmux-ssh">
      <h2>Мелочь дня: tmux и обрывы ssh</h2>
      <time datetime="2026-03-21">21 марта 2026</time>
      <p>Если ssh часто рвётся, например в поезде, удобно сразу попадать в ту же сессию tmux. Алиас, которым я пользуюсь каждый день:</p>
      <pre><code>alias s='ssh -t home "tmux new -A -s main"'</code></pre>
      <p>Флаг <code>-A</code> подключает к существующей сессии или создаёт новую. Связь оборвалась, переподключился, и всё на месте.</p>
    </article>

    <article id="about">
      <h2>Обо мне</h2>
      <p>Занимаюсь разработкой, в свободное время ковыряю железо и пишу небольшие утилиты для себя. Блог веду в основном как записную книжку: если что-то пришлось гуглить дольше часа, это повод записать.</p>
    </article>
  </main>

  <footer>© 2026 · Без счётчиков и рекламы</footer>
</div>
</body>
</html>
HTML
cat > "$WEBROOT/404.html" <<'HTML'
<!doctype html>
<html lang="ru">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Страница не найдена · Заметки на полях</title>
<style>
  :root { --bg: #faf8f4; --text: #24211d; --muted: #6f685f; --accent: #b4532a; color-scheme: light dark; }
  @media (prefers-color-scheme: dark) { :root { --bg: #17181a; --text: #e7e4de; --muted: #9a958d; --accent: #e08a5c; } }
  body { margin: 0; min-height: 100vh; display: grid; place-items: center; background: var(--bg); color: var(--text);
         font: 18px/1.6 Georgia, "Times New Roman", serif; }
  main { max-width: 480px; padding: 24px 20px; }
  h1 { margin: 0 0 8px; font-size: 28px; }
  p { margin: 0; color: var(--muted); }
  a { color: var(--accent); }
</style>
</head>
<body>
<main>
  <h1>Такой страницы нет</h1>
  <p>Возможно, запись переехала или её никогда не было. <a href="/">На главную</a></p>
</main>
</body>
</html>
HTML
fi
chown -R www-data:www-data "$WEBROOT"

# ---------------------------------------------------------------- 4. nginx: порт 80 (ACME + редирект)
log "Настраиваю nginx на порту 80"
rm -f /etc/nginx/sites-enabled/default

cat > "$NGX_CONF" <<NGINX
# Всё, что пришло не на наш домен (сканеры по IP), просто закрываем
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;
    return 444;
}

server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};

    location /.well-known/acme-challenge/ {
        root ${WEBROOT};
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}
NGINX
ln -sf "$NGX_CONF" "/etc/nginx/sites-enabled/${DOMAIN}.conf"
nginx -t
systemctl enable --now nginx
systemctl reload nginx

# ---------------------------------------------------------------- 5. Сертификат Let's Encrypt
if [[ ! -f "$CERT_DIR/fullchain.pem" ]]; then
  log "Выпускаю сертификат для $DOMAIN"
  if [[ -n "$EMAIL" ]]; then ACC=(-m "$EMAIL"); else ACC=(--register-unsafely-without-email); fi
  certbot certonly --webroot -w "$WEBROOT" -d "$DOMAIN" \
    --non-interactive --agree-tos "${ACC[@]}"
else
  log "Сертификат уже есть, пропускаю выпуск"
fi

mkdir -p /etc/letsencrypt/renewal-hooks/deploy
cat > /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh <<'HOOK'
#!/bin/sh
systemctl reload nginx
HOOK
chmod +x /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh

# ---------------------------------------------------------------- 6. nginx: сайт на 127.0.0.1:8443 (target для Reality)
log "Настраиваю HTTPS-сайт на 127.0.0.1:${SITE_PORT}"
NGX_VER="$(nginx -v 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')"
if printf '1.25.1\n%s\n' "$NGX_VER" | sort -V -C; then
  LISTEN="listen 127.0.0.1:${SITE_PORT} ssl;"
  HTTP2="http2 on;"
else
  LISTEN="listen 127.0.0.1:${SITE_PORT} ssl http2;"
  HTTP2=""
fi

cat >> "$NGX_CONF" <<NGINX

# Сайт для Reality self-steal: доступен только локально, снаружи его видно через Xray на 443
server {
    ${LISTEN}
    ${HTTP2}
    server_name ${DOMAIN};

    ssl_certificate     ${CERT_DIR}/fullchain.pem;
    ssl_certificate_key ${CERT_DIR}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers off;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;

    server_tokens off;
    root ${WEBROOT};
    index index.html;
    error_page 404 /404.html;

    location / {
        try_files \$uri \$uri/ =404;
    }
}
NGINX
nginx -t
systemctl reload nginx

# ---------------------------------------------------------------- 7. Docker + Remnanode
if ! command -v docker >/dev/null; then
  log "Устанавливаю Docker"
  curl -fsSL https://get.docker.com | sh
fi

log "Разворачиваю remnanode в $NODE_DIR"
mkdir -p "$NODE_DIR"
cat > "$NODE_DIR/docker-compose.yml" <<YML
services:
  remnanode:
    container_name: remnanode
    hostname: remnanode
    image: remnawave/node:latest
    network_mode: host
    restart: always
    cap_add:
      - NET_ADMIN
    ulimits:
      nofile:
        soft: 1048576
        hard: 1048576
    environment:
      - NODE_PORT=${NODE_PORT}
      - SECRET_KEY="${SECRET_KEY}"
YML
chmod 600 "$NODE_DIR/docker-compose.yml"
docker compose -f "$NODE_DIR/docker-compose.yml" pull
docker compose -f "$NODE_DIR/docker-compose.yml" up -d

# ---------------------------------------------------------------- 8. Фаервол
if command -v ufw >/dev/null && ufw status | grep -q "Status: active"; then
  log "ufw активен: открываю 80 и 443"
  ufw allow 80/tcp
  ufw allow 443/tcp
  warn "Порт ${NODE_PORT} (NODE_PORT) открой только для IP панели: ufw allow from <IP_ПАНЕЛИ> to any port ${NODE_PORT} proto tcp"
fi

# ---------------------------------------------------------------- 9. Ключи Reality и конфиг для панели
KEYS_FILE="$NODE_DIR/reality-keys.txt"
if [[ ! -f "$KEYS_FILE" ]]; then
  TMPKEY="$(mktemp)"
  openssl genpkey -algorithm X25519 -out "$TMPKEY" 2>/dev/null
  b64url() { base64 -w0 | tr '+/' '-_' | tr -d '='; }
  PRIV="$(openssl pkey -in "$TMPKEY" -outform DER | tail -c 32 | b64url)"
  PUB="$(openssl pkey -in "$TMPKEY" -pubout -outform DER | tail -c 32 | b64url)"
  SID="$(openssl rand -hex 8)"
  rm -f "$TMPKEY"
  printf 'PRIVATE_KEY=%s\nPUBLIC_KEY=%s\nSHORT_ID=%s\n' "$PRIV" "$PUB" "$SID" > "$KEYS_FILE"
  chmod 600 "$KEYS_FILE"
fi
# shellcheck disable=SC1090
source "$KEYS_FILE"

# ---------------------------------------------------------------- 10. Проверка
log "Проверяю сайт на 127.0.0.1:${SITE_PORT}"
if curl -sS -o /dev/null -w '%{http_code} %{http_version}\n' \
     --resolve "${DOMAIN}:${SITE_PORT}:127.0.0.1" "https://${DOMAIN}:${SITE_PORT}/"; then
  log "Сайт отвечает (ожидается: 200 2)"
else
  warn "Сайт не ответил, смотри: journalctl -u nginx, nginx -t"
fi

cat <<EOF

=====================================================================
 Готово. Ключи сохранены в $KEYS_FILE

 Inbound для Config Profile этой ноды в панели Remnawave:

{
  "tag": "VLESS_REALITY_SELFSTEAL",
  "listen": "0.0.0.0",
  "port": 443,
  "protocol": "vless",
  "settings": {
    "clients": [],
    "decryption": "none"
  },
  "sniffing": {
    "enabled": true,
    "destOverride": ["http", "tls", "quic"]
  },
  "streamSettings": {
    "network": "raw",
    "security": "reality",
    "realitySettings": {
      "show": false,
      "xver": 0,
      "target": "127.0.0.1:${SITE_PORT}",
      "spiderX": "",
      "shortIds": ["${SHORT_ID}"],
      "privateKey": "${PRIVATE_KEY}",
      "serverNames": ["${DOMAIN}"]
    }
  }
}

 Public key (pbk) для клиентов: ${PUBLIC_KEY}
 Host в панели: адрес ${DOMAIN}, порт 443, SNI ${DOMAIN}
=====================================================================
EOF
