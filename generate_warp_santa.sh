#!/bin/bash
#
# Регистрирует аккаунт Cloudflare WARP и сохраняет готовый конфиг в файл.
# По умолчанию регистрируется напрямую у Cloudflare: пара ключей создаётся на этом
# компьютере, и приватный ключ никуда не отправляется. Если не получилось —
# берёт конфиг у santa-atmo.ru.
# Запустите с --help, чтобы увидеть все параметры.
# Работает и со старым bash 3.2 (macOS).

WARP_API_URL="${WARP_API_URL:-https://santa-atmo.ru/warp/warp.php}"

# API регистрации, которым пользуется приложение 1.1.1.1. Версия и заголовки — как в wgcf
# (https://github.com/ViRb3/wgcf, cloudflare/api.go); если Cloudflare начнёт отказывать,
# сверьтесь со свежей версией wgcf.
CF_API_URL="${CF_API_URL:-https://api.cloudflareclient.com/v0a5641/reg}"
CF_USER_AGENT="1.1.1.1/6.38.9-5641 (Android 16.0.0)"
CF_CLIENT_VERSION="a-6.38.9-5641"

usage()
{
    cat <<'USAGE'
Использование: generate_warp_santa.sh [параметры]

Без параметров регистрирует новый аккаунт WARP и спрашивает имя файла.

Параметры:
  -s, --source SOURCE     auto (по умолчанию) — напрямую у Cloudflare, а если не вышло — santa;
                          cloudflare — только напрямую (ключ создаётся на этом компьютере);
                          santa — только через santa-atmo.ru (ключ создаёт их сервер)
  -f, --format FORMAT     awg (по умолчанию) — AmneziaWG с маскировкой трафика;
                          wg — обычный WireGuard (работает, только где WARP не блокируют)
  -d, --dns DNS           cloudflare (по умолчанию), google, comss, malw
                          или свои адреса через запятую: "9.9.9.9, 2620:fe::fe"
  -e, --endpoint HOST:PORT
                          сервер WARP (по умолчанию 162.159.192.1:500);
                          IPv6 — в квадратных скобках: [2606:4700:d0::a29f:c001]:2408
  -p, --port PORT         только сменить порт (500, 2408, 1701, 4500 или свой)
  -a, --allowed-ips IPS   all (по умолчанию) — весь трафик; nolan — кроме локальных сетей;
                          ipv4 — только IPv4; или свой список подсетей через запятую
      --mtu N             MTU, 1280–1500 (по умолчанию 1280)
      --keepalive N       PersistentKeepalive в секундах, 0–65535 (по умолчанию 25; 0 — выкл.)
  -o, --out FILE          куда сохранить; «-» — вывести в консоль.
                          По умолчанию warp_santa_<dns>.conf (для wg — warp_santa_<dns>_wg.conf)
  -j, --json FILE         взять готовый JSON-ответ santa из файла («-» — из stdin)
                          вместо регистрации
      --force             перезаписать существующий файл без вопроса
  -h, --help              показать эту справку

Примеры:
  generate_warp_santa.sh
  generate_warp_santa.sh --dns google --port 2408 -o home.conf
  generate_warp_santa.sh -f wg -a nolan -o router.conf
  generate_warp_santa.sh --json response.json -o - > warp.conf
USAGE
}

die()
{
    echo "Ошибка: $*" >&2
    exit 1
}

info()
{
    echo "$*" >&2
}

# Шаблон конфига общий со страницей index.html.
# Берём template.conf рядом со скриптом, а если его нет (скрипт скачан отдельно) —
# загружаем из репозитория.
TEMPLATE_URL="https://raw.githubusercontent.com/shvartem/santa-warp-config/main/template.conf"

# ---------- Значения по умолчанию и пресеты (держать в синхронизации с index.html) ----------
DEFAULT_ENDPOINT_HOST="162.159.192.1"
DEFAULT_ENDPOINT_PORT="500"

dnsPreset()
{
    case "$1" in
        cloudflare) echo "1.1.1.1, 2606:4700:4700::1111, 1.0.0.1, 2606:4700:4700::1001" ;;
        google)     echo "8.8.8.8, 2001:4860:4860::8888, 8.8.4.4, 2001:4860:4860::8844" ;;
        comss)      echo "83.220.169.155, 212.109.195.93" ;;
        malw)       echo "84.21.189.133, 2a12:bec4:1460:294::2, 193.23.209.189, 2a01:ecc0:680:120::2" ;;
        *)          return 1 ;;
    esac
}

# Весь IPv4, кроме 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 и 224.0.0.0/3 —
# как «Exclude private IPs» в приложении WireGuard
IPV4_WITHOUT_LAN="0.0.0.0/5, 8.0.0.0/7, 11.0.0.0/8, 12.0.0.0/6, 16.0.0.0/4, 32.0.0.0/3, \
64.0.0.0/2, 128.0.0.0/3, 160.0.0.0/5, 168.0.0.0/6, 172.0.0.0/12, 172.32.0.0/11, \
172.64.0.0/10, 172.128.0.0/9, 173.0.0.0/8, 174.0.0.0/7, 176.0.0.0/4, 192.0.0.0/9, \
192.128.0.0/11, 192.160.0.0/13, 192.169.0.0/16, 192.170.0.0/15, 192.172.0.0/14, \
192.176.0.0/12, 192.192.0.0/10, 193.0.0.0/8, 194.0.0.0/7, 196.0.0.0/6, 200.0.0.0/5, 208.0.0.0/4"

allowedIpsPreset()
{
    case "$1" in
        all)   echo "0.0.0.0/0, ::/0" ;;
        nolan) echo "$IPV4_WITHOUT_LAN, ::/0" ;;
        ipv4)  echo "0.0.0.0/0" ;;
        *)     return 1 ;;
    esac
}

# Параметры маскировки AmneziaWG, которых нет в обычном WireGuard
AWG_ONLY_KEYS='^[[:space:]]*(Jc|Jmin|Jmax|S[1-4]|H[1-4]|I[1-5]|J[1-3]|Itime)[[:space:]]*='

# ---------- Проверки ввода ----------
isIpv4()
{
    local re='^((25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])\.){3}(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])$'
    [[ "$1" =~ $re ]]
}

# Упрощённая проверка IPv6: шестнадцатеричные группы, двоеточия, не больше одного «::»
isIpv6()
{
    local a=$1
    [[ "$a" == *:* ]] || return 1
    [[ "$a" =~ ^[0-9a-fA-F:.]+$ ]] || return 1
    [[ "$a" != *:::* ]] || return 1
    local rest=${a#*::}
    [[ "$rest" != *::* ]] || return 1
    return 0
}

isUint()
{
    [[ "$1" =~ ^[0-9]+$ ]] && (( 10#$1 >= $2 && 10#$1 <= $3 ))
}

# Разбивает список по запятым и пробелам, печатает элементы по одному в строке
splitList()
{
    echo "$1" | tr ', ' '\n\n' | sed '/^$/d'
}

joinLines()
{
    paste -sd, - | sed 's/,/, /g'
}

parseDns()
{
    local preset
    if preset=$(dnsPreset "$1"); then
        echo "$preset"
        return
    fi
    local item items
    items=$(splitList "$1")
    [[ -n "$items" ]] || die "укажите DNS: cloudflare, google, comss, malw или свои адреса"
    while read -r item; do
        isIpv4 "$item" || isIpv6 "$item" || die "некорректный адрес DNS-сервера: $item (пресеты: cloudflare, google, comss, malw)"
    done <<< "$items"
    echo "$items" | joinLines
}

parseAllowedIps()
{
    local preset
    if preset=$(allowedIpsPreset "$1"); then
        echo "$preset"
        return
    fi
    local item items addr prefix
    items=$(splitList "$1")
    [[ -n "$items" ]] || die "укажите AllowedIPs: all, nolan, ipv4 или свой список подсетей"
    while read -r item; do
        addr=${item%%/*}
        prefix=""
        [[ "$item" == */* ]] && prefix=${item#*/}
        if isIpv4 "$addr"; then
            [[ -z "$prefix" ]] || isUint "$prefix" 0 32 || die "некорректная подсеть в AllowedIPs: $item"
        elif isIpv6 "$addr"; then
            [[ -z "$prefix" ]] || isUint "$prefix" 0 128 || die "некорректная подсеть в AllowedIPs: $item"
        else
            die "некорректная подсеть в AllowedIPs: $item (пресеты: all, nolan, ipv4)"
        fi
    done <<< "$items"
    echo "$items" | joinLines
}

# host:port → проверенный endpoint; IPv6 должен быть в []
parseEndpoint()
{
    local value=$1 host port
    if [[ "$value" =~ ^\[([^]]+)\]:([0-9]+)$ ]]; then
        host=${BASH_REMATCH[1]}
        port=${BASH_REMATCH[2]}
        isIpv6 "$host" || die "некорректный IPv6-адрес сервера: $host"
        host="[$host]"
    elif [[ "$value" =~ ^([^:]+):([0-9]+)$ ]]; then
        host=${BASH_REMATCH[1]}
        port=${BASH_REMATCH[2]}
        [[ "$host" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)*$ ]] \
            || die "некорректный адрес сервера: $host"
    else
        die "endpoint нужно указать как HOST:PORT (IPv6 — [адрес]:PORT): $value"
    fi
    isUint "$port" 1 65535 || die "порт должен быть числом от 1 до 65535: $port"
    echo "$host:$((10#$port))"
}

# ---------- Получение конфига ----------
# Обе функции при успехе кладут в response_body JSON в формате santa:
#   {"result": {"key": <приватный ключ>, "config": {"peers": [...], "interface": {...}}}}
# а при ошибке пишут причину в stderr и возвращают 1.

# santa-atmo.ru: сервер сам регистрирует аккаунт и присылает в том числе приватный ключ
fetchFromSanta()
{
    command -v curl > /dev/null 2>&1 || { info "Не найден curl"; return 1; }
    info "Запрашиваю конфиг у $WARP_API_URL..."
    local result http_code
    result=$(curl -sS --connect-timeout 20 --max-time 60 -w "\n%{http_code}" "$WARP_API_URL" \
        -A 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36' \
        -H "referer: $WARP_API_URL" \
        -H "Origin: $WARP_API_URL") || { info "Не удалось связаться с $WARP_API_URL"; return 1; }
    http_code=${result##*$'\n'}
    response_body=${result%$'\n'*}
    if [[ "$http_code" != "200" ]]; then
        info "Ответ: ${response_body:0:200}"
        info "Сервер $WARP_API_URL вернул код $http_code"
        return 1
    fi
    return 0
}

# Пара ключей X25519 (как у WireGuard) в base64. Печатает «приватный публичный».
# Пробует по очереди wg, openssl и python3 — что найдётся на компьютере.
generateKeys()
{
    local priv pub der
    if command -v wg > /dev/null 2>&1; then
        priv=$(wg genkey) && pub=$(printf '%s' "$priv" | wg pubkey)
    elif command -v openssl > /dev/null 2>&1 \
        && der=$(openssl genpkey -algorithm X25519 -outform DER 2> /dev/null | openssl base64 -A) \
        && [[ -n "$der" ]]; then
        # DER-обёртка ключа X25519 фиксированной длины: сам ключ — последние 32 байта
        priv=$(printf '%s' "$der" | openssl base64 -d -A | tail -c 32 | openssl base64 -A)
        pub=$(printf '%s' "$der" | openssl base64 -d -A \
            | openssl pkey -inform DER -pubout -outform DER 2> /dev/null | tail -c 32 | openssl base64 -A)
    elif command -v python3 > /dev/null 2>&1; then
        # X25519 по RFC 7748 на чистом Python — без сторонних библиотек
        read -r priv pub < <(python3 -I -c '
import os, base64
P = 2**255 - 19
def x25519(k, u):
    k = int.from_bytes(k, "little")
    x1, x2, z2, x3, z3, swap = u, 1, 0, u, 1, 0
    for t in reversed(range(255)):
        bit = (k >> t) & 1
        swap ^= bit
        if swap:
            x2, x3, z2, z3 = x3, x2, z3, z2
        swap = bit
        a, b, c, d = x2 + z2, x2 - z2, x3 + z3, x3 - z3
        aa, bb, da, cb = a * a, b * b, d * a, c * b
        e = aa - bb
        x3, z3 = (da + cb) ** 2 % P, u * (da - cb) ** 2 % P
        x2, z2 = aa * bb % P, e * (aa + 121665 * e) % P
    if swap:
        x2, z2 = x3, z3
    return (x2 * pow(z2, P - 2, P) % P).to_bytes(32, "little")
k = bytearray(os.urandom(32))
k[0] &= 248; k[31] &= 127; k[31] |= 64
k = bytes(k)
print(base64.b64encode(k).decode(), base64.b64encode(x25519(k, 9)).decode())
')
    fi
    # Ключ WireGuard в base64 — ровно 44 символа
    if [[ ${#priv} -ne 44 || ${#pub} -ne 44 ]]; then
        info "Не удалось создать ключи: нужен wg, openssl 1.1+ или python3"
        return 1
    fi
    echo "$priv $pub"
}

# Регистрация напрямую у Cloudflare: отправляется только публичный ключ
fetchFromCloudflare()
{
    command -v curl > /dev/null 2>&1 || { info "Не найден curl"; return 1; }
    local keys priv pub tos body result http_code
    keys=$(generateKeys) || return 1
    priv=${keys% *}
    pub=${keys#* }

    tos=$(date -u +%Y-%m-%dT%H:%M:%S.000Z)
    body=$(jq -cn --arg key "$pub" --arg tos "$tos" '{
        key: $key, install_id: "", fcm_token: "", tos: $tos, model: "PC",
        serial_number: "", locale: "en_US", os_version: "16.0.0",
        key_type: "curve25519", tunnel_type: "wireguard"
    }')

    info "Регистрирую аккаунт WARP напрямую у Cloudflare..."
    # TLS 1.2 — как у приложения 1.1.1.1
    result=$(curl -sS --tlsv1.2 --tls-max 1.2 --connect-timeout 20 --max-time 60 \
        -w "\n%{http_code}" -X POST "$CF_API_URL" \
        -H "User-Agent: $CF_USER_AGENT" \
        -H "CF-Client-Version: $CF_CLIENT_VERSION" \
        -H "Content-Type: application/json; charset=UTF-8" \
        -d "$body") || { info "Не удалось связаться с Cloudflare"; return 1; }
    http_code=${result##*$'\n'}
    result=${result%$'\n'*}
    if [[ "$http_code" != "200" ]]; then
        info "Cloudflare вернул код $http_code: ${result:0:200}"
        return 1
    fi

    # Приводим ответ к формату santa и добавляем наш приватный ключ
    if ! response_body=$(echo "$result" | jq -ce --arg key "$priv" '
            select(.config.peers[0].public_key and .config.interface.addresses.v4
                   and .config.interface.addresses.v6)
            | {result: (. + {key: $key})}' 2> /dev/null); then
        info "Неожиданный ответ Cloudflare: ${result:0:200}"
        return 1
    fi
    return 0
}


loadTemplate()
{
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [[ -f "$script_dir/template.conf" ]]; then
        cat "$script_dir/template.conf"
    else
        curl -fsS --connect-timeout 20 --max-time 60 "$TEMPLATE_URL"
    fi
}

confWarpBuilder()
{
    local response_body=$1
    local template=$2
    local peer_pub client_ipv4 client_ipv6 priv
    peer_pub=$(echo "$response_body" | jq -r '.result.config.peers[0].public_key // empty')
    client_ipv4=$(echo "$response_body" | jq -r '.result.config.interface.addresses.v4 // empty')
    client_ipv6=$(echo "$response_body" | jq -r '.result.config.interface.addresses.v6 // empty')
    priv=$(echo "$response_body" | jq -r '.result.key // empty')

    if [[ -z "$peer_pub" || -z "$client_ipv4" || -z "$client_ipv6" || -z "$priv" ]]; then
        echo "Ошибка: в ответе сервера нет нужных полей (ключи или адреса)" >&2
        return 1
    fi

    # Кавычки вокруг подстановки обязательны: в bash 5.2 символ & в ней иначе спецсимвол
    local conf=$template
    conf=${conf//"{{PRIVATE_KEY}}"/"$priv"}
    conf=${conf//"{{ADDRESS}}"/"$client_ipv4, $client_ipv6"}
    conf=${conf//"{{DNS}}"/"$opt_dns"}
    conf=${conf//"{{ENDPOINT}}"/"$opt_endpoint"}
    conf=${conf//"{{MTU}}"/"$opt_mtu"}
    conf=${conf//"{{ALLOWED_IPS}}"/"$opt_allowed_ips"}
    conf=${conf//"{{KEEPALIVE}}"/"$opt_keepalive"}
    conf=${conf//"{{PEER_PUBLIC_KEY}}"/"$peer_pub"}

    # Защита от расхождения шаблона и скрипта: незаполненных полей быть не должно
    if [[ "$conf" =~ \{\{[A-Z_]+\}\} ]]; then
        echo "Ошибка: в шаблоне есть незаполненное поле ${BASH_REMATCH[0]} — скачайте свежую версию скрипта" >&2
        return 1
    fi

    if [[ "$opt_format" == "wg" ]]; then
        echo "$conf" | grep -Ev "$AWG_ONLY_KEYS"
    else
        echo "$conf"
    fi
}

# ---------- Разбор параметров ----------
opt_format="awg"
dns_name="cloudflare"
opt_dns_arg="cloudflare"
endpoint_arg=""
port_arg=""
allowed_arg="all"
opt_mtu="1280"
opt_keepalive="25"
out_arg=""
json_arg=""
opt_source="auto"
force=0

needArg()
{
    [[ -n "$2" ]] || die "параметру $1 нужно значение (см. --help)"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)        usage; exit 0 ;;
        -s|--source)      needArg "$1" "$2"; opt_source=$2; shift 2 ;;
        -f|--format)      needArg "$1" "$2"; opt_format=$2; shift 2 ;;
        -d|--dns)         needArg "$1" "$2"; opt_dns_arg=$2; shift 2 ;;
        -e|--endpoint)    needArg "$1" "$2"; endpoint_arg=$2; shift 2 ;;
        -p|--port)        needArg "$1" "$2"; port_arg=$2; shift 2 ;;
        -a|--allowed-ips) needArg "$1" "$2"; allowed_arg=$2; shift 2 ;;
        --mtu)            needArg "$1" "$2"; opt_mtu=$2; shift 2 ;;
        --keepalive)      needArg "$1" "$2"; opt_keepalive=$2; shift 2 ;;
        -o|--out)         needArg "$1" "$2"; out_arg=$2; shift 2 ;;
        -j|--json)        needArg "$1" "$2"; json_arg=$2; shift 2 ;;
        --force)          force=1; shift ;;
        *)                die "неизвестный параметр: $1 (см. --help)" ;;
    esac
done

# ---------- Проверка параметров (до запроса к API, чтобы не тратить его зря) ----------
case "$opt_format" in
    awg|wg) ;;
    *) die "формат должен быть awg или wg: $opt_format" ;;
esac
case "$opt_source" in
    auto|cloudflare|santa) ;;
    *) die "источник должен быть auto, cloudflare или santa: $opt_source" ;;
esac
[[ -z "$json_arg" || "$opt_source" == "auto" ]] || die "укажите либо --json, либо --source, но не оба"

opt_dns=$(parseDns "$opt_dns_arg") || exit 1
if dnsPreset "$opt_dns_arg" > /dev/null; then
    dns_name=$opt_dns_arg
else
    dns_name="custom"
fi

[[ -z "$endpoint_arg" || -z "$port_arg" ]] || die "укажите либо --endpoint, либо --port, но не оба"
if [[ -n "$endpoint_arg" ]]; then
    opt_endpoint=$(parseEndpoint "$endpoint_arg") || exit 1
else
    opt_endpoint=$(parseEndpoint "$DEFAULT_ENDPOINT_HOST:${port_arg:-$DEFAULT_ENDPOINT_PORT}") || exit 1
fi

opt_allowed_ips=$(parseAllowedIps "$allowed_arg") || exit 1
isUint "$opt_mtu" 1280 1500 || die "MTU должен быть целым числом от 1280 до 1500: $opt_mtu"
isUint "$opt_keepalive" 0 65535 || die "PersistentKeepalive должен быть целым числом от 0 до 65535: $opt_keepalive"
opt_mtu=$((10#$opt_mtu))
opt_keepalive=$((10#$opt_keepalive))

# ---------- Зависимости ----------
command -v jq > /dev/null 2>&1 || die "не найден jq. Установите его: sudo apt install jq / brew install jq"
if [[ -z "$json_arg" ]] || [[ ! -f "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/template.conf" ]]; then
    command -v curl > /dev/null 2>&1 || die "не найден curl. Установите его: sudo apt install curl / brew install curl"
fi

# ---------- Получаем JSON ----------
if [[ -n "$json_arg" ]]; then
    if [[ "$json_arg" == "-" ]]; then
        response_body=$(cat)
    else
        [[ -f "$json_arg" ]] || die "файл не найден: $json_arg"
        response_body=$(cat "$json_arg")
    fi
else
    case "$opt_source" in
        cloudflare)
            fetchFromCloudflare || die "не удалось зарегистрироваться у Cloudflare (попробуйте --source santa)"
            ;;
        santa)
            fetchFromSanta || die "не удалось получить конфиг у santa-atmo.ru"
            ;;
        auto)
            if ! fetchFromCloudflare; then
                info "Пробую через santa-atmo.ru (приватный ключ в этом случае создаёт их сервер)..."
                fetchFromSanta || die "не удалось получить конфиг ни у Cloudflare, ни у santa-atmo.ru"
            fi
            ;;
    esac
fi

[[ -n "$response_body" ]] || die "пустой ответ"
if ! echo "$response_body" | jq -e . > /dev/null 2>&1; then
    info "Ответ: ${response_body:0:200}..."
    die "получен невалидный JSON"
fi

# ---------- Собираем конфиг ----------
template=$(loadTemplate) && [[ -n "$template" ]] || die "не удалось получить шаблон template.conf"
result_warp_config=$(confWarpBuilder "$response_body" "$template") && [[ -n "$result_warp_config" ]] \
    || die "не удалось собрать конфигурацию"

# ---------- Сохраняем ----------
if [[ "$out_arg" == "-" ]]; then
    echo "$result_warp_config"
    exit 0
fi

default_name="warp_santa_${dns_name}"
[[ "$opt_format" == "wg" ]] && default_name="${default_name}_wg"

filename=$out_arg
if [[ -z "$filename" ]]; then
    if [[ -t 0 ]]; then
        read -r -p "Имя файла (Enter — ${default_name}.conf): " filename
    fi
    filename=${filename:-$default_name}
fi
[[ "$filename" == *.conf ]] || filename="${filename}.conf"

if [[ -e "$filename" && $force -eq 0 ]]; then
    if [[ -t 0 ]]; then
        read -r -p "Файл $filename уже существует. Перезаписать? [y/N] " answer
        case "$answer" in
            y|Y|yes|д|Д|да) ;;
            *) die "файл не перезаписан. Укажите другое имя (-o) или --force" ;;
        esac
    else
        die "файл $filename уже существует. Укажите другое имя (-o) или --force"
    fi
fi

# Ключ приватный — файл доступен только владельцу
( umask 077 && printf '%s\n' "$result_warp_config" > "$filename" ) || die "не удалось записать $filename"

format_name="AmneziaWG"
[[ "$opt_format" == "wg" ]] && format_name="WireGuard"
info "✅ Конфигурация $format_name (DNS: $dns_name, endpoint: $opt_endpoint) сохранена в $filename"
