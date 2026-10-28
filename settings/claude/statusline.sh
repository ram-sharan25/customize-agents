#!/bin/sh
input=$(cat)

# Context window usage
used=$(echo "$input" | jq -r '.context_window.used_percentage // empty')

# Rate limits
five=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty')
week=$(echo "$input" | jq -r '.rate_limits.seven_day.used_percentage // empty')

# Build output
out=""

if [ -n "$used" ]; then
  out=$(printf "\033[33mctx:%.0f%%\033[0m" "$used")
fi

if [ -n "$five" ] || [ -n "$week" ]; then
  limits=""
  [ -n "$five" ] && limits="5h:$(printf '%.0f' "$five")%"
  [ -n "$week" ] && limits="${limits:+$limits }7d:$(printf '%.0f' "$week")%"
  out="${out:+$out }$(printf "\033[36m%s\033[0m" "$limits")"
fi

printf "%s" "$out"
