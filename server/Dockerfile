# Two stages: the first builds the crate, the second runs only the binary, so the image
# that stays on the server carries no compiler and no cargo.
FROM rust:1.88-alpine AS build

# rusqlite is used with the `bundled` feature, so SQLite is compiled from source. That needs
# a C compiler, which the rust image does not carry.
#
# 1.88 is the highest toolchain any pinned dependency requires — sha2 0.11.1 declares
# rust-version 1.88 — and the crate is edition 2024, which needs 1.85. Nothing in the repo
# records that floor, so it is stated here.
RUN apk add --no-cache build-base
WORKDIR /src

# Dependencies are built from placeholder sources first, so a changed source file does not
# rebuild them on the next build.
COPY Cargo.toml Cargo.lock ./
RUN mkdir -p src && echo '' > src/lib.rs && echo 'fn main() {}' > src/main.rs && cargo build --release

COPY . .

# Cargo decides what to rebuild by mtime, and the copied sources are older than the placeholder
# files it just built, so without the touch it would keep the placeholder binary. The
# dependencies stay cached; only the crate is compiled here. find is used instead of a glob so
# a source file in a subfolder of src is reached too.
RUN find src -exec touch {} + && cargo build --release

# Both stages are Alpine, so the binary is built for musl. A glibc builder with this runtime
# would fail when the binary is executed.
FROM alpine:3.20

RUN addgroup -S saphire && adduser -S saphire -G saphire

# The server resolves a relative path against the folder it is started from, so the database and
# the library paths have to be handed to the container as absolute paths under the mount
# (compose mounts them at /data). The page folder is the one path that must stay inside the
# working directory, because it is relative in the code.
#
# Both mount paths are created here with the service user, because a new named volume takes its
# ownership from the image at the path it is mounted on — without this the service user cannot
# write an uploaded file. An existing volume keeps the ownership it was created with.
WORKDIR /app
RUN mkdir -p /data/library && chown -R saphire:saphire /data
COPY --from=build /src/target/release/saphire-server /app/saphire-server
COPY static /app/static

USER saphire

# Documents the default; the mapping in compose is what makes the port reachable, and it uses
# whatever PORT says. This is the only port the container carries.
EXPOSE 8080

# A healthcheck that answers HTTP rather than only opening a port. Every API endpoint needs a
# session, so the page is the path that answers 200 without credentials; the mount is used
# rather than a file inside it, because `/static/index.html` is redirected. The address is an
# IPv4 literal because the server binds 0.0.0.0, so `localhost` inside the container resolves
# to ::1 and is refused. busybox wget is already in the base image, so nothing is installed for
# this. The check reports health; nothing here restarts an unhealthy container.
HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
  CMD wget -qO- "http://127.0.0.1:${PORT:-8080}/static/" >/dev/null || exit 1

CMD ["/app/saphire-server"]
