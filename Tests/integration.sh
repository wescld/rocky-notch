#!/bin/bash
# Integration harness: real rocky-hook against the real app binary.
# Covers: allow, deny, ask (silent), app down (fail-open latency).
# Usage: Tests/integration.sh  (builds release first)
set -u
cd "$(dirname "$0")/.."

PASS=0; FAIL=0
check() { # name expected actual
  if [ "$2" = "$3" ]; then PASS=$((PASS+1)); echo "ok: $1"
  else FAIL=$((FAIL+1)); echo "FAIL: $1 — esperado [$2], obtido [$3]"; fi
}

swift build -c release >/dev/null 2>&1 || { echo "build falhou"; exit 1; }
HOOK=.build/release/rocky-hook
APP=.build/release/Rocky

pkill -x Rocky; pkill -x Vibenotch 2>/dev/null; sleep 0.5

PR_EVENT='{"session_id":"it","hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"true"}}'

# 1. App down: silent, fast, exit 0.
start=$(python3 -c 'import time; print(time.time())')
out=$(echo "$PR_EVENT" | $HOOK); code=$?
elapsed=$(python3 -c "import time; print(int((time.time()-$start)*1000))")
check "app-down: exit 0" "0" "$code"
check "app-down: sem output" "" "$out"
[ "$elapsed" -lt 500 ] && PASS=$((PASS+1)) && echo "ok: app-down: rápido (${elapsed}ms)" \
  || { FAIL=$((FAIL+1)); echo "FAIL: app-down demorou ${elapsed}ms"; }

# 2-4. allow / deny / ask com o app decidindo automaticamente.
for decision in allow deny ask; do
  ROCKY_AUTODECIDE=$decision ROCKY_HEADLESS=1 $APP >/dev/null 2>&1 &
  APP_PID=$!
  sleep 1.5
  out=$(echo "$PR_EVENT" | $HOOK); code=$?
  kill $APP_PID 2>/dev/null; wait $APP_PID 2>/dev/null
  # O próximo app precisa ver o socket morto para fazer bind (anti-flake).
  sleep 1
  check "$decision: exit 0" "0" "$code"
  case $decision in
    allow|deny)
      echo "$out" | grep -q "\"behavior\":\"$decision\"" && PASS=$((PASS+1)) \
        && echo "ok: $decision: JSON correto" \
        || { FAIL=$((FAIL+1)); echo "FAIL: $decision: output [$out]"; }
      ;;
    ask)
      check "ask: sem output (prompt no terminal)" "" "$out"
      ;;
  esac
done

# 5. Evento fire-and-forget não espera resposta.
ROCKY_HEADLESS=1 $APP >/dev/null 2>&1 & APP_PID=$!
sleep 1.5
out=$(echo '{"session_id":"it","hook_event_name":"Stop"}' | $HOOK); code=$?
kill $APP_PID 2>/dev/null; wait $APP_PID 2>/dev/null
check "stop: exit 0" "0" "$code"
check "stop: sem output" "" "$out"

echo "---"
echo "passou: $PASS, falhou: $FAIL"
[ "$FAIL" -eq 0 ]
