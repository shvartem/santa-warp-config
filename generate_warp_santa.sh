#!/bin/bash
#
# Получает конфиг Cloudflare WARP через API santa-atmo.ru и сохраняет его в файл.
# Запустите с --help, чтобы увидеть все параметры.
# Работает и со старым bash 3.2 (macOS).

WARP_API_URL="${WARP_API_URL:-https://santa-atmo.ru/warp/warp.php}"

usage()
{
    cat <<'USAGE'
Использование: generate_warp_santa.sh [параметры]

Без параметров запрашивает конфиг у API и спрашивает имя файла.

Параметры:
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
  -j, --json FILE         взять готовый JSON-ответ API из файла («-» — из stdin)
                          вместо запроса к API
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

# Запрос к API; печатает тело ответа и последней строкой HTTP-код
requestConfWARP()
{
    curl -sS --connect-timeout 20 --max-time 60 -w "\n%{http_code}" "$WARP_API_URL" \
        -A 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36' \
        -H "referer: $WARP_API_URL" \
        -H "Origin: $WARP_API_URL"
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
force=0

needArg()
{
    [[ -n "$2" ]] || die "параметру $1 нужно значение (см. --help)"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)        usage; exit 0 ;;
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
    info "Запрашиваю конфиг у $WARP_API_URL..."
    result=$(requestConfWARP) || die "не удалось связаться с $WARP_API_URL"
    http_code=${result##*$'\n'}
    response_body=${result%$'\n'*}
    if [[ "$http_code" != "200" ]]; then
        info "Ответ: ${response_body:0:200}"
        die "сервер вернул код $http_code"
    fi
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
