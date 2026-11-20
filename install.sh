#!/usr/bin/env bash
# ZARUN – inštalácia / aktualizácia na VPS (Ubuntu/Debian, x86_64 alebo arm64).
# Spustenie (ako root):
#   curl -fsSL https://raw.githubusercontent.com/vladomarinica-design/zarun-app/main/install.sh | ZARUN_MENTOR_EMAIL=... ZARUN_RUNNER_EMAIL=... bash
# Aktualizácia neskôr: curl -fsSL .../install.sh | bash   (e-maily sa zoberú z /opt/zarun/.env)
# Opätovné spustenie appku aktualizuje; dáta (tréningy, účty) zostanú.
set -euo pipefail

GH_USER="${GH_USER:-vladomarinica-design}"
REPO="${REPO:-zarun-app}"
BRANCH="${BRANCH:-main}"
PB_VERSION="0.40.6"
CADDY_VERSION="2.11.9"
APP_DIR="/opt/zarun"
PORT="8090"
# E-maily s prístupom: zadaj pri spustení, alebo sa zoberú z existujúceho /opt/zarun/.env
IN_MENTOR="${ZARUN_MENTOR_EMAIL:-}"; IN_RUNNER="${ZARUN_RUNNER_EMAIL:-}"
[ -f "$APP_DIR/.env" ] && . "$APP_DIR/.env" || true
MENTOR_EMAIL="${IN_MENTOR:-${ZARUN_MENTOR_EMAIL:-}}"
RUNNER_EMAIL="${IN_RUNNER:-${ZARUN_RUNNER_EMAIL:-}}"

say(){ printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
die(){ printf '\n\033[1;31mCHYBA: %s\033[0m\n' "$*"; exit 1; }

[ "$(id -u)" = "0" ] || die "Spusti ako root (alebo: sudo bash)."
[ -n "$MENTOR_EMAIL" ] && [ -n "$RUNNER_EMAIL" ] || die "Zadaj e-maily: curl ... | ZARUN_MENTOR_EMAIL=ty@mail.sk ZARUN_RUNNER_EMAIL=ona@mail.sk bash"
command -v systemctl >/dev/null || die "Server nemá systemd."

case "$(uname -m)" in
  x86_64|amd64) ARCH=amd64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  *) die "Nepodporovaný procesor $(uname -m)." ;;
esac

say "Potrebné nástroje"
if command -v apt-get >/dev/null; then
  DEBIAN_FRONTEND=noninteractive apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl unzip tar ca-certificates >/dev/null
fi
for c in curl unzip tar; do command -v $c >/dev/null || die "Chýba program $c."; done

say "Verejná IP adresa a webová adresa appky"
IP="$(curl -4 -fsS --max-time 10 https://api.ipify.org || curl -4 -fsS --max-time 10 https://ifconfig.me || true)"
[ -n "$IP" ] || die "Nepodarilo sa zistiť verejnú IP adresu."
DOMAIN="${ZARUN_DOMAIN:-zarun.${IP//./-}.sslip.io}"
echo "IP: $IP   adresa: https://$DOMAIN"

say "Stiahnutie appky z GitHubu ($GH_USER/$REPO)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
curl -fsSL "https://raw.githubusercontent.com/$GH_USER/$REPO/$BRANCH/zarun.tgz?$(date +%s)" -o "$TMP/src.tgz" || die "Nepodarilo sa stiahnuť kód z GitHubu (je úložisko verejné?)."
mkdir -p "$TMP/src" && tar -xzf "$TMP/src.tgz" -C "$TMP/src"
SRC="$TMP/src"
[ -f "$SRC/pb_public/index.html" ] || die "V úložisku chýba pb_public/index.html."
curl -fsSL "https://registry.npmjs.org/pocketbase/-/pocketbase-0.29.0.tgz" -o "$TMP/sdk.tgz" || die "Nepodarilo sa stiahnuť PocketBase SDK."
tar -xzf "$TMP/sdk.tgz" -C "$TMP" package/dist/pocketbase.umd.js
cp "$TMP/package/dist/pocketbase.umd.js" "$SRC/pb_public/pocketbase.umd.js"

say "PocketBase $PB_VERSION (prihlasovanie + databáza)"
mkdir -p "$APP_DIR"
if [ ! -x "$APP_DIR/pocketbase" ] || ! "$APP_DIR/pocketbase" --version 2>/dev/null | grep -q "$PB_VERSION"; then
  curl -fsSL "https://github.com/pocketbase/pocketbase/releases/download/v${PB_VERSION}/pocketbase_${PB_VERSION}_linux_${ARCH}.zip" -o "$TMP/pb.zip"
  unzip -o -q "$TMP/pb.zip" pocketbase -d "$APP_DIR"
  chmod +x "$APP_DIR/pocketbase"
fi
rm -rf "$APP_DIR/pb_public" "$APP_DIR/pb_hooks" "$APP_DIR/pb_migrations"
cp -r "$SRC/pb_public" "$SRC/pb_hooks" "$SRC/pb_migrations" "$APP_DIR/"

id zarun >/dev/null 2>&1 || useradd --system --home "$APP_DIR" --shell /usr/sbin/nologin zarun
cat > "$APP_DIR/.env" <<EOF
ZARUN_MENTOR_EMAIL=$MENTOR_EMAIL
ZARUN_RUNNER_EMAIL=$RUNNER_EMAIL
EOF
mkdir -p "$APP_DIR/pb_data"
chown -R zarun:zarun "$APP_DIR"
chmod 600 "$APP_DIR/.env"

cat > /etc/systemd/system/zarun.service <<EOF
[Unit]
Description=ZARUN (PocketBase)
After=network-online.target
Wants=network-online.target

[Service]
User=zarun
Group=zarun
WorkingDirectory=$APP_DIR
EnvironmentFile=$APP_DIR/.env
ExecStart=$APP_DIR/pocketbase serve --http=127.0.0.1:$PORT --dir=$APP_DIR/pb_data --publicDir=$APP_DIR/pb_public --hooksDir=$APP_DIR/pb_hooks --migrationsDir=$APP_DIR/pb_migrations
Restart=always
RestartSec=3
LimitNOFILE=4096

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable zarun >/dev/null 2>&1
systemctl restart zarun
sleep 3
systemctl is-active --quiet zarun || { journalctl -u zarun -n 30 --no-pager; die "ZARUN sa nespustila."; }
curl -fsS "http://127.0.0.1:$PORT/api/health" >/dev/null || die "ZARUN neodpovedá na porte $PORT."

ADMIN_FILE="$APP_DIR/.admin"
if [ ! -f "$ADMIN_FILE" ]; then
  ADMIN_PASS="$(set +o pipefail; tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20)"
  runuser -u zarun -- "$APP_DIR/pocketbase" superuser upsert "$MENTOR_EMAIL" "$ADMIN_PASS" --dir="$APP_DIR/pb_data" >/dev/null
  printf 'Správa ZARUN: https://%s/_/\nE-mail: %s\nHeslo: %s\n' "$DOMAIN" "$MENTOR_EMAIL" "$ADMIN_PASS" > "$ADMIN_FILE"
  chmod 600 "$ADMIN_FILE"
fi

say "HTTPS (Caddy) pre $DOMAIN"
port_owner(){ { ss -ltnpH "( sport = :$1 )" 2>/dev/null | grep -o 'users:(("[^"]*' | head -n1 | sed 's/users:(("//'; } || true; }
P80="$(port_owner 80)"; P443="$(port_owner 443)"
SITE_BLOCK="$DOMAIN {
	encode zstd gzip
	reverse_proxy 127.0.0.1:$PORT
}"
if systemctl is-active --quiet caddy && [ -f /etc/caddy/Caddyfile ]; then
  if ! grep -q "$DOMAIN" /etc/caddy/Caddyfile; then printf '\n# ZARUN\n%s\n' "$SITE_BLOCK" >> /etc/caddy/Caddyfile; fi
  caddy validate --config /etc/caddy/Caddyfile >/dev/null 2>&1 || die "Caddyfile má chybu, skontroluj /etc/caddy/Caddyfile."
  systemctl reload caddy
elif [ -z "$P80" ] && [ -z "$P443" ]; then
  if ! command -v caddy >/dev/null; then
    curl -fsSL "https://github.com/caddyserver/caddy/releases/download/v${CADDY_VERSION}/caddy_${CADDY_VERSION}_linux_${ARCH}.tar.gz" -o "$TMP/caddy.tgz"
    tar -xzf "$TMP/caddy.tgz" -C "$TMP" caddy
    install -m 0755 "$TMP/caddy" /usr/local/bin/caddy
  fi
  id caddy >/dev/null 2>&1 || useradd --system --home /var/lib/caddy --create-home --shell /usr/sbin/nologin caddy
  mkdir -p /etc/caddy
  printf '# ZARUN\n%s\n' "$SITE_BLOCK" > /etc/caddy/Caddyfile
  CADDY_BIN="$(command -v caddy)"
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
else
  echo "Porty 80/443 už používa: ${P80:-?} / ${P443:-?}"
  echo "ZARUN beží na http://127.0.0.1:$PORT – treba ju napojiť na existujúci webový server."
  die "Port 80 alebo 443 je obsadený inou službou. Pošli tento výpis Claudovi."
fi

if command -v ufw >/dev/null && ufw status | grep -q "Status: active"; then
  ufw allow 80/tcp >/dev/null; ufw allow 443/tcp >/dev/null
fi

say "Čakám na HTTPS certifikát (do 60 s)"
ok=0
for i in $(seq 1 20); do
  if curl -fsS --max-time 5 "https://$DOMAIN/api/health" >/dev/null 2>&1; then ok=1; break; fi
  sleep 3
done

echo
echo "=============================================================="
if [ "$ok" = "1" ]; then echo " ZARUN beží:  https://$DOMAIN"; else echo " ZARUN beží lokálne, HTTPS ešte nenabehlo: https://$DOMAIN"; echo " (skontroluj firewall v LumaDock: porty 80 a 443 musia byť otvorené)"; fi
echo " Prístup majú: $MENTOR_EMAIL (mentor), $RUNNER_EMAIL (Zara)"
echo "--------------------------------------------------------------"
cat "$ADMIN_FILE"
echo "=============================================================="
