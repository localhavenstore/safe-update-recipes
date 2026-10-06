# n8n recipe for safe-update (sourced). Official image n8nio/n8n (docker.n8n.io/n8nio/n8n), SQLite (the default).
# Saves /home/node/.n8n (database.sqlite, config with the encryption key, binary data, community nodes) with the service
# STOPPED (SQLite must not change during the copy). n8n on PostgreSQL (DB_TYPE=postgresdb) is NOT covered - refused.
# Vendor notes (checked 2026-10-06): database migrations run on start, no supported downgrade; 3.0 removes nodes
# (Function, Cron, ... - check with the free n8n Move Check first). Tested versions: see TESTED in the README.
N8_SVC="" N8_IMG="" N8_DATA=""

recipe_detect() {
  local s
  for s in $(DC config --services); do
    [[ $(svc_image "$s") == *n8nio/n8n* ]] && { N8_SVC=$s; break; }
  done
  [[ -n $N8_SVC ]] || die "no service with an n8nio/n8n image in $COMPOSE_FILE"
  N8_IMG=$(svc_image "$N8_SVC")
  N8_DATA=$(svc_mount "$N8_SVC" /home/node/.n8n)
  [[ -n $N8_DATA ]] || die "service $N8_SVC has no /home/node/.n8n mount - nothing persistent to save"
  # SQLite only, and everything n8n keeps must be inside /home/node/.n8n (the one folder saved); refuse otherwise (nothing changed)
  local bad; bad=$(DC config --format json | python3 -c "
import json,os,sys
svc=json.load(sys.stdin)['services']['$N8_SVC']
e=svc.get('environment') or {}
e=e if isinstance(e,dict) else dict(x.split('=',1) for x in e if '=' in x)
H='/home/node/.n8n'
inside=lambda v: (lambda n: n==H or n.startswith(H+'/'))(os.path.normpath(str(v)))
out=[]
if (e.get('DB_TYPE') or 'sqlite')!='sqlite' or e.get('DB_TYPE_FILE'): out.append('DB_TYPE')
if e.get('N8N_USER_FOLDER') and os.path.normpath(str(e['N8N_USER_FOLDER']))!='/home/node': out.append('N8N_USER_FOLDER')
if e.get('DB_SQLITE_DATABASE') and os.path.normpath(str(e['DB_SQLITE_DATABASE']))!=H+'/database.sqlite': out.append('DB_SQLITE_DATABASE')
out+=[k for k in ('N8N_STORAGE_PATH','N8N_BINARY_DATA_STORAGE_PATH','N8N_CUSTOM_EXTENSIONS') if e.get(k) and not all(inside(x) for x in str(e[k]).split(';'))]
out+=[k for k in ('N8N_DEFAULT_BINARY_DATA_MODE','N8N_EXECUTION_DATA_STORAGE_MODE') if str(e.get(k) or 'default').lower() not in ('default','filesystem','database','db')]   # external (s3/azure/...) storage
out+=[k for k in e if k.endswith('_FILE')]   # secret files (e.g. N8N_ENCRYPTION_KEY_FILE) cannot be reproduced in the drill
out+=['mount '+v['target'] for v in svc.get('volumes',[]) if isinstance(v,dict) and v.get('target','').startswith(H+'/')]
print(' '.join(out))") || die "could not read the compose settings of n8n (check failed) - nothing changed"
  [[ -z $bad ]] || die "n8n setting not covered by this recipe ($bad: other database, data outside /home/node/.n8n, a mount inside it, or a *_FILE secret) - nothing changed"
  [[ $N8_DATA == volume:* ]] && { docker volume inspect "${N8_DATA#volume:}" >/dev/null 2>&1 || die "volume ${N8_DATA#volume:} does not exist (has the stack been started?) - nothing changed"; }
  RECIPE_SERVICES=("$N8_SVC")
}

_n8_ver() { echo "$1" | grep -oE '^v?[0-9]+(\.[0-9]+\.[0-9]+)?' | tr -d v || true; }   # 2.41.7, v3-rc-... -> 3

recipe_guard() {  # $1 = target tag
  local now to; now=$(_n8_ver "$(tag_of "$N8_IMG")"); to=$(_n8_ver "${1:-}")
  say "n8n: running tag $(tag_of "$N8_IMG")${1:+, target $1}"
  if [[ -n $now && -n $to && ${now%%.*} -lt 3 && ${to%%.*} -ge 3 ]]; then
    say "  note: 2.x -> 3.x removes nodes (Function, Cron, Read Binary File, ...) - run the free n8n Move Check first"
  fi
  [[ -z $now ]] && say "  note: tag '$(tag_of "$N8_IMG")' has no version number - the path cannot be checked; the snapshot still protects you"
  say "  upgrade path OK"
}

recipe_size() { _n8_in_image du -sb /data | awk '{print $1}'; }

_n8_src() { [[ $N8_DATA == volume:* ]] && echo "${N8_DATA#volume:}" || echo "$N8_DATA"; }
_n8_digest() { svc_digest "$N8_SVC"; }
_n8_in_image() {  # a command in the app's OWN image (no download, no network) with the data mounted read-only at /data
  docker run --rm --network none --user 0 --entrypoint "$1" -v "$(_n8_src)":/data:ro "$(_n8_digest)" "${@:2}" </dev/null
}

recipe_snapshot() {  # $1 = snapshot dir
  local S=$1 was_running=0
  [[ -n $(svc_container "$N8_SVC") ]] && was_running=1
  log "n8n: stopping $N8_SVC for a consistent copy"
  DC stop "$N8_SVC" >/dev/null
  docker run --rm --network none --user 0 --entrypoint tar -v "$(_n8_src)":/data:ro -v "$S":/out "$(_n8_digest)" \
    -C /data --numeric-owner -cf /out/n8n.tar . </dev/null || { DC start "$N8_SVC" >/dev/null; die "copy of /home/node/.n8n failed - service started again"; }
  (( was_running )) && DC start "$N8_SVC" >/dev/null
  log "n8n: /home/node/.n8n saved ($(human "$(stat -c %s "$S/n8n.tar")"))$( (( was_running )) && echo ", service started again")"
}

recipe_restore_data() {  # $1 = snapshot dir, $2 = dir for the replaced data
  local S=$1 R=$2 img
  img=$(python3 -c 'import json,sys;print(list(json.load(open(sys.argv[1]))["images"].values())[0]["id"])' "$S/manifest.json")
  docker run --rm --network none --user 0 --entrypoint sh -v "$(_n8_src)":/data -v "$S":/snap:ro -v "$R":/out "$img" -c \
    'tar -C /data --numeric-owner -cf /out/n8n-replaced.tar . && find /data -mindepth 1 -delete && tar -C /data --numeric-owner -xf /snap/n8n.tar' </dev/null \
    || die "restoring /home/node/.n8n failed - the data before this step is in $R/n8n-replaced.tar"
  log "n8n: /home/node/.n8n restored (the replaced one is in $R/n8n-replaced.tar)"
}

_n8_healthz() {  # $1 = container: /healthz answers 200 (node fetch inside the container; the image has no curl)
  local i
  for i in $(seq 1 90); do
    docker exec "$1" node -e "fetch('http://127.0.0.1:'+(process.env.N8N_PORT||5678)+'/healthz').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))" 2>/dev/null && return 0
    sleep 2
  done
  return 1
}

recipe_check() {
  local c v
  c=$(svc_container "$N8_SVC"); [[ -n $c ]] || { say "n8n is not running"; return 1; }
  _n8_healthz "$c" || { say "n8n /healthz did not answer within 180 s"; return 1; }
  docker exec "$c" sh -c 'test -s /home/node/.n8n/database.sqlite' || { say "n8n runs but database.sqlite is missing or empty"; return 1; }
  v=$(docker exec "$c" n8n --version 2>/dev/null | tail -1)
  say "n8n healthy, version ${v:-unknown}"
}

recipe_drill() {  # restore into a throwaway container (own volume, no network, no ports) and check /healthz + the database
  local S=$1 img vol name ok=1
  img=$(python3 -c 'import json,sys;print(list(json.load(open(sys.argv[1]))["images"].values())[0]["id"])' "$S/manifest.json")
  docker image inspect "$img" >/dev/null 2>&1 || { say "drill: the recorded image is not on this machine"; return 1; }
  vol=safe-update-drill-$$; name=safe-update-drill-$$
  docker volume create "$vol" >/dev/null
  docker run --rm --network none --user 0 --entrypoint tar -v "$vol":/data -v "$S":/snap:ro "$img" -C /data --numeric-owner -xf /snap/n8n.tar </dev/null || ok=0
  if (( ok )); then
    local envf; envf=$(mktemp); chmod 600 "$envf"
    DC config --format json | python3 -c "
import json,sys
e=json.load(sys.stdin)['services']['$N8_SVC'].get('environment') or {}
e=e if isinstance(e,dict) else dict(x.split('=',1) for x in e if '=' in x)
[print(f'{k}={v}') for k,v in e.items() if v is not None and '\\n' not in str(v)]" > "$envf"
    docker run -d --name "$name" --network none --env-file "$envf" -v "$vol":/home/node/.n8n "$img" >/dev/null
    rm -f "$envf"
    _n8_healthz "$name" || ok=0
    docker exec "$name" sh -c 'test -s /home/node/.n8n/database.sqlite' || ok=0
    # credentials must decrypt with the restored key (fails on a wrong key; fine with 0 credentials)
    docker exec "$name" sh -c 'n8n export:credentials --all --decrypted --output=/tmp/c.json >/dev/null 2>&1 || n8n export:credentials --all --decrypted --output=/tmp/c.json 2>&1 | grep -qi "no credentials found"; rc=$?; rm -f /tmp/c.json; exit $rc' || ok=0
    docker rm -f "$name" >/dev/null 2>&1
  fi
  docker volume rm "$vol" >/dev/null 2>&1
  (( ok ))
}
