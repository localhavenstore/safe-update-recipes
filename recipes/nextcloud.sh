# Nextcloud recipe for safe-update (sourced). Official image `nextcloud` (apache or fpm) + a PostgreSQL or MariaDB/MySQL
# service in the same compose file. Saves: a database dump (made inside the DB container with its own tools) and the
# /var/www/html volume (config, apps, themes and - in the default layout - data/), with every Nextcloud container STOPPED
# so files and database match. A separate /var/www/html/data mount is saved too. External storage is not saved.
# Vendor rule (docs 'Upgrade manual'): one major version at a time (34 -> 35, never 33 -> 35), no downgrades.
# Tested versions: see TESTED in the README.
NC_SVC="" NC_HTML="" NC_DATA="" DB_SVC="" DB_KIND="" NC_SVCS=()

_svc_json() { DC config --format json; }
_env_of() {  # $1 = service -> KEY=VALUE lines (compose 'environment' after interpolation)
  _svc_json | python3 -c "
import json,sys
e=json.load(sys.stdin)['services']['$1'].get('environment') or {}
e=e if isinstance(e,dict) else dict(x.split('=',1) for x in e if '=' in x)
[print(f'{k}={v}') for k,v in e.items() if v is not None]"
}

recipe_detect() {
  local s img
  for s in $(DC config --services); do
    img=$(svc_image "$s")
    case ${img##*/} in
      nextcloud:*|nextcloud) NC_SVCS+=("$s"); [[ -z $NC_SVC && -n $(svc_mount "$s" /var/www/html) ]] && NC_SVC=$s ;;
      postgres:*|postgres) DB_SVC=$s DB_KIND=postgres ;;
      mariadb:*|mariadb|mysql:*|mysql) DB_SVC=$s DB_KIND=mysql ;;
    esac
  done
  [[ -n $NC_SVC ]] || die "no service with a nextcloud image and a /var/www/html mount in $COMPOSE_FILE"
  [[ -n $DB_SVC ]] || die "no postgres/mariadb/mysql service in $COMPOSE_FILE (SQLite installs: not supported - use a real database)"
  NC_HTML=$(svc_mount "$NC_SVC" /var/www/html); NC_DATA=$(svc_mount "$NC_SVC" /var/www/html/data)
  local m; for m in "$NC_HTML" "$NC_DATA"; do
    [[ $m == volume:* ]] && { docker volume inspect "${m#volume:}" >/dev/null 2>&1 || die "volume ${m#volume:} does not exist (has the stack been started?) - nothing changed"; }
  done
  RECIPE_SERVICES=("${NC_SVCS[@]}" "$DB_SVC")
}

_major() { echo "$1" | grep -oE '^[0-9]+' || true; }

recipe_guard() {  # $1 = target tag ('' = not given)
  local now to; now=$(_major "$(tag_of "$(svc_image "$NC_SVC")")"); to=$(_major "${1:-}")
  say "nextcloud: running tag $(tag_of "$(svc_image "$NC_SVC")")${1:+, target $1}; database: $DB_KIND ($(svc_image "$DB_SVC"))"
  if [[ -z $to ]]; then
    say "  note: give --to TAG to check the upgrade path (one major version at a time; no downgrades)"; return 0
  fi
  if [[ -z $now ]]; then
    say "  note: tag '$(tag_of "$(svc_image "$NC_SVC")")' has no version number - the path cannot be checked; pin a version tag"; return 0
  fi
  if (( to > now + 1 )); then
    say "  REFUSED: $now -> $to skips a major version. Update to $((now + 1)) first, start it once (it migrates), then $to."; return 1
  fi
  if (( to < now )); then
    say "  REFUSED: $now -> $to is a downgrade - Nextcloud does not support it. Use 'restore' with a snapshot instead."; return 1
  fi
  say "  upgrade path OK"
}

_src() { [[ $1 == volume:* ]] && echo "${1#volume:}" || echo "$1"; }
_img() { svc_digest "$NC_SVC"; }
recipe_size() {
  local n
  n=$(docker run --rm --network none --entrypoint du -v "$(_src "$NC_HTML")":/h:ro "$(_img)" -sb /h </dev/null | awk '{print $1}')
  [[ -n $NC_DATA ]] && n=$(( n + $(docker run --rm --network none --entrypoint du -v "$(_src "$NC_DATA")":/d:ro "$(_img)" -sb /d </dev/null | awk '{print $1}') ))
  echo "$n"
}

_db_exec() {  # run a shell snippet in the running DB container (its own env: POSTGRES_* / MARIADB_* / MYSQL_*)
  docker exec -i "$(svc_container "$DB_SVC")" sh -c "$1"
}
_db_wait() {
  local i probe
  [[ $DB_KIND == postgres ]] && probe='pg_isready -q -U "$POSTGRES_USER"' \
                             || probe='A=$(command -v mariadb-admin || command -v mysqladmin); MYSQL_PWD=${MARIADB_ROOT_PASSWORD:-$MYSQL_ROOT_PASSWORD} $A -uroot ping >/dev/null 2>&1'
  for i in $(seq 1 60); do _db_exec "$probe" </dev/null && return 0; sleep 2; done
  return 1
}
_DUMP_PG='pg_dump -U "$POSTGRES_USER" -d "${POSTGRES_DB:-$POSTGRES_USER}"'
_OWNER_PG='psql -tA -U "$POSTGRES_USER" -d postgres -c "SELECT pg_get_userbyid(datdba) FROM pg_database WHERE datname='"'"'${POSTGRES_DB:-$POSTGRES_USER}'"'"'"'
_ROLES_PG='pg_dumpall -U "$POSTGRES_USER" --roles-only'
_MY='C=$(command -v mariadb || command -v mysql); D=${MARIADB_DATABASE:-$MYSQL_DATABASE}; export MYSQL_PWD=${MARIADB_ROOT_PASSWORD:-$MYSQL_ROOT_PASSWORD};'
_DUMP_MY=$_MY' B=$(command -v mariadb-dump || command -v mysqldump); $B -uroot --single-transaction --routines --databases "$D"'
# the accounts that have rights on the Nextcloud database (the installer makes its own, e.g. oc_admin) - with their grants
_USERS_MY=$_MY' for u in $($C -uroot -N -e "SELECT DISTINCT CONCAT(QUOTE(User),'"'"'@'"'"',QUOTE(Host)) FROM mysql.db WHERE Db='"'"'$D'"'"'"); do
  $C -uroot -N -e "SHOW CREATE USER $u" | sed "s/^CREATE USER/CREATE USER IF NOT EXISTS/;s/\$/;/"; $C -uroot -N -e "SHOW GRANTS FOR $u" | sed "s/\$/;/"; done'
_dump_to() {  # $1 = output base: $1 (dump) + $1.owner / $1.accounts (postgres: database owner + roles; mysql: accounts + grants)
  if [[ $DB_KIND == postgres ]]; then
    _db_exec "$_DUMP_PG" </dev/null > "$1" && _db_exec "$_OWNER_PG" </dev/null > "$1.owner" && _db_exec "$_ROLES_PG" </dev/null > "$1.accounts"
  else
    _db_exec "$_DUMP_MY" </dev/null > "$1" && _db_exec "$_USERS_MY" </dev/null > "$1.accounts"
  fi
}
_load_from() {  # $1 = dump base. accounts first (existing ones are kept), database dropped + created empty, dump loaded
  if [[ $DB_KIND == postgres ]]; then
    local owner; owner=$(tr -d '[:space:]' < "$1.owner"); [[ $owner =~ ^[A-Za-z0-9_]+$ ]] || return 1
    _db_exec 'psql -q -U "$POSTGRES_USER" -d postgres >/dev/null 2>&1' < "$1.accounts"
    _db_exec 'D=${POSTGRES_DB:-$POSTGRES_USER}; psql -q -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d postgres -c "DROP DATABASE IF EXISTS \"$D\" WITH (FORCE)" -c "CREATE DATABASE \"$D\" OWNER \"'"$owner"'\"" >/dev/null && psql -q -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$D" >/dev/null' < "$1"
  else
    _db_exec "$_MY"' $C -uroot -f >/dev/null 2>&1' < "$1.accounts"
    _db_exec "$_MY"' $C -uroot -e "DROP DATABASE IF EXISTS \`$D\`" && $C -uroot' < "$1"
  fi
}
_tar_out() {  # $1 = mount spec, $2 = out dir, $3 = file name
  docker run --rm --network none --entrypoint tar -v "$(_src "$1")":/src:ro -v "$2":/out "$(_img)" -C /src --numeric-owner -cf "/out/$3" . </dev/null
}

recipe_snapshot() {  # $1 = snapshot dir
  local S=$1 running=() s
  for s in "${NC_SVCS[@]}"; do [[ -n $(svc_container "$s") ]] && running+=("$s"); done
  [[ -n $(svc_container "$DB_SVC") ]] || die "the database service $DB_SVC is not running - start the stack first"
  log "nextcloud: stopping ${NC_SVCS[*]} so files and database match"
  DC stop "${NC_SVCS[@]}" >/dev/null
  restart() { [[ ${#running[@]} -gt 0 ]] && DC start "${running[@]}" >/dev/null; }
  _dump_to "$S/db.sql" && [[ -s $S/db.sql ]] || { restart; die "database dump failed - Nextcloud started again"; }
  _tar_out "$NC_HTML" "$S" html.tar || { restart; die "copy of /var/www/html failed - Nextcloud started again"; }
  if [[ -n $NC_DATA ]]; then _tar_out "$NC_DATA" "$S" data.tar || { restart; die "copy of the data folder failed - Nextcloud started again"; }; fi
  restart
  log "nextcloud: database ($DB_KIND, $(human "$(stat -c %s "$S/db.sql")")) + files ($(human "$(bytes_of "$S"/*.tar)")) saved$([[ ${#running[@]} -gt 0 ]] && echo ", Nextcloud started again")"
}

_tar_in() {  # $1 = mount spec, $2 = snapshot dir, $3 = file, $4 = replaced dir, $5 = image
  docker run --rm --network none --entrypoint sh -v "$(_src "$1")":/dst -v "$2":/snap:ro -v "$4":/out "$5" -c \
    "tar -C /dst --numeric-owner -cf /out/${3%.tar}-replaced.tar . && find /dst -mindepth 1 -delete && tar -C /dst --numeric-owner -xf /snap/$3" </dev/null
}

recipe_restore_data() {  # $1 = snapshot dir, $2 = dir for the replaced data (Nextcloud + DB are stopped by the runner)
  local S=$1 R=$2 img
  img=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["images"][sys.argv[2]]["id"])' "$S/manifest.json" "$NC_SVC")
  DC up -d --pull never "$DB_SVC" >/dev/null; _db_wait || die "the database did not start - nothing restored yet"
  _dump_to "$R/db-replaced.sql" || die "could not save the current database first - nothing restored"
  _load_from "$S/db.sql" || die "loading the saved database failed - the database before this step is in $R/db-replaced.sql"
  log "nextcloud: database restored (the replaced one is in $R/db-replaced.sql)"
  _tar_in "$NC_HTML" "$S" html.tar "$R" "$img" || die "restoring /var/www/html failed - the files before this step are in $R/html-replaced.tar"
  if [[ -n $NC_DATA ]]; then _tar_in "$NC_DATA" "$S" data.tar "$R" "$img" || die "restoring data failed - see $R/data-replaced.tar"; fi
  log "nextcloud: files restored (the replaced ones are in $R)"
}

_occ_status() {  # $1 = container -> 'installed version maintenance' or fails
  docker exec -u www-data "$1" php occ status --output=json 2>/dev/null | python3 -c '
import json,sys
d=json.loads(sys.stdin.read().strip().splitlines()[-1]); print(d["installed"], d["versionstring"], d["maintenance"])'
}

recipe_check() {  # occ status: installed, not in maintenance; occ user:list proves the database answers
  local c i out
  c=$(svc_container "$NC_SVC"); [[ -n $c ]] || { say "nextcloud is not running"; return 1; }
  for i in $(seq 1 60); do out=$(_occ_status "$c" || true); [[ $out == "True "*" False" ]] && break; sleep 2; done
  [[ $out == "True "*" False" ]] || { say "nextcloud not ready (occ status: ${out:-no answer})"; return 1; }
  docker exec -u www-data "$c" php occ user:list >/dev/null 2>&1 || { say "nextcloud cannot read its database (occ user:list failed)"; return 1; }
  say "nextcloud installed, version ${out#True }" | sed 's/ False$//'
}

recipe_drill() {  # throwaway copy: own network (internal) + volumes, recorded images, no ports; occ status + user:list
  local S=$1 dimg nimg net vol vold envd envn ok=1 i out t=safe-update-drill-$$
  dimg=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["images"][sys.argv[2]]["id"])' "$S/manifest.json" "$DB_SVC")
  nimg=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["images"][sys.argv[2]]["id"])' "$S/manifest.json" "$NC_SVC")
  docker image inspect "$dimg" >/dev/null 2>&1 && docker image inspect "$nimg" >/dev/null 2>&1 || { say "drill: a recorded image is not on this machine"; return 1; }
  envd=$(mktemp); envn=$(mktemp); chmod 600 "$envd" "$envn"; _env_of "$DB_SVC" > "$envd"; _env_of "$NC_SVC" > "$envn"
  net=$t-net; vol=$t-html; vold=$t-db
  docker network create --internal "$net" >/dev/null; docker volume create "$vol" >/dev/null; docker volume create "$vold" >/dev/null
  docker run --rm --network none --entrypoint tar -v "$vol":/dst -v "$S":/snap:ro "$nimg" -C /dst --numeric-owner -xf /snap/html.tar </dev/null || ok=0
  [[ -f $S/data.tar ]] && { docker volume create "$t-data" >/dev/null; docker run --rm --network none --entrypoint tar -v "$t-data":/dst -v "$S":/snap:ro "$nimg" -C /dst --numeric-owner -xf /snap/data.tar </dev/null || ok=0; }
  if (( ok )); then
    local dbdir=/var/lib/postgresql/data; [[ $DB_KIND == mysql ]] && dbdir=/var/lib/mysql
    docker run -d --name "$t-db" --network "$net" --network-alias "$DB_SVC" --env-file "$envd" -v "$vold":"$dbdir" "$dimg" >/dev/null
    svc_container() { echo "$t-db"; }   # point the DB helpers at the drill container
    _db_wait && _load_from "$S/db.sql" || ok=0
    unset -f svc_container; svc_container() { svc_cids "$1" running | head -1; }
  fi
  if (( ok )); then
    docker run -d --name "$t-nc" --network "$net" --env-file "$envn" -v "$vol":/var/www/html $([[ -f $S/data.tar ]] && echo "-v $t-data:/var/www/html/data") "$nimg" >/dev/null
    for i in $(seq 1 60); do out=$(_occ_status "$t-nc" || true); [[ $out == "True "*" False" ]] && break; sleep 2; done
    [[ $out == "True "*" False" ]] && docker exec -u www-data "$t-nc" php occ user:list >/dev/null 2>&1 || ok=0
  fi
  docker rm -f "$t-nc" "$t-db" >/dev/null 2>&1; docker volume rm "$vol" "$vold" "$t-data" >/dev/null 2>&1; docker network rm "$net" >/dev/null 2>&1
  rm -f "$envd" "$envn"
  (( ok ))
}
