#!/usr/bin/env bash
# Sync the Logos Wallet modules to their release-mirror repos.
#
# Development happens here (the logos-workshop monorepo); the module
# catalog at hackyguru/logos-modules consumes one repo per module, so
# each module dir is mirrored with `git subtree split`:
#
#   logos-wallet/logos-wallet-core → github.com/hackyguru/logos-wallet-core
#   logos-wallet/logos-wallet-ui   → github.com/hackyguru/logos-wallet-ui
#
# Run after committing wallet changes, before cutting a catalog release:
#
#   ./scripts/sync-wallet-modules.sh
#
# Then bump the submodule pointers in hackyguru/logos-modules and run the
# release workflows (./scripts/catalog.sh release-all over there).
#
# Force-push is intentional: the mirrors are read-only build inputs whose
# history is always regenerated from this repo — never commit to them
# directly.

set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

MODULES=(
  "logos-wallet/logos-wallet-core:https://github.com/hackyguru/logos-wallet-core.git"
  "logos-wallet/logos-wallet-ui:https://github.com/hackyguru/logos-wallet-ui.git"
)

for entry in "${MODULES[@]}"; do
  prefix="${entry%%:*}"
  url="${entry#*:}"
  branch="split/$(basename "${prefix}")"
  echo "==> splitting ${prefix}"
  git subtree split -P "${prefix}" -b "${branch}"
  echo "==> pushing to ${url}"
  git push --force "${url}" "${branch}:refs/heads/main"
done

echo "done — mirrors updated."
