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

confWarpBuilder()
{
    response_body=$1
    peer_pub=$(echo "$response_body" | jq -r '.result.config.peers[0].public_key')
    client_ipv4=$(echo "$response_body" | jq -r '.result.config.interface.addresses.v4')
    client_ipv6=$(echo "$response_body" | jq -r '.result.config.interface.addresses.v6')
    priv=$(echo "$response_body" | jq -r '.result.key')
    conf=$(cat <<EOM
[Interface]
PrivateKey = ${priv}
S1 = 0
S2 = 0
Jc = 120
Jmin = 23
Jmax = 911
H1 = 1
H2 = 2
H3 = 3
H4 = 4
MTU = 1280
I1 = <b 0xc2000000011419fa4bb3599f336777de79f81ca9a8d80d91eeec000044c635cef024a885dcb66d1420a91a8c427e87d6cf8e08b563932f449412cddf77d3e2594ea1c7a183c238a89e9adb7ffa57c133e55c59bec101634db90afb83f75b19fe703179e26a31902324c73f82d9354e1ed8da39af610afcb27e6$
Address = ${client_ipv4}, ${client_ipv6}
DNS = 1.1.1.1, 2606:4700:4700::1111, 1.0.0.1, 2606:4700:4700::1001

[Peer]
PublicKey = ${peer_pub}
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = 162.159.192.1:500
EOM
)
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

# Создаем конфигурацию
result_warp_config=$(confWarpBuilder "$response_body")

# Проверяем успешность
if [[ $? -eq 0 ]] && [[ -n "$result_warp_config" ]]; then
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
