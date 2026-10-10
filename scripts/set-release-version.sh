#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${1:-}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Usage: $0 VERSION" >&2; exit 2; }
sed -i "s/NUSAAS_VERSION:-[0-9.]*/NUSAAS_VERSION:-$VERSION/" install.sh
sed -i "s/^NUSAAS_VERSION=.*/NUSAAS_VERSION=$VERSION/" .env.selfhosted
sed -i -E "s/(NuSaaS |Version : |--version '|generated command · NuSaaS )[0-9]+\.[0-9]+\.[0-9]+/\1$VERSION/g" index.html
printf '%s\n' "$VERSION" > VERSION
python3 tests/site-smoke.py
