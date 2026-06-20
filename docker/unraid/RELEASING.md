# Releasing `djbriane/wallabag-opds` to Docker Hub

Runbook for rebuilding and republishing the Unraid image after you change the
OPDS feature, pull in upstream wallabag updates, or tweak the deploy config.

## Branch model

```
upstream/master
  └─ feat/opds-support     OPDS feature + the Sentry prod fix.  This is the PR branch.
       └─ deploy/unraid    Adds docker/unraid + .dockerignore.  Build the image from HERE.
```

- **Never** build releases from `feat/opds-support` — it has no Dockerfile.
- **Never** put `docker/unraid/**` onto `feat/opds-support` — it would pollute the upstream PR.
- The image is built from the **repo root** as context; `docker/unraid/Dockerfile`
  does `COPY .`, so whatever is committed on the checked-out branch is what ships.

## Prerequisites (one-time)

- Docker Desktop running, logged in to Docker Hub as `djbriane`
  (Docker Desktop GUI login is enough; `docker login` from a non-TTY shell fails).
- `docker buildx` available (bundled with Docker Desktop).
- Unraid is x86-64, so we build `linux/amd64`. On an Apple-Silicon Mac this runs
  under emulation and is slow (~10–15 min); that's expected.

## Standard release

```sh
cd <repo root>                      # the wallabag/ checkout

# 1. Get the latest feature/upstream work onto the deploy branch
git checkout feat/opds-support
git pull                            # if you track changes remotely
#   (to fold in upstream wallabag:  git fetch upstream && git rebase upstream/master)

git checkout deploy/unraid
git rebase feat/opds-support        # replay docker/unraid commits on top of latest code

# 2. Build amd64 and push straight to Docker Hub
docker buildx build --platform linux/amd64 \
  -f docker/unraid/Dockerfile \
  -t djbriane/wallabag-opds:latest \
  -t djbriane/wallabag-opds:2.7.0-dev \
  --push .

# 3. Push the branches so the source matches what you shipped
git push origin feat/opds-support deploy/unraid
```

Tip: bump/add a version tag per release (e.g. `-t djbriane/wallabag-opds:2025-06-21`)
so you can roll back to a specific image if an update misbehaves. `:latest` always
moves to the newest build.

## Verify before trusting it (optional but recommended)

Smoke-test the freshly built image locally before updating Unraid:

```sh
docker run -d --name wb-smoke -p 8899:80 \
  -e SYMFONY__ENV__DOMAIN_NAME="http://localhost:8899" \
  djbriane/wallabag-opds:latest

# wait for "wallabag is ready!"
docker logs -f wb-smoke

curl -s http://localhost:8899/api/info            # -> {"appname":"wallabag","version":...}
# OPDS (after setting a feed token under Config -> Feeds):
#   http://localhost:8899/opds/<user>/<token>

docker rm -f wb-smoke
```

## Update the running container on Unraid

1. Docker tab → the wallabag container → **Force Update** (or **Check for Updates**
   then apply). This re-pulls `:latest` and recreates the container.
2. Your data volume (`/var/www/wallabag/data`, SQLite DB + config) is preserved.
3. On boot the entrypoint detects the existing schema and runs **pending Doctrine
   migrations** automatically (a fresh DB instead gets installed with admin
   `wallabag` / `wallabag` — change it).

## What's baked in (so you don't rediscover it)

- App is configured by **real environment variables**; the entrypoint translates
  the official image's `SYMFONY__ENV__*` vars into them (see `root/entrypoint.sh`).
  Set at least `SYMFONY__ENV__DOMAIN_NAME` to the real URL — OPDS links use it.
- `app/config/config_prod.yml` needs the Sentry DSN `string:` cast or prod
  `cache:clear` fails (committed on `feat/opds-support`).
- nginx serves `web/index.php`; php prod config hides PHP 8.4 deprecation noise.

## Rollback

```sh
# re-tag a previous build as latest, or just deploy a pinned tag on Unraid:
#   Repository: djbriane/wallabag-opds:<old-version-tag>
```
