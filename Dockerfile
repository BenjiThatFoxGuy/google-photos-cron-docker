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
#   0005 – progress_writer.go:     write real-time progress JSON for web UI
#   0006 – webui_server.go:         "serve" subcommand: embedded Go HTTP server
FROM golang:1.26-alpine AS builder

ARG GOTOHP_VERSION=v0.7.0
ARG DOCKER_BRANCH
ARG DOCKER_COMMIT

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

# Copy the web UI HTML so it is available for go:embed at compile time.
COPY scripts/webui/index.html /gotohp/webui/index.html
RUN UPSTREAM_COMMIT="$(git rev-parse --short=12 HEAD)" \
    && sed -i \
      -e "s|__GOTOHP_VERSION__|${GOTOHP_VERSION}|g" \
      -e "s|__GOTOHP_COMMIT__|${UPSTREAM_COMMIT}|g" \
      -e "s|__GOTOHP_COMMIT_URL__|https://github.com/xob0t/gotohp/commit/${UPSTREAM_COMMIT}|g" \
      /gotohp/webui/index.html \
    && if [ -n "${DOCKER_BRANCH}" ]; then \
         DOCKER_COMMIT_SHORT="$(echo "${DOCKER_COMMIT}" | cut -c1-12)"; \
         sed -i \
           -e "s|__DOCKER_BRANCH__|${DOCKER_BRANCH}|g" \
           -e "s|__DOCKER_COMMIT__|${DOCKER_COMMIT_SHORT}|g" \
           /gotohp/webui/index.html; \
       fi

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

RUN apk add --no-cache bash supercronic tzdata \
    && ln -sf "${LOCALTIME_FILE}" /etc/localtime

COPY --from=builder /usr/local/bin/gotohp /usr/local/bin/gotohp

COPY scripts/*.sh /app/

RUN chmod +x /app/*.sh

VOLUME ["/config"]

ENTRYPOINT ["/app/entrypoint.sh"]
