#!/usr/bin/env bash
# Fetches Holdfast at the pinned commit and builds its page, which the node then
# serves (ADR 0011). Its k6 storm comes with it. A bump is a reviewed change here.
# Nothing of it is copied into this repo: vendor/ is ignored.
#
# Needs Node 26 or later and pnpm (the version Holdfast's package.json names).
set -euo pipefail
cd "$(dirname "$0")/.."

REPO=https://github.com/djwirz/holdfast.git
COMMIT=427109f8813b6f72a7bb0b8bd42b6033bf250756
DIR=vendor/holdfast

node -e 'process.exit(Number(process.versions.node.split(".")[0]) >= 26 ? 0 : 1)' || {
  echo "Node 26 or later is needed (with fnm: fnm exec --using 26 scripts/fetch-page.sh)" >&2
  exit 1
}

if [ ! -d "$DIR/.git" ]; then
  git init -q "$DIR"
  git -C "$DIR" remote add origin "$REPO"
fi
git -C "$DIR" fetch -q --depth 1 origin "$COMMIT"
git -C "$DIR" checkout -q --detach "$COMMIT"

cd "$DIR"
# pnpm also installs the workspace root's tools, which the page doesn't need and one
# of which downloads a binary when installed. The page needs no install scripts.
pnpm install --frozen-lockfile --ignore-scripts --filter '@holdfast/web...'
pnpm --filter @holdfast/web build
