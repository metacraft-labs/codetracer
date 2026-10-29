# Shared native prerequisites for the backend package and its unchanged Cargo
# hooks. Keep this independent of the full frontend/development SDK closure.
{
  pkgs,
  inputs,
  nimCompiler,
}:
{
  nativeBuildInputs = [
    pkgs.capnproto
    pkgs.nodejs_20
    pkgs.tree-sitter
    pkgs.rustc
    pkgs.cargo
    pkgs.rustPlatform.cargoSetupHook
    # nim is needed because db-backend's build.rs shells out to
    # codetracer-native-recorder/ct_emulator/build_native_api.sh,
    # which runs ``nim c`` to generate native C files.  Outside
    # the sandbox direnv loads the recorder's flake env; here we
    # provide nim directly.
    nimCompiler
    pkgs.gcc
  ];
  environment = {
    CODETRACER_DB_BACKEND_SKIP_DIRENV = "1";
    CODETRACER_TRACE_FORMAT_NIM_SKIP_NIMBLE_INSTALL = "1";
  };
  shellHook = ''
    # Inject the codetracer/libs Nim package directories so
    # ``results`` and ``stew`` resolve when
    # build_native_api.sh (ct_emulator) runs ``nim c``;
    # ``$PWD`` is the unpacked codetracer source at this point.
    if [ -d "$PWD/libs/nim-stew/stew" ]; then
      # Use ``libs/nim-stew/stew`` only -- it ships a
      # newer ``results.nim`` with proper ``Result[void,
      # E]`` support that ct_emulator relies on (the older
      # standalone libs/nim-result
      # mishandles ``?`` on void results so we
      # deliberately leave it off the path).  The stew
      # path also provides ``stew/byteutils``, ``stew/io2``
      # and the other modules the trace-format-nim sources
      # transitively pull in.
      NIM_PATHS_LIB="$PWD/libs/nim-stew/stew:$PWD/libs/nim-stew"
      export CT_EMULATOR_EXTRA_NIM_PATHS="$NIM_PATHS_LIB"
    fi
    # trace-format-nim itself needs the standalone `results`
    # package: stew's copy above does not compile its
    # `unsafeError` calls on `Result[void, E]` under upstream
    # Nim 2.2, so its writer build takes the same flake inputs as the
    # Python recorder in `nix/shells/ci-base.nix`.
    export CODETRACER_TRACE_FORMAT_NIM_EXTRA_PATHS="${inputs.nim-results}:${inputs.nim-stew}"
  '';
}
