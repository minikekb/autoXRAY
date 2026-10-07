# autoXRAY — VLESS REALITY и Telegram Web Proxy

Установщик для личного сервера на Debian 12/13 и Ubuntu. Настраивает только:

- **VLESS TCP REALITY + Vision** на внешнем TCP-порту **443**;
- **Telegram Web Proxy** на том же внешнем HTTPS-порту **443**.
- **WARP WireProxy** как локальный SOCKS5 для доменов `2ip.ru` и `2ip.io`.

Xray принимает соединения на `:443`. Обычный HTTPS-трафик (включая Telegram Web Proxy) передаётся локальному Nginx на `127.0.0.1:8443`. Сертификат для сайта-заглушки выпускается через ACME, порт 80 нужен для проверки домена и перенаправления HTTPS.

## Требования

- чистый Debian 12/13 или Ubuntu;
- root-доступ;
- домен с A-записью на адрес VPS;
- открытые входящие порты TCP 80 и TCP 443.

## Установка

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/xVRVx/autoXRAY/main/autoXRAY2.sh)" -- вашДОМЕН.com
```

После установки скрипт покажет ссылку VLESS REALITY, ссылку Telegram Web Proxy и адрес страницы с конфигурациями. VLESS-конфигурацию можно импортировать в совместимый с Xray клиент.

Установщик автоматически разворачивает WireProxy из скрипта [fscarmen/warp](https://gitlab.com/fscarmen/warp) и проверяет локальный SOCKS5 на `127.0.0.1:40000`. Запросы к `2ip.ru` и `2ip.io`, направленные клиентом через VLESS, Xray отправляет через WARP. WARP не меняет внешний IP самого сервера и не влияет на Web Proxy TG.

## Службы и конфигурации

- Xray: `/usr/local/etc/xray/config.json`
- Nginx: `/etc/nginx/conf.d/default.conf`
- Telemt: `/etc/telemt/telemt.toml`
- Telegram Web Proxy: `/etc/tproxy-server/`
- WARP WireProxy: служба `wireproxy`, SOCKS5 `127.0.0.1:40000`

Перезапуск Xray: `systemctl restart xray`. Статус служб: `systemctl status xray nginx telemt tproxy-server`.

## Удаление

Удаление Telegram Web Proxy:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/xVRVx/autoXRAY/main/test/telegram/web-proxy-uninstal.sh)"
```

Лицензия: GPL-3.0. Исходный проект: <https://github.com/xVRVx/autoXRAY>.
