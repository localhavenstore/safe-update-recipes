#!/usr/bin/env bash
# R5 (Home Assistant Container recipe) on a fresh throwaway VM, real image: recorder db_url via !include -> PostgreSQL
# is refused (nothing changed); an explicit SQLite db_url inside /config in a package file is accepted (snapshot + drill
# OK, recorder quick_check). Logs: lab/work/sur-r5/.
set -uo pipefail
VM=${TESTVM:?set TESTVM to your VM helper - see tests/README.md}; OUT=${OUTDIR:-./results}/sur-r5; SRC=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$OUT"; rm -f "$OUT"/*.txt
s() { "$VM" ssh "$1" > "$OUT/$2.txt" 2>&1; echo "== $2 exit $?" | tee -a "$OUT/summary.txt"; }
trap '"$VM" down >/dev/null 2>&1' EXIT
"$VM" up || exit 1
tar -C "$SRC" -czf /tmp/sur-src-$$.tgz safe-update recipes && "$VM" put /tmp/sur-src-$$.tgz /home/learner/sur.tgz; rm -f /tmp/sur-src-$$.tgz
SU="sudo /home/learner/sur/safe-update"; IMG=ghcr.io/home-assistant/home-assistant:2026.9.4
s "sudo apt-get update -qq && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq docker.io docker-compose-v2 python3 curl >/dev/null && mkdir -p sur && tar -xzf sur.tgz -C sur && echo ready" prereq
s "sudo mkdir -p /srv/ha/config && printf 'services:\n  homeassistant:\n    image: $IMG\n    volumes: [\"./config:/config\"]\n' | sudo tee /srv/ha/compose.yaml >/dev/null && cd /srv/ha && sudo docker compose up -d --quiet-pull 2>&1 | tail -1; for i in \$(seq 1 60); do sudo test -f /srv/ha/config/configuration.yaml && break; sleep 3; done; sleep 20; echo started" start
s "printf 'recorder: !include recorder.yaml\n' | sudo tee -a /srv/ha/config/configuration.yaml >/dev/null; printf 'db_url: postgresql://ha:pw@db/ha\n' | sudo tee /srv/ha/config/recorder.yaml >/dev/null; $SU plan homeassistant /srv/ha; echo rc=\$?" include-postgres
s "sudo sed -i '/^recorder: !include recorder.yaml/d' /srv/ha/config/configuration.yaml; sudo rm -f /srv/ha/config/recorder.yaml; sudo mkdir -p /srv/ha/config/packages; printf 'homeassistant:\n  packages: !include_dir_named packages\n' | sudo tee -a /srv/ha/config/configuration.yaml >/dev/null; printf 'recorder:\n  db_url: sqlite:////config/home-assistant_v2.db\n' | sudo tee /srv/ha/config/packages/rec.yaml >/dev/null; cd /srv/ha && sudo docker compose restart >/dev/null 2>&1; sleep 30; $SU snapshot homeassistant /srv/ha; echo rc=\$?; $SU check homeassistant /srv/ha; echo rc=\$?; $SU drill homeassistant /srv/ha; echo rc=\$?" package-sqlite
chk() { if eval "$2"; then echo "PASS $1" | tee -a "$OUT/summary.txt"; else echo "FAIL $1" | tee -a "$OUT/summary.txt"; fi; }
chk "HA: recorder db_url (PostgreSQL) via !include -> refused, nothing changed" "grep -q 'not the default recorder file' '$OUT/include-postgres.txt' && grep -q 'rc=1' '$OUT/include-postgres.txt'"
chk "HA: explicit SQLite db_url in a package file -> snapshot + check + drill OK" "grep -q 'snapshot COMPLETE' '$OUT/package-sqlite.txt' && grep -q 'home assistant up' '$OUT/package-sqlite.txt' && grep -q 'drill OK' '$OUT/package-sqlite.txt'"
chk "no Python traceback / SyntaxError in any output" "! grep -lE 'Traceback|SyntaxError' '$OUT'/*.txt"
