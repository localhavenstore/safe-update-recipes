# Jellyfin recipe for safe-update (sourced). Official image jellyfin/jellyfin (or lscr.io/linuxserver/jellyfin).
# Saves /config (database, settings, plugins, metadata) with the service STOPPED (SQLite must not change during the copy).
# /cache and media are not saved (cache rebuilds; media is yours and not changed by updates).
# Vendor notes (checked 2026-10-04, research problems-5): 12.x rewrites the database on first start, no downgrade;
# go to 10.11.11+ before 12.x. Tested versions: see TESTED in the README.
JF_SVC="" JF_IMG="" JF_CONFIG=""

recipe_detect() {
  local s
  for s in $(DC config --services); do
    [[ $(svc_image "$s") == *jellyfin* ]] && { JF_SVC=$s; break; }
  done
  [[ -n $JF_SVC ]] || die "no service with a jellyfin image in $COMPOSE_FILE"
  JF_IMG=$(svc_image "$JF_SVC")
  JF_CONFIG=$(svc_mount "$JF_SVC" /config)
  [[ -n $JF_CONFIG ]] || die "service $JF_SVC has no /config mount - nothing persistent to save"
  [[ $JF_CONFIG == volume:* ]] && { docker volume inspect "${JF_CONFIG#volume:}" >/dev/null 2>&1 || die "volume ${JF_CONFIG#volume:} does not exist (has the stack been started?) - nothing changed"; }
  RECIPE_SERVICES=("$JF_SVC")
}

_ver() { echo "$1" | grep -oE '^[0-9]+\.[0-9]+(\.[0-9]+)?' || true; }

recipe_guard() {  # $1 = target tag ('' = not given)
  local now to; now=$(_ver "$(tag_of "$JF_IMG")"); to=$(_ver "${1:-}")
  say "jellyfin: running tag $(tag_of "$JF_IMG")${1:+, target $1}"
  if [[ -z $to ]]; then
    say "  note: give --to TAG to check the upgrade path (12.x needs 10.11.11+ first; 12.x cannot go back without this snapshot)"
    return 0
  fi
  if [[ ${to%%.*} -ge 12 && -n $now && ${now%%.*} -eq 10 ]]; then
    local minor patch; minor=$(echo "$now" | cut -d. -f2); patch=$(echo "$now" | cut -d. -f3); patch=${patch:-0}
    if (( minor < 11 || (minor == 11 && patch < 11) )); then
      say "  REFUSED: $now -> $to skips the required step. Update to 10.11.11 (or newer 10.11.x) first, start it once, then 12.x."
      return 1
    fi
  fi
  [[ -z $now ]] && say "  note: tag '$(tag_of "$JF_IMG")' has no version number (latest?) - the path cannot be checked; the snapshot still protects you"
  say "  upgrade path OK"
}

recipe_size() { _in_image du -sb /data | awk '{print $1}'; }

_src() { [[ $JF_CONFIG == volume:* ]] && echo "${JF_CONFIG#volume:}" || echo "$JF_CONFIG"; }
_digest() { svc_digest "$JF_SVC"; }
_in_image() {  # run a command in the app's OWN image (no download, no network) with /config mounted at /data (read-only)
  docker run --rm --network none --entrypoint "$1" -v "$(_src)":/data:ro "$(_digest)" "${@:2}" </dev/null
}

recipe_snapshot() {  # $1 = snapshot dir
  local S=$1 was_running=0
  [[ -n $(svc_container "$JF_SVC") ]] && was_running=1
  log "jellyfin: stopping $JF_SVC for a consistent copy"
  DC stop "$JF_SVC" >/dev/null
  docker run --rm --network none --entrypoint tar -v "$(_src)":/data:ro -v "$S":/out "$(_digest)" \
    -C /data --numeric-owner -cf /out/config.tar . </dev/null || { DC start "$JF_SVC" >/dev/null; die "copy of /config failed - service started again"; }
  (( was_running )) && DC start "$JF_SVC" >/dev/null
  log "jellyfin: /config saved ($(human "$(stat -c %s "$S/config.tar")"))$( (( was_running )) && echo ", service started again")"
}

recipe_restore_data() {  # $1 = snapshot dir, $2 = dir for the replaced data
  local S=$1 R=$2 img
  img=$(python3 -c 'import json,sys;print(list(json.load(open(sys.argv[1]))["images"].values())[0]["id"])' "$S/manifest.json")
  docker run --rm --network none --entrypoint sh -v "$(_src)":/data -v "$S":/snap:ro -v "$R":/out "$img" -c \
    'tar -C /data --numeric-owner -cf /out/config-replaced.tar . && find /data -mindepth 1 -delete && tar -C /data --numeric-owner -xf /snap/config.tar' </dev/null \
    || die "restoring /config failed - the data before this step is in $R/config-replaced.tar"
  log "jellyfin: /config restored (the replaced one is in $R/config-replaced.tar)"
}

recipe_check() {  # health + version through the container itself (no published port needed)
  local c i out
  c=$(svc_container "$JF_SVC"); [[ -n $c ]] || { say "jellyfin is not running"; return 1; }
  for i in $(seq 1 60); do
    out=$(docker exec "$c" curl -fsS --max-time 3 http://localhost:8096/health 2>/dev/null || true)
    [[ $out == Healthy ]] && break
    sleep 2
  done
  [[ $out == Healthy ]] || { say "jellyfin /health did not answer Healthy within 120 s"; return 1; }
  say "jellyfin healthy, version $(docker exec "$c" curl -fsS --max-time 3 http://localhost:8096/System/Info/Public | python3 -c 'import json,sys;print(json.load(sys.stdin).get("Version","?"))')"
}

recipe_drill() {  # restore into a throwaway container (own volume, no network, no ports) and run the health check
  local S=$1 img vol name ok=1 i out
  img=$(python3 -c 'import json,sys;print(list(json.load(open(sys.argv[1]))["images"].values())[0]["id"])' "$S/manifest.json")
  docker image inspect "$img" >/dev/null 2>&1 || { say "drill: the recorded image is not on this machine"; return 1; }
  vol=safe-update-drill-$$; name=safe-update-drill-$$
  docker volume create "$vol" >/dev/null
  docker run --rm --network none --entrypoint tar -v "$vol":/data -v "$S":/snap:ro "$img" -C /data -xf /snap/config.tar </dev/null || ok=0
  if (( ok )); then
    docker run -d --name "$name" --network none -v "$vol":/config "$img" >/dev/null
    for i in $(seq 1 60); do
      out=$(docker exec "$name" curl -fsS --max-time 3 http://localhost:8096/health 2>/dev/null || true)
      [[ $out == Healthy ]] && break
      sleep 2
    done
    [[ $out == Healthy ]] || ok=0
    docker rm -f "$name" >/dev/null 2>&1
  fi
  docker volume rm "$vol" >/dev/null 2>&1
  (( ok ))
}
