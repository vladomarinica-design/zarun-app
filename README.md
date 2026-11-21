# ZARUN · run with a plan

Bežecká appka pre 52-týždňový plán na 12 km. Zara zapisuje tréningy (aj import GPX/TCX z Apple Watch cez HealthFit), mentor píše odporúčania a sleduje grafy.

- `pb_public/` – appka (PWA, dá sa pridať na plochu iPhonu)
- `pb_migrations/`, `pb_hooks/` – databáza a pravidlá prístupu (PocketBase)
- `install.sh` – inštalácia / aktualizácia na serveri
- `zarun.tgz` – zbalená appka (pb_public, pb_hooks, pb_migrations), ktorú si stiahne install.sh

## Inštalácia a aktualizácia na serveri (ako root)

```
curl -fsSL https://raw.githubusercontent.com/vladomarinica-design/zarun-app/main/install.sh | ZARUN_MENTOR_EMAIL=mentor@mail.sk ZARUN_RUNNER_EMAIL=bezkyna@mail.sk bash
```

Aktualizácia appky (bez zmeny nastavenia servera):

```
curl -fsSL https://raw.githubusercontent.com/vladomarinica-design/zarun-app/main/update.sh | bash
```

Prístup majú len e-maily v `/opt/zarun/.env` (mentor a bežkyňa). Po zmene e-mailov: `systemctl restart zarun`.
Správa databázy: `https://<adresa>/_/` (prihlasovacie údaje sú v `/opt/zarun/.admin`).
