# Vaultwarden recipe for safe-update (sourced). Official image vaultwarden/server (SQLite in /data - the default).
# Saves /data (db.sqlite3, attachments, sends, rsa keys, config.json, icon cache) with the service STOPPED (SQLite must
# not change during the copy). External databases (MySQL/PostgreSQL via DATABASE_URL) are NOT covered - refused.
# Vendor notes (checked 2026-10-06): database migrations run on start, there is no supported downgrade - the snapshot is
# the way back. Tested versions: see TESTED in the README.
VW_SVC="" VW_IMG="" VW_DATA=""

recipe_detect() {
  local s
  for s in $(DC config --services); do
    [[ $(svc_image "$s") == *vaultwarden/server* ]] && { VW_SVC=$s; break; }
  done
  [[ -n $VW_SVC ]] || die "no service with a vaultwarden/server image in $COMPOSE_FILE"
  VW_IMG=$(svc_image "$VW_SVC")
  VW_DATA=$(svc_mount "$VW_SVC" /data)
  [[ -n $VW_DATA ]] || die "service $VW_SVC has no /data mount - nothing persistent to save"
  # everything Vaultwarden keeps must be inside /data (the one folder this recipe saves); refuse relocations (nothing changed)
  local bad; bad=$(DC config --format json | python3 -c "
import json,os,re,sys
svc=json.load(sys.stdin)['services']['$VW_SVC']
e=svc.get('environment') or {}
e=e if isinstance(e,dict) else dict(x.split('=',1) for x in e if '=' in x)
def inside(v):
    v=re.sub(r'^sqlite://','',str(v)); v=v if v.startswith('/') else '/'+v
    n=os.path.normpath(v); return n=='/data' or n.startswith('/data/')
keys=('DATABASE_URL','DATA_FOLDER','ATTACHMENTS_FOLDER','SENDS_FOLDER','RSA_KEY_FILENAME','TEMPLATES_FOLDER','ICON_CACHE_FOLDER')
out=[k for k in keys if e.get(k) and not inside(e[k])]
out+=[k for k in e if k.endswith('_FILE') and k[:-5] in keys]
out+=['mount '+v['target'] for v in svc.get('volumes',[]) if isinstance(v,dict) and v.get('target','').startswith('/data/')]
if e.get('ENV_FILE'): out.append('ENV_FILE')          # Vaultwarden reads settings from its own env file - not checkable
out+=['mount '+v['target'] for v in svc.get('volumes',[]) if isinstance(v,dict) and str(v.get('target','')).endswith('.env')]
print(' '.join(out))") || die "could not read the compose settings of Vaultwarden (check failed) - nothing changed"
  [[ -z $bad ]] || die "Vaultwarden keeps data outside /data or in another database ($bad) - not covered by this recipe; nothing changed"
  [[ $VW_DATA == volume:* ]] && { docker volume inspect "${VW_DATA#volume:}" >/dev/null 2>&1 || die "volume ${VW_DATA#volume:} does not exist (has the stack been started?) - nothing changed"; }
  RECIPE_SERVICES=("$VW_SVC")
}

recipe_guard() {  # $1 = target tag ('' = not given) - no vendor-required intermediate versions known (2026-10-06)
  say "vaultwarden: running tag $(tag_of "$VW_IMG")${1:+, target $1}"
  say "  upgrade path OK (no required steps known; there is no downgrade - keep this snapshot until the new version works)"
}

recipe_size() { _vw_in_image du -sb /data | awk '{print $1}'; }

_vw_src() { [[ $VW_DATA == volume:* ]] && echo "${VW_DATA#volume:}" || echo "$VW_DATA"; }
_vw_digest() { svc_digest "$VW_SVC"; }
_vw_in_image() {  # a command in the app's OWN image (no download, no network) with /data mounted read-only
  docker run --rm --network none --entrypoint "$1" -v "$(_vw_src)":/data:ro "$(_vw_digest)" "${@:2}" </dev/null
}

recipe_snapshot() {  # $1 = snapshot dir
  local S=$1 was_running=0
  [[ -n $(svc_container "$VW_SVC") ]] && was_running=1
  log "vaultwarden: stopping $VW_SVC for a consistent copy"
  DC stop "$VW_SVC" >/dev/null
  docker run --rm --network none --entrypoint tar -v "$(_vw_src)":/data:ro -v "$S":/out "$(_vw_digest)" \
    -C /data --numeric-owner -cf /out/data.tar . </dev/null || { DC start "$VW_SVC" >/dev/null; die "copy of /data failed - service started again"; }
  (( was_running )) && DC start "$VW_SVC" >/dev/null
  log "vaultwarden: /data saved ($(human "$(stat -c %s "$S/data.tar")"))$( (( was_running )) && echo ", service started again")"
}

recipe_restore_data() {  # $1 = snapshot dir, $2 = dir for the replaced data
  local S=$1 R=$2 img
  img=$(python3 -c 'import json,sys;print(list(json.load(open(sys.argv[1]))["images"].values())[0]["id"])' "$S/manifest.json")
  docker run --rm --network none --entrypoint sh -v "$(_vw_src)":/data -v "$S":/snap:ro -v "$R":/out "$img" -c \
    'tar -C /data --numeric-owner -cf /out/data-replaced.tar . && find /data -mindepth 1 -delete && tar -C /data --numeric-owner -xf /snap/data.tar' </dev/null \
    || die "restoring /data failed - the data before this step is in $R/data-replaced.tar"
  log "vaultwarden: /data restored (the replaced one is in $R/data-replaced.tar)"
}

_vw_alive() {  # $1 = container: /alive answers 200 (inside the container, no published port needed)
  local i
  for i in $(seq 1 60); do
    docker exec "$1" curl -fsS --max-time 3 -o /dev/null http://localhost:${VW_PORT:-80}/alive 2>/dev/null && return 0
    sleep 2
  done
  return 1
}

recipe_check() {
  local c v
  c=$(svc_container "$VW_SVC"); [[ -n $c ]] || { say "vaultwarden is not running"; return 1; }
  VW_PORT=$(docker exec "$c" sh -c 'echo ${ROCKET_PORT:-80}' 2>/dev/null)
  _vw_alive "$c" || { say "vaultwarden /alive did not answer within 120 s"; return 1; }
  v=$(docker exec "$c" /vaultwarden --version 2>/dev/null | head -1)
  docker exec "$c" sh -c 'test -s /data/db.sqlite3' || { say "vaultwarden runs but /data/db.sqlite3 is missing or empty"; return 1; }
  say "vaultwarden alive, ${v:-version unknown}"
}

recipe_drill() {  # restore into a throwaway container (own volume, no network, no ports) and check /alive + the database
  local S=$1 img vol name ok=1
  img=$(python3 -c 'import json,sys;print(list(json.load(open(sys.argv[1]))["images"].values())[0]["id"])' "$S/manifest.json")
  docker image inspect "$img" >/dev/null 2>&1 || { say "drill: the recorded image is not on this machine"; return 1; }
  vol=safe-update-drill-$$; name=safe-update-drill-$$
  docker volume create "$vol" >/dev/null
  docker run --rm --network none --entrypoint tar -v "$vol":/data -v "$S":/snap:ro "$img" -C /data -xf /snap/data.tar </dev/null || ok=0
  if (( ok )); then
    docker run -d --name "$name" --network none -v "$vol":/data "$img" >/dev/null
    VW_PORT=80; _vw_alive "$name" || ok=0
    docker exec "$name" sh -c 'test -s /data/db.sqlite3' || ok=0
    docker rm -f "$name" >/dev/null 2>&1
  fi
  docker volume rm "$vol" >/dev/null 2>&1
  (( ok ))
}
