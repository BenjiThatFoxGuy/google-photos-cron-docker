# ── Stage 1: build gotohp CLI binary ──────────────────────────────────────────
# We clone the gotohp source and apply three patches so that the Wails GUI
# library (which requires CGo/webkit2gtk) is excluded when compiling with
# -tags cli.  The result is a pure-Go, statically-linked binary that runs
# on Alpine without any GUI libraries.
#
# Patches applied:
#   1. backend/wails_app.go   – prepend "//go:build !cli" (wraps the Wails
#      app adapter so it is skipped in CLI builds).
#   2. backend/album.go       – strip the Wails import and its init() block,
#      then re-create them in backend/album_gui.go guarded by "//go:build !cli".
#   3. backend/upload.go      – same treatment as album.go, via upload_gui.go.
#   4. cli.go                 – supply an os.Pipe() reader to tea.NewProgram so
#      Bubble Tea uses an epoll-safe fd instead of stdin (/dev/null in cron).
FROM golang:1.26-alpine AS builder

ARG GOTOHP_VERSION=v0.7.0

RUN apk add --no-cache git

RUN git clone --depth 1 --branch ${GOTOHP_VERSION} \
        https://github.com/xob0t/gotohp /gotohp

WORKDIR /gotohp

# Patch 1: guard wails_app.go so it is excluded from CLI builds.
# Only prepend the build constraint when it isn't already present, so that
# a future upstream addition of a //go:build line won't produce duplicate
# constraints and break compilation.
RUN if ! grep -q '^//go:build' backend/wails_app.go; then \
        { printf '//go:build !cli\n\n'; cat backend/wails_app.go; } \
            > /tmp/wails_app.go \
        && mv /tmp/wails_app.go backend/wails_app.go; \
    fi

# Patch 2: move the Wails-dependent init() out of album.go into a new
# album_gui.go file that is excluded from CLI builds.
# Post-sed checks ensure the sed patterns matched: if the Wails import or any
# RegisterEvent call is still present in album.go the build is aborted immediately.
RUN sed -i '/wailsapp\/wails/d' backend/album.go \
    && sed -i '/^func init() {$/,/^}$/d' backend/album.go \
    && if grep -q 'wailsapp/wails\|RegisterEvent' backend/album.go; then \
           echo 'Error: Wails import or RegisterEvent calls still present in backend/album.go after sed edits'; exit 1; \
       fi \
    && printf '//go:build !cli\n\npackage backend\n\nimport "github.com/wailsapp/wails/v3/pkg/application"\n\nfunc init() {\n\tapplication.RegisterEvent[AlbumStatus]("albumProgress")\n\tapplication.RegisterEvent[AlbumStatus]("albumComplete")\n\tapplication.RegisterEvent[AlbumError]("albumError")\n}\n' \
        > backend/album_gui.go

# Patch 3: same treatment for upload.go → upload_gui.go.
# Validation confirms that neither the Wails import nor any RegisterEvent
# call remains in upload.go after the sed edits.
RUN sed -i '/wailsapp\/wails/d' backend/upload.go \
    && sed -i '/^func init() {$/,/^}$/d' backend/upload.go \
    && if grep -q 'wailsapp/wails\|RegisterEvent' backend/upload.go; then \
           echo 'Error: Wails import or RegisterEvent calls still present in backend/upload.go after sed edits'; exit 1; \
       fi \
    && printf '//go:build !cli\n\npackage backend\n\nimport "github.com/wailsapp/wails/v3/pkg/application"\n\nfunc init() {\n\tapplication.RegisterEvent[UploadBatchStart]("uploadStart")\n\tapplication.RegisterEvent[application.Void]("uploadStop")\n\tapplication.RegisterEvent[FileUploadResult]("FileStatus")\n\tapplication.RegisterEvent[ThreadStatus]("ThreadStatus")\n\tapplication.RegisterEvent[application.Void]("uploadCancel")\n\tapplication.RegisterEvent[int64]("uploadTotalBytes")\n\tapplication.RegisterEvent[FilesDroppedEvent]("files-dropped")\n\tapplication.RegisterEvent[StartUploadEvent]("startUpload")\n}\n' \
        > backend/upload_gui.go

# Patch 4: supply an os.Pipe() read end as Bubble Tea's input so that the
# cancelreader package has an epoll-safe file descriptor.  Using os.Stdin
# directly fails in headless Docker cron jobs where stdin is /dev/null:
#   "error running TUI: error creating cancelreader: add reader to epoll interest list"
# A pipe fd is always a valid epoll target on Linux, solving both the original
# /dev/tty error and the newer epoll registration error.
RUN if ! grep -q '"os"' cli.go; then \
        awk '/^import \(/{print; print "\t\"os\""; next} {print}' cli.go > /tmp/cli.go \
        && mv /tmp/cli.go cli.go; \
    fi \
    && sed -i 's|p := tea.NewProgram(model)|r, w, _ := os.Pipe(); if w != nil { w.Close() }; if r == nil { r = os.Stdin }; p := tea.NewProgram(model, tea.WithInput(r))|' cli.go \
    && if ! grep -q '"os"' cli.go; then \
           echo 'Error: "os" import not found in cli.go after patch'; exit 1; \
       fi \
    && if ! grep -q 'tea.WithInput(r)' cli.go; then \
           echo 'Error: tea.WithInput(r) not found in cli.go after patch'; exit 1; \
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

RUN apk add --no-cache bash busybox-extras supercronic tzdata \
    && ln -sf "${LOCALTIME_FILE}" /etc/localtime

COPY --from=builder /usr/local/bin/gotohp /usr/local/bin/gotohp

COPY scripts/*.sh /app/
COPY scripts/webui/ /app/webui/

RUN chmod +x /app/*.sh /app/webui/cgi-bin/*.sh

VOLUME ["/config"]

ENTRYPOINT ["/app/entrypoint.sh"]
