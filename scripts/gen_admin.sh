#!/usr/bin/env bash
#
# Regenerate the OPTIONAL Admin API client (module `Shipeasy::Admin::Generated`)
# from the vendored OpenAPI spec. The generated client is a raw, 1:1 projection of
# `admin/openapi.json` (id-based, basis-points, snake_case) — no name->id or
# percent->bp ergonomics. The hand-written `lib/shipeasy/admin.rb` wrapper (the
# `Shipeasy::Admin::Client` entry point) sits on top and is NEVER touched by this
# script: only the generated `lib/shipeasy_admin.rb` + `lib/shipeasy_admin/` tree
# is replaced.
#
# The generated client is required lazily (only when the admin client is used) and
# its HTTP dependency (faraday) is an OPTIONAL development dependency, mirroring
# the OpenFeature provider — so `require "shipeasy-sdk"` never pulls it in.
#
# Usage:
#   1. Refresh the vendored spec when the contract changes:
#        cp <monorepo>/packages/openapi/openapi.json admin/openapi.json
#   2. Regenerate:
#        bash scripts/gen_admin.sh
#   3. Commit `admin/openapi.json` + `lib/shipeasy_admin.rb` + `lib/shipeasy_admin/`.
#
# Requires Java (for openapi-generator) and npx. Generator pinned in openapitools.json.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SPEC="admin/openapi.json"
BUILD="$(mktemp -d)"
trap 'rm -rf "$BUILD"' EXIT

if [[ ! -f "$SPEC" ]]; then
  echo "error: missing vendored spec at $SPEC — copy it from the monorepo's packages/openapi/openapi.json" >&2
  exit 1
fi

echo "Generating Shipeasy::Admin::Generated from $SPEC ..."
npx --yes @openapitools/openapi-generator-cli generate \
  -i "$SPEC" \
  -g ruby \
  --additional-properties='library=faraday,gemName=shipeasy_admin,moduleName=Shipeasy::Admin::Generated' \
  -o "$BUILD" >/dev/null

if [[ ! -f "$BUILD/lib/shipeasy_admin.rb" ]]; then
  echo "error: generator did not produce lib/shipeasy_admin.rb under $BUILD" >&2
  exit 1
fi

# Replace ONLY the generated tree. The hand-written shim (lib/shipeasy/admin.rb)
# and the rest of lib/ are left intact. The generated files keep their internal
# `require 'shipeasy_admin/...'` paths, which resolve on the gem's load path.
rm -rf lib/shipeasy_admin lib/shipeasy_admin.rb
cp "$BUILD/lib/shipeasy_admin.rb" lib/shipeasy_admin.rb
cp -R "$BUILD/lib/shipeasy_admin" lib/shipeasy_admin

echo "Wrote $(find lib/shipeasy_admin -name '*.rb' | wc -l | tr -d ' ') Ruby files (+ entry) to lib/"
echo "Done. Review the diff and commit admin/openapi.json + lib/shipeasy_admin*."
