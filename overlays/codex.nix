# The pinned Cargo hook makes -sys crates link system libraries instead of
# vendored ones (AWS_LC_SYS_USE_SYSTEM, ZSTD_SYS_USE_PKG_CONFIG,
# LIBSQLITE3_SYS_USE_PKG_CONFIG, LIBZ_SYS_STATIC=0, RUSTONIG_SYSTEM_LIBONIG),
# but codex 0.167.0 doesn't declare them, so its -sys crates fail to build.
# As an overlay, the fixed codex is the one ChatGPT and T3 Code pick up too,
# on the desktop and in the flake's `chatgpt` package. Drop this when nixpkgs
# has it.
final: prev: {
  codex = prev.codex.overrideAttrs (old: {
    buildInputs = old.buildInputs ++ (with final; [ aws-lc zstd sqlite zlib dbus oniguruma ]);
  });
}
