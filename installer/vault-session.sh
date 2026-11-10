# shellcheck shell=bash
# RAM-only Bitwarden state shared by retries of one host's installation.
# Sourced by install-nixos; never prints the session key.
vault_session_init() {
  VAULT_STATE=$1
  mkdir -p "$VAULT_STATE"
  chmod 700 "$VAULT_STATE"
  if [ -n "${BITWARDENCLI_APPDATA_DIR:-}" ]; then
    vault_owned=0
    printf '%s\n' "$BITWARDENCLI_APPDATA_DIR" > "$VAULT_STATE/appdata-path"
    printf '0\n' > "$VAULT_STATE/owned"
  elif [ -s "$VAULT_STATE/appdata-path" ]; then
    BITWARDENCLI_APPDATA_DIR=$(cat "$VAULT_STATE/appdata-path")
    vault_owned=$(cat "$VAULT_STATE/owned")
  else
    BITWARDENCLI_APPDATA_DIR="$VAULT_STATE/bitwarden"
    vault_owned=1
    printf '%s\n' "$BITWARDENCLI_APPDATA_DIR" > "$VAULT_STATE/appdata-path"
    printf '1\n' > "$VAULT_STATE/owned"
  fi
  export BITWARDENCLI_APPDATA_DIR
  if [ -z "${BW_SESSION:-}" ] && [ -s "$VAULT_STATE/session" ]; then
    BW_SESSION=$(cat "$VAULT_STATE/session")
  fi
  export BW_SESSION
}

vault_session_status() {
  bw status | jq -r '.status'
}

vault_session_unlock() {
  if [ "$(vault_session_status)" != unlocked ]; then
    # BW_PASSWORD: master password asked by the graphical installer
    if ! BW_SESSION=$(if [ -n "${BW_PASSWORD:-}" ]; then bw unlock --raw --passwordenv BW_PASSWORD; else bw unlock --raw; fi); then
      BW_SESSION=""
      rm -f "$VAULT_STATE/session"
      return 1
    fi
  fi
  [ -n "$BW_SESSION" ] || return 1
  export BW_SESSION
  (umask 077; printf '%s' "$BW_SESSION" > "$VAULT_STATE/session")
  chmod 600 "$VAULT_STATE/session"
}

vault_session_finish() {
  # Failure keeps login/session only, so --resume does not need another SSO.
  # Success clears managed state, without logging out a borrowed CLI login.
  if [ "$1" = 1 ] && [ -n "${VAULT_STATE:-}" ]; then
    if [ "$vault_owned" = 1 ]; then bw logout >/dev/null 2>&1 || true; fi
    rm -rf "$VAULT_STATE"
  fi
}
