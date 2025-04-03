#!/usr/bin/env bash

export CC="$(pwd)/mingw-cc"

nim \
    --cc:"env" \
    --os:windows \
    --d:ctWindows \
    -d:mingw \
    --verbosity:3 \
    --forceBuild:on \
    --amd64.windows.gcc.path=/nix/store/z8y274xxd92ywv39s5v4vcy10rsp637c-x86_64-w64-mingw32-gcc-wrapper-13.2.0/bin/ \
    -d:debug \
    -d:asyncBackend=asyncdispatch \
    --gc:refc \
    --debugInfo \
    --lineDir:on \
    --boundChecks:on \
    --stacktrace:on \
    --linetrace:on \
    -d:chronicles_sinks=json \
    -d:chronicles_line_numbers=true \
    -d:chronicles_timestamps=UnixTime \
    -d:ctTest \
    -d:testing \
    --hint[XDeclaredButNotUsed]:off \
    -d:builtWithNix \
    -d:ctEntrypoint \
    --nimcache:nimcache \
    --out:"${GIT_ROOT}"/windows/bin/ct c ../src/ct/codetracer.nim

# --cc:"env" \
    # --os:windows --passC:"-target" --passC:"x86_64-windows" \
#         --os:windows --passC:"-target" --passC:"x86_64-windows" \
