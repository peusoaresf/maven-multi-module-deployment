#!/usr/bin/env bash
set -euo pipefail

assert_eq() {
    local expected="$1"
    local actual="$2"

    if [[ "$actual" != "$expected" ]]; then
        printf 'FAIL: expected <%s>, got <%s>\n' "$expected" "$actual" >&2
        exit 1
    fi
}

assert_eq "minor" \
    "$(make -s msg-to-level msg='feat: add endpoint')"

assert_eq "true" \
  "$(make -s files-touch-module module=core files='api/pom.xml core/src/App.java')"

assert_eq "false" \
  "$(make -s files-touch-module module=api files='pom.xml core/pom.xml')"

assert_eq "true" \
  "$(make -s files-touch-module module=. files='pom.xml api/pom.xml')"

assert_eq "false" \
  "$(make -s files-touch-module module=. files='core/pom.xml api/pom.xml')"

assert_eq "2.0.0" \
  "$(make -s calculate-bump-version current=1.2.3-SNAPSHOT level=major)"

printf 'All Makefile tests passed.\n'
