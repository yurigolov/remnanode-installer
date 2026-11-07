#!/usr/bin/env bash
#
# vps-check.sh — проверяет, годится ли VPS под VPN-сервер / ноду Remnawave.
#
#   sudo bash vps-check.sh [опции]
#   curl -fsSL https://ВАШ-ХОСТ/vps-check.sh | sudo bash -s -- [опции]
#
# Ничего не устанавливает и не меняет настройки системы. Для проверки TUN и
# WireGuard создаются временные интерфейсы, которые сразу же удаляются.

VERSION="1.0"

# Хостеры, трафик к которым из РФ, по сообщениям пользователей, режется или
# замедляется ТСПУ (с 2025 г.). Список неполный и меняется — дополняйте.
RISKY_ASNS="AS24940:Hetzner AS213230:Hetzner AS14061:DigitalOcean AS16276:OVH AS63949:Akamai/Linode AS20473:Vultr AS16509:Amazon AS14618:Amazon AS13335:Cloudflare AS31898:Oracle AS12876:Scaleway AS51167:Contabo AS8075:Microsoft AS396982:Google"

# Порты, которые нужны типовой схеме: Reality на 443, certbot на 80, API ноды Remnawave.
NODE_PORT="${NODE_PORT:-2222}"

UA='Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/129.0 Safari/537.36'

usage() {
  cat <<'EOF'
Проверка VPS на пригодность под VPN-сервер.

  sudo bash vps-check.sh [опции]

  --fast       без тестов скорости, диска и шифрования (~30 с вместо ~1.5 мин)
  --no-ru      не проверять доступность IP из России (check-host.net)
  --port N     TCP-порт для проверки из РФ (по умолчанию — порт SSH)
  --no-color   без цветов (удобно для: ... | tee report.txt)
  -h, --help   эта справка

Переменные: NODE_PORT=2222 — порт API ноды Remnawave для проверки занятости.
EOF
}

# ------------------------------------------------------------------ helpers
have()  { command -v "$1" >/dev/null 2>&1; }
get()   { curl -s -L --max-time "${T:-10}" -A "$UA" "$@" 2>/dev/null; }
code()  { curl -s -o /dev/null --max-time "${T:-10}" -A "$UA" -w '%{http_code}' "$@" 2>/dev/null; }
isnum() { [[ $1 =~ ^[0-9]+([.][0-9]+)?$ ]]; }
fge()   { awk -v a="$1" -v b="$2" 'BEGIN{exit !(a>=b)}'; }
kge()   { [ "$KMAJ" -gt "$1" ] || { [ "$KMAJ" -eq "$1" ] && [ "$KMIN" -ge "$2" ]; }; }
mbit()  { awk -v b="$1" 'BEGIN{printf "%.0f", b*8/1000000}'; }
rate()  { awk -v m="$1" 'BEGIN{ if (m>=1000) printf "%.1f Гбит/с", m/1000; else printf "%.0f Мбит/с", m }'; }

PASS=0; NWARN=0; NFAIL=0; FAIL_L=(); WARN_L=()
pad()     { local s=$1 n; n=$((24 - ${#s})); [ "$n" -lt 1 ] && n=1; printf '%s%*s' "$s" "$n" ''; }
ok()      { PASS=$((PASS+1));   printf '  %s✔%s %s%s\n' "$G" "$N" "$(pad "$1")" "$2"; }
warn()    { NWARN=$((NWARN+1)); WARN_L+=("$1: $2"); printf '  %s!%s %s%s\n' "$Y" "$N" "$(pad "$1")" "$2"; }
fail()    { NFAIL=$((NFAIL+1)); FAIL_L+=("$1: $2"); printf '  %s✖%s %s%s\n' "$R" "$N" "$(pad "$1")" "$2"; }
info()    { printf '  %s•%s %s%s\n' "$B" "$N" "$(pad "$1")" "$2"; }
hint()    { printf '    %s↳ %s%s\n' "$D" "$1" "$N"; }
section() { printf '\n%s▌ %s%s\n' "$BOLD" "$1" "$N"; }

# Поле верхнего уровня из JSON на stdin: python3 → jq → sed.
json_get() {
  if have python3; then
    python3 -c 'import sys, json
try: d = json.load(sys.stdin)
except Exception: sys.exit()
v = d.get(sys.argv[1]) if isinstance(d, dict) else None
if v is not None: print(str(v).lower() if isinstance(v, bool) else v)' "$1" 2>/dev/null
  elif have jq; then
    jq -r --arg k "$1" '.[$k] | select(. != null)' 2>/dev/null
  else
    sed -n "s/.*\"$1\":\"\{0,1\}\([^\",}]*\).*/\1/p" | head -n1
  fi
}

get_ip() {
  local fam=$1 u ip
  for u in https://api.ipify.org https://ifconfig.me/ip https://icanhazip.com; do
    [ "$fam" = 6 ] && [ "$u" = https://api.ipify.org ] && u=https://api6.ipify.org
    ip=$(T=6 get "-$fam" "$u" | tr -d ' \r\n')
    if [ "$fam" = 4 ]; then
      [[ $ip =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] && { echo "$ip"; return; }
    else
      [[ $ip == *:* && ${#ip} -le 45 && $ip != *'<'* ]] && { echo "$ip"; return; }
    fi
  done
}

# Кто слушает порт: $1 = t|u, $2 = порт. Печатает имя процесса ("?" без root), код 1 — свободен.
port_owner() {
  local line name
  line=$(ss -ln"$1"p 2>/dev/null | awk -v p="$2" 'NR>1 { n=split($4,a,":"); if (a[n]==p) { print; exit } }')
  [ -z "$line" ] && return 1
  name=$(printf '%s' "$line" | grep -o 'users:(("[^"]*' | head -n1 | sed 's/.*"//')
  echo "${name:-?}"
}

cpu_stat() { awk '/^cpu /{t=0; for(i=2;i<=9;i++) t+=$i; print t, ($9==""?0:$9); exit}' /proc/stat; }

# Пропускная способность шифра на одном ядре, Мбит/с.
ossl_mbit() {
  local v
  v=$(openssl speed -elapsed -seconds 1 -bytes 16384 -evp "$1" 2>/dev/null | awk 'END{v=$NF; sub(/k$/,"",v); print v}')
  isnum "$v" && awk -v k="$v" 'BEGIN{printf "%.0f", k*8/1000}'
}

# Исходящий UDP: DNS-запрос к 1.1.1.1 / 8.8.8.8.
udp_out() {
  if have python3; then
    python3 - <<'PY' 2>/dev/null
import socket, sys
q = b'\x12\x34\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00\x07example\x03com\x00\x00\x01\x00\x01'
for srv in ('1.1.1.1', '8.8.8.8'):
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.settimeout(3)
        s.sendto(q, (srv, 53))
        if s.recv(512)[:2] == b'\x12\x34':
            sys.exit(0)
    except Exception:
        pass
sys.exit(1)
PY
  elif have dig; then
    dig +short +time=3 +tries=1 @1.1.1.1 example.com A 2>/dev/null | grep -q .
  elif have nslookup; then
    timeout 6 nslookup example.com 1.1.1.1 >/dev/null 2>&1
  else
    return 2
  fi
}

# TCP RTT до хоста (без учёта DNS), мс.
rtt() {
  curl -s -o /dev/null --max-time 6 -w '%{time_namelookup} %{time_connect}' "https://$1" 2>/dev/null |
    awk '$2>0 {printf "%.0f", ($2-$1)*1000}'
}

# Проверка с узлов check-host.net в РФ (+2 контрольных за рубежом).
# Вывод: строки "СТАТУС|метка|текст" и итоговые RU_TCP|n, RU_PING|мс.
write_ru_checker() {
  cat > "$1" <<'PY'
import json, sys, time, urllib.request

ip, port = sys.argv[1], sys.argv[2]
HDR = {'Accept': 'application/json', 'User-Agent': 'vps-check'}


def get(url):
    req = urllib.request.Request(url, headers=HDR)
    with urllib.request.urlopen(req, timeout=20) as r:
        return json.loads(r.read().decode('utf-8'))


def out(*parts):
    print('|'.join(str(p) for p in parts), flush=True)


def bail(msg):
    out('WARN', 'check-host.net', msg)
    out('RU_TCP', -1)
    sys.exit(0)


try:
    nodes = get('https://check-host.net/nodes/hosts')['nodes']
except Exception as e:
    bail('недоступен (%s)' % type(e).__name__)


def loc(n, i):
    l = nodes[n].get('location') or []
    return str(l[i]) if len(l) > i else ''


ru = sorted(n for n in nodes if loc(n, 0).lower() == 'ru')
ctl = sorted(n for n in nodes if loc(n, 0).lower() in ('de', 'nl', 'fi', 'se'))[:2]
if not ru:
    bail('нет доступных узлов в РФ')
targets = ru + ctl


def start(kind, host):
    q = '&'.join('node=' + n for n in targets)
    for attempt in range(4):
        r = get('https://check-host.net/check-%s?host=%s&%s' % (kind, host, q))
        if 'request_id' in r:
            return r['request_id']
        time.sleep(5 * (attempt + 1))   # limit_exceeded — частая проверка с одного IP
    bail('отказ: %s' % r.get('error', r))


def result(rid):
    res = {}
    for _ in range(12):
        time.sleep(2.5)
        res = get('https://check-host.net/check-result/' + rid) or {}
        if all(res.get(n) is not None for n in targets):
            break
    return res


try:
    pid = start('ping', ip)
    time.sleep(1)
    tid = start('tcp', '%s:%s' % (ip, port))
    pres, tres = result(pid), result(tid)
except Exception as e:
    bail('ошибка запроса (%s)' % type(e).__name__)


def ping_ms(r):
    try:
        good = [p[1] for p in r[0] if p and p[0] == 'OK']
    except Exception:
        return None
    return sum(good) / len(good) * 1000 if good else None


def tcp_ms(r):
    try:
        return r[0]['time'] * 1000
    except Exception:
        return None


def fmt(v):
    return '%.0f мс' % v if v is not None else '—'


ru_ok = ctl_ok = 0
pings = []
for n in targets:
    p, t = ping_ms(pres.get(n)), tcp_ms(tres.get(n))
    name = '%s %s' % (n.split('.')[0], loc(n, 2) or loc(n, 1))
    if n in ru:
        ru_ok += t is not None
        if p is not None:
            pings.append(p)
    else:
        ctl_ok += t is not None
        name += ' (контроль)'
    out('INFO', name, 'ping %s · TCP:%s %s' % (fmt(p), port, fmt(t) if t is not None else 'нет ответа'))

if ru_ok == len(ru):
    out('OK', 'Доступ из РФ', 'TCP:%s открывается со всех %d узлов' % (port, len(ru)))
    out('RU_TCP', 1)
elif ru_ok:
    out('WARN', 'Доступ из РФ', 'TCP:%s открывается с %d из %d узлов' % (port, ru_ok, len(ru)))
    out('HINT', 'возможна блокировка у части операторов или сбой узла — перепроверьте позже')
    out('RU_TCP', 1)
elif ctl_ok:
    out('FAIL', 'Доступ из РФ', 'из РФ недоступен, из-за рубежа — доступен')
    out('HINT', 'похоже, IP заблокирован в РФ — попросите у хостера другой IP')
    out('RU_TCP', 0)
else:
    out('WARN', 'Доступ из РФ', 'порт %s не открывается ни из РФ, ни из-за рубежа' % port)
    out('HINT', 'проверьте фаервол хостера или укажите открытый порт: --port N')
    out('RU_TCP', -1)
if pings:
    out('RU_PING', '%.0f' % (sum(pings) / len(pings)))
PY
}

cleanup() {
  [ -n "${RU_PID:-}" ] && kill "$RU_PID" 2>/dev/null
  [ -n "${DDFILE:-}" ] && rm -f "$DDFILE"
  [ -n "${TMPD:-}" ] && rm -rf "$TMPD"
  if [ "${IS_ROOT:-0}" = 1 ] && have ip; then
    ip link del "vpschk$$" 2>/dev/null
    ip link del "wgchk$$" 2>/dev/null
  fi
}

# ------------------------------------------------------------------ main
main() {
  FAST=0; CHECK_RU=1; USE_COLOR=1; CHECK_PORT=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --fast)     FAST=1 ;;
      --no-ru)    CHECK_RU=0 ;;
      --no-color) USE_COLOR=0 ;;
      --port)     CHECK_PORT=$2; shift ;;
      -h|--help)  usage; exit 0 ;;
      *) echo "Неизвестная опция: $1 (см. --help)"; exit 1 ;;
    esac
    shift
  done

  # ${#строка} должен считать символы, а не байты — нужна UTF-8 локаль.
  local l
  for l in C.UTF-8 C.utf8 en_US.UTF-8 en_US.utf8; do
    if locale -a 2>/dev/null | grep -qx "$l"; then export LC_ALL=$l; break; fi
  done

  if [ "$USE_COLOR" = 1 ] && [ -t 1 ]; then
    R=$'\e[31m' G=$'\e[32m' Y=$'\e[33m' B=$'\e[36m' D=$'\e[2m' BOLD=$'\e[1m' N=$'\e[0m'
  else
    R= G= Y= B= D= BOLD= N=
  fi

  have curl || { echo "Нужен curl:  apt install -y curl   или   dnf install -y curl"; exit 1; }
  IS_ROOT=0; [ "$(id -u)" -eq 0 ] && IS_ROOT=1
  TMPD=$(mktemp -d 2>/dev/null) || { TMPD=/tmp/vpscheck.$$; mkdir -p "$TMPD"; }
  trap cleanup EXIT
  trap 'exit 130' INT TERM

  printf '%sПроверка VPS под VPN-сервер%s  v%s · %s · %s\n' "$BOLD" "$N" "$VERSION" \
    "$(hostname 2>/dev/null)" "$(date '+%Y-%m-%d %H:%M %Z')"
  [ "$IS_ROOT" = 0 ] && printf '%s! Без root часть проверок (TUN, WireGuard, iptables, порты) будет неполной: sudo bash vps-check.sh%s\n' "$Y" "$N"

  # IP и порт узнаём сразу, чтобы проверка из РФ шла в фоне, пока идут остальные.
  IP4=$(get_ip 4); IP6=$(get_ip 6)
  if [ -z "$CHECK_PORT" ]; then
    CHECK_PORT=$(ss -lntp 2>/dev/null | awk '/"sshd"/{n=split($4,a,":"); print a[n]; exit}')
    [ -z "$CHECK_PORT" ] && [ -n "${SSH_CONNECTION:-}" ] && CHECK_PORT=$(echo "$SSH_CONNECTION" | awk '{print $4}')
    [ -z "$CHECK_PORT" ] && CHECK_PORT=$(awk 'tolower($1)=="port"{print $2; exit}' /etc/ssh/sshd_config 2>/dev/null)
    CHECK_PORT=${CHECK_PORT:-22}
  fi
  RU_PID=""
  if [ "$CHECK_RU" = 1 ] && [ -n "$IP4" ] && have python3; then
    write_ru_checker "$TMPD/ru.py"
    PYTHONIOENCODING=utf-8 python3 "$TMPD/ru.py" "$IP4" "$CHECK_PORT" >"$TMPD/ru.out" 2>/dev/null &
    RU_PID=$!
  fi

  # ================================================================ Система
  section "Система"
  OS=$( . /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-${NAME:-}}" )
  info "ОС" "${OS:-$(uname -s)} · $(uname -m)"

  KVER=$(uname -r)
  KMAJ=${KVER%%.*}; KMIN=${KVER#*.}; KMIN=${KMIN%%.*}; KMIN=${KMIN%%[!0-9]*}; KMIN=${KMIN:-0}
  if kge 5 6; then
    ok "Ядро" "$KVER (WireGuard встроен)"
  elif kge 4 9; then
    warn "Ядро" "$KVER — старое: BBR есть, WireGuard только через DKMS или userspace"
  else
    fail "Ядро" "$KVER — очень старое (часто OpenVZ), современный VPN-стек встанет плохо"
  fi

  VIRT=unknown; CONTAINER=0
  have systemd-detect-virt && VIRT=$(systemd-detect-virt 2>/dev/null)
  [ -z "$VIRT" ] && VIRT=unknown
  if [ -e /proc/user_beancounters ] || { [ -d /proc/vz ] && [ ! -d /proc/bc ]; }; then
    VIRT=openvz
  elif [ "$VIRT" = unknown ] || [ "$VIRT" = none ]; then
    if [ -f /.dockerenv ]; then VIRT=docker
    elif [ -s /run/systemd/container ]; then VIRT=$(cat /run/systemd/container)
    elif grep -qa 'container=lxc' /proc/1/environ 2>/dev/null; then VIRT=lxc
    elif [ "$VIRT" = unknown ] && grep -qw hypervisor /proc/cpuinfo; then VIRT=vm
    fi
  fi
  case "$VIRT" in
    openvz|lxc|lxc-libvirt|docker|podman|systemd-nspawn|rkt|wsl|proot|container-other) CONTAINER=1 ;;
  esac
  if [ "$CONTAINER" = 1 ]; then
    warn "Виртуализация" "$VIRT — контейнер, ядро общее с хостом"
    hint "модули ядра (WireGuard/AmneziaWG), BBR и sysctl зависят от хостера; Docker может не работать"
  elif [ "$VIRT" = none ]; then
    ok "Виртуализация" "нет (выделенный сервер)"
  elif [ "$VIRT" = unknown ]; then
    info "Виртуализация" "не определена"
  else
    ok "Виртуализация" "$VIRT — полноценная VM, своё ядро"
  fi
  info "Нагрузка (1/5/15 мин)" "$(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null)"

  # ================================================================ Ресурсы
  section "Ресурсы"
  CORES=$(nproc 2>/dev/null || grep -c ^processor /proc/cpuinfo)
  CPU_MODEL=$(awk -F': ' '/^model name/{print $2; exit}' /proc/cpuinfo)
  [ -z "$CPU_MODEL" ] && have lscpu && CPU_MODEL=$(lscpu 2>/dev/null | awk -F': +' '/^Model name/{print $2; exit}')
  if [ "${CORES:-1}" -ge 2 ]; then
    ok "CPU" "$CORES ядер · ${CPU_MODEL:-?}"
  else
    warn "CPU" "1 ядро · ${CPU_MODEL:-?}"
    hint "для небольшой ноды хватит; под сотни пользователей лучше 2+ ядра"
  fi

  if grep -qw aes /proc/cpuinfo; then
    ok "AES-NI" "есть (аппаратное ускорение AES-GCM)"
  else
    warn "AES-NI" "нет — AES будет медленным"
    hint "предпочитайте ChaCha20; WireGuard/AmneziaWG и так на ChaCha20"
  fi

  RAM_MB=$(awk '/^MemTotal/{print int($2/1024)}' /proc/meminfo)
  AVAIL_MB=$(awk '/^MemAvailable/{print int($2/1024)}' /proc/meminfo)
  SWAP_MB=$(awk '/^SwapTotal/{print int($2/1024)}' /proc/meminfo)
  RAM_MB=${RAM_MB:-0}
  if [ "$RAM_MB" -lt 400 ]; then
    fail "ОЗУ" "$RAM_MB МБ — слишком мало"
  elif [ "$RAM_MB" -lt 900 ]; then
    warn "ОЗУ" "$RAM_MB МБ (свободно ${AVAIL_MB:-?}) — Xray/WG хватит, Docker-ноде впритык"
  else
    ok "ОЗУ" "$RAM_MB МБ (свободно ${AVAIL_MB:-?})"
  fi
  if [ "${SWAP_MB:-0}" -eq 0 ] && [ "$RAM_MB" -lt 2000 ]; then
    info "Swap" "нет — при малом ОЗУ стоит добавить 1–2 ГБ"
  else
    info "Swap" "${SWAP_MB:-0} МБ"
  fi

  read -r DISK_FREE DISK_TOTAL < <(df -Pm / 2>/dev/null | awk 'NR==2{print $4, $2}')
  DISK_FREE=${DISK_FREE:-0}
  DISK_TXT="свободно $(awk -v m="$DISK_FREE" 'BEGIN{printf "%.1f", m/1024}') из $(awk -v m="${DISK_TOTAL:-0}" 'BEGIN{printf "%.1f", m/1024}') ГБ"
  if [ "$DISK_FREE" -lt 1500 ]; then
    fail "Диск" "$DISK_TXT — мало (Docker-образы, логи)"
  elif [ "$DISK_FREE" -lt 4000 ]; then
    warn "Диск" "$DISK_TXT — впритык, следите за логами"
  else
    ok "Диск" "$DISK_TXT"
  fi

  read -r t1 s1 < <(cpu_stat); sleep 2; read -r t2 s2 < <(cpu_stat)
  STEAL=$(awk -v a=$((s2-s1)) -v b=$((t2-t1)) 'BEGIN{printf "%.1f", (b>0 ? a*100/b : 0)}')
  if fge "$STEAL" 10; then
    fail "CPU steal" "${STEAL}% — хост сильно перегружен (оверселл)"
  elif fge "$STEAL" 3; then
    warn "CPU steal" "${STEAL}% — соседи по хосту отъедают CPU"
  else
    ok "CPU steal" "${STEAL}%"
  fi

  if [ "$FAST" = 0 ]; then
    DDFILE=""
    for l in /var/tmp /root /tmp; do [ -w "$l" ] && { DDFILE="$l/vpscheck.$$.dd"; break; }; done
    if [ "$DISK_FREE" -gt 1024 ] && [ -n "$DDFILE" ]; then
      t1=$(date +%s%N)
      dd if=/dev/zero of="$DDFILE" bs=1M count=256 conv=fdatasync 2>/dev/null
      t2=$(date +%s%N)
      rm -f "$DDFILE"
      if isnum "$t1" && isnum "$t2" && [ "$t2" -gt "$t1" ]; then
        DSPD=$(awk -v ns=$((t2-t1)) 'BEGIN{printf "%.0f", 256/(ns/1e9)}')
        if [ "$DSPD" -ge 100 ]; then ok "Запись на диск" "$DSPD МБ/с"
        else warn "Запись на диск" "$DSPD МБ/с — медленно (для VPN не критично, для БД/панели — да)"; fi
      fi
    fi
    if have openssl; then
      AES=$(ossl_mbit aes-128-gcm); CHA=$(ossl_mbit chacha20-poly1305)
      if [ -n "$AES$CHA" ]; then
        BEST=$(( ${AES:-0} > ${CHA:-0} ? ${AES:-0} : ${CHA:-0} ))
        TXT="AES-GCM $( [ -n "$AES" ] && rate "$AES" || echo '?'), ChaCha20 $( [ -n "$CHA" ] && rate "$CHA" || echo '?') на ядро"
        if [ "$BEST" -ge 1000 ]; then ok "Шифрование" "$TXT"
        else warn "Шифрование" "$TXT — CPU будет узким местом"; fi
      fi
    fi
  fi

  # ================================================================ Ядро и VPN-возможности
  section "Ядро и возможности для VPN"
  TUN=0
  if [ -c /dev/net/tun ]; then
    if [ "$IS_ROOT" = 1 ] && have ip; then
      if ip tuntap add dev "vpschk$$" mode tun 2>/dev/null; then
        ip link del "vpschk$$" 2>/dev/null
        TUN=1; ok "TUN" "работает"
      else
        fail "TUN" "/dev/net/tun есть, но интерфейс не создаётся"
        hint "попросите хостера включить TUN/TAP в панели VPS"
      fi
    else
      TUN=1; ok "TUN" "/dev/net/tun есть (полная проверка — под root)"
    fi
  else
    fail "TUN" "/dev/net/tun отсутствует"
    hint "без TUN не будут работать OpenVPN, wireguard-go, amneziawg-go; Xray — будет"
  fi

  WG_KERNEL=0
  if [ "$IS_ROOT" = 1 ] && have ip && ip link add "wgchk$$" type wireguard 2>/dev/null; then
    ip link del "wgchk$$" 2>/dev/null
    WG_KERNEL=1; ok "WireGuard в ядре" "есть"
  elif [ -d /sys/module/wireguard ] || modinfo wireguard >/dev/null 2>&1; then
    WG_KERNEL=1; ok "WireGuard в ядре" "модуль есть"
  elif [ "$TUN" = 1 ]; then
    warn "WireGuard в ядре" "нет — только wireguard-go (медленнее)"
  else
    fail "WireGuard в ядре" "нет, и TUN тоже нет"
  fi

  MODS_OK=1
  [ "$CONTAINER" = 1 ] && MODS_OK=0
  [ "$(cat /proc/sys/kernel/modules_disabled 2>/dev/null)" = 1 ] && MODS_OK=0
  if [ "$MODS_OK" = 1 ]; then
    if [ -d "/lib/modules/$KVER/build" ]; then
      ok "Модули ядра" "грузятся, заголовки ядра есть (модуль AmneziaWG соберётся)"
    else
      ok "Модули ядра" "грузятся; для AmneziaWG-модуля поставьте linux-headers-$KVER"
    fi
  else
    warn "Модули ядра" "загрузка невозможна — AmneziaWG только в userspace (amneziawg-go)"
  fi

  FWD_CUR=$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null)
  if [ -z "$FWD_CUR" ]; then
    FWD=0; fail "IP forwarding" "недоступен (/proc/sys/net/ipv4/ip_forward нет)"
  elif [ "$IS_ROOT" = 1 ]; then
    # Записываем то же значение — проверяем, что sysctl не read-only (бывает в контейнерах).
    if ( echo "$FWD_CUR" > /proc/sys/net/ipv4/ip_forward ) 2>/dev/null; then
      FWD=1; ok "IP forwarding" "можно включить (сейчас: $FWD_CUR)"
    else
      FWD=0; fail "IP forwarding" "sysctl только для чтения — WG/OpenVPN не смогут маршрутизировать"
    fi
  else
    FWD=2; info "IP forwarding" "сейчас: $FWD_CUR (проверка записи — под root)"
  fi

  NAT=2
  if [ "$IS_ROOT" = 1 ]; then
    if have iptables && iptables -t nat -S >/dev/null 2>&1; then
      NAT=1; ok "NAT (iptables)" "работает · $(iptables --version 2>/dev/null | awk '{print $2, $3}')"
    elif have nft && nft list tables >/dev/null 2>&1; then
      NAT=1; ok "NAT (nftables)" "nft работает"
    elif have iptables || have nft; then
      NAT=0; fail "NAT" "iptables/nft есть, но таблица nat недоступна"
    else
      info "NAT" "iptables/nft не установлены (поставятся вместе с VPN)"
    fi
  fi

  FW=""
  have ufw && ufw status 2>/dev/null | grep -q 'Status: active' && FW="ufw"
  have firewall-cmd && firewall-cmd --state 2>/dev/null | grep -q running && FW="$FW firewalld"
  [ "$IS_ROOT" = 1 ] && have iptables && iptables -S INPUT 2>/dev/null | grep -q -- '-P INPUT DROP' && FW="$FW iptables(DROP)"
  if [ -n "$FW" ]; then info "Фаервол" "активен:$FW — не забудьте открыть порты VPN"
  else info "Фаервол" "не обнаружен (у хостера может быть свой в панели)"; fi

  CC=$(cat /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null)
  CC_AV=$(cat /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null)
  QD=$(cat /proc/sys/net/core/default_qdisc 2>/dev/null)
  if [ "$CC" = bbr ]; then
    ok "BBR" "включён (qdisc: ${QD:-?})"
  elif [[ " $CC_AV " == *" bbr "* ]] || modinfo tcp_bbr >/dev/null 2>&1; then
    ok "BBR" "доступен, сейчас ${CC:-?} — стоит включить"
    hint "printf 'net.core.default_qdisc=fq\\nnet.ipv4.tcp_congestion_control=bbr\\n' > /etc/sysctl.d/99-bbr.conf && sysctl --system"
  else
    warn "BBR" "недоступен (сейчас: ${CC:-?}) — на плохих каналах скорость будет ниже"
  fi

  TIME_BAD=0
  NTP=$(timedatectl show -p NTPSynchronized --value 2>/dev/null)
  HDR=$(curl -sI --max-time 6 https://www.google.com 2>/dev/null | tr -d '\r' | awk 'tolower($1)=="date:"{sub(/^[^:]*: */,""); print; exit}')
  REMOTE=$(date -d "$HDR" +%s 2>/dev/null)
  if [ -n "$HDR" ] && isnum "$REMOTE"; then
    SKEW=$(( $(date +%s) - REMOTE )); SKEW=${SKEW#-}
    if [ "$SKEW" -le 5 ]; then
      ok "Время" "точное (±${SKEW} с${NTP:+, NTP: $NTP})"
    elif [ "$SKEW" -le 30 ]; then
      warn "Время" "расхождение ${SKEW} с"; hint "timedatectl set-ntp true"
    else
      TIME_BAD=1; fail "Время" "расхождение ${SKEW} с — VMess, Shadowsocks-2022 и TLS будут сбоить"
      hint "timedatectl set-ntp true  (или apt install chrony)"
    fi
  else
    info "Время" "не удалось сверить${NTP:+ (NTP: $NTP)}"
  fi

  if have docker; then
    if [ "$IS_ROOT" = 1 ] && ! docker info >/dev/null 2>&1; then
      warn "Docker" "установлен, но демон не отвечает"
    else
      ok "Docker" "$(docker --version 2>/dev/null | sed 's/^Docker version //; s/,.*//')"
    fi
  elif [ "$CONTAINER" = 1 ]; then
    warn "Docker" "не установлен; в контейнере ($VIRT) может не заработать"
  else
    info "Docker" "не установлен (curl -fsSL https://get.docker.com | sh)"
  fi

  # ================================================================ Сеть
  section "Сеть"
  HAS_IP4=1; BEHIND_NAT=0
  if [ -z "$IP4" ]; then
    HAS_IP4=0; fail "Публичный IPv4" "не определён — нет выхода в интернет по IPv4"
  else
    if have ip; then
      LOCAL4=$(ip -4 -o addr show scope global 2>/dev/null | awk '{split($4,a,"/"); print a[1]}')
    else
      LOCAL4=$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9.]+$')
    fi
    if [ -z "$LOCAL4" ]; then
      info "Публичный IPv4" "$IP4 (адреса интерфейсов не прочитать)"
    elif printf '%s\n' "$LOCAL4" | grep -qxF "$IP4"; then
      ok "Публичный IPv4" "$IP4 (назначен на интерфейс)"
    else
      BEHIND_NAT=1
      warn "Публичный IPv4" "$IP4, а на интерфейсе $(echo $LOCAL4) — NAT"
      hint "1:1 NAT (AWS, GCP, Oracle, Yandex Cloud) — нормально; NAT-VPS с парой проброшенных портов — плохо"
    fi
    EXTRA=$(printf '%s\n' "$LOCAL4" | awk NF | grep -vxF "$IP4" | grep -vE '^(10|127|169\.254|192\.168|172\.(1[6-9]|2[0-9]|3[01])|100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7]))\.' | tr '\n' ' ')
    [ -n "$EXTRA" ] && info "Доп. IPv4" "$EXTRA"
  fi
  if [ -n "$IP6" ]; then ok "IPv6" "$IP6"; else info "IPv6" "нет (не обязателен)"; fi

  DEV=$(ip -4 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
  MTU=$(cat "/sys/class/net/$DEV/mtu" 2>/dev/null)
  if [ -n "$MTU" ]; then
    if [ "$MTU" -ge 1500 ]; then ok "MTU" "$MTU ($DEV)"
    else warn "MTU" "$MTU ($DEV) — в WireGuard/AmneziaWG поставьте MTU $((MTU-80))"; fi
  fi

  if getent hosts google.com >/dev/null 2>&1 || get -o /dev/null https://google.com; then
    NS=$(awk '/^nameserver/{printf "%s%s", s, $2; s=" "}' /etc/resolv.conf 2>/dev/null)
    ok "DNS" "работает${NS:+ ($NS)}"
  else
    fail "DNS" "имена не резолвятся"
  fi

  UDP_OUT=1
  udp_out; rc=$?
  if [ "$rc" = 0 ]; then ok "Исходящий UDP" "работает"
  elif [ "$rc" = 1 ]; then UDP_OUT=0; warn "Исходящий UDP" "DNS по UDP не проходит — хостер может резать UDP"
  else info "Исходящий UDP" "нечем проверить (нужен python3 или dig)"; fi

  RU_RTT=""
  for h in ya.ru vk.com; do
    v=$(rtt "$h"); [ -n "$v" ] && { [ -z "$RU_RTT" ] || [ "$v" -lt "$RU_RTT" ]; } && RU_RTT=$v
  done
  if [ -z "$RU_RTT" ]; then
    info "Задержка до РФ" "не измерена (ya.ru / vk.com недоступны)"
  elif [ "$RU_RTT" -le 80 ]; then
    ok "Задержка до РФ" "$RU_RTT мс (TCP до ya.ru/vk.com)"
  elif [ "$RU_RTT" -le 160 ]; then
    info "Задержка до РФ" "$RU_RTT мс — нормально"
  else
    warn "Задержка до РФ" "$RU_RTT мс — далеко, пинг у пользователей будет высоким"
  fi

  PTR=$(getent hosts "$IP4" 2>/dev/null | awk '{print $2; exit}')
  [ -n "$IP4" ] && info "PTR (rDNS)" "${PTR:-нет}"

  # ================================================================ Порты
  section "Порты"
  P443_BUSY=0
  if ! have ss; then
    info "Порты" "ss не найден (пакет iproute2)"
  else
    for p in 443 80 "$NODE_PORT"; do
      if own=$(port_owner t "$p"); then
        case "$own" in
          xray|sing-box|hysteria*|rw-core|remnanode|node|x-ui|3x-ui|marzban*|docker-proxy)
            info "TCP $p" "занят: $own (похоже, VPN уже стоит)" ;;
          *)
            [ "$p" = 443 ] && P443_BUSY=1
            case "$p" in
              443) warn "TCP 443" "занят: $own"
                   hint "Reality лучше вешать на 443; иначе nginx stream с SNI-маршрутизацией или другой порт" ;;
              80)  warn "TCP 80" "занят: $own — certbot (HTTP-01) для self-steal не сможет выпустить сертификат" ;;
              *)   warn "TCP $p" "занят: $own — нужен другой NODE_PORT для ноды" ;;
            esac ;;
        esac
      else
        ok "TCP $p" "свободен"
      fi
    done
    if own=$(port_owner u 443); then info "UDP 443" "занят: $own"; else ok "UDP 443" "свободен (Hysteria2/TUIC)"; fi
    LT=$(ss -lnt 2>/dev/null | awk 'NR>1{n=split($4,a,":"); print a[n]}' | sort -un | tr '\n' ' ')
    LU=$(ss -lnu 2>/dev/null | awk 'NR>1{n=split($4,a,":"); print a[n]}' | sort -un | tr '\n' ' ')
    info "Слушают TCP" "${LT:-—}"
    info "Слушают UDP" "${LU:-—}"
  fi

  # ================================================================ IP и хостер
  section "IP и хостер"
  ASN_RISKY=0
  if [ -n "$IP4" ]; then
    IPAPI=$(T=8 get "http://ip-api.com/json/$IP4?fields=status,country,countryCode,city,isp,org,as,hosting,proxy")
    if [ "$(printf '%s' "$IPAPI" | json_get status)" = success ]; then
      CC2=$(printf '%s' "$IPAPI" | json_get countryCode)
      AS=$(printf '%s' "$IPAPI" | json_get as)
      info "Локация" "$(printf '%s' "$IPAPI" | json_get country), $(printf '%s' "$IPAPI" | json_get city) ($CC2)"
      info "Провайдер" "$(printf '%s' "$IPAPI" | json_get isp) · $AS"
      case "$CC2" in
        RU) warn "Страна" "Россия — для обхода блокировок не годится"; hint "подойдёт как входной мост в цепочке РФ → зарубежная нода" ;;
        BY|CN|IR|TM|KP) warn "Страна" "$CC2 — в стране своя цензура, для выхода в интернет не подходит" ;;
      esac
      if [ "$(printf '%s' "$IPAPI" | json_get proxy)" = true ]; then
        warn "Репутация IP" "помечен как proxy/VPN — часть сервисов будет капчить или блокировать"
      else
        ok "Репутация IP" "не помечен как proxy/VPN (ip-api.com)"
      fi
      ASN=${AS%% *}
      for e in $RISKY_ASNS; do
        if [ "${e%%:*}" = "$ASN" ]; then
          ASN_RISKY=1
          warn "Хостер и ТСПУ" "${e#*:} ($ASN) — из РФ к нему по отчётам режут/замедляют трафик"
          hint "проверьте реальную скорость с клиента в РФ до запуска в продакшн"
        fi
      done
    else
      info "Локация" "ip-api.com не ответил"
    fi
    CF_LOC=$(T=6 get https://www.cloudflare.com/cdn-cgi/trace | awk -F= '$1=="loc"{print $2}')
    if [ -n "$CF_LOC" ]; then
      if [ -n "${CC2:-}" ] && [ "$CF_LOC" != "$CC2" ]; then
        warn "Геолокация" "ip-api: $CC2, Cloudflare: $CF_LOC — сервисы видят разные страны"
      else
        info "Cloudflare видит" "$CF_LOC"
      fi
    fi
  fi

  # ================================================================ Доступ из РФ
  section "Доступность из России (check-host.net)"
  RU_TCP=-1; RU_PING=""
  if [ "$CHECK_RU" = 0 ]; then
    info "Пропущено" "--no-ru"
  elif [ -z "$IP4" ]; then
    info "Пропущено" "нет публичного IPv4"
  elif [ -z "$RU_PID" ]; then
    warn "Проверка из РФ" "нужен python3"
    hint "вручную: https://check-host.net/check-tcp?host=$IP4:$CHECK_PORT"
  else
    if ! ss -lnt 2>/dev/null | awk -v p="$CHECK_PORT" 'NR>1{n=split($4,a,":"); if(a[n]==p) f=1} END{exit !f}'; then
      info "Порт для проверки" "$CHECK_PORT — похоже, никто не слушает; укажите открытый: --port N"
    else
      info "Порт для проверки" "TCP $CHECK_PORT"
    fi
    wait "$RU_PID" 2>/dev/null
    RU_PID=""
    while IFS='|' read -r st a b; do
      case "$st" in
        OK) ok "$a" "$b" ;; WARN) warn "$a" "$b" ;; FAIL) fail "$a" "$b" ;;
        INFO) info "$a" "$b" ;; HINT) hint "$a" ;;
        RU_TCP) RU_TCP=$a ;; RU_PING) RU_PING=$a ;;
      esac
    done < "$TMPD/ru.out"
    [ -n "$RU_PING" ] && info "Средний ping из РФ" "$RU_PING мс"
  fi

  # ================================================================ Сервисы
  section "Доступ к сервисам с этого IP"
  r=$(curl -s -o /dev/null --max-time 10 -A "$UA" -w '%{http_code} %{redirect_url}' 'https://www.google.com/search?q=weather' 2>/dev/null)
  case "$r" in
    *sorry*|429*) warn "Google" "капча — IP помечен как подозрительный" ;;
    2*|3*)        ok "Google" "без капчи" ;;
    000*)         warn "Google" "нет соединения" ;;
    *)            info "Google" "ответ ${r%% *}" ;;
  esac

  YT=$(T=12 get -H 'Accept-Language: en-US' https://www.youtube.com/)
  if [ -n "$YT" ]; then
    GL=$(printf '%s' "$YT" | grep -oE '"INNERTUBE_CONTEXT_GL":"[A-Z]{2}"' | head -n1 | grep -oE '[A-Z]{2}"$' | tr -d '"')
    ok "YouTube" "доступен${GL:+ (регион: $GL)}"
  else
    warn "YouTube" "нет соединения"
  fi

  O=$(T=10 get -H 'Authorization: Bearer null' https://api.openai.com/compliance/cookie_requirements)
  if [ -z "$O" ]; then warn "ChatGPT / OpenAI" "нет ответа"
  elif printf '%s' "$O" | grep -qi unsupported_country; then warn "ChatGPT / OpenAI" "регион не поддерживается"
  else ok "ChatGPT / OpenAI" "доступен"; fi

  r=$(curl -s -o /dev/null --max-time 10 -A "$UA" -w '%{http_code} %{redirect_url}' https://claude.ai/ 2>/dev/null)
  case "$r" in
    *unavailable*) warn "Claude" "регион не поддерживается" ;;
    2*|3*)         ok "Claude" "доступен" ;;
    403*)          info "Claude" "не определить (защита Cloudflare)" ;;
    *)             warn "Claude" "нет соединения (${r%% *})" ;;
  esac

  n1=$(code -L https://www.netflix.com/title/81280792); n2=$(code -L https://www.netflix.com/title/70143836)
  if [ "$n1" = 200 ] || [ "$n2" = 200 ]; then ok "Netflix" "полный каталог региона"
  elif [ "$n1" = 404 ] && [ "$n2" = 404 ]; then warn "Netflix" "только собственные сериалы Netflix"
  else warn "Netflix" "недоступен ($n1/$n2)"; fi

  for s in "Instagram|https://www.instagram.com/" "Telegram|https://api.telegram.org/" \
           "Discord|https://discord.com/" "Spotify|https://open.spotify.com/" "X (Twitter)|https://x.com/"; do
    c=$(code "${s#*|}")
    case "$c" in
      2*|3*)   ok "${s%%|*}" "доступен" ;;
      000)     warn "${s%%|*}" "нет соединения" ;;
      403|451) warn "${s%%|*}" "блокирует этот IP ($c)" ;;
      *)       info "${s%%|*}" "ответ $c" ;;
    esac
  done

  # ================================================================ Скорость
  if [ "$FAST" = 0 ]; then
    section "Скорость (до ближайшего узла Cloudflare)"
    for dir in down up; do
      if [ "$dir" = down ]; then
        v=$(curl -s -o /dev/null --max-time 15 -w '%{speed_download}' 'https://speed.cloudflare.com/__down?bytes=100000000' 2>/dev/null)
        lbl="Входящая"
      else
        v=$(head -c 30000000 /dev/zero | curl -s -o /dev/null --max-time 20 -w '%{speed_upload}' -X POST --data-binary @- https://speed.cloudflare.com/__up 2>/dev/null)
        lbl="Исходящая"
      fi
      if isnum "${v:-x}" && fge "$v" 1; then
        m=$(mbit "$v")
        if [ "$m" -ge 200 ]; then ok "$lbl" "$(rate "$m")"
        elif [ "$m" -ge 50 ]; then warn "$lbl" "$(rate "$m") — средне"
        else fail "$lbl" "$(rate "$m") — мало для VPN"; fi
      else
        warn "$lbl" "не удалось измерить"
      fi
    done
    hint "для VPN важнее исходящая: это скорость скачивания у ваших пользователей"
  fi

  # ================================================================ Итог
  section "Итог по протоколам"
  proto() {
    local icon
    case "$1" in ok) icon="${G}✔${N}" ;; warn) icon="${Y}!${N}" ;; *) icon="${R}✖${N}" ;; esac
    printf '  %s %s%s\n' "$icon" "$(pad "$2")" "$3"
  }
  # degrade fail|warn "причина"
  degrade() { if [ "$1" = fail ]; then st=fail; elif [ "$st" = ok ]; then st=warn; fi; why+=("$2"); }
  why_txt() { local IFS=';'; local s="${why[*]}"; [ -n "$s" ] && echo "${s//;/, }" || echo "$1"; }
  base() {   # общие условия для всех протоколов
    st=ok; why=()
    [ "$HAS_IP4" = 0 ] && degrade fail "нет IPv4"
    [ "$RU_TCP" = 0 ] && degrade fail "IP недоступен из РФ"
    [ "$RAM_MB" -lt 256 ] && degrade fail "мало ОЗУ"
    [ "$BEHIND_NAT" = 1 ] && degrade warn "NAT"
    [ "$ASN_RISKY" = 1 ] && degrade warn "хостер под риском ТСПУ"
  }

  base
  [ "$TIME_BAD" = 1 ] && degrade fail "время сбито"
  [ "$P443_BUSY" = 1 ] && degrade warn "443 занят"
  [ "$RAM_MB" -lt 512 ] && degrade warn "ОЗУ < 512 МБ"
  proto "$st" "Xray: VLESS-Reality" "$(why_txt 'подходит')"

  base
  [ "$CONTAINER" = 1 ] && degrade warn "контейнер — Docker под вопросом"
  [ "$RAM_MB" -lt 900 ] && degrade warn "ОЗУ < 1 ГБ"
  [ "$TIME_BAD" = 1 ] && degrade fail "время сбито"
  [ "$P443_BUSY" = 1 ] && degrade warn "443 занят"
  [ "$DISK_FREE" -lt 1500 ] && degrade fail "мало диска"
  proto "$st" "Нода Remnawave" "$(why_txt 'подходит (Docker + Xray)')"

  base
  [ "$UDP_OUT" = 0 ] && degrade warn "UDP режется"
  proto "$st" "Hysteria2 / TUIC" "$(why_txt 'подходит') ${D}(входящий UDP не проверялся; в РФ QUIC часто режут)$N"

  base
  if [ "$TUN" = 0 ]; then
    if [ "$MODS_OK" = 0 ]; then degrade fail "нет TUN и модулей ядра"; else degrade warn "нет TUN — только модуль ядра"; fi
  elif [ "$MODS_OK" = 0 ]; then degrade warn "только amneziawg-go"; fi
  [ "$FWD" = 0 ] && degrade fail "нет ip_forward"
  [ "$NAT" = 0 ] && degrade fail "нет NAT"
  [ "$UDP_OUT" = 0 ] && degrade warn "UDP режется"
  proto "$st" "AmneziaWG" "$(why_txt 'подходит')"

  base
  [ "$WG_KERNEL" = 0 ] && { if [ "$TUN" = 1 ]; then degrade warn "только wireguard-go"; else degrade fail "нет WG и TUN"; fi; }
  [ "$FWD" = 0 ] && degrade fail "нет ip_forward"
  [ "$NAT" = 0 ] && degrade fail "нет NAT"
  proto "$st" "WireGuard" "$(why_txt 'подходит') ${D}(в РФ блокируется DPI — лучше AmneziaWG)$N"

  base
  [ "$TUN" = 0 ] && degrade fail "нет TUN"
  [ "$FWD" = 0 ] && degrade fail "нет ip_forward"
  [ "$NAT" = 0 ] && degrade fail "нет NAT"
  proto "$st" "OpenVPN" "$(why_txt 'подходит') ${D}(в РФ блокируется DPI)$N"

  section "Вердикт"
  if [ "$NFAIL" = 0 ] && [ "$NWARN" -le 2 ]; then
    printf '  %s%s✔ VPS подходит под VPN-сервер%s\n' "$BOLD" "$G" "$N"
  elif [ "$NFAIL" = 0 ]; then
    printf '  %s%s! Подходит, но есть замечания%s\n' "$BOLD" "$Y" "$N"
  else
    printf '  %s%s✖ Есть критичные проблемы%s\n' "$BOLD" "$R" "$N"
  fi
  printf '  %d ✔   %d !   %d ✖\n' "$PASS" "$NWARN" "$NFAIL"
  [ ${#FAIL_L[@]} -gt 0 ] && for x in "${FAIL_L[@]}"; do printf '  %s✖%s %s\n' "$R" "$N" "$x"; done
  [ ${#WARN_L[@]} -gt 0 ] && for x in "${WARN_L[@]}"; do printf '  %s!%s %s\n' "$Y" "$N" "$x"; done

  printf '\n%sНе проверяется: входящий UDP из РФ, замедление ТСПУ на объёме (тест с клиента в РФ),\nлимиты трафика и отношение хостера к VPN в ToS.%s\n' "$D" "$N"
}

main "$@"
