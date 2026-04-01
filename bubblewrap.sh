#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ./bubblewrap.sh <claude|codex> [tool arguments...]

Examples:
  ./bubblewrap.sh claude
  ./bubblewrap.sh codex
  ./bubblewrap.sh codex exec "pwd"
EOF
}

if [ $# -lt 1 ]; then
  usage >&2
  exit 1
fi

TOOL="$1"
shift

case "$TOOL" in
  claude)
    TOOL_CMD="$(command -v claude 2>/dev/null || true)"
    TOOL_EXTRA_ARGS=(--dangerously-skip-permissions)
    TOOL_STATE_DIRS=("$HOME/.claude")
    TOOL_STATE_FILES=("$HOME/.claude.json")
    TOOL_OPTIONAL_DIRS=(
      "$HOME/.nvm"
      "$HOME/.config/git"
      "$HOME/.config/gh"
      "/cvmfs"
      "/opt/claude-code"
    )
    TOOL_OPTIONAL_FILES=(
      "$HOME/.git-credentials"
    )
    TOOL_NEEDS_DBUS=1
    ;;
  codex)
    TOOL_CMD="$(command -v codex 2>/dev/null || true)"
    TOOL_EXTRA_ARGS=(--dangerously-bypass-approvals-and-sandbox)
    TOOL_STATE_DIRS=("$HOME/.codex")
    TOOL_STATE_FILES=()
    TOOL_OPTIONAL_DIRS=(
      "$HOME/.config/git"
      "$HOME/.config/gh"
      "$HOME/.local/share/codex"
      "$HOME/.npm-global"
    )
    TOOL_OPTIONAL_FILES=(
        "$HOME/.git-credentials"
        "$HOME/.codex/config.toml"
        "$HOME/.codex/auth.json"
    )
    TOOL_NEEDS_DBUS=0
    ;;
  -h|--help|help)
      usage
      exit 0
      ;;
  *)
      echo "Error: unsupported tool '$TOOL'. Expected 'claude' or 'codex'." >&2
      usage >&2
      exit 1
      ;;
esac

if [ -z "${TOOL_CMD:-}" ]; then
    echo "Error: '$TOOL' not found in PATH" >&2
    exit 1
fi

TOOL_BIN="$(readlink -f "$TOOL_CMD" 2>/dev/null || printf '%s\n' "$TOOL_CMD")"
if [ ! -e "$TOOL_BIN" ]; then
    echo "Error: resolved '$TOOL' binary does not exist: $TOOL_BIN" >&2
    exit 1
fi

OPTIONAL_BINDS=()
for path in "${TOOL_OPTIONAL_DIRS[@]}"; do
  [ -d "$path" ] && OPTIONAL_BINDS+=(--ro-bind "$path" "$path")
done
for path in "${TOOL_OPTIONAL_FILES[@]}"; do
  [ -f "$path" ] && OPTIONAL_BINDS+=(--ro-bind "$path" "$path")
done

STATE_BINDS=()
for path in "${TOOL_STATE_DIRS[@]}"; do
  [ -d "$path" ] && STATE_BINDS+=(--bind "$path" "$path")
done
for path in "${TOOL_STATE_FILES[@]}"; do
  [ -f "$path" ] && STATE_BINDS+=(--bind "$path" "$path")
done

SSH_BINDS=()
SSH_ENV=()
if [ -n "${SSH_AUTH_SOCK:-}" ] && [ -S "$SSH_AUTH_SOCK" ]; then
  SSH_DIR="$(dirname "$SSH_AUTH_SOCK")"
  SSH_BINDS+=(--bind "$SSH_DIR" "$SSH_DIR")
  SSH_ENV+=(--setenv SSH_AUTH_SOCK "$SSH_AUTH_SOCK")
fi

SSH_PUBKEY_BINDS=()
for pubkey in "$HOME/.ssh/id_ed25519.pub" "$HOME/.ssh/id_rsa.pub" "$HOME/.ssh/id_ecdsa.pub"; do
  [ -f "$pubkey" ] && SSH_PUBKEY_BINDS+=(--ro-bind "$pubkey" "$pubkey")
done

DBUS_BINDS=()
DBUS_ENV=()
KEYRING_BINDS=()
XDG_RUNTIME="/run/user/$(id -u)"
if [ "$TOOL_NEEDS_DBUS" -eq 1 ]; then
  if [ -S "$XDG_RUNTIME/bus" ]; then
    DBUS_BINDS+=(--bind "$XDG_RUNTIME/bus" "$XDG_RUNTIME/bus")
    DBUS_ENV+=(--setenv DBUS_SESSION_BUS_ADDRESS "unix:path=$XDG_RUNTIME/bus")
  fi

  if [ -d "$XDG_RUNTIME/keyring" ]; then
    KEYRING_BINDS+=(--bind "$XDG_RUNTIME/keyring" "$XDG_RUNTIME/keyring")
  fi
fi

GPG_ENV=()
[ -n "${GPG_SIGNING_KEY_ID:-}" ] && GPG_ENV+=(--setenv GPG_SIGNING_KEY_ID "$GPG_SIGNING_KEY_ID")

GPG_BINDS=()
if [ -d "$HOME/.gnupg" ]; then
  GPG_BINDS+=(--bind "$HOME/.gnupg" "$HOME/.gnupg")
fi

GPG_SOCKDIR="$(gpgconf --list-dirs socketdir 2>/dev/null || true)"
if [ -n "$GPG_SOCKDIR" ] && [ -d "$GPG_SOCKDIR" ]; then
  GPG_BINDS+=(--bind "$GPG_SOCKDIR" "$GPG_SOCKDIR")
fi

BASE_BINDS=(
  --ro-bind /usr /usr
  --ro-bind /lib /lib
  --ro-bind /lib64 /lib64
  --ro-bind /bin /bin
  --ro-bind /etc/resolv.conf /etc/resolv.conf
  --ro-bind /etc/hosts /etc/hosts
  --ro-bind /etc/ssl /etc/ssl
  --ro-bind /etc/passwd /etc/passwd
  --ro-bind /etc/group /etc/group
  --tmpfs /tmp
  --proc /proc
  --dev /dev
  --setenv HOME "$HOME"
  --setenv USER "$USER"
  --setenv PATH "$PATH"
  --setenv TERM "${TERM:-xterm-256color}"
  --share-net
  --unshare-pid
  --die-with-parent
  --chdir "$PWD"
)

[ -d /etc/ca-certificates ] && BASE_BINDS+=(--ro-bind /etc/ca-certificates /etc/ca-certificates)
[ -d /etc/pki ] && BASE_BINDS+=(--ro-bind /etc/pki /etc/pki)
[ -f "$HOME/.ssh/known_hosts" ] && BASE_BINDS+=(--ro-bind "$HOME/.ssh/known_hosts" "$HOME/.ssh/known_hosts")
[ -f /usr/bin/gpg ] && BASE_BINDS+=(--ro-bind /usr/bin/gpg /usr/bin/gpg)
[ -f "$HOME/.gitconfig" ] && BASE_BINDS+=(--ro-bind "$HOME/.gitconfig" "$HOME/.gitconfig")
[ -d "$HOME/.local" ] && BASE_BINDS+=(--ro-bind "$HOME/.local" "$HOME/.local")
[ -d "$HOME/.npm" ] && BASE_BINDS+=(--bind "$HOME/.npm" "$HOME/.npm")
[ -d "$PWD" ] && BASE_BINDS+=(--bind "$PWD" "$PWD")

[ -n "${OPENAI_API_KEY:-}" ] && BASE_BINDS+=(--setenv OPENAI_API_KEY "$OPENAI_API_KEY")
[ -n "${OPENAI_BASE_URL:-}" ] && BASE_BINDS+=(--setenv OPENAI_BASE_URL "$OPENAI_BASE_URL")
[ -n "${ANTHROPIC_API_KEY:-}" ] && BASE_BINDS+=(--setenv ANTHROPIC_API_KEY "$ANTHROPIC_API_KEY")

exec bwrap \
  "${BASE_BINDS[@]}" \
  "${SSH_BINDS[@]}" \
  "${SSH_PUBKEY_BINDS[@]}" \
  "${GPG_ENV[@]}" \
  "${OPTIONAL_BINDS[@]}" \
  "${STATE_BINDS[@]}" \
  "${GPG_BINDS[@]}" \
  "${DBUS_BINDS[@]}" \
  "${KEYRING_BINDS[@]}" \
  "${SSH_ENV[@]}" \
  "${DBUS_ENV[@]}" \
  "$TOOL_BIN" "${TOOL_EXTRA_ARGS[@]}" "$@"
