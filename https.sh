#!/usr/bin/env bash
# ZARUN – zapnutie HTTPS cez bezplatnú adresu sslip.io (bez kúpy domény).
# Spustenie (ako root):
#   curl -fsSL https://raw.githubusercontent.com/vladomarinica-design/zarun-app/main/https.sh | bash
# Bezpečné spustiť aj viackrát. Pred zmenou spraví zálohu nastavení do /root.
# Appku ani dáta nemení; update.sh funguje ďalej rovnako.
set -euo pipefail

APP_DIR=/opt/zarun
SERVICE=/etc/systemd/system/zarun.service
CADDY_VERSION="2.11.9"

say(){ printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
die(){ printf '\n\033[1;31mCHYBA: %s\033[0m\n' "$*"; echo "Pošli Claudovi screenshot tohto okna."; exit 1; }

[ "$(id -u)" = "0" ] || die "Spusti ako root."
[ -f "$SERVICE" ] || die "Nenašiel som $SERVICE – ZARUN nie je nainštalovaná."
command -v ss >/dev/null || die "Chýba program ss."

case "$(uname -m)" in
  x86_64|amd64) ARCH=amd64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  *) die "Nepodporovaný procesor $(uname -m)." ;;
esac

say "Zisťujem adresu servera"
IP="$(curl -4 -fsS --max-time 10 https://api.ipify.org 2>/dev/null || true)"
[ -n "$IP" ] || IP="$(ip -4 route get 1.1.1.1 2>/dev/null | grep -o 'src [0-9.]*' | cut -d' ' -f2 || true)"
[ -n "$IP" ] || die "Nepodarilo sa zistiť verejnú IP adresu."
DOMAIN="${ZARUN_DOMAIN:-zarun.${IP//./-}.sslip.io}"
echo "IP: $IP    nová adresa: https://$DOMAIN"

port_owner(){ { ss -ltnpH "( sport = :$1 )" 2>/dev/null | grep -o 'users:(("[^"]*' | head -n1 | sed 's/users:(("//'; } || true; }
pb_addr(){ grep -o -- '--http=[^ ]*' "$SERVICE" | head -n1 | cut -d= -f2 || true; }

say "Aktuálny stav"
PB_ADDR="$(pb_addr)"; [ -n "$PB_ADDR" ] || PB_ADDR="127.0.0.1:8090"
P80="$(port_owner 80)"; P443="$(port_owner 443)"
echo "ZARUN (PocketBase) počúva na: $PB_ADDR"
echo "Port 80 používa:  ${P80:-nikto}"
echo "Port 443 používa: ${P443:-nikto}"

say "Záloha nastavení"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/root/zarun-https-zaloha-$STAMP.tgz"
tar -czf "$BACKUP" $(ls -d "$SERVICE" /etc/systemd/system/caddy.service /etc/caddy /etc/nginx 2>/dev/null) 2>/dev/null || true
echo "Záloha: $BACKUP"

# 1) Ak PocketBase sám drží port 80/443, presunie sa na 127.0.0.1:8090 (vpredu bude Caddy).
if [ "$P80" = "pocketbase" ] || [ "$P443" = "pocketbase" ]; then
  say "Presúvam ZARUN na interný port 8090 (vpredu bude HTTPS server)"
  sed -i -E 's#--http=[^ ]*#--http=127.0.0.1:8090#; s# --https=[^ ]*##' "$SERVICE"
  grep -q -- '--http=' "$SERVICE" || sed -i -E 's#(pocketbase serve)#\1 --http=127.0.0.1:8090#' "$SERVICE"
  systemctl daemon-reload
  systemctl restart zarun
  sleep 3
  curl -fsS "http://127.0.0.1:8090/api/health" >/dev/null || { die "ZARUN po presune neodpovedá (záloha: $BACKUP)."; }
  PB_ADDR="127.0.0.1:8090"
  P80="$(port_owner 80)"; P443="$(port_owner 443)"
fi
PB_HOST="${PB_ADDR%:*}"; PB_PORT="${PB_ADDR##*:}"
case "$PB_HOST" in ""|0.0.0.0|"[::]"|localhost) PB_HOST=127.0.0.1 ;; esac
UPSTREAM="$PB_HOST:$PB_PORT"
curl -fsS "http://$UPSTREAM/api/health" >/dev/null || die "ZARUN neodpovedá na $UPSTREAM."

SITE_BLOCK="$DOMAIN {
	encode zstd gzip
	reverse_proxy $UPSTREAM
}"
IP_BLOCK="http://$IP {
	redir https://$DOMAIN{uri}
}"

install_caddy(){
  if ! command -v caddy >/dev/null; then
    say "Inštalujem Caddy $CADDY_VERSION (HTTPS server s automatickým certifikátom)"
    T="$(mktemp -d)"
    curl -fsSL "https://github.com/caddyserver/caddy/releases/download/v${CADDY_VERSION}/caddy_${CADDY_VERSION}_linux_${ARCH}.tar.gz" -o "$T/caddy.tgz"
    tar -xzf "$T/caddy.tgz" -C "$T" caddy
    install -m 0755 "$T/caddy" /usr/local/bin/caddy
    rm -rf "$T"
  fi
  id caddy >/dev/null 2>&1 || useradd --system --home /var/lib/caddy --create-home --shell /usr/sbin/nologin caddy
  mkdir -p /etc/caddy /var/lib/caddy; chown caddy:caddy /var/lib/caddy
  printf '# ZARUN\n%s\n\n# stará adresa cez IP presmeruje na novú\n%s\n' "$SITE_BLOCK" "$IP_BLOCK" > /etc/caddy/Caddyfile
  CADDY_BIN="$(command -v caddy)"
  "$CADDY_BIN" validate --config /etc/caddy/Caddyfile >/dev/null 2>&1 || die "Caddyfile má chybu."
  cat > /etc/systemd/system/caddy.service <<EOF
[Unit]
Description=Caddy web server
After=network-online.target
Wants=network-online.target

[Service]
User=caddy
Group=caddy
ExecStart=$CADDY_BIN run --environ --config /etc/caddy/Caddyfile
ExecReload=$CADDY_BIN reload --config /etc/caddy/Caddyfile --force
Restart=always
AmbientCapabilities=CAP_NET_BIND_SERVICE
Environment=XDG_DATA_HOME=/var/lib/caddy XDG_CONFIG_HOME=/var/lib/caddy

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable caddy >/dev/null 2>&1
  systemctl restart caddy
}

# Je port 80/443 obsadený Docker kontajnerom?
DOCKER_C=""
if command -v docker >/dev/null && docker info >/dev/null 2>&1; then
  DOCKER_C="$(docker ps --format '{{.Names}}\t{{.Ports}}' | grep -E ':(80|443)->' | head -n1 | cut -f1 || true)"
fi

docker_info(){
  echo "--- Docker kontajnery ---"
  docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Ports}}' 2>/dev/null || true
  if [ -n "$DOCKER_C" ]; then
    echo "--- Súbory kontajnera $DOCKER_C ---"
    docker inspect -f '{{range .Mounts}}{{.Source}} -> {{.Destination}}{{println}}{{end}}' "$DOCKER_C" 2>/dev/null || true
  fi
}

if [ -n "$DOCKER_C" ]; then
  IMG="$(docker inspect -f '{{.Config.Image}}' "$DOCKER_C")"
  say "Porty 80/443 má Docker kontajner $DOCKER_C ($IMG)"
  case "$IMG" in *caddy*) : ;; *) docker_info; die "Kontajner $DOCKER_C nie je Caddy, nič som nemenil." ;; esac
  # nájdi Caddyfile na disku servera
  CF=""; DEST_CF=/etc/caddy/Caddyfile
  while IFS='|' read -r SRC DST; do
    [ -z "$SRC" ] && continue
    if [ "$DST" = "/etc/caddy/Caddyfile" ] && [ -f "$SRC" ]; then CF="$SRC"; fi
    if [ "$DST" = "/etc/caddy" ] && [ -f "$SRC/Caddyfile" ]; then CF="$SRC/Caddyfile"; fi
  done < <(docker inspect -f '{{range .Mounts}}{{.Source}}|{{.Destination}}{{println}}{{end}}' "$DOCKER_C")
  [ -n "$CF" ] || { docker_info; die "Nenašiel som Caddyfile kontajnera $DOCKER_C, nič som nemenil."; }
  echo "Caddyfile: $CF"
  grep -Eq '^[[:space:]]*auto_https[[:space:]]+off' "$CF" && { docker_info; cat "$CF"; die "V Caddyfile je vypnuté HTTPS (auto_https off), nič som nemenil."; }
  # adresa ZARUN tak, ako ju kontajner už pozná
  C_UP="$(grep -Eo 'reverse_proxy[[:space:]]+[^[:space:]{]*:'"$PB_PORT" "$CF" | head -n1 | awk '{print $2}' || true)"
  [ -n "$C_UP" ] || C_UP="$UPSTREAM"
  echo "Kontajner sa na ZARUN pripája cez: $C_UP"
  cp -p "$CF" "$CF.pred-https-$STAMP"
  if ! grep -qF "$DOMAIN" "$CF"; then
    printf '\n# ZARUN HTTPS\n%s {\n\tencode zstd gzip\n\treverse_proxy %s\n}\n' "$DOMAIN" "$C_UP" >> "$CF"
  fi
  if ! docker exec "$DOCKER_C" caddy validate --config "$DEST_CF" --adapter caddyfile >/dev/null 2>&1; then
    cat "$CF.pred-https-$STAMP" > "$CF"
    docker exec "$DOCKER_C" caddy validate --config "$DEST_CF" --adapter caddyfile 2>&1 | tail -n 5 || true
    die "Nová konfigurácia nebola v poriadku, vrátil som pôvodnú."
  fi
  if ! docker exec -w /etc/caddy "$DOCKER_C" caddy reload --config "$DEST_CF" --adapter caddyfile >/dev/null 2>&1; then
    cat "$CF.pred-https-$STAMP" > "$CF"
    docker exec -w /etc/caddy "$DOCKER_C" caddy reload --config "$DEST_CF" --adapter caddyfile >/dev/null 2>&1 || true
    die "Caddy novú konfiguráciu neprijal, vrátil som pôvodnú."
  fi

elif [ "$P80" = "caddy" ] || [ "$P443" = "caddy" ] || { systemctl is-active --quiet caddy 2>/dev/null && [ -f /etc/caddy/Caddyfile ]; }; then
  say "Caddy už beží – pridávam novú adresu"
  CF=/etc/caddy/Caddyfile
  [ -f "$CF" ] || die "Caddy beží, ale nenašiel som $CF."
  cp "$CF" "$CF.pred-https-$STAMP"
  if ! grep -qF "$DOMAIN" "$CF"; then printf '\n# ZARUN\n%s\n' "$SITE_BLOCK" >> "$CF"; fi
  if ! caddy validate --config "$CF" --adapter caddyfile >/dev/null 2>&1; then
    cp "$CF.pred-https-$STAMP" "$CF"; die "Nová konfigurácia Caddy nebola v poriadku, vrátil som pôvodnú."
  fi
  systemctl reload caddy || systemctl restart caddy

elif [ -z "$P80" ] && [ -z "$P443" ]; then
  install_caddy

elif [ "$P80" = "nginx" ] && { [ -z "$P443" ] || [ "$P443" = "nginx" ]; }; then
  say "Beží nginx – pridávam novú adresu a certifikát (certbot)"
  if [ -d /etc/nginx/sites-available ]; then
    NCONF=/etc/nginx/sites-available/zarun-sslip
    LINK=/etc/nginx/sites-enabled/zarun-sslip
  else
    NCONF=/etc/nginx/conf.d/zarun-sslip.conf; LINK=""
  fi
  if ! grep -rqF "$DOMAIN" /etc/nginx/ 2>/dev/null; then
    cat > "$NCONF" <<EOF
server {
    listen 80;
    server_name $DOMAIN;
    client_max_body_size 50m;
    location / {
        proxy_pass http://$UPSTREAM;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 360s;
        proxy_buffering off;
    }
}
EOF
    [ -n "$LINK" ] && ln -sf "$NCONF" "$LINK"
  fi
  if ! nginx -t >/dev/null 2>&1; then rm -f "$NCONF" ${LINK:+"$LINK"}; die "nginx konfigurácia nebola v poriadku, zmenu som vrátil."; fi
  systemctl reload nginx
  DEBIAN_FRONTEND=noninteractive apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq certbot python3-certbot-nginx >/dev/null
  if command -v ufw >/dev/null && ufw status | grep -q "Status: active"; then ufw allow 80/tcp >/dev/null; ufw allow 443/tcp >/dev/null; fi
  certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos --register-unsafely-without-email --redirect --keep-until-expiring \
    || die "Certifikát sa nepodarilo získať. Skontroluj firewall v LumaDock: porty 80 a 443 musia byť otvorené."

else
  echo "Port 80 používa: ${P80:-nikto}, port 443: ${P443:-nikto}"
  command -v docker >/dev/null && docker_info
  die "Tento webový server nepoznám, nič som nemenil."
fi

if command -v ufw >/dev/null && ufw status | grep -q "Status: active"; then
  say "Firewall: otváram porty 80 a 443"
  ufw allow 80/tcp >/dev/null; ufw allow 443/tcp >/dev/null
fi

say "Čakám na HTTPS certifikát (do 90 s)"
ok=0
for i in $(seq 1 30); do
  if curl -fsS --max-time 5 "https://$DOMAIN/api/health" >/dev/null 2>&1; then ok=1; break; fi
  sleep 3
done

# adresa v súbore so správcovskými údajmi
[ -f "$APP_DIR/.admin" ] && sed -i -E "s#^Správa ZARUN: .*#Správa ZARUN: https://$DOMAIN/_/#" "$APP_DIR/.admin" || true

echo
echo "=============================================================="
if [ "$ok" = "1" ]; then
  echo " HTTPS funguje. ZARUN je na adrese:"
  echo "   https://$DOMAIN"
else
  echo " Nastavenie je hotové, ale HTTPS zatiaľ neodpovedá:"
  echo "   https://$DOMAIN"
  echo " Skontroluj firewall v LumaDock: porty 80 a 443 musia byť otvorené."
  echo " Potom tento príkaz spusti znova."
fi
echo " Záloha nastavení: $BACKUP"
echo "=============================================================="
[ "$ok" = "1" ] || exit 1
