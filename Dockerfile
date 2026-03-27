# ── Stage 1: build gotohp CLI binary ──────────────────────────────────────────
# We clone the gotohp source, patch backend/wails_app.go to add
# "//go:build !cli" so that it (and its Wails/webkit2gtk dependency) is
# excluded when compiling with -tags cli.  The result is a pure-Go,
# statically-linked binary that runs on Alpine without any GUI libraries.
FROM golang:1.24-alpine AS builder

ARG GOTOHP_VERSION=v0.7.0

RUN apk add --no-cache git

RUN git clone --depth 1 --branch ${GOTOHP_VERSION} \
        https://github.com/xob0t/gotohp /gotohp

WORKDIR /gotohp

# Prepend the build constraint so the Wails-dependent file is skipped
# when building with -tags cli, removing all webkit2gtk/CGo requirements.
RUN { printf '//go:build !cli\n\n'; cat backend/wails_app.go; } \
        > /tmp/wails_app.go \
    && mv /tmp/wails_app.go backend/wails_app.go

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
