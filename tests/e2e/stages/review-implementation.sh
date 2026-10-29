# e2e: review-implementation against a staged, correct implementation.
setup() {
  cat > "$REPO/greet.sh" <<'SH'
#!/bin/sh
# greet [--shout] NAME — print a greeting for NAME.
greet() {
  if [ "$1" = --shout ]; then
    shift
    printf 'Hello, %s!\n' "$1" | tr '[:lower:]' '[:upper:]'
  else
    printf 'Hello, %s!\n' "$1"
  fi
}

[ "${0##*/}" = greet.sh ] && greet "$@"
SH
  awk '{print} /^check "\$\(greet Ada\)"/ {print "check \"$(greet --shout Ada)\" \"HELLO, ADA!\""}' \
    "$REPO/test.sh" > "$REPO/test.sh.new" && mv "$REPO/test.sh.new" "$REPO/test.sh"
  git -C "$REPO" add greet.sh test.sh
}
check() {
  f=$(ls "$TASK"/artifacts/*review-implementation*/findings.md 2>/dev/null | head -1)
  [[ -n "$f" ]] || { fail "no findings.md under artifacts/"; return; }
  for k in Missing Extra Misunderstood "Declined to judge"; do require_text "$f" "$k"; done
  require_regex "$f" "Shouting is a flag"
  require_regex "$f" "\b(met|not met)\b"
  [[ -n "$(git -C "$REPO" diff --cached --name-only)" ]] || fail "the review changed the staged work"
  require_next 'implement-plan'
}
