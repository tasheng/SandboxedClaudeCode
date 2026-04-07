#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ./bubblewrap.sh <claude|codex|bash> [tool arguments...]

Examples:
  ./bubblewrap.sh claude
  ./bubblewrap.sh codex
  ./bubblewrap.sh bash
  ./bubblewrap.sh codex exec "pwd"
EOF
}

if [ $# -lt 1 ]; then
  usage >&2
  exit 1
fi

TOOL="$1"
shift
TOOL_ARGS=("$@")

COMMON_OPTIONAL_DIRS=(
  "$HOME/.nvm"
  "$HOME/.config/git"
  "/cvmfs"
  "/data"
  "/opt/cuda"
  "/usr/local/cuda"
  "/usr/lib/nvidia"
  "/usr/lib/x86_64-linux-gnu/nvidia"
  "/etc/OpenCL"
  "/etc/OpenCL/vendors"
  "/etc/vulkan"
  "/usr/share/vulkan"
  "/usr/share/glvnd"
  "/usr/share/egl"
  "/usr/share/nvidia"
  "/etc/ld.so.conf.d"
  "/proc/driver/nvidia"
  "/sys/bus/pci/devices"
  "/sys/class/drm"
  "/sys/module/nvidia"
  "/sys/module/nvidia_uvm"
  "/sys/module/nvidia_modeset"
  "/sys/dev/char"
  "/run/nvidia"
  "/run/opengl-driver"
)

COMMON_OPTIONAL_FILES=(
  "/etc/ld.so.conf"
)

COMMON_WRITABLE_DIRS=(
  "$HOME/.config/gh"
  "/data00/tsheng"
)

GIT_CREDENTIAL_STORE_DIR="$HOME/.local/share/git"
GIT_CREDENTIAL_STORE_FILE="$GIT_CREDENTIAL_STORE_DIR/credentials"

mkdir -p "$GIT_CREDENTIAL_STORE_DIR"
if [ -f "$HOME/.git-credentials" ] && [ ! -f "$GIT_CREDENTIAL_STORE_FILE" ]; then
  cp "$HOME/.git-credentials" "$GIT_CREDENTIAL_STORE_FILE"
  chmod 600 "$GIT_CREDENTIAL_STORE_FILE"
fi

case "$TOOL" in
  claude)
    TOOL_CMD="$(command -v claude 2>/dev/null || true)"
    TOOL_EXTRA_ARGS=(--dangerously-skip-permissions)
    TOOL_STATE_DIRS=("$HOME/.claude")
    TOOL_STATE_FILES=("$HOME/.claude.json")
    TOOL_OPTIONAL_DIRS=(
      "${COMMON_OPTIONAL_DIRS[@]}"
      "/opt/claude-code"
    )
    TOOL_OPTIONAL_FILES=("${COMMON_OPTIONAL_FILES[@]}")
    TOOL_NEEDS_DBUS=1
    ;;
  codex)
    TOOL_CMD="$(command -v codex 2>/dev/null || true)"
    TOOL_EXTRA_ARGS=(--dangerously-bypass-approvals-and-sandbox)
    TOOL_STATE_DIRS=("$HOME/.codex")
    TOOL_STATE_FILES=()
    TOOL_OPTIONAL_DIRS=(
      "${COMMON_OPTIONAL_DIRS[@]}"
      "$HOME/.local/share/codex"
      "$HOME/.npm-global"
    )
    TOOL_OPTIONAL_FILES=(
      "${COMMON_OPTIONAL_FILES[@]}"
      "$HOME/.codex/config.toml"
      "$HOME/.codex/auth.json"
    )
    TOOL_NEEDS_DBUS=1
    ;;
  bash)
    TOOL_CMD="$(command -v bash 2>/dev/null || true)"
    TOOL_EXTRA_ARGS=()
    TOOL_STATE_DIRS=()
    TOOL_STATE_FILES=()
    TOOL_OPTIONAL_DIRS=(
        "${COMMON_OPTIONAL_DIRS[@]}"
        "$HOME/bin"
        "$HOME/.cargo"
        "$HOME/.local"
    )
    TOOL_OPTIONAL_FILES=(
        "${COMMON_OPTIONAL_FILES[@]}"
        "$HOME/.bashrc"
    )
    TOOL_NEEDS_DBUS=1
    ;;
  -h|--help|help)
      usage
      exit 0
      ;;
  *)
      echo "Error: unsupported tool '$TOOL'. Expected 'claude', 'codex', or 'bash'." >&2
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
  OPTIONAL_BINDS+=(--ro-bind-try "$path" "$path")
done
for path in "${TOOL_OPTIONAL_FILES[@]}"; do
  OPTIONAL_BINDS+=(--ro-bind-try "$path" "$path")
done

CUDA_ENV=()
if [ -d /opt/cuda ]; then
  CUDA_LIB_PATHS=(/opt/cuda/lib64 /opt/cuda/nvvm/lib64)
  CUDA_LD_LIBRARY_PATH="$(IFS=:; printf '%s' "${CUDA_LIB_PATHS[*]}")"
  if [ -n "${LD_LIBRARY_PATH:-}" ]; then
    CUDA_LD_LIBRARY_PATH="$CUDA_LD_LIBRARY_PATH:$LD_LIBRARY_PATH"
  fi
  CUDA_ENV+=(
    --setenv CUDA_HOME /opt/cuda
    --setenv CUDA_PATH /opt/cuda
    --setenv LD_LIBRARY_PATH "$CUDA_LD_LIBRARY_PATH"
  )
fi

GPU_DEVICE_BINDS=()
GPU_DEVICES=(
  /dev/dri
  /dev/kfd
  /dev/nvidia0
  /dev/nvidiactl
  /dev/nvidia-uvm
  /dev/nvidia-uvm-tools
  /dev/nvidia-modeset
)
for path in "${GPU_DEVICES[@]}"; do
  GPU_DEVICE_BINDS+=(--dev-bind-try "$path" "$path")
done

WRITABLE_BINDS=()
for path in "${COMMON_WRITABLE_DIRS[@]}"; do
  [ -d "$path" ] && WRITABLE_BINDS+=(--bind "$path" "$path")
done

LATEX_RO_BINDS=()
LATEX_RO_BINDS+=(--ro-bind-try /etc/texmf /etc/texmf)

LATEX_RW_BINDS=()
[ -d "$HOME/.texlive/texmf-config" ] && LATEX_RW_BINDS+=(--bind "$HOME/.texlive/texmf-config" "$HOME/.texlive/texmf-config")
[ -d "$HOME/.texlive/texmf-var" ] && LATEX_RW_BINDS+=(--bind "$HOME/.texlive/texmf-var" "$HOME/.texlive/texmf-var")

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
  SSH_PUBKEY_BINDS+=(--ro-bind-try "$pubkey" "$pubkey")
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

GIT_ENV=()
GIT_CONFIG_COUNT_BASE="${GIT_CONFIG_COUNT:-0}"
if [[ "$GIT_CONFIG_COUNT_BASE" =~ ^[0-9]+$ ]]; then
  GIT_CONFIG_COUNT_RESET_INDEX="$GIT_CONFIG_COUNT_BASE"
  GIT_CONFIG_COUNT_HELPER_INDEX="$((GIT_CONFIG_COUNT_BASE + 1))"
  GIT_ENV+=(
    --setenv GIT_CONFIG_COUNT "$((GIT_CONFIG_COUNT_BASE + 2))"
    --setenv "GIT_CONFIG_KEY_$GIT_CONFIG_COUNT_RESET_INDEX" credential.helper
    --setenv "GIT_CONFIG_VALUE_$GIT_CONFIG_COUNT_RESET_INDEX" ""
    --setenv "GIT_CONFIG_KEY_$GIT_CONFIG_COUNT_HELPER_INDEX" credential.helper
    --setenv "GIT_CONFIG_VALUE_$GIT_CONFIG_COUNT_HELPER_INDEX" "store --file $GIT_CREDENTIAL_STORE_FILE"
  )
fi

GIT_CREDENTIAL_BINDS=()
[ -d "$GIT_CREDENTIAL_STORE_DIR" ] && GIT_CREDENTIAL_BINDS+=(--bind "$GIT_CREDENTIAL_STORE_DIR" "$GIT_CREDENTIAL_STORE_DIR")

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

[ -d /etc/ca-certificates ] && BASE_BINDS+=(--ro-bind-try /etc/ca-certificates /etc/ca-certificates)
[ -d /etc/pki ] && BASE_BINDS+=(--ro-bind-try /etc/pki /etc/pki)
BASE_BINDS+=(--ro-bind-try "$HOME/.ssh/known_hosts" "$HOME/.ssh/known_hosts")
BASE_BINDS+=(--ro-bind-try /usr/bin/gpg /usr/bin/gpg)
BASE_BINDS+=(--ro-bind-try "$HOME/.gitconfig" "$HOME/.gitconfig")
BASE_BINDS+=(--ro-bind-try "$HOME/.local" "$HOME/.local")
[ -d "$HOME/.npm" ] && BASE_BINDS+=(--bind "$HOME/.npm" "$HOME/.npm")
[ -d "$PWD" ] && BASE_BINDS+=(--bind "$PWD" "$PWD")

[ -n "${OPENAI_API_KEY:-}" ] && BASE_BINDS+=(--setenv OPENAI_API_KEY "$OPENAI_API_KEY")
[ -n "${OPENAI_BASE_URL:-}" ] && BASE_BINDS+=(--setenv OPENAI_BASE_URL "$OPENAI_BASE_URL")
[ -n "${ANTHROPIC_API_KEY:-}" ] && BASE_BINDS+=(--setenv ANTHROPIC_API_KEY "$ANTHROPIC_API_KEY")

exec bwrap \
  "${BASE_BINDS[@]}" \
  "${CUDA_ENV[@]}" \
  "${GPU_DEVICE_BINDS[@]}" \
  "${SSH_BINDS[@]}" \
  "${SSH_PUBKEY_BINDS[@]}" \
  "${GPG_ENV[@]}" \
  "${OPTIONAL_BINDS[@]}" \
  "${WRITABLE_BINDS[@]}" \
  "${LATEX_RO_BINDS[@]}" \
  "${LATEX_RW_BINDS[@]}" \
  "${STATE_BINDS[@]}" \
  "${GIT_CREDENTIAL_BINDS[@]}" \
  "${GPG_BINDS[@]}" \
  "${DBUS_BINDS[@]}" \
  "${KEYRING_BINDS[@]}" \
  "${GIT_ENV[@]}" \
  "${SSH_ENV[@]}" \
  "${DBUS_ENV[@]}" \
  "$TOOL_BIN" "${TOOL_EXTRA_ARGS[@]}" "${TOOL_ARGS[@]}"
