# VM tests

Each script starts a FRESH throw-away Ubuntu 24.04 VM, installs Docker, runs the app on real images, and writes PASS/FAIL
lines to `$OUTDIR/sur-*/summary.txt` (default `./results`): seed data, refused upgrade path, snapshot, real major update,
new data, restore, drill on a good and on a damaged snapshot, "never downloads".

They need a small VM helper of your own, given as `TESTVM=/path/to/helper`, with four commands:
`helper up` (boot a fresh VM with a sudo user `learner`, network on; exit non-zero if busy), `helper ssh 'COMMAND'`,
`helper put LOCAL REMOTE_PATH`, `helper down` (stop + delete).

    TESTVM=~/bin/testvm bash tests/r1_jellyfin_vm.sh
    TESTVM=~/bin/testvm DB=mariadb bash tests/r2_nextcloud_vm.sh      # DB=postgres (default) or mariadb
    TESTVM=~/bin/testvm bash tests/r3_immich_vm.sh
