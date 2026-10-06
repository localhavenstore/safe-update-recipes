#!/usr/bin/env bash
# R4 (new recipes vaultwarden + n8n, after Codex recipes r1) on a fresh throwaway VM, real images:
# VW sqlite:// URL accepted; VW attachments outside /data refused; n8n key only in the environment + a credential ->
# snapshot + drill OK (credential decrypts); n8n binary data outside the folder refused. Logs: lab/work/sur-r4/.
set -uo pipefail
VM=${TESTVM:?set TESTVM to your VM helper - see tests/README.md}; OUT=${OUTDIR:-./results}/sur-r4; SRC=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$OUT"; rm -f "$OUT"/*.txt
s() { "$VM" ssh "$1" > "$OUT/$2.txt" 2>&1; echo "== $2 exit $?" | tee -a "$OUT/summary.txt"; }
trap '"$VM" down >/dev/null 2>&1' EXIT
"$VM" up || exit 1
tar -C "$SRC" -czf /tmp/sur-src-$$.tgz safe-update recipes && "$VM" put /tmp/sur-src-$$.tgz /home/learner/sur.tgz; rm -f /tmp/sur-src-$$.tgz
SU="sudo /home/learner/sur/safe-update"
printf '%s' '[{"id":"uwCred000000001","name":"Test API","type":"httpHeaderAuth","data":{"name":"X-Key","value":"r4-secret-value"}}]' > /tmp/sur-cred-$$.json
"$VM" put /tmp/sur-cred-$$.json /home/learner/cred.json; rm -f /tmp/sur-cred-$$.json
s "sudo apt-get update -qq && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq docker.io docker-compose-v2 python3 curl >/dev/null && mkdir -p sur && tar -xzf sur.tgz -C sur && echo ready" prereq
# Vaultwarden: documented sqlite URL -> accepted
s "sudo mkdir -p /srv/vw && printf 'services:\n  vaultwarden:\n    image: vaultwarden/server:1.37.3\n    environment: {DATABASE_URL: \"sqlite:///data/db.sqlite3\"}\n    volumes: [\"./vw-data:/data\"]\n' | sudo tee /srv/vw/compose.yaml >/dev/null && cd /srv/vw && sudo docker compose up -d --quiet-pull 2>&1 | tail -1; sleep 8; $SU snapshot vaultwarden /srv/vw; echo rc=\$?; $SU drill vaultwarden /srv/vw; echo rc=\$?" vw-sqlite-url
# Vaultwarden: attachments outside /data -> refused, nothing changed
s "cd /srv/vw && sudo docker compose down >/dev/null 2>&1; sudo mkdir -p /srv/vw2 /srv/vw2/att && printf 'services:\n  vaultwarden:\n    image: vaultwarden/server:1.37.3\n    environment: {ATTACHMENTS_FOLDER: /att}\n    volumes: [\"./vw-data:/data\", \"./att:/att\"]\n' | sudo tee /srv/vw2/compose.yaml >/dev/null && cd /srv/vw2 && sudo docker compose up -d --quiet-pull 2>&1 | tail -1; sleep 8; $SU snapshot vaultwarden /srv/vw2; echo rc=\$?; sudo ls -A /srv/vw2/.safe-update 2>/dev/null | grep -c '^2' ; echo snaps-listed" vw-attach-refused
# Vaultwarden: traversal path + nested mount inside /data -> refused
s "sudo mkdir -p /srv/vw3 && printf 'services:\n  vaultwarden:\n    image: vaultwarden/server:1.37.3\n    environment: {DATABASE_URL: /data/../ext/db.sqlite3}\n    volumes: [\"./vw-data:/data\"]\n' | sudo tee /srv/vw3/compose.yaml >/dev/null && cd /srv/vw3 && $SU plan vaultwarden /srv/vw3; echo rc=\$?; sudo mkdir -p /srv/vw4 && printf 'services:\n  vaultwarden:\n    image: vaultwarden/server:1.37.3\n    volumes: [\"./vw-data:/data\", \"./att:/data/attachments\"]\n' | sudo tee /srv/vw4/compose.yaml >/dev/null && $SU plan vaultwarden /srv/vw4; echo rc=\$?" vw-traversal-nested
# Vaultwarden ENV_FILE + n8n external (s3) binary mode -> refused (plan only)
s "sudo mkdir -p /srv/vw5 /srv/n9 && printf 'services:\n  vaultwarden:\n    image: vaultwarden/server:1.37.3\n    environment: {ENV_FILE: /config/vw.env}\n    volumes: [\"./vw-data:/data\"]\n' | sudo tee /srv/vw5/compose.yaml >/dev/null && $SU plan vaultwarden /srv/vw5; echo rc=\$?; printf 'services:\n  n8n:\n    image: docker.n8n.io/n8nio/n8n:2.41.7\n    environment: {N8N_EXECUTION_DATA_STORAGE_MODE: s3}\n    volumes: [\"./n8n-data:/home/node/.n8n\"]\n' | sudo tee /srv/n9/compose.yaml >/dev/null && $SU plan n8n /srv/n9; echo rc=\$?" envfile-s3
# n8n: key only in the environment + one credential -> snapshot + drill OK (credential must decrypt)
s "cd /srv/vw2 && sudo docker compose down >/dev/null 2>&1; sudo mkdir -p /srv/n8 && printf 'services:\n  n8n:\n    image: docker.n8n.io/n8nio/n8n:2.41.7\n    environment: {N8N_ENCRYPTION_KEY: r4-env-only-key-123, GENERIC_TIMEZONE: UTC}\n    volumes: [\"n8ndata:/home/node/.n8n\"]\nvolumes:\n  n8ndata: {}\n' | sudo tee /srv/n8/compose.yaml >/dev/null && cd /srv/n8 && sudo docker compose up -d --quiet-pull 2>&1 | tail -1; for i in \$(seq 1 60); do sudo docker compose exec -T n8n node -e \"fetch('http://127.0.0.1:5678/healthz').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))\" && break; sleep 2; done; sudo docker cp /home/learner/cred.json \$(sudo docker compose ps -q n8n):/tmp/cred.json && sudo docker compose exec -T n8n n8n import:credentials --input=/tmp/cred.json 2>&1 | tail -1; $SU snapshot n8n /srv/n8; echo rc=\$?; $SU drill n8n /srv/n8; echo rc=\$?" n8n-envkey
# n8n: binary data outside the folder -> refused
s "cd /srv/n8 && sudo sed -i 's#GENERIC_TIMEZONE: UTC#GENERIC_TIMEZONE: UTC, N8N_BINARY_DATA_STORAGE_PATH: /bindata#' compose.yaml && sudo docker compose up -d 2>&1 | tail -1; sleep 15; $SU snapshot n8n /srv/n8; echo rc=\$?" n8n-binary-refused
chk() { if eval "$2"; then echo "PASS $1" | tee -a "$OUT/summary.txt"; else echo "FAIL $1" | tee -a "$OUT/summary.txt"; fi; }
chk "VW: documented sqlite:///data URL accepted (snapshot + drill OK)" "grep -q 'snapshot COMPLETE' '$OUT/vw-sqlite-url.txt' && grep -q 'drill OK' '$OUT/vw-sqlite-url.txt'"
chk "VW: ATTACHMENTS_FOLDER outside /data -> refused, no snapshot" "grep -q 'outside /data' '$OUT/vw-attach-refused.txt' && grep -q 'rc=1' '$OUT/vw-attach-refused.txt' && grep -qx 0 '$OUT/vw-attach-refused.txt'"
chk "VW: traversal path (/data/../ext) and a nested mount at /data/attachments -> both refused" "[ \$(grep -c 'outside /data' '$OUT/vw-traversal-nested.txt') = 2 ] && [ \$(grep -c '^rc=1' '$OUT/vw-traversal-nested.txt') = 2 ]"
chk "VW ENV_FILE and n8n s3 binary mode -> both refused" "grep -q 'ENV_FILE' '$OUT/envfile-s3.txt' && grep -q 'N8N_EXECUTION_DATA_STORAGE_MODE' '$OUT/envfile-s3.txt' && [ \$(grep -c '^rc=1' '$OUT/envfile-s3.txt') = 2 ]"
chk "n8n: key only in the environment + credential -> snapshot + drill OK (credential decrypts in the drill)" "grep -q 'snapshot COMPLETE' '$OUT/n8n-envkey.txt' && grep -q 'drill OK' '$OUT/n8n-envkey.txt'"
chk "n8n: binary data outside the folder -> refused" "grep -q 'outside /home/node/.n8n' '$OUT/n8n-binary-refused.txt' && grep -q 'rc=1' '$OUT/n8n-binary-refused.txt'"
chk "no Python traceback / SyntaxError in any output" "! grep -lE 'Traceback|SyntaxError' '$OUT'/*.txt"
