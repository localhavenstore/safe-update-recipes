#!/usr/bin/env bash
# R2 (Nextcloud) on a fresh throwaway VM: real images nextcloud 34 -> 35 (major upgrade, DB migration) with PostgreSQL
# (default) or MariaDB (DB=mariadb): refuse 34 -> 36, snapshot before 35, restore after it, drill good + damaged dump.
# Logs: lab/work/sur-r2-<db>/. The VM is deleted at the end.
set -uo pipefail
DB=${DB:-postgres}; [[ $DB == postgres || $DB == mariadb ]] || { echo "DB=postgres|mariadb"; exit 64; }
VM=${TESTVM:?set TESTVM to your VM helper - see tests/README.md}; OUT=${OUTDIR:-./results}/sur-r2-$DB; SRC=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$OUT"; rm -f "$OUT"/*.txt
s() { "$VM" ssh "$1" > "$OUT/$2.txt" 2>&1; echo "== $2 exit $?" | tee -a "$OUT/summary.txt"; }
trap '"$VM" down >/dev/null 2>&1' EXIT
"$VM" up || exit 1
tar -C "$SRC" -czf /tmp/sur-src-$$.tgz safe-update recipes && "$VM" put /tmp/sur-src-$$.tgz /home/learner/sur.tgz; rm -f /tmp/sur-src-$$.tgz
D=/srv/nc
SU="sudo /home/learner/sur/safe-update"
if [[ $DB == postgres ]]; then
  DBSVC='  db:
    image: postgres:17
    environment: {POSTGRES_DB: nextcloud, POSTGRES_USER: nextcloud, POSTGRES_PASSWORD: pg-pass-1}
    volumes: ["dbdata:/var/lib/postgresql/data"]
    restart: unless-stopped'
  APPENV='POSTGRES_HOST: db, POSTGRES_DB: nextcloud, POSTGRES_USER: nextcloud, POSTGRES_PASSWORD: pg-pass-1'
else
  DBSVC='  db:
    image: mariadb:11.4
    command: --transaction-isolation=READ-COMMITTED --binlog-format=ROW
    environment: {MARIADB_ROOT_PASSWORD: root-pass-1, MARIADB_DATABASE: nextcloud, MARIADB_USER: nextcloud, MARIADB_PASSWORD: my-pass-1}
    volumes: ["dbdata:/var/lib/mysql"]
    restart: unless-stopped'
  APPENV='MYSQL_HOST: db, MYSQL_DATABASE: nextcloud, MYSQL_USER: nextcloud, MYSQL_PASSWORD: my-pass-1'
fi
cat > /tmp/sur-compose-$$.yaml <<EOF
services:
$DBSVC
  app:
    image: nextcloud:34-apache
    depends_on: [db]
    ports: ["127.0.0.1:8080:80"]
    environment: {$APPENV, NEXTCLOUD_ADMIN_USER: admin, NEXTCLOUD_ADMIN_PASSWORD: admin-pass-1, NEXTCLOUD_TRUSTED_DOMAINS: localhost}
    volumes: ["html:/var/www/html"]
    restart: unless-stopped
volumes:
  dbdata: {}
  html: {}
EOF
"$VM" put /tmp/sur-compose-$$.yaml /home/learner/compose.yaml; rm -f /tmp/sur-compose-$$.yaml
cat > /tmp/sur-h-$$.sh <<'EOF'
occ() { sudo docker compose -f /srv/nc/compose.yaml exec -T -u www-data app php occ "$@"; }
wait_nc() {  # installed, not in maintenance, version starts with $1
  for i in $(seq 1 150); do
    st=$(occ status --output=json 2>/dev/null | tail -1)
    echo "$st" | python3 -c "import json,sys;d=json.load(sys.stdin);sys.exit(0 if d['installed'] and not d['maintenance'] and d['versionstring'].startswith('$1') else 1)" 2>/dev/null && return 0
    sleep 4
  done; echo "not ready: $st"; return 1
}
version() { occ status --output=json | tail -1 | python3 -c 'import json,sys;print(json.load(sys.stdin)["versionstring"])'; }
users() { occ user:list --output=json | tail -1 | python3 -c 'import json,sys;print(" ".join(sorted(json.load(sys.stdin))))'; }
hello() { sudo docker compose -f /srv/nc/compose.yaml exec -T -u www-data app cat data/admin/files/hello.txt; }
set_tag() { sudo sed -i "s#image: nextcloud:.*#image: nextcloud:$1#" /srv/nc/compose.yaml; }
EOF
"$VM" put /tmp/sur-h-$$.sh /home/learner/h.sh; rm -f /tmp/sur-h-$$.sh
P=". /home/learner/h.sh;"
s "sudo apt-get update -qq && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq docker.io docker-compose-v2 python3 >/dev/null && mkdir -p sur && tar -xzf sur.tgz -C sur && sudo docker version --format '{{.Server.Version}}'" prereq
s "sudo mkdir -p $D && sudo cp /home/learner/compose.yaml $D/ && cd $D && sudo docker compose up -d --quiet-pull 2>&1 | tail -2; $P wait_nc 34 && version" start
s "$P sudo docker compose -f $D/compose.yaml exec -T -e OC_PASS=alice-pass-1 -u www-data app php occ user:add --password-from-env alice >/dev/null && sudo docker compose -f $D/compose.yaml exec -T -u www-data app sh -c 'echo hello-34 > data/admin/files/hello.txt' && occ files:scan admin >/dev/null && users && hello" seed
s "$SU plan nextcloud $D --to 36-apache; echo rc=\$?" plan-refused
s "$SU snapshot nextcloud $D --to 36-apache; echo rc=\$?; sudo ls -A $D/.safe-update 2>&1 | head -3" snap-refused
s "$SU plan nextcloud $D --to 35-apache; echo rc=\$?" plan-ok
s "$SU snapshot nextcloud $D --to 35-apache; echo rc=\$?; $P wait_nc 34 && echo ready-after-snapshot; $SU list nextcloud $D; sudo sh -c 'ls -l $D/.safe-update/2*Z/; tar -tf $D/.safe-update/2*Z/html.tar ./version.php'" snapshot
s "$P set_tag 35-apache && cd $D && sudo docker compose up -d --quiet-pull 2>&1 | tail -1; wait_nc 35 && version && sudo docker compose -f $D/compose.yaml exec -T -e OC_PASS=bob-pass-1 -u www-data app php occ user:add --password-from-env bob >/dev/null && users" to-35
s "$SU restore nextcloud $D; echo rc=\$?" restore-dry
s "$P users; version; grep 'image: nextcloud' $D/compose.yaml" before-restore
s "$SU restore nextcloud $D --yes; echo rc=\$?; $P wait_nc 34; version; users; hello; grep 'image: nextcloud' $D/compose.yaml; sudo ls $D/.safe-update" restore
s "$SU drill nextcloud $D; echo rc=\$?" drill-good
s "S=\$(sudo sh -c 'ls -1d $D/.safe-update/2*Z' | head -1); sudo cp -a \$S $D/.safe-update/29990101T000000Z && sudo truncate -s 2000 $D/.safe-update/29990101T000000Z/db.sql && $SU drill nextcloud $D 29990101T000000Z; echo rc=\$?" drill-damaged
s "grep -nE '\\b(curl|wget)\\b' /home/learner/sur/safe-update /home/learner/sur/recipes/*.sh | grep -v 'docker exec' | grep -vE ':[0-9]+: *#' ; echo end" no-download
chk() { if eval "$2"; then echo "PASS $1" | tee -a "$OUT/summary.txt"; else echo "FAIL $1" | tee -a "$OUT/summary.txt"; fi; }
chk "[$DB] seed: admin + alice on 34, file saved" "grep -qx 'admin alice' '$OUT/seed.txt' && grep -qx hello-34 '$OUT/seed.txt' && grep -q '^34' '$OUT/start.txt'"
chk "[$DB] 34 -> 36 refused by plan + snapshot, nothing written" "grep -q REFUSED '$OUT/plan-refused.txt' && grep -q 'rc=1' '$OUT/snap-refused.txt' && ! grep -q '^2' '$OUT/snap-refused.txt'"
chk "[$DB] snapshot on 34 complete (db.sql + html.tar), Nextcloud ready again" "grep -q 'snapshot COMPLETE' '$OUT/snapshot.txt' && grep -q ready-after-snapshot '$OUT/snapshot.txt' && grep -q db.sql '$OUT/snapshot.txt' && grep -q html.tar '$OUT/snapshot.txt' && grep -qx './version.php' '$OUT/snapshot.txt'"
chk "[$DB] 35 migrated + bob added" "grep -q '^35' '$OUT/to-35.txt' && grep -qx 'admin alice bob' '$OUT/to-35.txt'"
chk "[$DB] restore dry-run changes nothing" "grep -q 'DRY RUN' '$OUT/restore-dry.txt' && grep -qx 'admin alice bob' '$OUT/before-restore.txt'"
chk "[$DB] restore: 34 + admin alice (no bob) + file + compose back + replaced kept" "grep -q 'restore OK' '$OUT/restore.txt' && grep -q '^34' '$OUT/restore.txt' && grep -qx 'admin alice' '$OUT/restore.txt' && grep -qx hello-34 '$OUT/restore.txt' && grep -q 'nextcloud:34-apache' '$OUT/restore.txt' && grep -q 'replaced-' '$OUT/restore.txt'"
chk "[$DB] drill good = OK" "grep -q 'drill OK' '$OUT/drill-good.txt'"
chk "[$DB] drill damaged = FAIL" "grep -qE 'DAMAGED|drill FAILED' '$OUT/drill-damaged.txt' && grep -q 'rc=1' '$OUT/drill-damaged.txt'"
chk "[$DB] scripts never download" "grep -qx end '$OUT/no-download.txt' && [ \$(wc -l < '$OUT/no-download.txt') = 1 ]"
