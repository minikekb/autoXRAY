# autoXRAY — VLESS REALITY, Telegram Web Proxy и WARP

Установщик для личного сервера на Debian 12/13 и Ubuntu. Настраивает:

- **VLESS TCP REALITY + Vision** на внешнем TCP-порту **443**;
- **Telegram Web Proxy** на том же внешнем HTTPS-порту **443**;
- **WARP WireProxy** как локальный SOCKS5-выход для выбранных доменов.

Xray принимает соединения на `:443`. Обычный HTTPS-трафик, включая Telegram Web Proxy, передаётся локальному Nginx на `127.0.0.1:8443`. Сертификат для сайта-заглушки выпускается через ACME; порт 80 нужен для проверки домена и перенаправления HTTPS.

Клиентский конфиг направляет перечисленные ниже домены через VLESS на сервер. На сервере Xray отправляет этот трафик через локальный SOCKS5 WireProxy в WARP. Остальные запросы обслуживаются обычными правилами маршрутизации. WARP не меняет IP самого сервера и не влияет на Telegram Web Proxy.

Через WARP направляются:

- Проверка IP: `2ip.ru`, `2ip.io`, `ifconfig.me`, `checkip.amazonaws.com`, `pify.org`, `geosite:category-ip-geo-detect`;
- `habr.com`;
- Canva: `geosite:canva`;
- WhatsApp: `geosite:whatsapp`;
- Google Gemini: `geosite:google-gemini`.

## Требования

- чистый Debian 12/13 или Ubuntu;
- root-доступ;
- домен с A-записью на адрес VPS;
- домен нужно указывать маленькими латинскими буквами; для международного домена используйте ASCII/IDNA запись (`xn--...`). Установщик дополнительно приводит заглавные латинские буквы к нижнему регистру;
- открытые входящие порты TCP 80 и TCP 443.

## Установка

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/minikekb/autoXRAY/reality-webproxy/autoXRAY2.sh)" -- вашДОМЕН.com
```

После установки скрипт покажет ссылку VLESS REALITY, ссылку Telegram Web Proxy и адрес страницы с конфигурациями. VLESS-конфигурацию можно импортировать в совместимый с Xray клиент.

Установщик автоматически устанавливает и запускает WireProxy с помощью скрипта [fscarmen/warp](https://gitlab.com/fscarmen/warp). SOCKS5 доступен только локально на `127.0.0.1:40000`; установщик проверяет службу и порт перед генерацией конфига Xray.

## Службы и конфигурации

- Xray: `/usr/local/etc/xray/config.json`
- Nginx: `/etc/nginx/conf.d/default.conf`
- Telemt: `/etc/telemt/telemt.toml`
- Telegram Web Proxy: `/etc/tproxy-server/`
- WARP WireProxy: служба `wireproxy`, SOCKS5 `127.0.0.1:40000`

Перезапуск Xray: `systemctl restart xray`. Статус служб: `systemctl status xray nginx telemt tproxy-server wireproxy`.

Проверить WARP-прокси можно на сервере:

```bash
systemctl status wireproxy
curl --socks5-hostname 127.0.0.1:40000 https://ifconfig.me
```

Для проверки синтаксиса конфига Xray:

```bash
xray run -test -config /usr/local/etc/xray/config.json
```

## Удаление

Удаление Telegram Web Proxy:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/xVRVx/autoXRAY/main/test/telegram/web-proxy-uninstal.sh)"
```

Лицензия: GPL-3.0. Исходный проект: <https://github.com/xVRVx/autoXRAY>.
