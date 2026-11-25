#!/usr/bin/env bash
# ZARUN – diagnostika prihlásenia (nič nemení, iba vypíše stav).
D=zarun.154-13-149-235.sslip.io
SVC=/etc/systemd/system/zarun.service
ADDR="$(grep -o -- '--http=[^ ]*' "$SVC" | head -n1 | cut -d= -f2)"
echo "== 1) ZARUN služba: $(systemctl is-active zarun)  adresa: $ADDR"
echo "== 2) Priamo:  $(curl -s -m 5 -o /dev/null -w '%{http_code}' "http://$ADDR/api/health")"
echo "== 3) HTTPS health: $(curl -s -m 10 -o /dev/null -w '%{http_code}' "https://$D/api/health")"
echo "== 4) HTTPS login test (čakám 400): $(curl -s -m 10 -o /dev/null -w '%{http_code}' -X POST -H 'content-type: application/json' -d '{"identity":"test@test.sk","password":"zlezlezle"}' "https://$D/api/collections/users/auth-with-password")"
echo "== 5) HTTPS stránka: $(curl -s -m 10 -o /dev/null -w '%{http_code}' "https://$D/")  SDK: $(curl -s -m 10 -o /dev/null -w '%{http_code}' "https://$D/pocketbase.umd.js")"
echo "== 6) DNS: $(getent hosts $D | head -n1)"
echo "== 7) Caddy:"; docker ps -a --format '   {{.Names}} {{.Status}}' 2>/dev/null | grep -i caddy
echo "== 8) Caddyfile (ZARUN časť):"; grep -n -B1 -A4 "$D" /opt/tendman/deploy/Caddyfile 2>/dev/null
echo "== 9) Caddy log (chyby):"; docker logs --tail 200 deploy-caddy-1 2>&1 | grep -i "$D\|error" | tail -n 8
echo "== 10) ZARUN log:"; journalctl -u zarun -n 8 --no-pager 2>/dev/null
echo "== HOTOVO – skopíruj celý tento výpis do chatu."
