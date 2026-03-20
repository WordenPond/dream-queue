#!/usr/bin/env bash
# Unit tests for queue manipulation logic used in telegram-receiver.yml
set -euo pipefail

PASS=0
FAIL=0

assert_equals() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc"
    echo "        expected: '$expected'"
    echo "        actual:   '$actual'"
    FAIL=$((FAIL + 1))
  fi
}

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if echo "$haystack" | grep -qF "$needle"; then
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc (missing: '$needle')"
    FAIL=$((FAIL + 1))
  fi
}

assert_not_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if ! echo "$haystack" | grep -qF "$needle"; then
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc (unexpectedly found: '$needle')"
    FAIL=$((FAIL + 1))
  fi
}

make_queue() {
  local tmp
  tmp=$(mktemp -d)
  cat > "$tmp/QUEUE.md" << 'EOF'
# TikketQ Implementation Queue

## Queue
<!-- Add issues below this line -->

## Completed
EOF
  echo "$tmp"
}

find_next() {
  local queue_file="$1"
  awk '/^## Queue/{found=1} found && /^- \[ \] #[0-9]/{print; exit}' "$queue_file" \
    | grep -oP '#\K[0-9]+' || true
}

add_to_queue() {
  local queue_file="$1"
  shift
  for NUM in "$@"; do
    if ! grep -qE "^\- \[.\] #${NUM}$" "$queue_file"; then
      sed -i "/^<!-- Add issues/i - [ ] #${NUM}" "$queue_file"
    fi
  done
}

# ── Find-next-issue ───────────────────────────────────────────────────────────
echo ""
echo "=== find-next-issue ==="

TMP=$(make_queue)
assert_equals "empty queue returns empty" "" "$(find_next "$TMP/QUEUE.md")"

echo "- [ ] #42" >> "$TMP/QUEUE.md"
assert_equals "single pending issue found" "42" "$(find_next "$TMP/QUEUE.md")"

cat > "$TMP/QUEUE.md" << 'EOF'
## Queue
<!-- Add issues below this line -->
- [x] #10
- [ ] #11
EOF
assert_equals "completed issue skipped" "11" "$(find_next "$TMP/QUEUE.md")"

cat > "$TMP/QUEUE.md" << 'EOF'
## Queue
<!-- Add issues below this line -->
- [ ] #5
- [ ] #6
- [ ] #7
EOF
assert_equals "multiple pending — returns first" "5" "$(find_next "$TMP/QUEUE.md")"
rm -rf "$TMP"

# ── Queue-add ordering ────────────────────────────────────────────────────────
echo ""
echo "=== queue add ordering ==="

TMP=$(make_queue)
add_to_queue "$TMP/QUEUE.md" 10
assert_equals "single issue added" "10" "$(find_next "$TMP/QUEUE.md")"

cat > "$TMP/QUEUE.md" << 'EOF'
## Queue
<!-- Add issues below this line -->

## Completed
EOF
for N in 20 21 22; do
  sed -i "/^<!-- Add issues/i - [ ] #${N}" "$TMP/QUEUE.md"
done
assert_equals "first issue added is first in queue" "20" "$(find_next "$TMP/QUEUE.md")"

LINE_20=$(grep -n "^\- \[ \] #20$" "$TMP/QUEUE.md" | cut -d: -f1)
LINE_21=$(grep -n "^\- \[ \] #21$" "$TMP/QUEUE.md" | cut -d: -f1)
LINE_22=$(grep -n "^\- \[ \] #22$" "$TMP/QUEUE.md" | cut -d: -f1)
if [[ "$LINE_20" -lt "$LINE_21" && "$LINE_21" -lt "$LINE_22" ]]; then
  echo "  PASS: queue ordering 20 < 21 < 22"
  PASS=$((PASS + 1))
else
  echo "  FAIL: queue ordering wrong (lines: #20=$LINE_20, #21=$LINE_21, #22=$LINE_22)"
  FAIL=$((FAIL + 1))
fi

# Duplicate not added twice
add_to_queue "$TMP/QUEUE.md" 20
COUNT=$(grep -c "^\- \[ \] #20$" "$TMP/QUEUE.md" || true)
assert_equals "duplicate not added twice" "1" "$COUNT"
rm -rf "$TMP"

# ── Mark complete ─────────────────────────────────────────────────────────────
echo ""
echo "=== mark issue complete ==="

TMP=$(make_queue)
cat > "$TMP/QUEUE.md" << 'EOF'
## Queue
<!-- Add issues below this line -->
- [ ] #15
- [ ] #16
EOF
sed -i "s/^- \[ \] #15$/- [x] #15/" "$TMP/QUEUE.md"
CONTENT=$(cat "$TMP/QUEUE.md")
assert_contains     "issue 15 marked complete"    "- [x] #15" "$CONTENT"
assert_contains     "issue 16 still pending"      "- [ ] #16" "$CONTENT"
assert_not_contains "issue 15 not still pending"  "- [ ] #15" "$CONTENT"
assert_equals "find-next skips #15 returns #16" "16" "$(find_next "$TMP/QUEUE.md")"
rm -rf "$TMP"

# ── Status counts ─────────────────────────────────────────────────────────────
echo ""
echo "=== status counts ==="

TMP=$(make_queue)
cat > "$TMP/QUEUE.md" << 'EOF'
## Queue
<!-- Add issues below this line -->
- [x] #1
- [x] #2
- [ ] #3
- [ ] #4
- [ ] #5
EOF
PENDING=$(grep -c '^- \[ \]' "$TMP/QUEUE.md" 2>/dev/null || echo 0)
DONE=$(grep -c '^- \[x\]' "$TMP/QUEUE.md" 2>/dev/null || echo 0)
assert_equals "pending count"   "3" "$PENDING"
assert_equals "completed count" "2" "$DONE"
rm -rf "$TMP"

# ── Pause flag ────────────────────────────────────────────────────────────────
echo ""
echo "=== pause flag ==="

TMP=$(make_queue)
if [ ! -f "$TMP/.queue-paused" ]; then
  echo "  PASS: no pause file means not paused"
  PASS=$((PASS + 1))
else
  echo "  FAIL: unexpected .queue-paused file"
  FAIL=$((FAIL + 1))
fi

touch "$TMP/.queue-paused"
[ -f "$TMP/.queue-paused" ] && { echo "  PASS: pause file detected"; PASS=$((PASS+1)); } \
  || { echo "  FAIL: pause file not detected"; FAIL=$((FAIL+1)); }

rm "$TMP/.queue-paused"
[ ! -f "$TMP/.queue-paused" ] && { echo "  PASS: resume removes pause file"; PASS=$((PASS+1)); } \
  || { echo "  FAIL: pause file still present"; FAIL=$((FAIL+1)); }
rm -rf "$TMP"

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
echo ""
[[ "$FAIL" -gt 0 ]] && exit 1 || exit 0
