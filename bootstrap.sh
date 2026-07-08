#!/usr/bin/env bash
# Fresh-install bootstrap for NixOS. See README.md for usage and prerequisites.
#
# Usage: ./bootstrap.sh <hostname>

set -euo pipefail

# Preflight checks — fail fast before touching anything
if [ "$(id -u)" -ne 0 ]; then
  echo "error: must be run as root" >&2
  exit 1
fi

if ! mountpoint -q /mnt; then
  echo "error: /mnt is not mounted — partition and mount the target disk first" >&2
  exit 1
fi

# Refuses to run if machine is already bootstrapped
if [ -e /etc/age/host.key ]; then
  echo "error: /etc/age/host.key already exists on this machine." >&2
  echo "This host has already been bootstrapped - re-running bootstrap.sh is not supported." >&2
  echo "To regenerate hardware-configuration.nix or a missing agenix key, use 'nix-regen-host' instead." >&2
  exit 1
fi

if [ "$#" -ne 1 ]; then
  echo "Usage: $0 <hostname>" >&2
  exit 1
fi

HOSTNAME="$1"
REPO_URL=""
HOST_FILE_REL="hosts/$HOSTNAME/default.nix"

export NIX_CONFIG="experimental-features = nix-command flakes"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TMPDIR="$(mktemp -d)"
CRED_HELPER=""
trap 'rm -rf "$TMPDIR" ${CRED_HELPER:+"$CRED_HELPER"}' EXIT

# Set up git credentials from passphrase-encrypted secret if present.
# git-repo-creds.age lives alongside this script in the bootstrap repo and is
# encrypted with 'age -p' so it can be decrypted with just a passphrase —
# no keys required on the new host.
CREDS_SECRET="$SCRIPT_DIR/git-repo-creds.age"
if [ -f "$CREDS_SECRET" ]; then
  echo "Decrypting git-repo-creds.age (you will be prompted for the passphrase)..."
  DECRYPTED="$(nix shell nixpkgs#age --command age -d "$CREDS_SECRET")"

  GIT_CRED_USERNAME=""
  GIT_CRED_PASSWORD=""
  while IFS='=' read -r key value; do
    case "$key" in
      username) GIT_CRED_USERNAME="$value" ;;
      password) GIT_CRED_PASSWORD="$value" ;;
      url)      REPO_URL="$value" ;;
    esac
  done <<< "$DECRYPTED"

  if [ -n "$GIT_CRED_USERNAME" ] && [ -n "$GIT_CRED_PASSWORD" ]; then
    export GIT_CRED_USERNAME GIT_CRED_PASSWORD
    CRED_HELPER="$(mktemp)"
    cat > "$CRED_HELPER" << 'HELPER_EOF'
#!/bin/sh
printf 'username=%s\npassword=%s\n' "$GIT_CRED_USERNAME" "$GIT_CRED_PASSWORD"
HELPER_EOF
    chmod +x "$CRED_HELPER"
    git config --global credential.helper "$CRED_HELPER"
    echo "Git credentials configured from git-repo-creds.age."
  else
    echo "warning: git-repo-creds.age decrypted but missing username= or password= lines; proceeding without configured credentials." >&2
  fi
fi

if [ -z "$REPO_URL" ]; then
  read -rp "Repo URL: " REPO_URL
fi

# Clone to a temp dir first so we can read NIX_CONFIG_DIR from the host config
git clone "$REPO_URL" "$TMPDIR/repo"

if [ ! -d "$TMPDIR/repo/hosts/$HOSTNAME" ]; then
  echo "error: hosts/$HOSTNAME does not exist in $REPO_URL" >&2
  echo "Create and push that host's configuration first, then re-run this script." >&2
  exit 1
fi

# Read install directory from the host config
DIRECTORY="$(grep -oP 'NIX_CONFIG_DIR\s*=\s*"\K[^"]+' "$TMPDIR/repo/$HOST_FILE_REL" || true)"

if [ -z "$DIRECTORY" ]; then
  echo "error: NIX_CONFIG_DIR is not set in $HOST_FILE_REL" >&2
  echo "Add 'environment.variables.NIX_CONFIG_DIR = \"/path/to/nix-config\";' to that file and push." >&2
  exit 1
fi

case "$DIRECTORY" in
  /*) ;;
  *)
    echo "error: NIX_CONFIG_DIR in $HOST_FILE_REL must be an absolute path" >&2
    exit 1
    ;;
esac

TARGET_DIR="/mnt$DIRECTORY"

# Overwrite any existing clone at the target location
if [ -e "$TARGET_DIR" ]; then
  rm -rf "$TARGET_DIR"
fi

mkdir -p "$(dirname "$TARGET_DIR")"
mv "$TMPDIR/repo" "$TARGET_DIR"

# Set git identity for all commits made by this script
git -C "$TARGET_DIR" config user.name "NixOS Bootstrap"
git -C "$TARGET_DIR" config user.email ""

# All auto-commits go on a dedicated branch so master isn't pushed directly
BOOTSTRAP_BRANCH="$HOSTNAME-bootstrap"
git -C "$TARGET_DIR" checkout -b "$BOOTSTRAP_BRANCH"

# Generate this host's hardware-configuration.nix and commit it
nixos-generate-config --root /mnt --show-hardware-config \
  > "$TARGET_DIR/hosts/$HOSTNAME/hardware-configuration.nix"

git -C "$TARGET_DIR" add "hosts/$HOSTNAME/hardware-configuration.nix"
git -C "$TARGET_DIR" commit -m "Add hardware-configuration.nix for $HOSTNAME"

# Check early for duplicate host key
HOST_KEY_FILE="$TARGET_DIR/hosts/$HOSTNAME/age-key.pub"
if [ -e "$HOST_KEY_FILE" ]; then
  echo "error: $HOST_KEY_FILE already exists - $HOSTNAME has already been bootstrapped." >&2
  echo "To regenerate hardware-configuration.nix or a missing agenix key on that host, use 'nix-regen-host' instead." >&2
  exit 1
fi

# Do the install
nixos-install --root /mnt --flake "$TARGET_DIR#$HOSTNAME"

# Set passwords for all normal users on the installed system
while IFS=: read -r username _ uid _; do
  if [ "$uid" -ge 1000 ]; then
    echo "Set password for $username:"
    passwd --root /mnt "$username"
  fi
done < /mnt/etc/passwd

install -d -m 700 /mnt/etc/age
rm -f /mnt/etc/age/host.key
nix shell nixpkgs#age --command age-keygen -o /mnt/etc/age/host.key
chmod 600 /mnt/etc/age/host.key
AGE_PUBKEY="$(nix shell nixpkgs#age --command age-keygen -y /mnt/etc/age/host.key)"

# Persist new agenix key
printf '%s\n' "$AGE_PUBKEY" > "$HOST_KEY_FILE"
git -C "$TARGET_DIR" add "hosts/$HOSTNAME/age-key.pub"
git -C "$TARGET_DIR" commit -m "Add agenix key for $HOSTNAME"
git -C "$TARGET_DIR" push origin "$BOOTSTRAP_BRANCH"

# The clone was made as root (from the installer session). Match whoever
# already owns its parent directory (created for the real user during
# nixos-install's activation) rather than requiring a username here.
chown -R --reference="$(dirname "$TARGET_DIR")" "$TARGET_DIR"

echo "Bootstrap complete! Next steps:"
echo "  > Merge branch '$BOOTSTRAP_BRANCH' into master on your git remote"
echo "  > Reboot (out of live boot) and log in"
echo "  > -- Configure secrets --"
echo "    > Run 'nix-reencrypt' on an existing host, then push the new secrets"
echo "    > Run 'nix-rebuild' here"
