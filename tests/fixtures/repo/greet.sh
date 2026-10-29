#!/bin/sh
# greet NAME — print a greeting for NAME.
greet() {
  printf 'Hello, %s!\n' "$1"
}

[ "${0##*/}" = greet.sh ] && greet "$@"
