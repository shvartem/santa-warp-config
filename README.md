# WARP Config Builder

**WARP Config Builder** — это простой веб-инструмент для генерации конфигурационного файла **AmneziaWG** (формат `.conf`) из JSON‑ответа, получаемого от API.

Создан для удобного получения готового конфига для Cloudflare WARP, который можно сразу скопировать или сохранить на устройство.

> ⚠️ **Нужен клиент с поддержкой AmneziaWG** — например, [AmneziaVPN](https://amnezia.org) или AmneziaWG.
> Конфиг содержит параметры обфускации (`Jc`, `Jmin`, `Jmax`, `S1`, `S2`, `H1`–`H4`, `I1`), которые обычный клиент WireGuard не понимает.

---

## Возможности

- 🔧 Преобразование JSON в конфигурацию AmneziaWG
- 🌐 Выбор DNS-сервиса (Cloudflare, Google, COMSS, MALW)
- 📋 Копирование результата в буфер обмена
- 💾 Сохранение в файл `warp_config.conf`

---

## Как использовать

1. Откройте [страницу инструмента](https://shvartem.github.io/santa-warp-config/) или запустите локально.
2. Получите JSON‑ответ от API: перейдите по ссылке [https://santa-atmo.ru/warp/warp.php](https://santa-atmo.ru/warp/warp.php) (откроется в новой вкладке) и скопируйте содержимое.
3. Вставьте JSON в текстовое поле на странице.
4. Нажмите **«Собрать конфиг»**.
5. После успешной генерации вы сможете:
   - скопировать конфиг в буфер обмена;
   - сохранить его как файл `warp_santa_<dns>.conf`.

---

## Установка и запуск

Проект не требует сборки или установки зависимостей.

### Локальный запуск
Страница загружает общий шаблон `template.conf`, поэтому при открытии файла напрямую (`file://`) браузер его не отдаст. Запустите любой локальный веб-сервер:

```bash
git clone https://github.com/shvartem/santa-warp-config.git
cd santa-warp-config
python3 -m http.server 8000
```

и откройте <http://localhost:8000>.

### Скрипт для терминала
`generate_warp_santa.sh` сам запрашивает JSON у API и сохраняет готовый конфиг (DNS — Cloudflare). Нужны `curl` и `jq`.

```bash
bash generate_warp_santa.sh
```

## Структура

- `index.html` — веб-страница
- `generate_warp_santa.sh` — скрипт для терминала
- `template.conf` — общий шаблон конфига для страницы и скрипта. Параметры AmneziaWG, endpoint и т.п. меняются только здесь.

---

## Ссылки

- [Страница инструмента](https://shvartem.github.io/santa-warp-config/)

---
