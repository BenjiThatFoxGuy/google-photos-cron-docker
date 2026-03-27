# google-photos-cron-docker

A Docker container that performs scheduled uploads to Google Photos using
[gotohp](https://github.com/xob0t/gotohp) and
[supercronic](https://github.com/aptible/supercronic).

The configuration style is intentionally similar to
[tgdrive/rclone-backup](https://github.com/tgdrive/rclone-backup), making it
easy to adopt if you are already familiar with that project.

---

## Features

- Scheduled uploads via cron (powered by supercronic)
- Single **or** multiple source → album pairs per container
- All `gotohp upload` flags exposed as environment variables
- Per-pair overrides for any upload option (e.g. `GOTOHP_THREADS_0`)
- Credentials stored in a Docker volume — survive container restarts
- Secrets can be supplied via files (`_FILE` suffix) or a `.env` file
- Tiny Alpine-based image, pure-Go binary (no webkit/GUI dependencies)

---

## Quick start

### 1. Obtain Google Photos credentials

gotohp requires mobile-app credentials obtained once from your Android device.
See the [official gotohp README](https://github.com/xob0t/gotohp#requires-mobile-app-credentials-to-work)
for full instructions.  The credential string looks like:

```
androidId=XXXXXXXXXXXXXXXXXX&...
```

### 2. Configure and run

Copy `docker-compose.yml`, fill in your values, and start:

```bash
docker compose up -d
```

### 3. Trigger a one-shot backup

```bash
docker compose run --rm photos-backup backup
```

---

## Environment variables

### Scheduling

| Variable   | Default        | Description               |
|------------|----------------|---------------------------|
| `CRON`     | `5 * * * *`    | Cron expression           |
| `TIMEZONE` | `UTC`          | Container timezone (e.g. `America/New_York`) |

### Credentials

| Variable        | Default | Description |
|-----------------|---------|-------------|
| `GOTOHP_CREDS`  | —       | Credential string (`androidId=...`) from your Android device |
| `GOTOHP_EMAIL`  | —       | Active account email or partial match (optional if only one credential is stored) |

### Source / Album pairs

Define a single backup job with the shorthand variables, or multiple jobs with
the indexed form.  Both styles may be combined.

| Variable         | Description |
|------------------|-------------|
| `SOURCE_PATH`    | Path inside the container to upload (alias for `SOURCE_PATH_0`) |
| `ALBUM_NAME`     | Destination album name (alias for `ALBUM_NAME_0`; leave empty to upload to library root) |
| `SOURCE_PATH_N`  | Nth source path (`SOURCE_PATH_0`, `SOURCE_PATH_1`, …) |
| `ALBUM_NAME_N`   | Nth album name; use `AUTO` for per-folder album creation |

### Upload options

| Variable                   | Default | Description |
|----------------------------|---------|-------------|
| `GOTOHP_THREADS`           | `3`     | Concurrent upload threads |
| `GOTOHP_RECURSIVE`         | `TRUE`  | Include sub-directories |
| `GOTOHP_FORCE`             | `FALSE` | Re-upload even if file already exists in Google Photos |
| `GOTOHP_DELETE`            | `FALSE` | Delete source file after successful upload |
| `GOTOHP_DISABLE_FILTER`    | `FALSE` | Upload all file types, not just media |
| `GOTOHP_DATE_FROM_FILENAME`| `FALSE` | Parse media date from filename (e.g. `20240709_182027.jpg`) |
| `GOTOHP_LOG_LEVEL`         | `info`  | Log verbosity: `debug`, `info`, `warn`, `error` |

### Per-pair upload option overrides

Any upload option can be overridden for a specific source/album pair by appending
the pair index to the variable name.  If the per-pair variable is not set, the
global value is used as the default.

| Variable                      | Description |
|-------------------------------|-------------|
| `GOTOHP_THREADS_N`            | Override concurrent threads for pair N |
| `GOTOHP_RECURSIVE_N`          | Override recursive flag for pair N |
| `GOTOHP_FORCE_N`              | Override force flag for pair N |
| `GOTOHP_DELETE_N`             | Override delete flag for pair N |
| `GOTOHP_DISABLE_FILTER_N`     | Override disable-filter flag for pair N |
| `GOTOHP_DATE_FROM_FILENAME_N` | Override date-from-filename flag for pair N |
| `GOTOHP_LOG_LEVEL_N`          | Override log level for pair N |

### Secret handling

Every variable above supports a `_FILE` suffix — the container will read the
value from the given path.  This is useful with Docker Secrets:

```yaml
environment:
  GOTOHP_CREDS_FILE: /run/secrets/gotohp_creds
secrets:
  - gotohp_creds
```

Variables can also be placed in a `/.env` file mounted into the container.

---

## Volumes

| Mount point | Purpose |
|-------------|---------|
| `/config`   | Persists the gotohp credential store and settings across restarts |
| Source dirs | Mount your photo directories here. If you enable [`GOTOHP_DELETE`](#upload-options) or [`GOTOHP_DELETE_N`](#per-pair-upload-option-overrides) to delete files after a successful upload, the mount **must be read-write**. If you are not using delete-after-upload, adding `:ro` to the mount is safe and recommended. |

---

## Examples

### Single source

```yaml
services:
  photos-backup:
    image: ghcr.io/benjithatfoxguy/google-photos-cron-docker:latest
    environment:
      CRON: "0 2 * * *"
      GOTOHP_CREDS: "androidId=..."
      SOURCE_PATH: /photos
      ALBUM_NAME: "My Backup"
      GOTOHP_DELETE: "TRUE"   # delete source file after a successful upload
    volumes:
      - /mnt/photos:/photos       # read-write required when GOTOHP_DELETE is enabled
      - gotohp-config:/config     # persists credentials & config

volumes:
  gotohp-config:
```

> **Note:** If you are not using `GOTOHP_DELETE`, you can add `:ro` to the source
> mount (e.g. `/mnt/photos:/photos:ro`) for an extra layer of safety.

### Multiple sources

```yaml
services:
  photos-backup:
    image: ghcr.io/benjithatfoxguy/google-photos-cron-docker:latest
    environment:
      CRON: "0 3 * * *"
      GOTOHP_CREDS: "androidId=..."
      GOTOHP_THREADS: "3"          # global default
      SOURCE_PATH_0: /camera
      ALBUM_NAME_0: "Camera Roll"
      GOTOHP_THREADS_0: "8"        # override threads for pair 0 only
      GOTOHP_DELETE_0: "TRUE"      # delete camera files after upload (pair 0)
      SOURCE_PATH_1: /screenshots
      ALBUM_NAME_1: "Screenshots"
      GOTOHP_RECURSIVE_1: "FALSE"  # flat folder — skip sub-directories (pair 1)
      SOURCE_PATH_2: /videos
      # ALBUM_NAME_2 omitted — uploads to library root
    volumes:
      - /mnt/camera:/camera           # read-write — GOTOHP_DELETE_0 is enabled
      - /mnt/screenshots:/screenshots:ro  # read-only is fine; no delete for pair 1
      - /mnt/videos:/videos:ro            # read-only is fine; no delete for pair 2
      - gotohp-config:/config

volumes:
  gotohp-config:
```

### Per-folder albums (AUTO mode)

```yaml
SOURCE_PATH: /organised
ALBUM_NAME: "AUTO"   # creates one album per sub-folder
```

### Run a one-shot backup immediately

```bash
docker run --rm \
  -e GOTOHP_CREDS="androidId=..." \
  -e SOURCE_PATH=/photos \
  -e ALBUM_NAME="My Backup" \
  -v /mnt/photos:/photos \
  -v gotohp-config:/config \
  ghcr.io/benjithatfoxguy/google-photos-cron-docker:latest backup
```

> **Note:** Pass `-e GOTOHP_DELETE=TRUE` to delete each file after it is
> successfully uploaded.  If you are not using `GOTOHP_DELETE`, you can append
> `:ro` to the source mount for safety.

---

## Building locally

```bash
docker build -t google-photos-cron-docker .
```

The Dockerfile uses a two-stage build:

1. **Builder** (`golang:1.24-alpine`) — clones the gotohp source at the pinned
   tag, patches `backend/wails_app.go` to exclude the Wails GUI layer when
   compiled with `-tags cli`, and produces a static binary with
   `CGO_ENABLED=0`.
2. **Runtime** (`alpine:3.21`) — copies only the binary and shell scripts;
   no GUI libraries required.

---

## Credits

- [xob0t/gotohp](https://github.com/xob0t/gotohp) — the Google Photos upload engine
- [tgdrive/rclone-backup](https://github.com/tgdrive/rclone-backup) — inspiration for project structure and conventions
- [aptible/supercronic](https://github.com/aptible/supercronic) — container-friendly cron daemon