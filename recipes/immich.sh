# Immich recipe for safe-update (sourced). Official compose: immich-server, immich-machine-learning, redis/valkey and
# Immich's postgres image. Saves: a full database dump (pg_dumpall --clean --if-exists, as in Immich's backup docs) with
# immich-server and machine-learning STOPPED, plus an INVENTORY of the library (path, size, mtime) - photos and videos
# are NOT copied (too big; updates do not rewrite them). Restore = database back (Immich's documented search_path fix),
# then the library is compared with the inventory: files added after the snapshot are kept and reported.
# Upgrade rule: no downgrades; one major version at a time; read Immich's release notes for breaking changes.
# Tested versions: see TESTED in the README.
IM_SVC="" IM_ML="" IM_DB="" IM_REDIS="" IM_DATA=""

_im_svcs() { local s img; for s in $(DC config --services); do img=$(svc_image "$s"); echo "$s ${img%%@*}"; done; }
recipe_detect() {
  local s img
  while read -r s img; do
    case $img in
      *immich-server*) IM_SVC=$s ;;
      *immich-machine-learning*) IM_ML=$s ;;
      *immich-app/postgres*|postgres:*|*/postgres:*) IM_DB=$s ;;
      *redis*|*valkey*) IM_REDIS=$s ;;
    esac
  done < <(_im_svcs)
  [[ -n $IM_SVC ]] || die "no immich-server service in $COMPOSE_FILE"
  [[ -n $IM_DB ]] || die "no postgres service in $COMPOSE_FILE"
  IM_DATA=$(svc_mount "$IM_SVC" /data); [[ -n $IM_DATA ]] || IM_DATA=$(svc_mount "$IM_SVC" /usr/src/app/upload)
  [[ -n $IM_DATA ]] || die "immich-server has no /data (or /usr/src/app/upload) mount"
  [[ $IM_DATA == volume:* ]] && { docker volume inspect "${IM_DATA#volume:}" >/dev/null 2>&1 || die "volume ${IM_DATA#volume:} does not exist - nothing changed"; }
  RECIPE_SERVICES=("$IM_SVC" "$IM_DB"); [[ -n $IM_ML ]] && RECIPE_SERVICES+=("$IM_ML"); [[ -n $IM_REDIS ]] && RECIPE_SERVICES+=("$IM_REDIS")
}

_v() { echo "${1#v}" | grep -oE '^[0-9]+\.[0-9]+(\.[0-9]+)?' || true; }
recipe_guard() {
  local now to tag; tag=$(tag_of "$(svc_image "$IM_SVC")"); now=$(_v "$tag"); to=$(_v "${1:-}")
  say "immich: running tag $tag${1:+, target $1}"
  [[ -z $to ]] && { say "  note: give --to TAG to check the path; always read Immich's release notes (breaking changes) first"; return 0; }
  [[ -z $now ]] && { say "  note: tag '$tag' has no version number (release?) - pin IMMICH_VERSION to a version; path not checked"; return 0; }
  local a b; a=${now%%.*}; b=${to%%.*}
  if [[ $(printf '%s\n%s\n' "$now" "$to" | sort -V | head -1) == "$to" && $now != "$to" ]]; then
    say "  REFUSED: $now -> $to is a downgrade - Immich's database migrations cannot go back. Use 'restore' with a snapshot."; return 1
  fi
  (( b > a + 1 )) && { say "  REFUSED: $now -> $to skips a major version. Go to the latest $((a + 1)).x first."; return 1; }
  (( b == a + 1 )) && say "  note: major update - read the breaking changes in Immich's release notes before you start"
  say "  upgrade path OK"
}

_db() { docker exec -i "$(svc_container "$IM_DB")" sh -c "$1"; }
_db_wait() { local i; for i in $(seq 1 60); do _db 'pg_isready -q -U "$POSTGRES_USER"' </dev/null && return 0; sleep 2; done; return 1; }
_srcd() { [[ $IM_DATA == volume:* ]] && echo "${IM_DATA#volume:}" || echo "$IM_DATA"; }
_simg() { svc_digest "$IM_SVC"; }
_inventory() {  # $1 = image -> 'path<TAB>size<TAB>mtime' of every library file, sorted
  docker run --rm --network none --entrypoint find -v "$(_srcd)":/d:ro "$1" /d -type f -printf '%P\t%s\t%T@\n' </dev/null | sort
}
recipe_size() { _db 'du -sb /var/lib/postgresql/data | cut -f1' </dev/null; }

recipe_snapshot() {
  local S=$1 stop=("$IM_SVC") running=() s
  [[ -n $IM_ML ]] && stop+=("$IM_ML")
  for s in "${stop[@]}"; do [[ -n $(svc_container "$s") ]] && running+=("$s"); done
  [[ -n $(svc_container "$IM_DB") ]] || die "the database service $IM_DB is not running - start the stack first"
  log "immich: stopping ${stop[*]} so the database does not change during the dump"
  DC stop "${stop[@]}" >/dev/null
  restart() { [[ ${#running[@]} -gt 0 ]] && DC start "${running[@]}" >/dev/null; }
  _db 'pg_dumpall --clean --if-exists -U "$POSTGRES_USER"' </dev/null > "$S/db.sql" && [[ -s $S/db.sql ]] || { restart; die "database dump failed - Immich started again"; }
  _inventory "$(_simg)" > "$S/library-inventory.tsv" || { restart; die "library inventory failed - Immich started again"; }
  restart
  log "immich: database ($(human "$(stat -c %s "$S/db.sql")")) + library inventory ($(wc -l < "$S/library-inventory.tsv") files, not copied) saved"
}

# Immich docs (backup-and-restore): a dump restored with an empty search_path breaks the vector extensions
_SP_FIX="s/SELECT pg_catalog.set_config('search_path', '', false);/SELECT pg_catalog.set_config('search_path', 'public, pg_catalog', true);/g"
# pg_dumpall --clean always gives 2 harmless errors on load (the superuser that runs it cannot be dropped / already exists);
# ANY other error = the restore failed (never reported as restored)
_load() { sed "$_SP_FIX" "$1" | _db 'psql -q -U "$POSTGRES_USER" -d postgres >/dev/null 2>/tmp/safe-update-load.err; rc=$?
  bad=$(grep "ERROR:" /tmp/safe-update-load.err | grep -v -e "current user cannot be dropped" -e "role \"$POSTGRES_USER\" already exists")
  if [ "$rc" -ne 0 ] || [ -n "$bad" ]; then echo "database load FAILED (psql rc=$rc):" >&2; printf "%s\n" "$bad" | head -5 >&2; exit 1; fi'; }

recipe_restore_data() {
  local S=$1 R=$2 img now new
  img=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["images"][sys.argv[2]]["id"])' "$S/manifest.json" "$IM_SVC")
  local up=("$IM_DB"); [[ -n $IM_REDIS ]] && up+=("$IM_REDIS")
  DC up -d --pull never "${up[@]}" >/dev/null; _db_wait || die "the database did not start - nothing restored yet"
  _db 'pg_dumpall --clean --if-exists -U "$POSTGRES_USER"' </dev/null > "$R/db-replaced.sql" && [[ -s $R/db-replaced.sql ]] || die "could not save the current database first - nothing restored"
  _load "$S/db.sql" || die "loading the saved database failed - the database before this step is in $R/db-replaced.sql"
  log "immich: database restored (the replaced one is in $R/db-replaced.sql)"
  _inventory "$img" > "$R/library-now.tsv"
  new=$(comm -13 <(cut -f1 "$S/library-inventory.tsv" | sort) <(cut -f1 "$R/library-now.tsv" | sort) | wc -l)
  now=$(comm -23 <(cut -f1 "$S/library-inventory.tsv" | sort) <(cut -f1 "$R/library-now.tsv" | sort) | wc -l)
  log "immich: library vs snapshot: $new file(s) added after the snapshot (kept on disk, not in the restored database), $now file(s) from the snapshot MISSING"
  (( now == 0 )) || say "WARNING: $now library file(s) that the snapshot knew are gone - see $R/library-now.tsv vs $S/library-inventory.tsv"
}

_im_api() {  # $1 = container, $2 = path -> body (asks the server via node, which is in its image)
  docker exec "$1" node -e "fetch('http://127.0.0.1:2283$2').then(r=>r.ok?r.text():Promise.reject(r.status)).then(t=>console.log(t)).catch(e=>{console.error(e);process.exit(1)})" 2>/dev/null
}
recipe_check() {
  local c i out
  c=$(svc_container "$IM_SVC"); [[ -n $c ]] || { say "immich-server is not running"; return 1; }
  for i in $(seq 1 90); do out=$(_im_api "$c" /api/server/ping || true); [[ $out == *pong* ]] && break; sleep 2; done
  [[ $out == *pong* ]] || { say "immich /api/server/ping did not answer within 180 s"; return 1; }
  say "immich up, version $(_im_api "$c" /api/server/version | python3 -c 'import json,sys;d=json.load(sys.stdin);print("%s.%s.%s" % (d["major"], d["minor"], d["patch"]))')"
}

recipe_drill() {  # throwaway: own internal network, recorded DB/redis/server images, empty library with Immich's folder
  local S=$1 t=safe-update-drill-$$ dimg simg rimg envd envs ok=1 i out   # markers (.immich files) from the inventory
  read -r dimg simg rimg < <(python3 -c 'import json,sys;m=json.load(open(sys.argv[1]))["images"];print(m[sys.argv[2]]["id"],m[sys.argv[3]]["id"],m.get(sys.argv[4],{}).get("id","-"))' "$S/manifest.json" "$IM_DB" "$IM_SVC" "${IM_REDIS:-none}")
  [[ $rimg != - ]] || { say "drill: no redis/valkey service recorded"; return 1; }
  envd=$(mktemp); envs=$(mktemp); chmod 600 "$envd" "$envs"
  DC config --format json | python3 -c '
import json,sys
c=json.load(sys.stdin)["services"]
for s,f in ((sys.argv[1],sys.argv[3]),(sys.argv[2],sys.argv[4])):
    e=c[s].get("environment") or {}
    open(f,"w").write("".join(f"{k}={v}\n" for k,v in e.items() if v is not None))' "$IM_DB" "$IM_SVC" "$envd" "$envs"
  docker network create --internal "$t-net" >/dev/null; docker volume create "$t-db" >/dev/null; docker volume create "$t-data" >/dev/null
  grep -E '(^|/)\.immich	' "$S/library-inventory.tsv" | cut -f1 | docker run --rm -i --network none --entrypoint sh -v "$t-data":/d "$simg" \
    -c 'while read -r p; do mkdir -p "/d/$(dirname "$p")" && touch "/d/$p"; done' || ok=0
  docker run -d --name "$t-db" --network "$t-net" --network-alias "$IM_DB" --env-file "$envd" -v "$t-db":/var/lib/postgresql/data "$dimg" >/dev/null
  docker run -d --name "$t-redis" --network "$t-net" --network-alias "$IM_REDIS" "$rimg" >/dev/null
  svc_container() { case $1 in "$IM_DB") echo "$t-db" ;; *) svc_cids "$1" running | head -1 ;; esac; }
  _db_wait && _load "$S/db.sql" 2>/dev/null || ok=0
  if (( ok )); then
    docker run -d --name "$t-server" --network "$t-net" --env-file "$envs" -e IMMICH_MACHINE_LEARNING_ENABLED=false -v "$t-data":/data "$simg" >/dev/null
    for i in $(seq 1 90); do out=$(_im_api "$t-server" /api/server/ping || true); [[ $out == *pong* ]] && break; sleep 2; done
    [[ $out == *pong* ]] || ok=0
  fi
  svc_container() { svc_cids "$1" running | head -1; }
  docker rm -f "$t-server" "$t-redis" "$t-db" >/dev/null 2>&1; docker volume rm "$t-db" "$t-data" >/dev/null 2>&1; docker network rm "$t-net" >/dev/null 2>&1
  rm -f "$envd" "$envs"
  (( ok ))
}
