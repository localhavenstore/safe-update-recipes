#!/usr/bin/env bash
# R1 (Jellyfin) on a fresh throwaway VM: real images 10.11.10 -> 10.11.11 -> 12.1 (DB migration), snapshot before the
# major update, restore after it, drill good + damaged snapshot. Logs: lab/work/sur-r1/. The VM is deleted at the end.
set -uo pipefail
VM=${TESTVM:?set TESTVM to your VM helper - see tests/README.md}; OUT=${OUTDIR:-./results}/sur-r1; SRC=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$OUT"; rm -f "$OUT"/*.txt
s() { "$VM" ssh "$1" > "$OUT/$2.txt" 2>&1; echo "== $2 exit $?" | tee -a "$OUT/summary.txt"; }
trap '"$VM" down >/dev/null 2>&1' EXIT
"$VM" up || exit 1
tar -C "$SRC" -czf /tmp/sur-src-$$.tgz safe-update recipes && "$VM" put /tmp/sur-src-$$.tgz /home/learner/sur.tgz; rm -f /tmp/sur-src-$$.tgz
D=/srv/jf
SU="sudo /home/learner/sur/safe-update"
# helpers inside the VM: wait for health, create the first user via the wizard, list users (admin token)
cat > /tmp/sur-h-$$.sh <<'EOF'
wait_jf() { for i in $(seq 1 90); do [ "$(curl -fsS --max-time 3 http://127.0.0.1:8096/health 2>/dev/null)" = Healthy ] && return 0; sleep 2; done; return 1; }
H='Authorization: MediaBrowser Client="t", Device="t", DeviceId="t1", Version="1"'
token() { curl -fsS -H "$H" -H 'Content-Type: application/json' -d '{"Username":"alice","Pw":"alice-pass-1"}' http://127.0.0.1:8096/Users/AuthenticateByName | python3 -c 'import json,sys;print(json.load(sys.stdin)["AccessToken"])'; }
users() { T=$(token); curl -fsS -H "$H, Token=\"$T\"" http://127.0.0.1:8096/Users | python3 -c 'import json,sys;print(" ".join(sorted(u["Name"] for u in json.load(sys.stdin))))'; }
version() { curl -fsS http://127.0.0.1:8096/System/Info/Public | python3 -c 'import json,sys;print(json.load(sys.stdin)["Version"])'; }
set_tag() { sudo sed -i "s#image: jellyfin/jellyfin:.*#image: jellyfin/jellyfin:$1#" /srv/jf/compose.yaml; }
EOF
"$VM" put /tmp/sur-h-$$.sh /home/learner/h.sh; rm -f /tmp/sur-h-$$.sh
P=". /home/learner/h.sh;"
s "sudo apt-get update -qq && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq docker.io docker-compose-v2 python3 >/dev/null && mkdir -p sur && tar -xzf sur.tgz -C sur && sudo docker version --format '{{.Server.Version}}'" prereq
s "sudo mkdir -p $D/config && printf 'services:\n  jellyfin:\n    image: jellyfin/jellyfin:10.11.10\n    ports: [\"127.0.0.1:8096:8096\"]\n    volumes: [\"./config:/config\", \"jfcache:/cache\"]\n    restart: unless-stopped\nvolumes:\n  jfcache: {}\n' | sudo tee $D/compose.yaml >/dev/null && cd $D && sudo docker compose up -d --quiet-pull 2>&1 | tail -2; $P wait_jf && echo healthy" start
s "$P curl -fsS -H 'Content-Type: application/json' -d '{\"UICulture\":\"en-US\",\"MetadataCountryCode\":\"US\",\"PreferredMetadataLanguage\":\"en\"}' http://127.0.0.1:8096/Startup/Configuration && curl -fsS http://127.0.0.1:8096/Startup/User >/dev/null && curl -fsS -H 'Content-Type: application/json' -d '{\"Name\":\"alice\",\"Password\":\"alice-pass-1\"}' http://127.0.0.1:8096/Startup/User && curl -fsS -X POST http://127.0.0.1:8096/Startup/Complete && echo wizard-done; users; version" seed
s "$SU plan jellyfin $D --to 12.1; echo rc=\$?" plan-refused
s "$SU snapshot jellyfin $D --to 12.1; echo rc=\$?; ls -A $D/.safe-update 2>&1 | head -3" snap-refused
s "$P set_tag 10.11.11 && cd $D && sudo docker compose up -d --quiet-pull 2>&1 | tail -1; wait_jf && version && users" to-10.11.11
s "$SU plan jellyfin $D --to 12.1; echo rc=\$?" plan-ok
s "$SU snapshot jellyfin $D --to 12.1; echo rc=\$?; $P wait_jf && echo healthy-after-snapshot; $SU list jellyfin $D" snapshot
s "$P set_tag 12.1 && cd $D && sudo docker compose up -d --quiet-pull 2>&1 | tail -1; wait_jf && version && T=\$(token) && curl -fsS -H \"\$H, Token=\\\"\$T\\\"\" -H 'Content-Type: application/json' -d '{\"Name\":\"bob\",\"Password\":\"bob-pass-1\"}' http://127.0.0.1:8096/Users/New >/dev/null && users" to-12.1
s "$SU restore jellyfin $D; echo rc=\$?" restore-dry
s "$P users; version; grep image: $D/compose.yaml" before-restore
s "$SU restore jellyfin $D --yes; echo rc=\$?; $P wait_jf; version; users; grep image: $D/compose.yaml; sudo ls $D/.safe-update" restore
s "$SU drill jellyfin $D; echo rc=\$?" drill-good
s "S=\$(sudo sh -c 'ls -1d $D/.safe-update/2*Z' | head -1); sudo cp -a \$S $D/.safe-update/29990101T000000Z && sudo truncate -s 100000 $D/.safe-update/29990101T000000Z/config.tar && $SU drill jellyfin $D 29990101T000000Z; echo rc=\$?" drill-damaged
s "grep -nE '\\b(curl|wget)\\b' /home/learner/sur/safe-update /home/learner/sur/recipes/*.sh | grep -v 'docker exec' | grep -vE ':[0-9]+: *#' ; echo end" no-download
chk() { if eval "$2"; then echo "PASS $1" | tee -a "$OUT/summary.txt"; else echo "FAIL $1" | tee -a "$OUT/summary.txt"; fi; }
chk "seed: alice on 10.11.10" "grep -qx alice '$OUT/seed.txt' && grep -q '^10.11.10' '$OUT/seed.txt'"
chk "10.11.10 -> 12.1 refused by plan + snapshot, nothing written" "grep -q REFUSED '$OUT/plan-refused.txt' && grep -q 'rc=1' '$OUT/snap-refused.txt' && ! grep -q '^2' '$OUT/snap-refused.txt'"
chk "snapshot on 10.11.11 complete, service healthy again" "grep -q 'snapshot COMPLETE' '$OUT/snapshot.txt' && grep -q healthy-after-snapshot '$OUT/snapshot.txt'"
chk "12.1 migrated + bob added" "grep -q '^12.1' '$OUT/to-12.1.txt' && grep -qx 'alice bob' '$OUT/to-12.1.txt'"
chk "restore dry-run changes nothing" "grep -q 'DRY RUN' '$OUT/restore-dry.txt' && grep -qx 'alice bob' '$OUT/before-restore.txt'"
chk "restore: 10.11.11 + alice only + compose back + replaced kept" "grep -q 'restore OK' '$OUT/restore.txt' && grep -q '^10.11.11' '$OUT/restore.txt' && grep -qx alice '$OUT/restore.txt' && grep -q 'jellyfin:10.11.11' '$OUT/restore.txt' && grep -q 'replaced-' '$OUT/restore.txt'"
chk "drill good = OK" "grep -q 'drill OK' '$OUT/drill-good.txt'"
chk "drill damaged = FAIL" "grep -qE 'DAMAGED|drill FAILED' '$OUT/drill-damaged.txt' && grep -q 'rc=1' '$OUT/drill-damaged.txt'"
chk "scripts never download" "grep -qx end '$OUT/no-download.txt' && [ \$(wc -l < '$OUT/no-download.txt') = 1 ]"
