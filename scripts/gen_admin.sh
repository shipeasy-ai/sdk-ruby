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
#        cp <monorepo>/marketplace/openapi/openapi.json admin/openapi.json
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
  echo "error: missing vendored spec at $SPEC — copy it from the monorepo's marketplace/openapi/openapi.json" >&2
  exit 1
fi

# OpenAPI version-compat shim. The pinned openapi-generator (openapitools.json)
# bundles a swagger-parser that cannot parse OpenAPI >= 3.2 (it NPEs before
# codegen). The canonical admin spec is emitted as 3.2.x, but its *content* is
# 3.1-compatible — only the version label is ahead of the parser. Pin the label
# down to 3.1.0 (byte-preserving: only the version token changes) so the vendored
# spec is consumable. Harmless no-op when the spec is already <= 3.1.
perl -0pi -e 's/("openapi"\s*:\s*")3\.[2-9]\.\d+(")/${1}3.1.0${2}/' "$SPEC"

echo "Generating Shipeasy::Admin::Generated from $SPEC ..."
# --skip-validate-spec: the leniently-parsed 3.2-labelled spec trips the strict
# validator (spurious "unexpected"/"missing" errors); the codegen model builder
# handles the 3.1-expressible surface correctly, so skip validation.
npx --yes @openapitools/openapi-generator-cli generate \
  -i "$SPEC" \
  -g ruby \
  --skip-validate-spec \
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
