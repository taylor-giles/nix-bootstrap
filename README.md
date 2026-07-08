# nix-bootstrap

Bootstrap script for provisioning a new NixOS host from a live installer session.

## Prerequisites

- The target host's configuration must already exist in the nix-config repo (`hosts/<hostname>/`)
- `NIX_CONFIG_DIR` must be set in `hosts/<hostname>/default.nix` (e.g. `/home/taylor/nix-config`)
- Run from a NixOS live installer with the target disk mounted at `/mnt`

## Usage

```sh
./bootstrap.sh <hostname>
```

The repo URL is read from `git-repo-creds.age` if present, otherwise prompted interactively.

## What it does

1. Clones the nix-config repo at `<repo-url>` and runs `nixos-install`
2. Sets passwords for all normal users
3. Generates an age keypair for agenix — private key written to `/mnt/etc/age/host.key`, public key committed to `hosts/<hostname>/age-key.pub`
4. Commits hardware config and age key to a branch named `<hostname>-bootstrap` and pushes it

After the script completes:
- Merge `<hostname>-bootstrap` into master on the remote
- Reboot into the installed system
- On an existing host, run `nix-reencrypt` to grant the new host access to secrets, then push
- On the new host, run `nix-rebuild`

> **Note:** The new host cannot decrypt agenix secrets until `nix-reencrypt` has been run on an existing host and the result pushed and pulled.

## Git credentials

`git-repo-creds.age` sits alongside this script and holds credentials for cloning and pushing the (private) nix-config repo. It is passphrase-encrypted with `age -p` — no keys required, just the passphrase at the terminal.

### To create or rotate:

```sh
age -p -o git-repo-creds.age
```

Then enter at the prompt:

```
url=https://github.com/you/nix-config
username=<git-username>
password=<token>
```

Press `Ctrl+D` when done. Commit and push the updated file.
