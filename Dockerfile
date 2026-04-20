# ── Stage 1: build gotohp CLI binary ──────────────────────────────────────────
# We clone the gotohp source and apply patches/ on top so that the Wails GUI
# library (which requires CGo/webkit2gtk) is excluded when compiling with
# -tags cli, and to add CLI-specific enhancements.  The result is a pure-Go,
# statically-linked binary that runs on Alpine without any GUI libraries.
#
# To add or modify a patch:
#   1. Edit the relevant .patch file in patches/ (or add a new one, numbered
#      sequentially: 0005-description.patch).
#   2. To regenerate patches after upstream changes:
#        git clone --depth 1 --branch <NEW_VERSION> https://github.com/xob0t/gotohp /tmp/gotohp
#        cd /tmp/gotohp && git am /path/to/patches/*.patch
#      If git am fails, resolve conflicts, then: git am --continue
#      Re-export with: git format-patch HEAD~N -o patches/
#
# Patches currently applied (see patches/ directory for full diffs):
#   0001 – backend/wails_app.go:   guard with //go:build !cli
#   0002 – backend/album.go:       split Wails init() into album_gui.go
#   0003 – backend/upload.go:      split Wails init() into upload_gui.go
#   0004 – cli.go:                 supply os.Pipe() to Bubble Tea for epoll safety
FROM golang:1.26-alpine AS builder

ARG GOTOHP_VERSION=v0.7.0

RUN apk add --no-cache git

RUN git clone --depth 1 --branch ${GOTOHP_VERSION} \
        https://github.com/xob0t/gotohp /gotohp

WORKDIR /gotohp

# Apply all patches in order.  git am aborts with clear diff context on failure,
# making it immediately obvious which upstream change broke a patch.
COPY patches/ /patches/
RUN git config user.email "build@dockerfile" \
    && git config user.name "Dockerfile" \
    && git am /patches/*.patch

RUN CGO_ENABLED=0 go build \
        -tags cli \
        -trimpath \
        -ldflags="-w -s" \
        -o /usr/local/bin/gotohp \
        .

# ── Stage 2: minimal Alpine runtime ───────────────────────────────────────────
FROM alpine:3.21

ENV XDG_CONFIG_HOME=/config \
    LOCALTIME_FILE="/tmp/localtime"

RUN apk add --no-cache bash busybox-extras supercronic tzdata \
    && ln -sf "${LOCALTIME_FILE}" /etc/localtime

COPY --from=builder /usr/local/bin/gotohp /usr/local/bin/gotohp

COPY scripts/*.sh /app/
COPY scripts/webui/ /app/webui/

RUN chmod +x /app/*.sh /app/webui/cgi-bin/*.sh

VOLUME ["/config"]

ENTRYPOINT ["/app/entrypoint.sh"]
