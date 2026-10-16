// Прокси регистрации Cloudflare WARP для страницы WARP Config Builder.
//
// Зачем он нужен: API регистрации Cloudflare не разрешает запросы из браузера (CORS),
// поэтому страница не может обратиться к нему напрямую. Worker принимает от страницы
// ТОЛЬКО публичный ключ, регистрирует его у Cloudflare и возвращает адреса и ключ сервера.
// Приватный ключ создаётся в браузере пользователя и сюда не попадает.
//
// Запрос:  POST /reg   {"key": "<публичный ключ WireGuard, base64>"}
// Ответ:   200 {"config": {"peers": [{"public_key", "endpoint"}], "interface": {"addresses": {"v4", "v6"}}}}
//          4xx/5xx {"error": "<текст на русском>"}
//
// Настройки (wrangler.toml → [vars]):
//   ALLOWED_ORIGINS — сайты, которым разрешено обращаться к Worker, через запятую
//   CF_API_URL      — адрес API регистрации (по умолчанию как в wgcf 2.3.1)
// Необязательные ограничения частоты (wrangler.toml → [[ratelimits]]):
//   RATE_LIMITER_IP     — на один IP-адрес
//   RATE_LIMITER_GLOBAL — на весь Worker, чтобы Cloudflare не начал отказывать всем (429)

// Версия API и заголовки — как в wgcf (https://github.com/ViRb3/wgcf, cloudflare/api.go)
const DEFAULT_CF_API_URL = 'https://api.cloudflareclient.com/v0a5641/reg';
const CF_HEADERS = {
    'User-Agent': '1.1.1.1/6.38.9-5641 (Android 16.0.0)',
    'CF-Client-Version': 'a-6.38.9-5641',
    'Content-Type': 'application/json; charset=UTF-8',
};
const DEFAULT_ALLOWED_ORIGINS = 'https://shvartem.github.io';
const MAX_BODY_BYTES = 1024;

export default {
    async fetch(request, env) {
        const origin = request.headers.get('Origin') || '';
        const allowed = parseOrigins(env.ALLOWED_ORIGINS);
        const cors = allowed.includes(origin)
            ? {
                'Access-Control-Allow-Origin': origin,
                'Access-Control-Allow-Methods': 'POST, OPTIONS',
                'Access-Control-Allow-Headers': 'Content-Type',
                'Access-Control-Max-Age': '86400',
                'Vary': 'Origin',
            }
            : { 'Vary': 'Origin' };

        const url = new URL(request.url);
        // Открыли адрес Worker в браузере — подскажем, что всё в порядке
        if (url.pathname === '/' && (request.method === 'GET' || request.method === 'HEAD')) {
            return new Response(
                'Worker регистрации WARP работает.\n' +
                'Он принимает только POST-запросы на /reg от страницы https://shvartem.github.io/santa-warp-config/\n',
                { status: 200, headers: { 'Content-Type': 'text/plain; charset=utf-8', 'Cache-Control': 'no-store' } }
            );
        }
        if (url.pathname !== '/reg') {
            return json({ error: 'Не найдено' }, 404, cors);
        }
        if (request.method === 'OPTIONS') {
            return new Response(null, { status: allowed.includes(origin) ? 204 : 403, headers: cors });
        }
        if (request.method !== 'POST') {
            return json({ error: 'Нужен POST-запрос' }, 405, { ...cors, 'Allow': 'POST, OPTIONS' });
        }
        // Браузер с чужого сайта всё равно не прочитает ответ, но регистрацию лучше вообще не делать
        if (origin && !allowed.includes(origin)) {
            return json({ error: 'Запросы с этого сайта не разрешены' }, 403, cors);
        }

        // Ограничение частоты (если настроено в wrangler.toml)
        const ip = request.headers.get('CF-Connecting-IP') || 'unknown';
        if (env.RATE_LIMITER_IP && !(await env.RATE_LIMITER_IP.limit({ key: ip })).success) {
            return json({ error: 'Слишком много запросов. Подождите минуту и попробуйте снова.' }, 429, cors);
        }
        if (env.RATE_LIMITER_GLOBAL && !(await env.RATE_LIMITER_GLOBAL.limit({ key: 'global' })).success) {
            return json({ error: 'Сервис сейчас перегружен. Попробуйте через минуту или получите JSON вручную.' }, 429, cors);
        }

        // Разбираем и проверяем публичный ключ
        const text = await request.text();
        if (text.length > MAX_BODY_BYTES) {
            return json({ error: 'Слишком большой запрос' }, 413, cors);
        }
        let key;
        try {
            key = JSON.parse(text).key;
        } catch {
            return json({ error: 'Тело запроса должно быть JSON' }, 400, cors);
        }
        if (!isWireGuardKey(key)) {
            return json({ error: 'Поле key должно быть публичным ключом WireGuard (base64, 32 байта)' }, 400, cors);
        }

        // Регистрация у Cloudflare
        const body = {
            key,
            install_id: '',
            fcm_token: '',
            tos: new Date().toISOString(),
            model: 'PC',
            serial_number: '',
            locale: 'en_US',
            os_version: '16.0.0',
            key_type: 'curve25519',
            tunnel_type: 'wireguard',
        };
        let upstream;
        try {
            upstream = await fetch(env.CF_API_URL || DEFAULT_CF_API_URL, {
                method: 'POST',
                headers: CF_HEADERS,
                body: JSON.stringify(body),
            });
        } catch (e) {
            return json({ error: 'Не удалось связаться с Cloudflare' }, 502, cors);
        }
        if (!upstream.ok) {
            const status = upstream.status === 429 ? 429 : 502;
            return json({ error: `Cloudflare отказал в регистрации (код ${upstream.status})` }, status, cors);
        }

        let data;
        try {
            data = await upstream.json();
        } catch {
            return json({ error: 'Cloudflare прислал неожиданный ответ' }, 502, cors);
        }
        const peer = data?.config?.peers?.[0];
        const addresses = data?.config?.interface?.addresses;
        if (!peer?.public_key || !addresses?.v4 || !addresses?.v6) {
            return json({ error: 'Cloudflare прислал неожиданный ответ' }, 502, cors);
        }

        // Отдаём только то, что нужно для конфига: без токена и идентификаторов аккаунта
        return json({
            config: {
                peers: [{ public_key: peer.public_key, endpoint: peer.endpoint }],
                interface: { addresses: { v4: addresses.v4, v6: addresses.v6 } },
            },
        }, 200, cors);
    },
};

function parseOrigins(value) {
    return (value || DEFAULT_ALLOWED_ORIGINS).split(',').map(s => s.trim()).filter(Boolean);
}

function isWireGuardKey(value) {
    if (typeof value !== 'string' || !/^[A-Za-z0-9+/]{43}=$/.test(value)) return false;
    try {
        return atob(value).length === 32;
    } catch {
        return false;
    }
}

function json(data, status, headers) {
    return new Response(JSON.stringify(data), {
        status,
        headers: { ...headers, 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store' },
    });
}
