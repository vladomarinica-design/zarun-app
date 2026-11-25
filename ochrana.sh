#!/usr/bin/env bash
# ZARUN – trvalá ochrana HTTPS adresy.
# Nainštaluje strážcu, ktorý každé 2 minúty skontroluje, či Caddy (spoločný s Tendmanom)
# stále pozná adresu ZARUN. Ak ju napr. aktualizácia Tendmanu zmaže, hneď ju vráti.
# Spustenie (ako root): curl -fsSL https://raw.githubusercontent.com/vladomarinica-design/zarun-app/main/ochrana.sh | bash
set -euo pipefail
[ "$(id -u)" = "0" ] || { echo "CHYBA: spusti ako root."; exit 1; }

cat > /usr/local/bin/zarun-strazca <<'EOF'
#!/usr/bin/env bash
# ZARUN strážca: vráti adresu ZARUN do Caddyfile, ak zmizla. Bezpečné spúšťať opakovane.
set -uo pipefail
SERVICE=/etc/systemd/system/zarun.service
STAMP_F=/var/lib/zarun-strazca.reload
log(){ echo "[zarun-strazca] $*"; logger -t zarun-strazca "$*" 2>/dev/null || true; }
command -v docker >/dev/null || exit 0
IP="$(ip -4 route get 1.1.1.1 2>/dev/null | grep -o 'src [0-9.]*' | cut -d' ' -f2)"
DOMAIN="${ZARUN_DOMAIN:-zarun.${IP//./-}.sslip.io}"
UP="$(grep -o -- '--http=[^ ]*' "$SERVICE" | head -n1 | cut -d= -f2)"; [ -n "$UP" ] || UP=127.0.0.1:8090
C="$(docker ps --format '{{.Names}}\t{{.Image}}\t{{.Ports}}' | awk -F'\t' '$2 ~ /caddy/ && $3 ~ /:443->/ {print $1; exit}')"
[ -n "$C" ] || { log "Caddy kontajner nebeží, skúsim neskôr."; exit 0; }
CF=""
while IFS='|' read -r SRC DST; do
  [ -z "$SRC" ] && continue
  [ "$DST" = "/etc/caddy/Caddyfile" ] && [ -f "$SRC" ] && CF="$SRC"
  [ "$DST" = "/etc/caddy" ] && [ -f "$SRC/Caddyfile" ] && CF="$SRC/Caddyfile"
done < <(docker inspect -f '{{range .Mounts}}{{.Source}}|{{.Destination}}{{println}}{{end}}' "$C")
[ -n "$CF" ] || { log "Nenašiel som Caddyfile kontajnera $C."; exit 0; }
reload(){ docker exec -w /etc/caddy "$C" caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null 2>&1; }
if ! grep -qF "$DOMAIN" "$CF"; then
  BK="$CF.pred-strazcom"; cp -p "$CF" "$BK"
  printf '\n# ZARUN HTTPS (pridal zarun-strazca)\n%s {\n\tencode zstd gzip\n\treverse_proxy %s\n}\n' "$DOMAIN" "$UP" >> "$CF"
  if docker exec "$C" caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null 2>&1 && reload; then
    log "Adresa $DOMAIN chýbala v $CF – vrátená."
  else
    cat "$BK" > "$CF"; reload; log "CHYBA: nová konfigurácia neprešla, vrátil som pôvodnú."
  fi
  exit 0
fi
# Adresa v súbore je, ale HTTPS neodpovedá → Caddy možno nenačítal súbor; reload najviac raz za 30 min.
if ! curl -fsS --max-time 8 "https://$DOMAIN/api/health" >/dev/null 2>&1; then
  last="$(cat "$STAMP_F" 2>/dev/null || echo 0)"; now="$(date +%s)"
  if [ $((now-last)) -gt 1800 ]; then echo "$now" > "$STAMP_F"; reload && log "HTTPS neodpovedalo, Caddy znova načítal nastavenia."; fi
fi
exit 0
EOF
chmod 755 /usr/local/bin/zarun-strazca

cat > /etc/systemd/system/zarun-strazca.service <<'EOF'
[Unit]
Description=ZARUN strazca HTTPS adresy v Caddy
After=docker.service network-online.target
[Service]
Type=oneshot
ExecStart=/usr/local/bin/zarun-strazca
EOF
cat > /etc/systemd/system/zarun-strazca.timer <<'EOF'
[Unit]
Description=ZARUN strazca kazde 2 minuty
[Timer]
OnBootSec=1min
OnUnitActiveSec=2min
[Install]
WantedBy=timers.target
EOF
systemctl daemon-reload
systemctl enable --now zarun-strazca.timer >/dev/null 2>&1
/usr/local/bin/zarun-strazca
D="zarun.$(ip -4 route get 1.1.1.1 | grep -o 'src [0-9.]*' | cut -d' ' -f2 | tr . -).sslip.io"
if systemctl is-active --quiet zarun-strazca.timer && curl -fsS --max-time 10 "https://$D/api/health" >/dev/null; then
  echo "=============================================="
  echo " Ochrana zapnutá. ZARUN beží na https://$D"
  echo "=============================================="
else
  systemctl status zarun-strazca.timer --no-pager | head -n 5; echo "CHYBA: ochrana sa nezapla alebo HTTPS neodpovedá. Pošli screenshot."; exit 1
fi
