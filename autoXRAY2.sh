#!/bin/bash

# Цвета для вывода
GRN='\033[1;32m'
RED='\033[1;31m'
YEL='\033[1;33m'
CYAN='\033[1;36m'
NC='\033[0m' # No Color

echo -e "${GRN}Версия: 150 ${NC}"
sleep 1

[[ $EUID -eq 0 ]] || { echo -e "${RED}❌ Скрипту нужны root права!${NC}"; exit 1; }

# Компактная проверка ОС (Debian / Ubuntu)
. /etc/os-release 2>/dev/null
[[ "$ID" =~ ^(debian|ubuntu)$ ]] || { echo -e "${RED}❌ Ошибка: поддерживаются только Debian и Ubuntu!${NC}"; exit 1; }
[[ "$ID" == "ubuntu" ]] && echo -e "${YEL}⚠️ Внимание: запуск на Ubuntu. Рекомендованная система: Debian 12/13.${NC}"

DOMAIN=$1

if [ -z "$DOMAIN" ]; then
    echo -e "${RED}❌ Ошибка: домен не задан.${NC}"
    exit 1
fi

KEYRING_PKG=$([ "$ID" = "ubuntu" ] && echo "ubuntu-keyring" || echo "debian-archive-keyring")

echo -e "${YEL}Подготовка официального репозитория Nginx для $ID ($VERSION_CODENAME)...${NC}"
apt-get update && apt-get install -y curl gnupg2 ca-certificates $KEYRING_PKG dnsutils openssl wget tar cron gettext-base

# Добавление ключа и репозитория nginx.org
curl -fsSL https://nginx.org/keys/nginx_signing.key | gpg --dearmor --yes -o /usr/share/keyrings/nginx-archive-keyring.gpg

echo "deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] https://nginx.org/packages/$ID $VERSION_CODENAME nginx" \
    | tee /etc/apt/sources.list.d/nginx.list >/dev/null

echo -e "Package: *\nPin: origin nginx.org\nPin: release o=nginx\nPin-Priority: 900\n" \
    | tee /etc/apt/preferences.d/99nginx >/dev/null

apt-get update
apt-get install -y nginx
systemctl enable --now nginx
systemctl enable --now cron

LOCAL_IP=$(hostname -I | awk '{print $1}')
DNS_IP=$(dig +short "$DOMAIN" | grep '^[0-9]' | head -n 1)

if [ "$LOCAL_IP" != "$DNS_IP" ]; then
    echo -e "${RED}❌ Внимание: IP-адрес ($LOCAL_IP) не совпадает с A-записью $DOMAIN ($DNS_IP).${NC}"
    echo -e "${YEL}Правильно укажите одну A-запись для вашего домена в ДНС - $LOCAL_IP ${NC}"
    
	read -p "Продолжить на ваш страх и риск? (y/N):" choice

	if [[ ! "$choice" =~ ^[Yy]$ ]]; then
		echo -e "${RED}Выполнение скрипта прервано.${NC}"
		exit 1
	fi
    echo -e "${YEL}Продолжение выполнения скрипта...${NC}"
fi

# Telegram Web Proxy обязателен и доступен на внешнем порту 443.
NGINX_web_proxy='    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_buffering off;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }'

fpBro="chrome"

# Включаем BBR, MTU Probing и расширенные TCP-буферы ядра
cat <<EOF > /etc/sysctl.d/999-autoXRAY.conf
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv4.tcp_mtu_probing=1
net.core.rmem_max=16777216
net.core.wmem_max=16777216
net.ipv4.tcp_rmem=4096 87380 16777216
net.ipv4.tcp_wmem=4096 65536 16777216
EOF
sysctl --system >/dev/null 2>&1
echo -e "${GRN}BBR, TCP буферы и MTU Probing активированы${NC}"

cat <<EOF > /etc/security/limits.d/99-autoXRAY.conf
*       soft    nofile  1048576
*       hard    nofile  1048576
root    soft    nofile  1048576
root    hard    nofile  1048576
EOF
ulimit -n 65535
echo -e "${GRN}Лимиты применены. Текущий ulimit -n: $(ulimit -n) ${NC}"

# Создание директории сайта
WEB_PATH="/var/www/$DOMAIN"
mkdir -p "$WEB_PATH"

# Генерируем сайт маскировку
bash -c "$(curl -sL https://github.com/xVRVx/autoXRAY/raw/refs/heads/main/test/gen_page3.sh)" -- "$WEB_PATH"

# Установка Xray
bash -c "$(curl -sL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install --version v26.9.9

# ==========================================
# Блок ACME.SH (Установка и выпуск сертификата)
# ==========================================
CONFIG_PATH="/etc/nginx/conf.d/default.conf"
mkdir -p /var/www/html

cat <<EOF > "$CONFIG_PATH"
server {
	listen 80 default_server;
	server_name _;

	location /.well-known/acme-challenge/ {
		root /var/www/html;
		allow all;
	}

	location / {
		return 301 https://\$host\$request_uri;
	}
}
EOF
systemctl reload nginx

mkdir -p /var/lib/xray/cert/

echo -e "\n${YEL}Проверка и установка acme.sh...${NC}"
curl -sL https://get.acme.sh | sh -s email=mail@$DOMAIN
ACME_BIN="$HOME/.acme.sh/acme.sh"

CERT_EXISTS=false
if $ACME_BIN --list | grep -q "$DOMAIN"; then
    echo -e "${GRN}Сертификат для $DOMAIN уже существует в acme.sh.${NC}"
    CERT_EXISTS=true
fi

if [ "$CERT_EXISTS" = false ]; then
    $ACME_BIN --register-account -m mail@$DOMAIN --server zerossl

    echo -e "\n${YEL}Выпуск сертификата (сначала ZeroSSL, затем Let's Encrypt)...${NC}"
    $ACME_BIN --issue -d "$DOMAIN" -w /var/www/html --server zerossl --keylength ec-256
    RET=$?
    
    if [ $RET -ne 0 ]; then
        echo -e "${YEL}ZeroSSL не ответил, пробуем через Let's Encrypt...${NC}"
        $ACME_BIN --issue -d "$DOMAIN" -w /var/www/html --server letsencrypt --keylength ec-256
        RET=$?
    fi
else
    RET=0
fi

if [ $RET -eq 0 ]; then
    $ACME_BIN --install-cert -d "$DOMAIN" --ecc \
      --fullchain-file /var/lib/xray/cert/fullchain.pem \
      --key-file /var/lib/xray/cert/privkey.pem \
      --reloadcmd "chmod 744 /var/lib/xray/cert/privkey.pem /var/lib/xray/cert/fullchain.pem; systemctl reload nginx; systemctl restart xray"

    chmod 744 /var/lib/xray/cert/privkey.pem /var/lib/xray/cert/fullchain.pem

    echo -e "\n${GRN}========================================"
    echo    "✅  Сертификат успешно настроен и применен!"
    echo    "✅  acme.sh настроил автообновление через cron"
    echo    "========================================"
    echo -e "${NC}"
else
    echo -e "\n${RED}========================================"
    echo    "❌  ОШИБКА: не удалось выпустить сертификат через acme.sh"
    echo    "========================================"
    echo -e "${NC}"
    exit 1
fi
# ==========================================

path_subpage=$(openssl rand -base64 15 | tr -dc 'A-Za-z0-9' | head -c 20)

# Конфиг Nginx с ОЗУ-буферами для высокой скорости отдачи
cat <<EOF > "$CONFIG_PATH"
http2 on;
server_tokens off;

map \$http_upgrade \$connection_upgrade {
    default upgrade;
    ''      close;
}

server {
    server_name $DOMAIN;
    listen 127.0.0.1:8443 ssl;
    ssl_certificate /var/lib/xray/cert/fullchain.pem;
    ssl_certificate_key /var/lib/xray/cert/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;

    server_tokens off;
    access_log off;
    error_log /var/log/nginx/error.log crit;

    root /var/www/$DOMAIN;
    index index.html;

    location = /${path_subpage}.html {
        try_files \$uri =404;
    }

    location = /${path_subpage}.json {
        add_header profile-title "base64:YXV0b1hSQVk=";
        add_header routing "happ://routing/onadd/eyJOYW1lIjoiYXV0b1hSQVkiLCJHbG9iYWxQcm94eSI6InRydWUiLCJSb3V0ZU9yZGVyIjoiYmxvY2stcHJveHktZGlyZWN0IiwiUmVtb3RlRE5TVHlwZSI6IkRvSCIsIlJlbW90ZUROU0RvbWFpbiI6Imh0dHBzOi8vZG5zLmdvb2dsZS9kbnMtcXVlcnkiLCJSZW1vdGVETlNJUCI6IjguOC40LjQiLCJEb21lc3RpY0ROU1R5cGUiOiJEb0giLCJEb21lc3RpY0ROU1RvbWFpbiI6Imh0dHBzOi8vY2xvdWRmbGFyZS1kbnMuY29tL2Rucy1xdWVyeSIsIkRvbWVzdGljRE5TSVAiOiIxLjEuMS4xIiwiR2VvaXB1cmwiOiJodHRwczovL2dpdGh1Yi5jb20vTG95YWxzb2xkaWVyL3YycmF5LXJ1bGVzLWRhdC9yZWxlYXNlcy9sYXRlc3QvZG93bmxvYWQvZ2VvaXAuZGF0IiwiR2Vvc2l0ZXVybCI6Imh0dHBzOi8vZ2l0aHViLmNvbS9Mb3lhbHNvbGRpZXIvdjJyYXktcnVsZXMtZGF0L3JlbGVhc2VzL2xhdGVzdC9kb3dubG9hZC9nZW9zaXRlLmRhdCIsIkxhc3RVcGRhdGVkIjoiMTc3NTIwNjEwOCIsIkRuc0hvc3RzIjp7fSwiRGlyZWN0U2l0ZXMiOlsiZ2Vvc2l0ZTpjYXRlZ29yeS1ydSIsImdlb3NpdGU6cHJpdmF0ZSJdLCJEaXJlY3RJcCI6WyJnZW9pcDpwcml2YXRlIl0sIlByb3h5U2l0ZXMiOltdLCJQcm94eUlwIjpbXSwiQmxvY2tTaXRlcyI6WyJnZW9pcDpjYXRlZ29yeS1hZHMiLCJnZW9zaXRlOndpbi1zcHkiXSwiQmxvY2tJcCI6W10sIkRvbWFpblN0cmF0ZWd5IjoiSVBJZk5vbk1hdGNoIiwiRmFrZUROUyI6ImZhbHNlIiwiVXNlQ2h1bmtGaWxlcyI6ImZhbHNlIn0";
        add_header routing-enable 0;
        try_files \$uri =404;
    }

$NGINX_web_proxy

    location ~ /\.ht {
        deny all;
    }
}

server {
    listen 80;
    server_name $DOMAIN;

    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}
EOF

systemctl restart nginx
echo -e "${GRN}✅ Конфигурация nginx обновлена.${NC}"

SCRIPT_DIR=/usr/local/etc/xray

# Генерируем ключи и переменные
xray_uuid_vrv=$(xray uuid)
xray_shortIds_vrv=$(openssl rand -hex 8)
reality_keys=$(xray x25519)
xray_reality_private=$(printf '%s\n' "$reality_keys" | awk -F ': ' '/^(PrivateKey|Private key):/ {print $2; exit}')
xray_reality_public=$(printf '%s\n' "$reality_keys" | awk -F ': ' '/^Password( \(PublicKey\))?:/ || /^Public key:/ || /^PublicKey:/ {print $2; exit}')
if [[ -z "$xray_reality_private" || -z "$xray_reality_public" ]]; then
    echo -e "${RED}❌ Не удалось получить ключи REALITY из xray x25519.${NC}"
    exit 1
fi

socksUser=$(openssl rand -base64 16 | tr -dc 'A-Za-z0-9' | head -c 6)
socksPasw=$(openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | head -c 16)

# Устанавливаем WireProxy/WARP как локальный SOCKS5 для выбранных маршрутов.
# Слушатель привязан к loopback и не открывается наружу.
WARP_SOCKS_PORT=40000
if systemctl is-active --quiet wireproxy && ss -ltnH | awk -v port="127.0.0.1:${WARP_SOCKS_PORT}" '$4 == port { found=1 } END { exit !found }'; then
    echo -e "${GRN}WARP WireProxy уже запущен на 127.0.0.1:${WARP_SOCKS_PORT}.${NC}"
else
    echo -e "${YEL}Устанавливаем WARP WireProxy (SOCKS5 127.0.0.1:${WARP_SOCKS_PORT})...${NC}"
    if ! echo -e "1\n1\n${WARP_SOCKS_PORT}" | bash <(curl -fsSL https://gitlab.com/fscarmen/warp/-/raw/main/menu.sh) w; then
        echo -e "${RED}❌ Не удалось установить WARP WireProxy.${NC}"
        exit 1
    fi
fi

if ! systemctl is-active --quiet wireproxy || ! ss -ltnH | awk -v port="127.0.0.1:${WARP_SOCKS_PORT}" '$4 == port { found=1 } END { exit !found }'; then
    echo -e "${RED}❌ WARP WireProxy не слушает порт ${WARP_SOCKS_PORT}; Xray не будет настроен с нерабочим WARP-маршрутом.${NC}"
    exit 1
fi

# Экспортируем переменные для envsubst
export xray_uuid_vrv xray_shortIds_vrv xray_reality_private xray_reality_public DOMAIN path_subpage WEB_PATH socksUser socksPasw WARP_SOCKS_PORT

# Создаем JSON конфигурацию сервера Xray
cat << 'EOF' | envsubst > "$SCRIPT_DIR/config.json"
{
  "log": {
    "dnsLog": false,
    "access": "/var/log/xray/access.log",
    "error": "/var/log/xray/error.log",
    "loglevel": "none"
  },
  "dns": {
    "servers": [
      "https+local://8.8.4.4/dns-query",
      "https+local://8.8.8.8/dns-query",
      "https+local://1.1.1.1/dns-query",
      "localhost"
    ],
    "queryStrategy": "UseIPv4"
  },
  "inbounds": [
    {
      "tag": "vless-reality-vision",
      "listen": "0.0.0.0",
      "port": 443,
      "protocol": "vless",
      "settings": {
        "clients": [{"id": "${xray_uuid_vrv}", "flow": "xtls-rprx-vision"}],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "raw",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "target": "127.0.0.1:8443",
          "xver": 0,
          "serverNames": ["${DOMAIN}"],
          "privateKey": "${xray_reality_private}",
          "shortIds": ["${xray_shortIds_vrv}"]
        }
      },
      "sniffing": {"enabled": true, "destOverride": ["http", "tls", "quic"]}
    },
    {
      "tag": "socks5",
      "port": 10443,
      "listen": "127.0.0.1",
      "protocol": "mixed",
      "settings": {
        "ip": "127.0.0.1",
        "udp": true,
        "auth": "password",
        "accounts": [
          {
            "user": "${socksUser}",
            "pass": "${socksPasw}"
          }
        ]
      }
    }
  ],
  "outbounds": [
    {
      "tag": "direct",
      "protocol": "freedom",
      "settings": {
        "domainStrategy": "ForceIPv4"
      }
    },
    {
      "tag": "block",
      "protocol": "blackhole"
    },
    {
      "tag": "warp",
      "protocol": "socks",
      "settings": {
        "servers": [
          {
            "address": "127.0.0.1",
            "port": ${WARP_SOCKS_PORT}
          }
        ]
      }
    }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {
        "domain": [
          "domain:2ip.ru",
          "domain:2ip.io"
        ],
        "outboundTag": "warp"
      },
      {
        "ip": [
          "geoip:private"
        ],
        "outboundTag": "block"
      },
      {
        "port": "25, 135, 137-139, 445",
        "outboundTag": "block"
      },
      {
        "protocol": [
          "bittorrent"
        ],
        "outboundTag": "block"
      },
      {
        "domain": [
          "geosite:category-ads",
          "geosite:win-spy",
          "geosite:private"
        ],
        "outboundTag": "block"
      },
      {
        "outboundTag": "block",
        "domain": [
          "ifconfig.me",
          "checkip.amazonaws.com",
          "pify.org"
        ]
      }
    ]
  }
}
EOF

# Создаем JSON конфигурацию клиента
print_config() {
  local PROXY_OUTBOUND="$1"
  local REMARK="$2"

  cat << TPL
{
  "log": {
    "loglevel": "warning"
  },
  "dns": {
    "servers": [
      {
        "address": "https+local://77.88.8.8/dns-query",
        "domains": [
          "geosite:category-ru",
          "geosite:yandex",
          "geosite:vk",
          "domain:ru",
          "domain:su",
          "domain:xn--p1ai"
        ],
        "skipFallback": true
      },
      "https://8.8.4.4/dns-query",
      "https://8.8.8.8/dns-query",
      "https://1.1.1.1/dns-query"
    ],
    "queryStrategy": "UseIPv4"
  },
  "routing": {
    "domainMatcher": "hybrid",
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {
        "domain": [
          "geosite:category-ads",
          "geosite:win-spy"
        ],
        "outboundTag": "block"
      },
      {
        "protocol": [
          "bittorrent"
        ],
        "outboundTag": "direct"
      },
      {
        "domain": [
          "habr.com",
          "apkmirror.com",
          "domain:2ip.ru",
          "domain:2ip.io"
        ],
        "outboundTag": "proxy"
      },
      {
        "domain": [
          "geosite:private",
          "ifconfig.me",
          "checkip.amazonaws.com",
          "pify.org",
          "domain:ru",
          "domain:su",
          "domain:xn--p1ai",
          "geosite:apple",
          "geosite:apple-pki",
          "geosite:f-droid",
          "geosite:yandex",
          "geosite:vk",
          "geosite:category-ru"
        ],
        "outboundTag": "direct"
      },
      {
        "ip": [
          "geoip:ru",
          "geoip:private"
        ],
        "outboundTag": "direct"
      }
    ]
  },
  "inbounds": [
    {
      "tag": "socks-in",
      "protocol": "socks",
      "listen": "127.0.0.1",
      "port": 10808,
      "settings": {
        "udp": true
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls",
          "quic"
        ]
      }
    },
    {
      "tag": "socks-sb",
      "protocol": "mixed",
      "listen": "127.0.0.1",
      "port": 2080,
      "settings": {
        "udp": true
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls",
          "quic"
        ]
      }
    },
    {
      "tag": "http-in",
      "protocol": "http",
      "listen": "127.0.0.1",
      "port": 10809,
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls",
          "quic"
        ]
      }
    }
  ],
  "outbounds": [
    $PROXY_OUTBOUND,
    {
      "tag": "direct",
      "protocol": "freedom"
    },
    {
      "tag": "block",
      "protocol": "blackhole"
    }
  ],
  "remarks": "$REMARK"
}
TPL
}

# --- VLESS RAW REALITY VISION (TCP/443)
OUT_REALITY='{
  "tag": "proxy",
  "protocol": "vless",
  "settings": {
    "vnext": [{"address": "${DOMAIN}", "port": 443, "users": [{"id": "${xray_uuid_vrv}", "flow": "xtls-rprx-vision", "encryption": "none"}]}]
  },
  "streamSettings": {
    "network": "raw",
    "security": "reality",
    "realitySettings": {
      "serverName": "${DOMAIN}",
      "fingerprint": "${fpBro}",
      "password": "${xray_reality_public}",
      "shortId": "${xray_shortIds_vrv}",
      "spiderX": "/"
    }
  }
}'

# В подписку добавляется только VLESS REALITY.
(
  echo "["
  print_config "$OUT_REALITY" "🇪🇺 VLESS REALITY VISION"
  echo "]"
) | envsubst > "$WEB_PATH/$path_subpage.json"

systemctl restart xray
echo -e "Перезапуск XRAY"

# Формирование ссылок
subPageLink="https://$DOMAIN/$path_subpage.json"

linkREALITY="vless://${xray_uuid_vrv}@$DOMAIN:443?type=tcp&security=reality&pbk=$xray_reality_public&fp=$fpBro&sni=$DOMAIN&sid=$xray_shortIds_vrv&spx=%2F&flow=xtls-rprx-vision#VLESS-REALITY"

configListLink="https://$DOMAIN/$path_subpage.html"

CONFIGS_ARRAY=(
    "VLESS REALITY VISION|$linkREALITY"
)
ALL_LINKS_TEXT=""

echo -e "\n\n${GRN}Устанавливаем Telegram Web Proxy ${NC}"
source <(curl -sL https://raw.githubusercontent.com/xVRVx/autoXRAY/refs/heads/main/test/telegram/web-proxy.sh)
# Фиксируем внешний порт в ссылке для Telegram.
MTProto="tg://webproxy?server=${DOMAIN}&port=443&secret=${SECRET}"

# --- ЗАПИСЬ HEAD (СТАТИКА, МИНИФИЦИРОВАННЫЕ СТИЛИ И JS) ---
cat > "$WEB_PATH/$path_subpage.html" <<'EOF'
<!DOCTYPE html><html lang="ru"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1.0">
<meta name="robots" content="noindex,nofollow">
<title>autoXRAY configs</title>
<link rel="icon" type="image/svg+xml" href='data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyNCAyNCIgZmlsbD0ibm9uZSIgc3Ryb2tlPSIjMDBCRkZGIiBzdHJva2Utd2lkdGg9IjIiIHN0cm9rZS1saW5lY2FwPSJyb3VuZCIgc3Ryb2tlLWxpbmVqb2luPSJyb3VuZCI+PHBhdGggZD0iTTIxIDJsLTIgMm0tNy42MSA3LjYxYTUuNSA1LjUgMCAxIDEtNy43NzggNy43NzggNS41IDUuNSAwIDAgMSA3Ljc3Ny03Ljc3N3ptMCAwTDE1LjUgNy41bTAgMGwzIDNMMjIgN2wtMy0zbS0zLjUgMy41TDE5IDQiLz48L3N2Zz4='>
<script src="https://cdnjs.cloudflare.com/ajax/libs/qrcode/1.5.1/qrcode.min.js"></script>
<style>
body{font-family:monospace;background:#121212;color:#e0e0e0;padding:10px;max-width:900px;margin:0 auto}h2{color:#c3e88d;border-top:2px solid #333;padding-top:20px;margin:15px 0 10px;font-size:18px}.config-row{background:#1e1e1e;border:1px solid #333;border-radius:6px;padding:5px;display:flex;flex-wrap:wrap;align-items:center;gap:8px;margin-bottom:8px}.config-label{background:#2c2c2c;color:#82aaff;padding:6px 10px;border-radius:4px;font-weight:700;font-size:13px;white-space:nowrap;min-width:140px;text-align:center}.config-code{flex:1;white-space:nowrap;overflow-x:auto;padding:8px;background:#121212;border-radius:4px;color:#c3e88d;font-size:12px;scrollbar-width:none}.config-code::-webkit-scrollbar{display:none}.btn-action{border:1px solid #555;padding:6px 12px;border-radius:4px;cursor:pointer;font-weight:700;font-size:12px;transition:all .2s;height:32px;display:flex;align-items:center;justify-content:center}.copy-btn{background:#333;color:#e0e0e0;min-width:60px}.copy-btn:hover{background:#c3e88d;color:#121212;border-color:#c3e88d}.qr-btn{background:#333;color:#82aaff;border-color:#82aaff;min-width:40px}.qr-btn:hover{background:#82aaff;color:#121212}.btn-group{display:flex;gap:10px;margin:10px 0 20px}.btn{flex:1;background:#2c2c2c;color:#c3e88d;border:1px solid #c3e88d;padding:10px;text-align:center;border-radius:6px;text-decoration:none;font-weight:700;font-size:14px}.btn:hover{background:#c3e88d;color:#121212}.btn.download{border-color:#82aaff;color:#82aaff}.btn.download:hover{background:#82aaff;color:#121212}.btn.tg{border-color:#2AABEE;color:#2AABEE}.btn.tg:hover{background:#2AABEE;color:#fff}.modal-overlay{display:none;position:fixed;top:0;left:0;width:100%;height:100%;background:rgba(0,0,0,.85);z-index:999;justify-content:center;align-items:center;backdrop-filter:blur(3px)}.modal-content{background:#1e1e1e;padding:20px;border-radius:10px;border:1px solid #82aaff;text-align:center}#qrcode{background:#fff;padding:10px;border-radius:6px;margin-bottom:10px}#qrcode canvas,#qrcode img{display:block;margin:0 auto}.qr-err{color:#c31e1e;font-size:13px;padding:10px;background:#fff;border-radius:4px;font-weight:700}.close-modal-btn{background:#c31e1e;color:#fff;border:none;padding:8px 20px;border-radius:4px;cursor:pointer}@media(max-width:600px){.config-label{width:100%;margin-bottom:2px}.config-code{min-width:100%;order:3}.btn-action{flex:1;order:2}}
</style>
<script>
function copyText(e,t){navigator.clipboard.writeText(document.getElementById(e).innerText.trim()).then(()=>{let o=t.innerText;t.innerText="OK",t.style.cssText="background:#c3e88d;color:#121212",setTimeout(()=>{t.innerText=o,t.style.cssText=""},1500)}).catch(e=>console.error(e))}
function showQR(e){
    let t=document.getElementById(e).innerText.trim(),o=document.getElementById("qrModal"),n=document.getElementById("qrcode");
    n.innerHTML="";
    if(e==='cAll'||t.length>1800){
        n.innerHTML="<div class='qr-err'>❌ Слишком много данных для одного QR-кода.<br>Используйте кнопку Copy.</div>";
        o.style.display="flex";
        return;
    }
    let c=document.createElement("canvas");
    n.appendChild(c);
    QRCode.toCanvas(c,t,{width:256,margin:2,errorCorrectionLevel:'L'},function(err){
        if(err){
            console.error(err);
            n.innerHTML="<div class='qr-err'>❌ Ошибка создания QR.<br>Скопируйте ссылку вручную.</div>";
        }
    });
    o.style.display="flex";
}
function closeModal(){document.getElementById("qrModal").style.display="none"}
window.onclick=function(e){e.target==document.getElementById("qrModal")&&closeModal()};
</script>
</head><body>
EOF

# --- ЗАПИСЬ BODY (ДИНАМИЧЕСКИЕ ДАННЫЕ) ---
cat >> "$WEB_PATH/$path_subpage.html" <<EOF

<h2>📂 Ссылка на подписку (готовый конфиг клиента с роутингом)</h2>
<div class="config-row">
    <div class="config-label">Subscription</div>
    <div class="config-code" id="subLink">$subPageLink</div>
    <button class="btn-action copy-btn" onclick="copyText('subLink', this)">Copy</button>
    <button class="btn-action qr-btn" onclick="showQR('subLink')">QR</button>
</div>


<h2>📱 Приложение HAPP (Windows/Android/iOS/MAC/Linux)</h2>

<div class="btn-group">
    <a href="happ://add/$subPageLink" class="btn">⚡ Add to HAPP</a>
    <a href="https://www.happ.su/main/ru" target="_blank" class="btn download">⬇️ Download App</a>
</div>
<p>Маршрутизацию нужно выключить, она тут встроенная. По умолчанию она выключена - включается, если вы пользовались сторонними сервисами.</p>


<h2>➡️ Конфиги</h2>
EOF

# Отображение единственной VLESS REALITY конфигурации
idx=1
for item in "${CONFIGS_ARRAY[@]}"; do
    title="${item%%|*}"
    link="${item#*|}"
    
    if [ -z "$ALL_LINKS_TEXT" ]; then ALL_LINKS_TEXT="$link"; else ALL_LINKS_TEXT="$ALL_LINKS_TEXT<br>$link"; fi
    
    cat >> "$WEB_PATH/$path_subpage.html" <<EOF
<div class="config-row">
    <div class="config-label">$title</div>
    <div class="config-code" id="c$idx">$link</div>
    <button class="btn-action copy-btn" onclick="copyText('c$idx', this)">Copy</button>
    <button class="btn-action qr-btn" onclick="showQR('c$idx')">QR</button>
</div>
EOF
    ((idx++))
done

# Добавляем Web Proxy блок (чистые tg:// ссылки)
cat >> "$WEB_PATH/$path_subpage.html" <<EOF
<div class="config-row">
    <div class="config-label">Telegram Web Proxy</div>
    <div class="config-code" id="mtproto">${MTProto}</div>
    <button class="btn-action copy-btn" onclick="copyText('mtproto', this)">Copy</button>
    <a href="${MTProto}" target="_blank" class="btn-action qr-btn" title="автодобавление прокси в тг" style="text-decoration:none">✈️ Add to TG</a>
</div>
EOF

# Дописываем конец страницы
cat >> "$WEB_PATH/$path_subpage.html" <<EOF
<h2>💠 Все конфиги вместе</h2>
<div class="config-row">
    <div class="config-code" id="cAll" style="max-height:60px;white-space:pre-wrap;word-break:break-all">$ALL_LINKS_TEXT</div>
    <button class="btn-action copy-btn" onclick="copyText('cAll', this)">Copy ALL</button>
</div>

<div><a style="color:white;margin:40px auto 20px;display:block;text-align:center;" href="https://github.com/xVRVx/autoXRAY">https://github.com/xVRVx/autoXRAY</a></div>

<div id="qrModal" class="modal-overlay"><div class="modal-content"><div id="qrcode"></div><button class="close-modal-btn" onclick="closeModal()">Close</button></div></div>
</body></html>
EOF

# --- ФИНАЛЬНАЯ ПРОВЕРКА ---
echo -e "\n${YEL}=== Финальная проверка статусов ===${NC}"

if systemctl is-active --quiet telemt; then echo -e "Telemt: ${GRN}RUNNING${NC}"; else echo -e "Telemt: ${RED}STOPPED/ERROR${NC}"; fi
if systemctl is-active --quiet tproxy-server; then echo -e "WebProxy: ${GRN}RUNNING${NC}"; else echo -e "WebProxy: ${RED}STOPPED/ERROR${NC}"; fi

if systemctl is-active --quiet nginx; then
    echo -e "Nginx: ${GRN}RUNNING${NC}"
else
    echo -e "Nginx: ${RED}STOPPED/ERROR${NC}"
fi

if systemctl is-active --quiet xray; then
    echo -e "XRAY: ${GRN}RUNNING${NC}"
else
    echo -e "XRAY: ${RED}STOPPED/ERROR${NC}"
fi

echo -e "\n"

echo -e "${YEL}Telegram Web Proxy для ТГ:${NC}"
echo -e "${CYAN}$MTProto${NC}\n"

echo -e "${YEL}VLESS REALITY VISION (Порт 443 TCP) ${NC}
$linkREALITY

${YEL}Ваша json страничка подписки ${NC}
$subPageLink

${YEL}Ссылка на сохраненные конфиги ${NC}
${GRN}$configListLink ${NC}

Скопируйте подписку в специализированное приложение:
- iOS: Happ или v2RayTun или v2rayN
- Android: Happ или v2RayTun или v2rayNG
- Windows: конфиги Happ или winLoadXRAY или v2rayN
	для vless v2RayTun или Throne

Внутри клиента открыт socks5 на 10808, 2080 и http на 10809.

${GRN}Поддержать автора: https://github.com/xVRVx/autoXRAY ${NC}
"
