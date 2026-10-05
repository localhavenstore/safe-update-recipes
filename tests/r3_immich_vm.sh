#!/usr/bin/env bash
# R3 (Immich) on a fresh throwaway VM: real images v3.1.0 -> v3.2.4 (DB migrations), machine learning off (8 GB VM).
# Seed admin + 1 photo, refuse a downgrade, snapshot, update, add photo 2, restore -> 1 asset again, photo 2's file kept and
# reported, drill good + damaged dump. Logs: lab/work/sur-r3/. The VM is deleted at the end.
set -uo pipefail
VM=${TESTVM:?set TESTVM to your VM helper - see tests/README.md}; OUT=${OUTDIR:-./results}/sur-r3; SRC=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$OUT"; rm -f "$OUT"/*.txt
s() { "$VM" ssh "$1" > "$OUT/$2.txt" 2>&1; echo "== $2 exit $?" | tee -a "$OUT/summary.txt"; }
trap '"$VM" down >/dev/null 2>&1' EXIT
"$VM" up || exit 1
tar -C "$SRC" -czf /tmp/sur-src-$$.tgz safe-update recipes && "$VM" put /tmp/sur-src-$$.tgz /home/learner/sur.tgz; rm -f /tmp/sur-src-$$.tgz
D=/srv/im
SU="sudo /home/learner/sur/safe-update"
PG='ghcr.io/immich-app/postgres:14-vectorchord0.4.3-pgvectors0.2.0@sha256:bcf63357191b76a916ae5eb93464d65c07511da41e3bf7a8416db519b40b1c23'
VK='docker.io/valkey/valkey:9@sha256:70739f85ad2ee01a726a965584a0f94895f01b0c60b3cc8b0aeef11eaa6888cf'
cat > /tmp/sur-compose-$$.yaml <<EOF
services:
  immich-server:
    image: ghcr.io/immich-app/immich-server:v3.1.0
    volumes: ["./library:/data"]
    environment: {DB_HOSTNAME: database, DB_USERNAME: postgres, DB_PASSWORD: pg-pass-1, DB_DATABASE_NAME: immich, REDIS_HOSTNAME: redis, IMMICH_MACHINE_LEARNING_ENABLED: "false"}
    ports: ["127.0.0.1:2283:2283"]
    depends_on: [redis, database]
    restart: unless-stopped
  redis:
    image: $VK
    restart: unless-stopped
  database:
    image: $PG
    environment: {POSTGRES_PASSWORD: pg-pass-1, POSTGRES_USER: postgres, POSTGRES_DB: immich, POSTGRES_INITDB_ARGS: --data-checksums}
    volumes: ["pgdata:/var/lib/postgresql/data"]
    shm_size: 128mb
    restart: unless-stopped
volumes:
  pgdata: {}
EOF
"$VM" put /tmp/sur-compose-$$.yaml /home/learner/compose.yaml; rm -f /tmp/sur-compose-$$.yaml
cat > /tmp/sur-h-$$.sh <<'EOF'
U=http://127.0.0.1:2283/api
wait_im() { for i in $(seq 1 120); do v=$(curl -fsS $U/server/version 2>/dev/null) && echo "$v" | grep -q "\"minor\":$1" && return 0; sleep 3; done; echo "not ready: $v"; return 1; }
version() { curl -fsS $U/server/version | python3 -c 'import json,sys;d=json.load(sys.stdin);print("%s.%s.%s" % (d["major"], d["minor"], d["patch"]))'; }
tok() { curl -fsS -H 'Content-Type: application/json' -d '{"email":"admin@example.com","password":"admin-pass-1"}' $U/auth/login | python3 -c 'import json,sys;print(json.load(sys.stdin)["accessToken"])'; }
png() { python3 - "$1" "$2" <<'PY'
import struct, sys, zlib
w = h = 64; seed = int(sys.argv[2])
raw = b"".join(b"\x00" + b"".join(bytes(((x * 4 + seed * 50) % 256, (y * 4) % 256, (seed * 90) % 256)) for x in range(w)) for y in range(h))
c = lambda t, d: struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d))
open(sys.argv[1], "wb").write(b"\x89PNG\r\n\x1a\n" + c(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)) + c(b"IDAT", zlib.compress(raw)) + c(b"IEND", b""))
PY
}
upload() { png /tmp/p$1.png $1; T=$(tok); curl -fsS -H "Authorization: Bearer $T" -F assetData=@/tmp/p$1.png -F deviceAssetId=p$1 -F deviceId=test \
  -F fileCreatedAt=2026-10-0$1T10:00:00.000Z -F fileModifiedAt=2026-10-0$1T10:00:00.000Z $U/assets | python3 -c 'import json,sys;print("upload",json.load(sys.stdin).get("status"))'; }
assets() { T=$(tok); curl -fsS -H "Authorization: Bearer $T" $U/assets/statistics | python3 -c 'import json,sys;print("assets", json.load(sys.stdin)["total"])'; }
set_tag() { sudo sed -i "s#immich-server:v[0-9.]*#immich-server:$1#" /srv/im/compose.yaml; }
EOF
"$VM" put /tmp/sur-h-$$.sh /home/learner/h.sh; rm -f /tmp/sur-h-$$.sh
P=". /home/learner/h.sh;"
s "sudo apt-get update -qq && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq docker.io docker-compose-v2 python3 curl >/dev/null && mkdir -p sur && tar -xzf sur.tgz -C sur && sudo docker version --format '{{.Server.Version}}'" prereq
s "sudo mkdir -p $D/library && sudo cp /home/learner/compose.yaml $D/ && cd $D && sudo docker compose up -d --quiet-pull 2>&1 | tail -2; $P wait_im 1 && version" start
s "$P curl -fsS -H 'Content-Type: application/json' -d '{\"email\":\"admin@example.com\",\"password\":\"admin-pass-1\",\"name\":\"Admin\"}' \$U/auth/admin-sign-up >/dev/null && upload 1 && sleep 3 && assets" seed
s "$SU plan immich $D --to v3.0.3; echo rc=\$?" plan-refused
s "$SU snapshot immich $D --to v3.0.3; echo rc=\$?; sudo ls -A $D/.safe-update 2>&1 | head -3" snap-refused
s "$SU snapshot immich $D --to v3.2.4; echo rc=\$?; $P wait_im 1 && echo ready-after-snapshot; sudo sh -c 'ls -l $D/.safe-update/2*Z/; grep -c . $D/.safe-update/2*Z/library-inventory.tsv'" snapshot
s "$P set_tag v3.2.4 && cd $D && sudo docker compose up -d --quiet-pull 2>&1 | tail -1; wait_im 2 && version && upload 2 && sleep 3 && assets" to-3.2.4
s "$SU restore immich $D; echo rc=\$?" restore-dry
s "$SU restore immich $D --yes; echo rc=\$?; $P wait_im 1; version; assets; grep immich-server: $D/compose.yaml" restore
s "$SU drill immich $D; echo rc=\$?" drill-good
s "S=\$(sudo sh -c 'ls -1d $D/.safe-update/2*Z' | head -1); sudo cp -a \$S $D/.safe-update/29990101T000000Z && sudo truncate -s 5000 $D/.safe-update/29990101T000000Z/db.sql && $SU drill immich $D 29990101T000000Z; echo rc=\$?" drill-damaged
s "grep -nE '\\b(curl|wget)\\b' /home/learner/sur/safe-update /home/learner/sur/recipes/*.sh | grep -v 'docker exec' | grep -vE ':[0-9]+: *#' ; echo end" no-download
chk() { if eval "$2"; then echo "PASS $1" | tee -a "$OUT/summary.txt"; else echo "FAIL $1" | tee -a "$OUT/summary.txt"; fi; }
chk "seed: admin + 1 photo on 3.1" "grep -q '^3.1' '$OUT/start.txt' && grep -q 'assets 1' '$OUT/seed.txt'"
chk "downgrade 3.1 -> 3.0.3 refused by plan + snapshot, nothing written" "grep -q REFUSED '$OUT/plan-refused.txt' && grep -q 'rc=1' '$OUT/snap-refused.txt' && ! grep -q '^2' '$OUT/snap-refused.txt'"
chk "snapshot on 3.1 complete (db.sql + inventory), Immich ready again" "grep -q 'snapshot COMPLETE' '$OUT/snapshot.txt' && grep -q ready-after-snapshot '$OUT/snapshot.txt' && grep -q library-inventory.tsv '$OUT/snapshot.txt'"
chk "3.2.4 migrated + photo 2 added" "grep -q '^3.2.4' '$OUT/to-3.2.4.txt' && grep -q 'assets 2' '$OUT/to-3.2.4.txt'"
chk "restore dry-run" "grep -q 'DRY RUN' '$OUT/restore-dry.txt'"
chk "restore: 3.1 + 1 asset + compose back + photo 2 file reported (kept), none missing" "grep -q 'restore OK' '$OUT/restore.txt' && grep -q '^3.1' '$OUT/restore.txt' && grep -q 'assets 1' '$OUT/restore.txt' && grep -q 'immich-server:v3.1.0' '$OUT/restore.txt' && grep -qE '[1-9][0-9]* file\\(s\\) added after the snapshot' '$OUT/restore.txt' && grep -q ', 0 file(s) from the snapshot MISSING' '$OUT/restore.txt'"
chk "drill good = OK" "grep -q 'drill OK' '$OUT/drill-good.txt'"
chk "drill damaged = FAIL" "grep -qE 'DAMAGED|drill FAILED' '$OUT/drill-damaged.txt' && grep -q 'rc=1' '$OUT/drill-damaged.txt'"
chk "scripts never download" "grep -qx end '$OUT/no-download.txt' && [ \$(wc -l < '$OUT/no-download.txt') = 1 ]"
