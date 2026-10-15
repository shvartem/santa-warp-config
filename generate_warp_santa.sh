#!/bin/bash

requestConfWARP1()
{
    warp_address="https://santa-atmo.ru/warp/warp.php"
    # запрос конфигурации WARP
    local response=$(curl --connect-timeout 20 --max-time 60 -w "%{http_code}" "$warp_address" \
        -A 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36' \
        -H "referer: $warp_address" \
        -H "Origin: $warp_address")
    echo "$response"
}

# Шаблон конфига общий со страницей index.html.
# Берём template.conf рядом со скриптом, а если его нет (скрипт скачан отдельно) —
# загружаем из репозитория.
TEMPLATE_URL="https://raw.githubusercontent.com/shvartem/santa-warp-config/main/template.conf"
DNS_DEFAULT="1.1.1.1, 2606:4700:4700::1111, 1.0.0.1, 2606:4700:4700::1001"
ENDPOINT_DEFAULT="162.159.192.1:500"
MTU_DEFAULT="1280"
ALLOWED_IPS_DEFAULT="0.0.0.0/0, ::/0"
KEEPALIVE_DEFAULT="25"

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
    conf=${conf//"{{DNS}}"/"$DNS_DEFAULT"}
    conf=${conf//"{{ENDPOINT}}"/"$ENDPOINT_DEFAULT"}
    conf=${conf//"{{MTU}}"/"$MTU_DEFAULT"}
    conf=${conf//"{{ALLOWED_IPS}}"/"$ALLOWED_IPS_DEFAULT"}
    conf=${conf//"{{KEEPALIVE}}"/"$KEEPALIVE_DEFAULT"}
    conf=${conf//"{{PEER_PUBLIC_KEY}}"/"$peer_pub"}

    # Защита от расхождения шаблона и скрипта: незаполненных полей быть не должно
    if [[ "$conf" =~ \{\{[A-Z_]+\}\} ]]; then
        echo "Ошибка: в шаблоне есть незаполненное поле ${BASH_REMATCH[0]} — скачайте свежую версию скрипта" >&2
        return 1
    fi
    echo "$conf"
}

# Получаем результат от первой функции
result=$(requestConfWARP1)

# Разделяем тело ответа и HTTP код
http_code="${result: -3}"
response_body="${result%???}"

# Проверяем HTTP код
if [[ "$http_code" != "200" ]]; then
    echo "Ошибка: сервер вернул код $http_code" >&2
    echo "Ответ: $response_body" >&2
    exit 1
fi

# Проверяем, что тело ответа не пустое
if [[ -z "$response_body" ]]; then
    echo "Ошибка: пустой ответ от сервера" >&2
    exit 1
fi

# Проверяем валидность JSON
if ! echo "$response_body" | jq -e . > /dev/null 2>&1; then
    echo "Ошибка: получен невалидный JSON" >&2
    echo "Ответ: ${response_body:0:200}..." >&2
    exit 1
fi

# Загружаем шаблон
if ! template=$(loadTemplate) || [[ -z "$template" ]]; then
    echo "Ошибка: не удалось получить шаблон template.conf" >&2
    exit 1
fi

# Создаем конфигурацию
if result_warp_config=$(confWarpBuilder "$response_body" "$template") && [[ -n "$result_warp_config" ]]; then
    # Запрашиваем имя файла у пользователя
    read -p "Введите имя файла для сохранения (без расширения): " filename

    if [[ -z "$filename" ]]; then
        echo "Ошибка: имя файла не может быть пустым"
        exit 1
    fi

    # Добавляем расширение .conf
    filename="${filename}.conf"

    # Сохраняем конфигурацию
    cat > "$filename" << EOF
$result_warp_config
EOF

    echo "✅ Конфигурация WARP сохранена в $filename"
else
    echo "❌ Ошибка при создании конфигурации"
    exit 1
fi
