#!/usr/bin/env bash
# ZARUN – aktualizácia appky na serveri (nemení nastavenie servera ani dáta).
# Spustenie (ako root): curl -fsSL https://raw.githubusercontent.com/vladomarinica-design/zarun-app/main/update.sh | bash
set -euo pipefail
APP_DIR=/opt/zarun
URL="https://raw.githubusercontent.com/vladomarinica-design/zarun-app/main/zarun.tgz?$(date +%s)"
[ -d "$APP_DIR/pb_public" ] || { echo "CHYBA: ZARUN nie je nainštalovaná v $APP_DIR"; exit 1; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
echo "==> Sťahujem novú verziu"
curl -fsSL "$URL" -o "$TMP/z.tgz"
mkdir -p "$TMP/src" && tar -xzf "$TMP/z.tgz" -C "$TMP/src"
[ -f "$TMP/src/pb_public/index.html" ] || { echo "CHYBA: balík je poškodený"; exit 1; }
echo "==> Záloha a kopírovanie"
STAMP="$(date +%Y%m%d-%H%M%S)"
tar -czf "$APP_DIR/backup-$STAMP.tgz" -C "$APP_DIR" pb_public pb_hooks pb_migrations pb_data 2>/dev/null || true
cp -r "$TMP/src/pb_public/." "$APP_DIR/pb_public/"
cp -r "$TMP/src/pb_hooks/." "$APP_DIR/pb_hooks/"
cp -r "$TMP/src/pb_migrations/." "$APP_DIR/pb_migrations/"
chown -R zarun:zarun "$APP_DIR"
echo "==> Reštart"
systemctl restart zarun
sleep 3
ADDR="$(grep -o -- '--http=[^ ]*' /etc/systemd/system/zarun.service | cut -d= -f2)"
if curl -fsS "http://$ADDR/api/health" >/dev/null; then
  echo "=============================================="
  echo " ZARUN aktualizovaná a beží. Záloha: backup-$STAMP.tgz"
  echo "=============================================="
else
  journalctl -u zarun -n 20 --no-pager; echo "CHYBA: ZARUN po aktualizácii neodpovedá."; exit 1
fi
