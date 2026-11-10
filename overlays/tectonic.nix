# The pinned Cargo hook requires system AWS-LC, but tectonic 0.17.0 only
# declares OpenSSL. They are different libraries: OpenSSL has no openssl/base.h.
# Keep ChatGPT's TeX engine and supply the missing library instead of enabling
# vendored crypto or removing the application. Drop this when nixpkgs has it.
final: prev: {
  tectonic-unwrapped = prev.tectonic-unwrapped.overrideAttrs (old: {
    buildInputs = (old.buildInputs or [ ]) ++ [ final.aws-lc ];
  });
}
