#!/usr/bin/env bash
# ZARUN – nastavenie nového hesla do appky (keď ho niekto zabudol).
# Spustenie (ako root):
#   curl -fsSL https://raw.githubusercontent.com/vladomarinica-design/zarun-app/main/heslo.sh | bash
# Opýta sa, komu nastaviť heslo, a nové heslo (pri písaní nie je vidieť). Iné dáta nemení.
set -euo pipefail
APP_DIR=/opt/zarun
SERVICE=/etc/systemd/system/zarun.service

die(){ printf '\n\033[1;31mCHYBA: %s\033[0m\n' "$*"; echo "Pošli Claudovi screenshot tohto okna."; exit 1; }
[ "$(id -u)" = "0" ] || die "Spusti ako root."
[ -f "$APP_DIR/.env" ] || die "Nenašiel som $APP_DIR/.env."
command -v python3 >/dev/null || die "Chýba python3."
exec 3</dev/tty || die "Skript treba spustiť v okne terminálu."

. "$APP_DIR/.env"
MENTOR="$(echo "${ZARUN_MENTOR_EMAIL:-}" | tr 'A-Z' 'a-z' | xargs)"
RUNNER="$(echo "${ZARUN_RUNNER_EMAIL:-}" | tr 'A-Z' 'a-z' | xargs)"
ADDR="$(grep -o -- '--http=[^ ]*' "$SERVICE" | head -n1 | cut -d= -f2 || true)"; [ -n "$ADDR" ] || ADDR=127.0.0.1:8090
case "${ADDR%:*}" in ""|0.0.0.0) ADDR="127.0.0.1:${ADDR##*:}" ;; esac
API="http://$ADDR/api"
curl -fsS "$API/health" >/dev/null || die "ZARUN neodpovedá ($ADDR)."

echo
echo "Komu nastaviť nové heslo?"
echo "  1) $MENTOR (mentor)"
echo "  2) $RUNNER (Zara)"
read -r -u 3 -p "Napíš 1 alebo 2 a stlač Enter: " CH
case "$CH" in 1) EMAIL="$MENTOR" ;; 2) EMAIL="$RUNNER" ;; *) die "Treba napísať 1 alebo 2." ;; esac
[ -n "$EMAIL" ] || die "Tento e-mail nie je nastavený v $APP_DIR/.env."

while :; do
  read -r -s -u 3 -p "Nové heslo (aspoň 8 znakov, pri písaní ho nevidno): " P1; echo
  read -r -s -u 3 -p "Nové heslo ešte raz: " P2; echo
  if [ "${#P1}" -lt 8 ]; then echo "Heslo je kratšie ako 8 znakov, skús znova."; continue; fi
  if [ "$P1" != "$P2" ]; then echo "Heslá sa nezhodujú, skús znova."; continue; fi
  break
done

# Správcovský prístup (bez neho sa heslo meniť nedá): dočasný správca, na konci sa zmaže.
ADM_EMAIL="zarun-heslo-$(date +%s)@example.com"
ADM_PASS="$(set +o pipefail; tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32)"
PBX=(runuser -u zarun -- "$APP_DIR/pocketbase")
DIRARG="--dir=$APP_DIR/pb_data"
"${PBX[@]}" superuser upsert "$ADM_EMAIL" "$ADM_PASS" "$DIRARG" >/dev/null 2>&1 || die "Nepodarilo sa vytvoriť dočasného správcu."
cleanup(){ "${PBX[@]}" superuser delete "$ADM_EMAIL" "$DIRARG" >/dev/null 2>&1 || true; }
trap cleanup EXIT

export API ADM_EMAIL ADM_PASS EMAIL P1
python3 - <<'PY' || die "Heslo sa nepodarilo nastaviť."
import json, os, urllib.request, urllib.parse, urllib.error
api=os.environ["API"]
def call(method, path, data=None, token=None):
    req=urllib.request.Request(api+path, method=method,
        data=json.dumps(data).encode() if data is not None else None,
        headers={"Content-Type":"application/json", **({"Authorization":token} if token else {})})
    with urllib.request.urlopen(req, timeout=15) as r:
        return json.loads(r.read() or b"{}")
tok=call("POST","/collections/_superusers/auth-with-password",
         {"identity":os.environ["ADM_EMAIL"],"password":os.environ["ADM_PASS"]})["token"]
email=os.environ["EMAIL"]; pw=os.environ["P1"]
flt=urllib.parse.quote('email="%s"' % email.replace('"',''))
items=call("GET","/collections/users/records?perPage=1&filter="+flt, token=tok).get("items",[])
body={"password":pw,"passwordConfirm":pw,"verified":True}
if items:
    call("PATCH","/collections/users/records/"+items[0]["id"], body, tok)
    print("\nHeslo zmenené pre", email)
else:
    body["email"]=email
    call("POST","/collections/users/records", body, tok)
    print("\nÚčet vytvorený pre", email)
PY

echo "=============================================="
echo " Hotovo. Prihlás sa v appke ako $EMAIL"
echo " s novým heslom."
echo "=============================================="
