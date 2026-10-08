# The non-nix producer for `ct host`'s container image — WD2's alternative to
# `packages.codetracer-host-image`.
#
# ## Why this exists, and what it is NOT
#
# `interactive-session-substrate.md` §5 declines to commit to the dev container
# standard and says why: `devcontainer.json` is a way to build a Docker image,
# which is a build-time input rather than a runtime. The substrate resolves an
# image reference in its own store and does not care who produced it. So this is
# a second producer of an equivalent image, for a customer or a CI system with
# Docker and no nix — it is not a second runtime and nothing in the substrate
# reads it.
#
# ## What it has to get right, and it is three things
#
# The substrate needs the container to run `ct host` on a port it can address.
# Everything else is this file's business. The three obligations, which are the
# three `config` keys `codetracer-host-image` sets:
#
#   * the entrypoint is `ct host`;
#   * it binds `0.0.0.0` — the explicit choice WD1a's loopback default exists to
#     force, and the right one inside a namespace of one's own;
#   * the working directory is `/workspace`, which is where the substrate mounts
#     the project.
#
# ## Why it builds through nix anyway, in a builder stage
#
# Because the alternative is reimplementing the hosting closure by hand, and the
# hosting closure is 20 store paths with a `CODETRACER_PREFIX` that has to point
# at the right one — `nix/packages/default.nix`'s `hostingDeps` exists because
# getting that wrong produces an image that contains every file and still starts
# an index that cannot find one. A second hand-written recipe for it would drift
# from the first, and the drift would be invisible until a panel was blank.
#
# What this file gives a Docker-only consumer is therefore a DOCKER BUILD, not a
# nix workflow: `docker build .devcontainer` needs Docker and a network, and
# nothing else on the host.

FROM nixos/nix:2.24.9 AS builder

# Flakes and the sandbox, explicitly rather than by hoping the image's default
# is the one we want.
RUN mkdir -p /etc/nix && \
    printf 'experimental-features = nix-command flakes\nfilter-syscalls = false\n' \
      >> /etc/nix/nix.conf

WORKDIR /src
COPY . /src

# `?submodules=1` is this flake's documented invocation: the two trace-format
# inputs are a MATCHED FFI PAIR and are resolved from the submodule checkouts,
# so they move together or not at all.
RUN nix build --no-link --print-out-paths '.?submodules=1#codetracer-host' > /tmp/out-path && \
    mkdir -p /tmp/closure && \
    nix copy --no-check-sigs --to /tmp/closure "$(cat /tmp/out-path)" 2>/dev/null || true

# The runtime stage is a plain Debian rather than a nix image: a customer
# inspecting this container should find a filesystem they recognise, and the
# product's own closure is self-contained under /nix/store.
FROM debian:bookworm-slim

RUN apt-get update && \
    apt-get install -y --no-install-recommends ca-certificates git && \
    rm -rf /var/lib/apt/lists/*

COPY --from=builder /nix/store /nix/store
COPY --from=builder /tmp/out-path /tmp/out-path

# `/bin/ct` is the name the substrate's entrypoint expects, and it is a symlink
# into the store rather than a copy: a copy would lose the wrapper that sets
# `CODETRACER_PREFIX`, which is the one variable an index process cannot start
# without.
RUN ln -s "$(cat /tmp/out-path)/bin/ct" /bin/ct && rm /tmp/out-path

ENV SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt
WORKDIR /workspace

# The same three obligations as `codetracer-host-image`'s `config`.
ENTRYPOINT ["/bin/ct", "host", "--bind", "0.0.0.0"]
