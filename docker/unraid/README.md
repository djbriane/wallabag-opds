# wallabag (OPDS) — self-built image for Unraid

This image is a drop-in replacement for the official
[`wallabag/wallabag`](https://hub.docker.com/r/wallabag/wallabag) image, built
from this source tree so the **OPDS 1.2 catalog** is baked in.

It keeps the official image's runtime shape: Alpine + s6 + nginx + php-fpm, app
at `/var/www/wallabag`, listens on port **80**, persists to the
`/var/www/wallabag/data` volume, and is configured with the same
`SYMFONY__ENV__*` environment variables. An entrypoint shim translates those
into the `.env.local` the newer code reads, so your existing Unraid template
works unchanged.

## Build & push

Run from the repository root (not from `docker/unraid`):

```sh
# amd64 image for a typical Unraid server, pushed straight to Docker Hub
docker buildx build \
  --platform linux/amd64 \
  -f docker/unraid/Dockerfile \
  -t djbriane/wallabag-opds:latest \
  -t djbriane/wallabag-opds:2.6 \
  --push .
```

## Run on Unraid

Point your existing wallabag container at `djbriane/wallabag-opds:latest`. The
relevant settings (defaults shown):

| Setting        | Value                                             |
|----------------|---------------------------------------------------|
| Repository     | `djbriane/wallabag-opds:latest`                   |
| Port           | host → `80`                                        |
| Path (data)    | host appdata → `/var/www/wallabag/data`           |
| `SYMFONY__ENV__DOMAIN_NAME` | `https://wallabag.your-domain` (no trailing slash) |
| `SYMFONY__ENV__DATABASE_DRIVER` | `pdo_sqlite` (default; data lives in the volume) |

On first start the entrypoint installs a fresh database with the default admin
**`wallabag` / `wallabag`** — change the password immediately. On later starts
it runs pending Doctrine migrations instead.

### OPDS

Once logged in, your OPDS catalog root is:

```
/opds/{username}/{feed-token}/
```

Generate the feed token under **Config → Feeds** if you don't have one yet.
Point KOReader / Foliate / Thorium at that URL.

## Notes

- Migrating from the official SQLite image: copy your existing
  `data/db/wallabag.sqlite` into the new container's data volume; the entrypoint
  detects the existing schema and only applies migrations.
- For MySQL/Postgres, set `SYMFONY__ENV__DATABASE_DRIVER` plus the matching
  `SYMFONY__ENV__DATABASE_*` variables exactly as with the official image.
