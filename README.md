# safe-update (v0.1.1, preview)

**A consistent data snapshot right before a container update - and a restore that puts the data AND the old image back
together.**

Most updaters can roll back the *image*. That does not help when the new version has already migrated your database:
the old image cannot read the new data (Nextcloud: "downgrading is not supported", Jellyfin 12: database rewritten on
first start). `safe-update` saves the data in a state that matches the running version, knows each app's upgrade rules,
and can restore both halves.

```
sudo ./safe-update plan     nextcloud /srv/nextcloud --to 35-apache   # read-only: what is saved, upgrade-path check, disk
sudo ./safe-update snapshot nextcloud /srv/nextcloud --to 35-apache   # consistent snapshot -> /srv/nextcloud/.safe-update/<UTC>/
# ... you update the way you always do (docker compose pull && docker compose up -d) ...
sudo ./safe-update restore  nextcloud /srv/nextcloud                  # dry run: prints the steps
sudo ./safe-update restore  nextcloud /srv/nextcloud --yes            # data + compose file + old image back, app check
sudo ./safe-update drill    nextcloud /srv/nextcloud                  # proves a snapshot restores (throwaway copy, no ports)
sudo ./safe-update check    nextcloud /srv/nextcloud                  # read-only: the app check on the running stack (0 = OK)
./safe-update --version
```

## What each recipe does
| app | snapshot | upgrade rule it enforces | app check |
|---|---|---|---|
| Nextcloud (PostgreSQL or MariaDB/MySQL) | Nextcloud containers stopped -> database dump made inside the DB container (+ its accounts/owner) -> `/var/www/html` (+ a separate `data` mount) | one major version at a time, no downgrades | `occ status` (installed, not in maintenance) + `occ user:list` |
| Jellyfin | service stopped -> `/config` (database, settings, plugins, metadata); `/cache` and media are not saved | 10.11.x -> 12.x only from 10.11.11+ | `/health` = Healthy + version |
| Immich (machine learning optional) | services stopped -> full database dump (`pg_dumpall --clean --if-exists`, as in Immich's docs) + an inventory of the library (photos are NOT copied) | no downgrades, one major at a time | `/api/server/ping` + version |

## Rules it keeps
- **Never downloads anything.** No curl/wget in the scripts; restore uses the images still on your machine (it tells
  you the exact `docker pull <digest>` if you pruned one).
- **Never deletes.** Snapshots are kept until you remove them. Restore first saves the current data, compose file and
  `.env` next to the snapshot (`<snapshot>.replaced-<time>`).
- **Refuses instead of guessing:** an upgrade path that skips a required version, less than 2x the snapshot size free
  on disk, a damaged snapshot (every file is checked against the manifest's sha256), a named volume that does not exist.
- Restore without `--yes` only prints what it would do.

## Honest limits
- **Not a backup strategy.** Snapshots live on the same disk, next to your compose file. Keep real backups elsewhere.
- Photos/media are not copied by the Immich and Jellyfin recipes (too big; updates do not change them).
- The app is stopped for the copy (minutes for big Nextcloud data folders). External storage is not included.
- **One compose file.** safe-update reads only `compose.yaml` (or `docker-compose.yml`); with a `compose.override.yaml`
  next to it, snapshot refuses (nothing changed) instead of saving the wrong data.
- **One tool at a time per stack.** safe-update locks a stack for its own snapshot, restore and drill, but it cannot
  see other tools: do not run another update/backup tool on the same stack while it works.
- Tested only with the versions below, on fresh Ubuntu 24.04 VMs with Docker's Ubuntu packages.

## Tested (automated VM runs, real images)
| app | path tested | checks |
|---|---|---|
| Jellyfin | 10.11.10 -> 12.1 refused; 10.11.10 -> 10.11.11 -> snapshot -> 12.1 (migration) -> restore to 10.11.11 | 9/9 |
| Nextcloud + PostgreSQL 17 | 34 -> 36 refused; 34 -> snapshot -> 35.0.1 (migration) -> restore to 34.0.4 | 9/9 |
| Nextcloud + MariaDB 11.4 | same path | 9/9 |
| Immich (+ its postgres image, valkey) | v3.1.0 -> v3.0.3 refused; v3.1.0 -> snapshot -> v3.2.4 (migration) + a new photo -> restore to 3.1.0 (1 asset; the newer photo's file kept and reported) | 10/10 |

Each run: seed real data, snapshot, real major update, add data on the new version, restore, then check the version,
the exact users/files and that the compose file and the replaced data were kept; drill on a good snapshot = OK, on a
damaged one = FAIL (Immich also: a dump with a real SQL error = FAIL). Test scripts: `tests/`.

## Changes in 0.1.1 (5 Oct 2026)
- **Fix (Immich):** in 0.1 the Immich restore and drill ignored errors while loading the database dump, so a load that
  failed part-way could still be reported as restored. Now only the two harmless messages every `pg_dumpall --clean`
  load prints are accepted; any other error stops the restore (the database before it stays saved) and fails the drill.
  If you restored Immich with 0.1: run `safe-update check immich DIR` and a `drill` on the snapshot you used.
  Nextcloud and Jellyfin were not affected (their loads already stopped on the first error).
- **Fix (restore):** restore now reads services and data folders from the snapshot's OWN copy of the compose file and
  `.env`, not from the current ones (a volume changed in `.env` after the snapshot could otherwise receive the old data).
  A `.env` the snapshot did not have is removed and kept in the replaced folder.
- safe-update runs `docker compose` with a clean environment (as `sudo` does by default): only the compose file and
  `.env` decide images, folders and settings - variables exported in your shell are ignored. `snapshot` refuses
  (nothing changed) when the compose file + `.env` do not describe the running stack (for example a stack started
  with a shell variable that `.env` does not have - checked: image, folders/volumes and environment): put the variable
  into `.env` first.
- Snapshot, restore and drill lock the stack, so two safe-update runs cannot work on it at once.
- New: `safe-update check APP DIR` (read-only app check), `safe-update app-service APP DIR` (prints the service the
  recipe treats as the app) and `safe-update --version`.

MIT licence. Made with AI assistance. Not affiliated with Nextcloud, Jellyfin or Immich.


## Support

The tool is free and stays free. If it saved you time, you can leave a tip:
[![Tip on Ko-fi](https://img.shields.io/badge/Ko--fi-leave%20a%20tip-FF5E5B?logo=ko-fi&logoColor=white)](https://ko-fi.com/localhaven)
(optional - nothing is unlocked by it).
