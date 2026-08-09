#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

SHARED="$REPO_ROOT/server/shared/jwt.gd"
GATEWAY="$REPO_ROOT/server/gateway/scripts/jwt.gd"
MASTER="$REPO_ROOT/server/master/scripts/jwt.gd"

FAIL=0

for f in "$SHARED" "$GATEWAY" "$MASTER"; do
  if [[ ! -f "$f" ]]; then
    echo "FAIL: missing $f"
    FAIL=1
  fi
done

if [[ $FAIL -eq 1 ]]; then
  exit 1
fi

if ! diff -q "$SHARED" "$GATEWAY" > /dev/null 2>&1; then
  echo "FAIL: server/gateway/scripts/jwt.gd differs from server/shared/jwt.gd"
  FAIL=1
fi

if ! diff -q "$SHARED" "$MASTER" > /dev/null 2>&1; then
  echo "FAIL: server/master/scripts/jwt.gd differs from server/shared/jwt.gd"
  FAIL=1
fi

if [[ $FAIL -eq 1 ]]; then
  echo "Run: cp server/shared/jwt.gd server/gateway/scripts/jwt.gd server/master/scripts/jwt.gd"
  exit 1
fi

echo "OK: all jwt.gd copies are byte-identical"
exit 0
