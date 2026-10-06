# Home Assistant (Container) recipe for safe-update (sourced). Image ghcr.io/home-assistant/home-assistant or
# homeassistant/home-assistant. Saves /config (configuration, .storage with users/integrations, the SQLite recorder
# database) with the container STOPPED (SQLite must not change during the copy). Refused (nothing changed): a recorder
# on another database (recorder db_url not SQLite inside /config), and mounts nested inside /config.
# Home Assistant OS / Supervised are not compose stacks - use Home Assistant's own backups there.
# Vendor notes (checked 2026-10-06): no supported downgrade after a database schema upgrade - the snapshot is the way back.
HA_SVC="" HA_IMG="" HA_CONFIG=""

recipe_detect() {
  local s
  for s in $(DC config --services); do
    [[ $(svc_image "$s") == *home-assistant/home-assistant* || $(svc_image "$s") == *homeassistant/home-assistant* ]] && { HA_SVC=$s; break; }
  done
  [[ -n $HA_SVC ]] || die "no service with a home-assistant image in $COMPOSE_FILE"
  HA_IMG=$(svc_image "$HA_SVC")
  HA_CONFIG=$(svc_mount "$HA_SVC" /config)
  [[ -n $HA_CONFIG ]] || die "service $HA_SVC has no /config mount - nothing persistent to save"
  [[ $HA_CONFIG == volume:* ]] && { docker volume inspect "${HA_CONFIG#volume:}" >/dev/null 2>&1 || die "volume ${HA_CONFIG#volume:} does not exist (has the stack been started?) - nothing changed"; }
  local bad; bad=$(DC config --format json | python3 -c "
import json,sys
svc=json.load(sys.stdin)['services']['$HA_SVC']
print(' '.join('mount '+v['target'] for v in svc.get('volumes',[]) if isinstance(v,dict) and str(v.get('target','')).startswith('/config/')))") || die "could not read the compose settings of Home Assistant (check failed) - nothing changed"
  [[ -z $bad ]] || die "Home Assistant has a mount inside /config ($bad) - not covered by this recipe; nothing changed"
  # recorder on another database? read configuration.yaml (+ secrets.yaml) from the data, in the app's own image
  # every db_url in ANY yaml under /config (real YAML parse, HA tags tolerated; secrets resolved) must be EXACTLY the
  # default SQLite recorder file - anything else (other path, other database, unparsable yaml) is refused (fail closed)
  local dbu; dbu=$(_ha_in_image python3 -c "
import glob,os,yaml
class L(yaml.SafeLoader): pass
def tag(loader, suffix, node):
    if isinstance(node, yaml.ScalarNode): return ('!'+suffix, loader.construct_scalar(node))
    return None
L.add_multi_constructor('!', tag)
def load(f):
    with open(f, errors='replace') as h: return yaml.load(h, Loader=L)
def secret(name, d):   # like Home Assistant: secrets.yaml next to the referencing file first, then the parent folders
    while True:
        p=os.path.join(d,'secrets.yaml')
        if os.path.exists(p):
            v=load(p) or {}
            if isinstance(v, dict) and name in v: return v[name]
        if d in ('/data','/') or not d.startswith('/data'): return None
        d=os.path.dirname(d)
DEF='sqlite:////config/home-assistant_v2.db'
def ok(v, d):
    if isinstance(v, tuple) and v[0]=='!secret': v=secret(v[1], d)
    if not isinstance(v, str) or not v.startswith('sqlite:///'): return False
    return os.path.normpath(v[len('sqlite:///'):])=='/config/home-assistant_v2.db'
def walk(x, d):
    if isinstance(x, dict):
        for k,v in x.items():
            if str(k)=='db_url' and not ok(v, d): return False
            if not walk(v, d): return False
    elif isinstance(x, list):
        return all(walk(v, d) for v in x)
    return True
res='OK'
for f in glob.glob('/data/**/*.yaml', recursive=True)+glob.glob('/data/**/*.yml', recursive=True):
    if '/.storage/' in f or '/deps/' in f: continue
    try: d=load(f)
    except Exception: res='EXTERNAL'; break
    if not walk(d, os.path.dirname(f)): res='EXTERNAL'; break
print(res)") || die "could not read the Home Assistant yaml files (check failed) - nothing changed"
  [[ $dbu == OK ]] || die "a db_url in Home Assistant's yaml is not the default recorder file /config/home-assistant_v2.db (other database, other path, or unreadable yaml) - not covered by this recipe; nothing changed"
  RECIPE_SERVICES=("$HA_SVC")
}

_HA_QC='import os,sqlite3,sys
p=sys.argv[1]
if not os.path.exists(p): print("NODB"); sys.exit(0)
q="?immutable=1" if len(sys.argv)>2 and sys.argv[2]=="stopped" else "?mode=ro"   # stopped db on a ro mount: no -shm can be made
c=sqlite3.connect("file:"+p+q, uri=True); r=c.execute("PRAGMA quick_check").fetchone()[0]
print("OK" if r=="ok" else "BAD")'
_ha_dbcheck_in_image() { local r; r=$(_ha_in_image python3 -c "$_HA_QC" /data/home-assistant_v2.db stopped) || return 1; [[ $r == OK || $r == NODB ]]; }
_ha_recorder_ok() {  # $1 = container: database passes quick_check and the log shows no recorder failure
  local r; r=$(docker exec "$1" python3 -c "$_HA_QC" /config/home-assistant_v2.db 2>&1) || return 1
  [[ $r == OK ]] || return 1
  local lg; lg=$(docker logs "$1" 2>&1) || return 1                       # unreadable logs = not proven healthy
  [[ -n $lg ]] || return 1
  ! grep -qiE "setup failed for .?recorder|database (disk image )?is malformed|recorder.*(unable|failed)" <<< "$lg"
}

recipe_guard() {  # $1 = target tag - no vendor-required intermediate versions (2026-10-06)
  say "homeassistant: running tag $(tag_of "$HA_IMG")${1:+, target $1}"
  say "  upgrade path OK (no required steps known; there is no downgrade after a database upgrade - keep this snapshot)"
}

recipe_size() { _ha_in_image du -sb /data | awk '{print $1}'; }

_ha_src() { [[ $HA_CONFIG == volume:* ]] && echo "${HA_CONFIG#volume:}" || echo "$HA_CONFIG"; }
_ha_digest() { svc_digest "$HA_SVC"; }
_ha_in_image() {  # a command in the app's OWN image (no download, no network) with /config mounted read-only at /data
  docker run --rm --network none --entrypoint "$1" -v "$(_ha_src)":/data:ro "$(_ha_digest)" "${@:2}" </dev/null
}

recipe_snapshot() {  # $1 = snapshot dir
  local S=$1 was_running=0
  [[ -n $(svc_container "$HA_SVC") ]] && was_running=1
  log "homeassistant: stopping $HA_SVC for a consistent copy"
  DC stop "$HA_SVC" >/dev/null
  _ha_dbcheck_in_image || { (( was_running )) && DC start "$HA_SVC" >/dev/null; die "the recorder database failed its integrity check - nothing saved (fix the database first)"; }
  docker run --rm --network none --entrypoint tar -v "$(_ha_src)":/data:ro -v "$S":/out "$(_ha_digest)" \
    -C /data --numeric-owner -cf /out/config.tar . </dev/null || { (( was_running )) && DC start "$HA_SVC" >/dev/null; die "copy of /config failed - service state as before"; }
  (( was_running )) && DC start "$HA_SVC" >/dev/null
  log "homeassistant: /config saved ($(human "$(stat -c %s "$S/config.tar")"))$( (( was_running )) && echo ", service started again")"
}

recipe_restore_data() {  # $1 = snapshot dir, $2 = dir for the replaced data
  local S=$1 R=$2 img
  img=$(python3 -c 'import json,sys;print(list(json.load(open(sys.argv[1]))["images"].values())[0]["id"])' "$S/manifest.json")
  docker run --rm --network none --entrypoint sh -v "$(_ha_src)":/data -v "$S":/snap:ro -v "$R":/out "$img" -c \
    'tar -C /data --numeric-owner -cf /out/config-replaced.tar . && find /data -mindepth 1 -delete && tar -C /data --numeric-owner -xf /snap/config.tar' </dev/null \
    || die "restoring /config failed - the data before this step is in $R/config-replaced.tar"
  log "homeassistant: /config restored (the replaced one is in $R/config-replaced.tar)"
}

_ha_up() {  # $1 = container: the web server answers /manifest.json (no login needed)
  local i
  for i in $(seq 1 90); do
    docker exec "$1" curl -fsS --max-time 3 -o /dev/null http://localhost:8123/manifest.json 2>/dev/null && return 0
    sleep 2
  done
  return 1
}

recipe_check() {
  local c v
  c=$(svc_container "$HA_SVC"); [[ -n $c ]] || { say "home assistant is not running"; return 1; }
  _ha_up "$c" || { say "home assistant did not answer within 180 s"; return 1; }
  docker exec "$c" sh -c 'test -s /config/.storage/core.config_entries -o -s /config/.storage/onboarding' || { say "home assistant runs but /config/.storage is missing"; return 1; }
  local i; for i in $(seq 1 30); do _ha_recorder_ok "$c" && break; sleep 2; done
  _ha_recorder_ok "$c" || { say "home assistant runs but its recorder database is not healthy (quick_check or a setup error in the log)"; return 1; }
  v=$(docker exec "$c" python3 -c 'import homeassistant.const as c; print(c.__version__)' 2>/dev/null)
  say "home assistant up, version ${v:-unknown}"
}

recipe_drill() {  # restore into a throwaway container (own volume, no network, no ports) and check it serves again
  local S=$1 img vol name ok=1
  img=$(python3 -c 'import json,sys;print(list(json.load(open(sys.argv[1]))["images"].values())[0]["id"])' "$S/manifest.json")
  docker image inspect "$img" >/dev/null 2>&1 || { say "drill: the recorded image is not on this machine"; return 1; }
  vol=safe-update-drill-$$; name=safe-update-drill-$$
  docker volume create "$vol" >/dev/null
  docker run --rm --network none --entrypoint tar -v "$vol":/data -v "$S":/snap:ro "$img" -C /data --numeric-owner -xf /snap/config.tar </dev/null || ok=0
  if (( ok )); then
    docker run -d --name "$name" --network none -v "$vol":/config "$img" >/dev/null
    _ha_up "$name" || ok=0
    docker exec "$name" sh -c 'test -s /config/.storage/core.config_entries -o -s /config/.storage/onboarding' || ok=0   # same test as recipe_check
    local i; for i in $(seq 1 30); do _ha_recorder_ok "$name" && break; sleep 2; done
    _ha_recorder_ok "$name" || ok=0
    docker rm -f "$name" >/dev/null 2>&1
  fi
  docker volume rm "$vol" >/dev/null 2>&1
  (( ok ))
}
