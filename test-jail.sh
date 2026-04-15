#!/usr/bin/env bash
#
# test-jail.sh — verify the sbx-helpers and per-agent profile wrappers.
#
# Run this from inside a fresh `flox activate` subshell in ~/dev/sbx,
# AFTER the manifest changes have taken effect. Profile functions
# (sbx-here, claude-jail, etc.) are only available in such a subshell;
# running this script via `flox activate -- ./test-jail.sh` will miss
# the profile tests.
#
# The script probes sbx-run / sbx-cwd / sbx-agent with real workloads
# (pipes, command substitution, background jobs, TCP connects), then
# tests a handful of representative profile wrappers (claude-jail,
# copilot-jail, codex-jail) against a fake agent binary placed on PATH
# so we don't need the real tools installed.
#
# Exit status is 0 if every assertion passed, 1 otherwise.

set -u

# Guard: must be run from inside a flox-activated shell so $FLOX_ENV
# resolves to the env's run dir (where the profile file lives).
if [[ -z "${FLOX_ENV:-}" ]]; then
  printf 'error: FLOX_ENV is not set. Run this inside a `flox activate` subshell in ~/dev/sbx.\n' >&2
  exit 2
fi

# Profile functions (sbx-here, claude-jail, ...) are defined in the
# parent interactive shell but are NOT exported to child bashes. Source
# the profile file explicitly so this script sees them.
profile_file="$FLOX_ENV/activate.d/profile-common"
if [[ ! -r "$profile_file" ]]; then
  printf 'error: profile file not readable: %s\n' "$profile_file" >&2
  exit 2
fi
# shellcheck disable=SC1090
source "$profile_file"

pass=0
fail=0
skip=0

# run_pass LABEL CMD...      — expect success (rc 0)
# run_fail LABEL CMD...      — expect failure (rc != 0)
# run_match LABEL NEEDLE CMD — expect stdout+stderr to contain NEEDLE
_record_pass() { printf '  \033[32m[PASS]\033[0m %s\n' "$1"; pass=$((pass + 1)); }
_record_fail() { printf '  \033[31m[FAIL]\033[0m %s\n' "$1"; printf '         %s\n' "$2"; fail=$((fail + 1)); }
_record_skip() { printf '  \033[33m[SKIP]\033[0m %s\n' "$1"; printf '         %s\n' "$2"; skip=$((skip + 1)); }

run_pass() {
  local label="$1"; shift
  local out rc
  out=$("$@" 2>&1); rc=$?
  if [[ $rc -eq 0 ]]; then
    _record_pass "$label"
  else
    _record_fail "$label" "rc=$rc out=${out:0:200}"
  fi
}

run_fail() {
  local label="$1"; shift
  local out rc
  out=$("$@" 2>&1); rc=$?
  if [[ $rc -ne 0 ]]; then
    _record_pass "$label (denied, rc=$rc)"
  else
    _record_fail "$label" "expected failure but rc=0, out=${out:0:200}"
  fi
}

run_match() {
  local label="$1"; shift
  local needle="$1"; shift
  local out rc
  out=$("$@" 2>&1); rc=$?
  if [[ "$out" == *"$needle"* ]]; then
    _record_pass "$label"
  else
    _record_fail "$label" "needle not found (rc=$rc). out=${out:0:200}"
  fi
}

section() { printf '\n\033[1m### %s ###\033[0m\n' "$1"; }

# --- presence checks ------------------------------------------------

section "presence: binaries and profile functions"

for bin in sbx-run sbx-cwd sbx-agent; do
  if path=$(command -v "$bin" 2>/dev/null); then
    _record_pass "$bin on PATH ($path)"
  else
    _record_fail "$bin on PATH" "not found — is the runtime env activated?"
  fi
done

for fn in sbx-here claude-jail codex-jail gemini-jail copilot-jail \
          crush-jail opencode-jail openclaw-jail nullclaw-jail \
          zeroclaw-jail nanobot-jail nanocoder-jail; do
  if type "$fn" >/dev/null 2>&1; then
    _record_pass "$fn defined"
  else
    _record_fail "$fn defined" "profile function missing — did you exit and re-enter flox activate?"
  fi
done

# Identity check: confirm the new sbx-agent is what we think it is.
if sbx-agent --help 2>&1 | grep -q 'sandbox-exec prints a deprecation'; then
  _record_pass "sbx-agent --help fingerprint matches rewritten version"
else
  _record_fail "sbx-agent --help fingerprint" "help text missing expected string"
fi

# --- sbx-run --------------------------------------------------------

section "sbx-run"

run_pass "single command" sbx-run git --version
run_pass "sh pipe (fork)" sbx-run sh -c 'cat /etc/hosts | head -1'
run_pass "command substitution" sbx-run sh -c 'x=$(date +%Y); echo "$x" | wc -c'
run_pass "background jobs" sbx-run sh -c 'sleep 0.1 & sleep 0.1 & wait; echo done'
run_fail "write denied (PWD)" sbx-run sh -c 'echo hi > /tmp/sbx-run-write-denied.$$'
run_fail "network denied (TCP)" sbx-run bash -c 'exec 3<>/dev/tcp/1.1.1.1/443'

# --- sbx-cwd --------------------------------------------------------

section "sbx-cwd"

scratch=$(mktemp -d -t sbx-jail-scratch.XXXXXX)
trap 'rm -rf "$scratch" 2>/dev/null' EXIT
# Use pushd/popd, not (cd ... ), because a subshell's pass/fail
# counter increments don't propagate back to the parent.
pushd "$scratch" >/dev/null
run_pass "write inside PWD"   sbx-cwd sh -c 'echo ok > in.txt && test -s in.txt'
run_pass "write inside TMPDIR" sbx-cwd sh -c 'f="$TMPDIR/sbx-jail-tmp.$$"; echo ok > "$f" && test -s "$f" && rm "$f"'
run_fail "write outside scope" sbx-cwd sh -c 'echo nope > /etc/sbx-leak.$$'
run_fail "network denied"     sbx-cwd bash -c 'exec 3<>/dev/tcp/1.1.1.1/443'
popd >/dev/null

# --- sbx-agent ------------------------------------------------------

section "sbx-agent: fork-heavy workloads"

run_pass "pipe"              sbx-agent -- sh -c 'cat /etc/hosts | head -1'
run_pass "command subst"     sbx-agent -- sh -c 'echo $(date) | wc -w'
run_pass "background + wait" sbx-agent -- sh -c 'sleep 0.1 & sleep 0.1 & wait; echo done'

section "sbx-agent: file writes"

pushd "$scratch" >/dev/null
run_pass '$PWD writable'   sbx-agent -- sh -c 'echo a > agent-pwd.txt && test -s agent-pwd.txt'
run_pass '$TMPDIR writable' sbx-agent -- sh -c 'f="$TMPDIR/sbx-agent-tmp.$$"; echo a > "$f" && test -s "$f" && rm "$f"'
run_fail '$TMPDIR denied with --no-tmpdir' sbx-agent --no-tmpdir -- sh -c 'echo nope > "$TMPDIR/no-tmpdir.$$"'
popd >/dev/null

extra_dir=$(mktemp -d -t sbx-jail-extra.XXXXXX)
run_pass "--write <extra> allows writes in that dir" \
  sbx-agent --write "$extra_dir" -- sh -c "echo extra > '$extra_dir/extra.txt' && test -s '$extra_dir/extra.txt'"
rm -rf "$extra_dir"

section "sbx-agent: network modes"

run_pass "--net allow permits TCP to 1.1.1.1:443" \
  sbx-agent --net allow -- bash -c 'exec 3<>/dev/tcp/1.1.1.1/443'
run_fail "--net block denies TCP to 1.1.1.1:443" \
  sbx-agent --net block -- bash -c 'exec 3<>/dev/tcp/1.1.1.1/443'
run_pass "--net '*:443' permits port 443 globally" \
  sbx-agent --net '*:443' -- bash -c 'exec 3<>/dev/tcp/1.1.1.1/443'
run_fail "--net '*:443' denies port 80" \
  sbx-agent --net '*:443' -- bash -c 'exec 3<>/dev/tcp/1.1.1.1/80'
run_fail "--net rejects numeric IP literal (SBPL limitation)" \
  sbx-agent --net 1.1.1.1:443 -- true
run_fail "--net rejects DNS names" sbx-agent --net example.com:443 -- true
run_fail "--net rejects CIDR"      sbx-agent --net 10.0.0.0/24 -- true
run_fail "--net rejects bad port"  sbx-agent --net '*:abc' -- true

section "sbx-agent: --strict-reads mode"

# Fork-heavy ops must still work under the Birdcage-derived deny-default
# preamble (the whole point of adopting that preamble was (allow process-fork)).
run_pass "strict + pipe"       sbx-agent --strict-reads -- sh -c 'cat /etc/hosts | head -1'
run_pass "strict + cmdsubst"   sbx-agent --strict-reads -- sh -c 'echo $(date) | wc -w'
run_pass "strict + background" sbx-agent --strict-reads -- sh -c 'sleep 0.1 & sleep 0.1 & wait; echo done'

# Read-side isolation — the gap strict mode exists to close.
# cat exits 1 when the file can't be read, so the outer rc is 1.
run_fail "strict denies \$HOME/.ssh read" \
  sbx-agent --strict-reads -- sh -c 'cat "$HOME/.ssh/id_ed25519"'
run_fail "strict denies ls \$HOME" \
  sbx-agent --strict-reads -- sh -c 'ls "$HOME"'

# --read opens a specific read path that would otherwise be denied.
# Note: use /tmp (→ /private/tmp) instead of mktemp -t which puts the
# dir under $TMPDIR, and $TMPDIR is already in the default allowlist —
# that would make the test trivially pass even without --read.
strict_scratch=$(mktemp -d /tmp/sbx-strict-read.XXXXXX)
echo secret > "$strict_scratch/data.txt"
run_match "strict + --read opens that path" \
  "secret" \
  sbx-agent --strict-reads --read "$strict_scratch" -- cat "$strict_scratch/data.txt"
# Without --read, reading that path is denied (strict_scratch is under
# /private/tmp, which is NOT in the strict-mode default allowlist).
run_fail "strict denies dir without matching --read" \
  sbx-agent --strict-reads -- cat "$strict_scratch/data.txt"
rm -rf "$strict_scratch"

# --write in strict mode must also grant read on that path, so tools
# can read existing files before modifying them. Same /tmp trick so
# the test isn't trivially satisfied by $TMPDIR's default allowance.
strict_rw=$(mktemp -d /tmp/sbx-strict-rw.XXXXXX)
echo existing > "$strict_rw/old.txt"
run_match "strict + --write implies read" \
  "existing" \
  sbx-agent --strict-reads --write "$strict_rw" -- cat "$strict_rw/old.txt"
run_pass "strict + --write still writes" \
  sbx-agent --strict-reads --write "$strict_rw" -- sh -c "echo new > '$strict_rw/new.txt' && test -s '$strict_rw/new.txt'"
rm -rf "$strict_rw"

# Network modes still work the same way in strict mode.
run_pass "strict + --net allow permits TCP" \
  sbx-agent --strict-reads --net allow -- bash -c 'exec 3<>/dev/tcp/1.1.1.1/443'
run_fail "strict + --net block denies TCP" \
  sbx-agent --strict-reads --net block -- bash -c 'exec 3<>/dev/tcp/1.1.1.1/443'
run_pass "strict + --net '*:443' permits port 443" \
  sbx-agent --strict-reads --net '*:443' -- bash -c 'exec 3<>/dev/tcp/1.1.1.1/443'
run_fail "strict + --net '*:443' denies port 80" \
  sbx-agent --strict-reads --net '*:443' -- bash -c 'exec 3<>/dev/tcp/1.1.1.1/80'

# --read is a no-op in non-strict mode; sbx-agent warns on stderr.
run_match "non-strict + --read warns it is a no-op" \
  "no effect without --strict-reads" \
  sbx-agent --read /tmp -- true

section "sbx-agent: argument validation"

run_fail "no command after --"          sbx-agent --
run_fail "positional before --"         sbx-agent foo -- true
run_fail "--net requires argument"      sbx-agent --net
run_fail "--write requires argument"    sbx-agent --write
run_fail "--read requires argument"     sbx-agent --read
run_fail "--passenv requires argument"  sbx-agent --passenv
run_fail "--timeout requires argument"  sbx-agent --timeout
run_fail "--max-cpu requires argument"  sbx-agent --max-cpu
run_fail "--max-procs requires argument" sbx-agent --max-procs
run_fail "--max-files requires argument" sbx-agent --max-files
run_fail "--audit-log requires argument" sbx-agent --audit-log
run_fail "--net-allow-host requires argument" sbx-agent --net-allow-host
run_fail "--max-mem no longer accepted"  sbx-agent --max-mem 4G -- true

section "sbx-agent: --net-allow-host (HTTPS proxy mode)"

# The hardened sbx-proxy blocks dials to loopback, private, link-local,
# multicast, and reserved CIDR ranges (SSRF guard). That's a security
# feature: it prevents the proxy from becoming an oracle against
# internal services via DNS tricks. It also means we CANNOT test
# positive byte-loopback end-to-end in offline mode — pointing the
# allowlist at 127.0.0.1 causes the SSRF guard to refuse the dial.
#
# Positive byte-loopback IS tested by the Go unit suite in main_test.go
# via TestHandleConnectTunnelsPayloadAndUsesClean200, which injects a
# fake resolveAndDialFunc that returns a net.Pipe. That runs during
# `flox build sbx-proxy`'s checkPhase, so it's always verified fresh.
#
# The bash tests below cover what only bash can: the sbx-agent ↔
# sbx-proxy lifecycle, env injection, sandbox interaction, audit logs,
# and the deny paths which short-circuit before the SSRF guard is
# reached.

# We use allowed.example.test as the allowlist entry throughout. It's
# a valid hostname per RFC 2606 but won't resolve, so even if a test
# accidentally reaches the dial step it fails cleanly at resolve time.
proxy_test_host="allowed.example.test"

trap_str=$(trap -p EXIT | sed "s/^trap -- '//;s/' EXIT\$//")
trap "$trap_str; pkill -f 'sbx-proxy --listen' 2>/dev/null" EXIT

# --net-allow-host and --net are mutually exclusive.
run_fail "--net and --net-allow-host conflict" \
  sbx-agent --net allow --net-allow-host example.com -- true

# HTTPS_PROXY is injected into the sandboxed child.
run_match "proxy mode injects HTTPS_PROXY into child env" \
  "http://127.0.0.1:" \
  sbx-agent --net-allow-host "$proxy_test_host" -- sh -c 'echo "$HTTPS_PROXY"'

# Child sees HTTPS_PROXY even with --passenv-all.
run_match "proxy mode injects HTTPS_PROXY under --passenv-all" \
  "http://127.0.0.1:" \
  sbx-agent --net-allow-host "$proxy_test_host" --passenv-all -- sh -c 'echo "$HTTPS_PROXY"'

# CONNECT to a non-allowlisted host returns 403 from the proxy before
# any dial is attempted. Safe to run regardless of SSRF hardening.
# Uses /usr/bin/nc (macOS-native, no Command Line Tools needed) to
# speak raw HTTP to the proxy — python3 is not available on stock
# macOS without CLT installed.
proxy_deny_out=$(sbx-agent --net-allow-host "$proxy_test_host" --passenv-all -- bash -c '
authority="${HTTPS_PROXY#http://}"
phost="${authority%:*}"
pport="${authority#*:}"
printf "CONNECT blocked.example.com:443 HTTP/1.1\r\nHost: blocked.example.com:443\r\n\r\n" \
  | /usr/bin/nc -w 2 "$phost" "$pport"
' 2>&1)
[[ "$proxy_deny_out" == *"403"* ]] && _record_pass "proxy returns 403 for non-allowlisted host" \
  || _record_fail "proxy 403 deny" "out=${proxy_deny_out:0:200}"

# Non-CONNECT method returns 405.
proxy_405_out=$(sbx-agent --net-allow-host "$proxy_test_host" --passenv-all -- bash -c '
authority="${HTTPS_PROXY#http://}"
phost="${authority%:*}"
pport="${authority#*:}"
printf "GET / HTTP/1.1\r\nHost: example.com\r\n\r\n" \
  | /usr/bin/nc -w 2 "$phost" "$pport"
' 2>&1)
[[ "$proxy_405_out" == *"405"* ]] && _record_pass "proxy returns 405 for non-CONNECT method" \
  || _record_fail "proxy 405" "out=${proxy_405_out:0:200}"

# Raw TCP to a non-proxy port is blocked by the sandbox (not by the
# proxy). The agent can only reach localhost:<proxy_port>; any other
# destination is denied by the kernel.
run_fail "sandbox denies direct TCP when proxy mode is active" \
  sbx-agent --net-allow-host "$proxy_test_host" --passenv-all -- \
  bash -c 'exec 3<>/dev/tcp/127.0.0.1/65530'

# SSRF hardening regression: even if the allowlist accepts a hostname
# whose resolution lands on loopback, the dial is refused.
#
# We use /usr/bin/curl (macOS-native, no CLT required) with --proxy
# to drive a real TLS handshake through the proxy to "localhost:443".
# Curl sends CONNECT, receives 200, then begins TLS with SNI=localhost
# (which matches the allowlisted target, so the proxy advances past
# the SNI check). The proxy then dials upstream, hits the SSRF guard
# because 127.0.0.1 is loopback, and refuses. We check the proxy log
# for the denial marker.
tmp_ssrf=$(mktemp -d)
FLOX_ENV_CACHE="$tmp_ssrf" sbx-agent --net-allow-host localhost --passenv-all -- bash -c '
authority="${HTTPS_PROXY#http://}"
/usr/bin/curl -sS -o /dev/null \
  --proxy "http://$authority" \
  --max-time 5 \
  -k \
  https://localhost:443/ 2>/dev/null || true
' >/dev/null 2>&1 || true
sleep 0.3
# Tight regex: require a single log line that proves the proxy
# reached the dial step AND isSafeRemoteIP rejected the resolved IP.
# `dial_failed_after_client_ok` begins with `dial_failed`, so the
# prefix matches either the SNI-off or the SNI-enforced code path.
# The err field must also contain `blocked`, which is the marker
# appended by resolveAndDial for IPs the SSRF guard refuses. An
# unrelated deny (tls_sni_parse, not_in_allowlist, parse_err) will
# NOT match because neither reason token begins with `dial_failed`.
if grep -Eq 'reason=dial_failed[^ ]* .*blocked' "$tmp_ssrf/sbx-proxy.log" 2>/dev/null; then
  _record_pass "SSRF guard refuses dial to loopback (logged)"
else
  _record_fail "SSRF guard evidence" "proxy log: $(tail -5 "$tmp_ssrf/sbx-proxy.log" 2>/dev/null)"
fi
rm -rf "$tmp_ssrf"

# Proxy is cleaned up after agent exits (no orphan).
for _ in $(seq 1 20); do
  pgrep -f 'sbx-proxy --listen' >/dev/null 2>&1 || break
  sleep 0.1
done
baseline_proxies=$(pgrep -f 'sbx-proxy --listen' | wc -l | tr -d ' ')
sbx-agent --net-allow-host "$proxy_test_host" -- true >/dev/null 2>&1
for _ in $(seq 1 20); do
  current=$(pgrep -f 'sbx-proxy --listen' | wc -l | tr -d ' ')
  [[ "$current" -eq "$baseline_proxies" ]] && break
  sleep 0.1
done
if [[ "$current" -eq "$baseline_proxies" ]]; then
  _record_pass "proxy auto-terminates after agent exits"
else
  _record_fail "proxy cleanup" "baseline=$baseline_proxies current=$current"
fi

# Audit log records proxy=yes with host list.
tmp_audit=$(mktemp -d)
FLOX_ENV_CACHE="$tmp_audit" sbx-agent --net-allow-host "$proxy_test_host" -- true >/dev/null 2>&1
sleep 0.2
if grep -q 'proxy=yes' "$tmp_audit/sbx-agent.log" \
   && grep -q "proxy_hosts=\[$proxy_test_host\]" "$tmp_audit/sbx-agent.log"; then
  _record_pass "audit log records proxy=yes and proxy_hosts"
else
  _record_fail "audit log proxy fields" "$(cat "$tmp_audit/sbx-agent.log" 2>/dev/null)"
fi
if [[ -s "$tmp_audit/sbx-proxy.log" ]] && grep -q 'event=start' "$tmp_audit/sbx-proxy.log"; then
  _record_pass "sbx-proxy.log created alongside audit log"
else
  _record_fail "sbx-proxy.log" "missing or empty"
fi
rm -rf "$tmp_audit"

# Two concurrent sbx-agent invocations get independent proxies on
# different ephemeral ports (each with its own --ppid watcher).
for _ in $(seq 1 20); do
  pgrep -f 'sbx-proxy --listen' >/dev/null 2>&1 || break
  sleep 0.1
done
sbx-agent --net-allow-host "$proxy_test_host" -- sleep 1 >/dev/null 2>&1 &
sbx_pid_a=$!
sbx-agent --net-allow-host "$proxy_test_host" -- sleep 1 >/dev/null 2>&1 &
sbx_pid_b=$!
sleep 0.5
live_proxies=$(pgrep -f 'sbx-proxy --listen' | wc -l | tr -d ' ')
wait "$sbx_pid_a" "$sbx_pid_b" 2>/dev/null
if [[ "$live_proxies" -ge 2 ]]; then
  _record_pass "concurrent sbx-agent invocations start independent proxies"
else
  _record_fail "concurrent proxies" "saw $live_proxies live proxies, expected >= 2"
fi

section "sbx-agent: --dump-policy"

# Test 1: basic dump. The permissive default policy should contain
# all the baseline rules — version line, allow default, pasteboard
# denies, file-write scoping, network block.
dp_basic=$(sbx-agent --dump-policy -- true 2>&1)
if [[ "$dp_basic" == *"(version 1)"* ]] \
   && [[ "$dp_basic" == *"(allow default)"* ]] \
   && [[ "$dp_basic" == *'(deny mach-lookup (global-name-prefix "com.apple.pasteboard"))'* ]] \
   && [[ "$dp_basic" == *'(deny file-write*)'* ]] \
   && [[ "$dp_basic" == *'(deny network*)'* ]]; then
  _record_pass "--dump-policy basic: permissive preamble with pasteboard deny + write scope + net block"
else
  _record_fail "--dump-policy basic" "missing expected rules: ${dp_basic:0:300}"
fi

# Test 2: strict dump. Birdcage-derived deny-default preamble must
# appear, plus process-fork allow, plus the import of system.sb.
dp_strict=$(sbx-agent --dump-policy --strict-reads -- true 2>&1)
if [[ "$dp_strict" == *'(import "system.sb")'* ]] \
   && [[ "$dp_strict" == *"(deny default)"* ]] \
   && [[ "$dp_strict" == *"(allow process-fork)"* ]] \
   && [[ "$dp_strict" == *"(allow file-read-metadata)"* ]]; then
  _record_pass "--dump-policy strict: deny-default preamble with process-fork and system.sb import"
else
  _record_fail "--dump-policy strict" "missing expected rules: ${dp_strict:0:300}"
fi

# Test 3: --net block shows the explicit deny.
dp_block=$(sbx-agent --dump-policy --net block -- true 2>&1)
if [[ "$dp_block" == *"(deny network*)"* ]]; then
  _record_pass "--dump-policy --net block shows (deny network*)"
else
  _record_fail "--dump-policy --net block" "missing deny network*"
fi

# Test 4: --net allow does NOT emit a redundant deny network*. In
# permissive mode (allow default), network is already permitted and
# no extra rule is added — the dumped policy must not contain
# (deny network*).
dp_allow=$(sbx-agent --dump-policy --net allow -- true 2>&1)
if [[ "$dp_allow" != *"(deny network*)"* ]]; then
  _record_pass "--dump-policy --net allow does NOT add (deny network*)"
else
  _record_fail "--dump-policy --net allow" "unexpected (deny network*) in permissive mode"
fi

# Test 5: --write paths are canonicalized in the dump. /tmp becomes
# /private/tmp on macOS, and the test verifies the canonical form
# appears in the dumped policy.
dp_write=$(sbx-agent --dump-policy --write /tmp/sbx-dump-foo -- true 2>&1)
if [[ "$dp_write" == *'(subpath "/private/tmp/sbx-dump-foo")'* ]]; then
  _record_pass "--dump-policy --write canonicalizes /tmp → /private/tmp"
else
  _record_fail "--dump-policy --write canonicalization" "${dp_write:0:300}"
fi

# Test 6: --net-allow-host in dump mode must use the literal
# placeholder "<PROXY_PORT>" and NOT start a real proxy process.
# Drain any lingering proxies first to get a clean baseline.
for _ in $(seq 1 20); do
  pgrep -f 'sbx-proxy --listen' >/dev/null 2>&1 || break
  sleep 0.1
done
dp_baseline_proxies=$(pgrep -f 'sbx-proxy --listen' | wc -l | tr -d ' ')
dp_proxy=$(sbx-agent --dump-policy --net-allow-host example.com -- true 2>&1)
sleep 0.3
dp_after_proxies=$(pgrep -f 'sbx-proxy --listen' | wc -l | tr -d ' ')
if [[ "$dp_proxy" == *'localhost:<PROXY_PORT>'* ]] \
   && [[ "$dp_after_proxies" -eq "$dp_baseline_proxies" ]]; then
  _record_pass "--dump-policy --net-allow-host uses placeholder; no proxy process started"
else
  _record_fail "--dump-policy proxy placeholder" \
    "placeholder_present=$([[ "$dp_proxy" == *'localhost:<PROXY_PORT>'* ]] && echo yes || echo no) baseline=$dp_baseline_proxies after=$dp_after_proxies"
fi

# Test 7: --dump-policy alone, with no command after --, works.
dp_noargs=$(sbx-agent --dump-policy 2>&1); dp_noargs_rc=$?
if [[ $dp_noargs_rc -eq 0 && "$dp_noargs" == *"(version 1)"* ]]; then
  _record_pass "--dump-policy works with no command argument"
else
  _record_fail "--dump-policy no-arg" "rc=$dp_noargs_rc out=${dp_noargs:0:200}"
fi

# Test 8: tripwire — --dump-policy must NOT exec the command. Use
# a canary file name; the dump should complete without creating it.
dp_canary="/tmp/sbx-dump-canary-$$-$RANDOM"
rm -f "$dp_canary"
sbx-agent --dump-policy -- /usr/bin/touch "$dp_canary" >/dev/null 2>&1
if [[ ! -e "$dp_canary" ]]; then
  _record_pass "tripwire: --dump-policy does NOT exec the command (no canary file created)"
else
  _record_fail "tripwire: dump exec leak" "canary file $dp_canary exists"
  rm -f "$dp_canary"
fi

# Test 9: tripwire — --dump-policy must NOT write to the audit log.
dp_audit_dir=$(mktemp -d)
FLOX_ENV_CACHE="$dp_audit_dir" sbx-agent --dump-policy -- true >/dev/null 2>&1
if [[ ! -e "$dp_audit_dir/sbx-agent.log" ]]; then
  _record_pass "tripwire: --dump-policy does NOT write audit log"
else
  _record_fail "tripwire: dump audit leak" "audit log exists: $(cat "$dp_audit_dir/sbx-agent.log")"
fi
rm -rf "$dp_audit_dir"

# Test 10: input validation is preserved. Invalid --net values must
# still error out in dump mode, not silently dump a broken policy.
run_fail "--dump-policy preserves --net DNS-name rejection" \
  sbx-agent --dump-policy --net 'example.com:443' -- true

# Test 11: output goes to stdout, not stderr. Capture stdout alone
# with 2>/dev/null and verify the expected content is still present.
dp_stdout=$(sbx-agent --dump-policy -- true 2>/dev/null)
if [[ "$dp_stdout" == *"(version 1)"* && "$dp_stdout" == *"(allow default)"* ]]; then
  _record_pass "--dump-policy output goes to stdout (not stderr)"
else
  _record_fail "--dump-policy stdout" "stdout was: ${dp_stdout:0:200}"
fi

# Test 12: dump mode ignores command arguments entirely (not just
# the command name). If the parser were leaking args into the dump,
# we'd see the sentinel string somewhere in the output.
dp_sentinel="SBX_DUMP_SENTINEL_$$_$RANDOM"
dp_args_out=$(sbx-agent --dump-policy -- /bin/echo "$dp_sentinel" 2>&1)
if [[ "$dp_args_out" != *"$dp_sentinel"* ]]; then
  _record_pass "--dump-policy ignores command arguments (no echo/exec leak)"
else
  _record_fail "--dump-policy arg leak" "sentinel '$dp_sentinel' appeared in output"
fi

# Test 13: --passenv warnings are suppressed in dump mode. In real
# mode, --passenv NONEXIST prints "note: ... not set in environment"
# to stderr. In dump mode, env_args construction is skipped entirely,
# so the warning does not fire. This is intentional asymmetry: users
# debugging passenv should drop --dump-policy.
dp_passenv_err=$(sbx-agent --dump-policy --passenv SBX_DEFINITELY_NOT_SET_$$ -- true 2>&1 1>/dev/null)
if [[ "$dp_passenv_err" != *"not set in environment"* ]]; then
  _record_pass "--dump-policy suppresses --passenv unset warnings (no env_args in dump)"
else
  _record_fail "--dump-policy passenv warning leak" "${dp_passenv_err:0:200}"
fi

# Test 14: strict-mode --read and --write semantics in the dump.
# --read grants read-only; --write grants both read AND write
# (because strict mode needs to be able to read existing files
# before modifying them). Verify both paths appear correctly.
dp_rw=$(sbx-agent --dump-policy --strict-reads --read /tmp/sbx-dump-ro --write /tmp/sbx-dump-rw -- true 2>&1)
if [[ "$dp_rw" == *'(allow file-read* (subpath "/private/tmp/sbx-dump-ro"))'* ]] \
   && [[ "$dp_rw" == *'(allow file-read* (subpath "/private/tmp/sbx-dump-rw"))'* ]] \
   && [[ "$dp_rw" == *'(allow file-write* (subpath "/private/tmp/sbx-dump-rw"))'* ]] \
   && [[ "$dp_rw" != *'(allow file-write* (subpath "/private/tmp/sbx-dump-ro"))'* ]]; then
  _record_pass "--dump-policy strict: --read is read-only, --write is read+write"
else
  _record_fail "--dump-policy strict read/write" \
    "rules mismatched: ${dp_rw:0:400}"
fi

# Test 15: --no-tmpdir suppresses the TMPDIR write rule in the dump.
# This verifies dump mode correctly honors --no-tmpdir (the TMPDIR
# rule should NOT appear in policy_lines at all).
dp_notmp=$(sbx-agent --dump-policy --no-tmpdir -- true 2>&1)
# Check that NO /private/var/folders/.../T rule appears (the
# canonical form of $TMPDIR on macOS).
if [[ "$dp_notmp" != *"/private/var/folders"* ]]; then
  _record_pass "--dump-policy --no-tmpdir removes TMPDIR write rule"
else
  _record_fail "--dump-policy --no-tmpdir" "TMPDIR rule still present"
fi

# Test 16: dump mode still enforces --net / --net-allow-host mutual
# exclusion. A user passing both should get the conflict error even
# when dumping.
run_fail "--dump-policy preserves --net / --net-allow-host mutex" \
  sbx-agent --dump-policy --net allow --net-allow-host example.com -- true

section "sbx-agent: --passenv env scrubbing"

# Export a distinctive var and verify it's scrubbed by default.
export SBX_TEST_SECRET="tripwire-$$"
run_match "default scrubs SBX_TEST_SECRET (drops)" \
  "DROPPED" \
  sbx-agent -- sh -c 'echo "${SBX_TEST_SECRET:-DROPPED}"'
run_match "--passenv SBX_TEST_SECRET reinjects" \
  "tripwire-$$" \
  sbx-agent --passenv SBX_TEST_SECRET -- sh -c 'echo "$SBX_TEST_SECRET"'
run_match "--passenv-all passes full env through" \
  "tripwire-$$" \
  sbx-agent --passenv-all -- sh -c 'echo "${SBX_TEST_SECRET:-DROPPED}"'
unset SBX_TEST_SECRET

# --passenv for a var that isn't set emits a note but doesn't error.
run_match "--passenv of unset var notes and continues" \
  "not set in environment" \
  sbx-agent --passenv DEFINITELY_NOT_SET_XYZ -- true

# PATH and HOME must survive default scrubbing (agents need them).
run_pass "default scrub preserves PATH" \
  sbx-agent -- sh -c '[ -n "$PATH" ]'
run_pass "default scrub preserves HOME" \
  sbx-agent -- sh -c '[ "$HOME" = '"$HOME"' ]'
run_pass "default scrub preserves FLOX_ENV" \
  sbx-agent -- sh -c '[ -n "$FLOX_ENV" ]'

# SSH_AUTH_SOCK is an example of something that MUST be dropped.
SSH_AUTH_SOCK=/tmp/fake-ssh-sock.$$ run_match "default scrubs SSH_AUTH_SOCK" \
  "NOT-SET" \
  sbx-agent -- sh -c 'echo "${SSH_AUTH_SOCK:-NOT-SET}"'

section "sbx-agent: resource limits"

# --timeout kills long sleep. timeout's rc for a killed process is 124.
run_fail "--timeout 1 kills sleep 10" \
  sbx-agent --timeout 1 -- sleep 10

run_pass "--timeout 5 permits sleep 0.1" \
  sbx-agent --timeout 5 -- sleep 0.1

# --max-cpu kills CPU-bound loop; pair with --timeout so we don't hang
# if the limit fails to apply. Expected exit: 152 (SIGXCPU 24 + 128).
run_fail "--max-cpu 1 kills busy loop" \
  sbx-agent --max-cpu 1 --timeout 30 -- bash -c 'while :; do :; done'

# --max-files denies opening too many fds. Bash's exec redirection
# fails with "cannot duplicate fd: Invalid argument" under EMFILE.
run_fail "--max-files 10 denies 20 concurrent fds" \
  sbx-agent --max-files 10 -- bash -c '
    for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
      exec {fd}</dev/null || exit 1
    done'

section "sbx-agent: audit log"

# Use a temporary log dir so we don't collide with the real one.
audit_dir=$(mktemp -d /tmp/sbx-audit-test.XXXXXX)
trap 'rm -rf "$scratch" "$audit_dir" 2>/dev/null' EXIT

# Default location: writes to FLOX_ENV_CACHE/sbx-agent.log if that is
# set. We override FLOX_ENV_CACHE to our temp dir for the test.
FLOX_ENV_CACHE="$audit_dir" sbx-agent -- true
if [[ -s "$audit_dir/sbx-agent.log" ]]; then
  _record_pass "audit log written to \$FLOX_ENV_CACHE/sbx-agent.log"
else
  _record_fail "audit log default location" "no log file"
fi

# Record should contain expected keys.
if grep -q 'ts=.*pid=.*cwd=.*argv=' "$audit_dir/sbx-agent.log"; then
  _record_pass "audit log has ts/pid/cwd/argv fields"
else
  _record_fail "audit log fields" "$(head -1 "$audit_dir/sbx-agent.log")"
fi

# --strict-reads should show strict=1 in the record.
FLOX_ENV_CACHE="$audit_dir" sbx-agent --strict-reads -- true
if tail -1 "$audit_dir/sbx-agent.log" | grep -q 'strict=1'; then
  _record_pass "audit log reflects strict=1"
else
  _record_fail "audit log strict flag" "$(tail -1 "$audit_dir/sbx-agent.log")"
fi

# --no-audit-log suppresses.
rm -f "$audit_dir/sbx-agent.log"
FLOX_ENV_CACHE="$audit_dir" sbx-agent --no-audit-log -- true
if [[ ! -e "$audit_dir/sbx-agent.log" ]]; then
  _record_pass "--no-audit-log suppresses writing"
else
  _record_fail "--no-audit-log" "log still exists"
fi

# --audit-log <path> writes to explicit location.
custom_log="$audit_dir/custom.log"
sbx-agent --audit-log "$custom_log" -- true
if [[ -s "$custom_log" ]]; then
  _record_pass "--audit-log <path> writes to explicit location"
else
  _record_fail "--audit-log explicit path" "no file"
fi

# Unset FLOX_ENV_CACHE + no --audit-log: logging silently disabled.
rm -f "$audit_dir/sbx-agent.log"
env -i PATH="$PATH" sbx-agent -- true 2>/dev/null
# (The explicit env -i gives the child no FLOX_ENV_CACHE. sbx-agent
# itself runs outside the sandbox with FLOX_ENV_CACHE unset.)
if [[ ! -e "$audit_dir/sbx-agent.log" ]]; then
  _record_pass "no FLOX_ENV_CACHE + no --audit-log skips logging"
else
  _record_fail "silent skip" "log written anyway"
fi

# --- ROADMAP #6: net_orig field preserves the original --net value ---
# Covers the three kv-emit paths: bare block, bare allow, and the
# host-list case where sbx-agent internally rewrites net_mode to
# "hosts". Uses grep -F to avoid regex surprises with the asterisks.

rm -f "$audit_dir/sbx-agent.log"
FLOX_ENV_CACHE="$audit_dir" sbx-agent --net block -- true
if grep -qF 'net=block net_orig=""' "$audit_dir/sbx-agent.log"; then
  _record_pass "audit log: --net block → net_orig empty"
else
  _record_fail "audit log net_orig (block)" "$(tail -1 "$audit_dir/sbx-agent.log" 2>/dev/null)"
fi

rm -f "$audit_dir/sbx-agent.log"
FLOX_ENV_CACHE="$audit_dir" sbx-agent --net allow -- true
if grep -qF 'net=allow net_orig=""' "$audit_dir/sbx-agent.log"; then
  _record_pass "audit log: --net allow → net_orig empty"
else
  _record_fail "audit log net_orig (allow)" "$(tail -1 "$audit_dir/sbx-agent.log" 2>/dev/null)"
fi

rm -f "$audit_dir/sbx-agent.log"
FLOX_ENV_CACHE="$audit_dir" sbx-agent --net '*:443,*:80' -- true
if grep -qF 'net=hosts net_orig="*:443,*:80"' "$audit_dir/sbx-agent.log"; then
  _record_pass "audit log: --net host-list → net_orig preserves original"
else
  _record_fail "audit log net_orig (hosts)" "$(tail -1 "$audit_dir/sbx-agent.log" 2>/dev/null)"
fi

# --- ROADMAP #7: audit log rotates when it crosses 10 MB ------------
# Pre-populate a >10 MB file, run sbx-agent once, assert the old file
# was rotated to .log.1 (byte-for-byte preserved) and the new .log is
# fresh and small (a single kv record is well under 1 KB).

rm -f "$audit_dir/sbx-agent.log" "$audit_dir/sbx-agent.log.1"
# 11 MiB of zeros via explicit byte count (portable across GNU/BSD dd).
# The test runs inside `flox activate -d ~/dev/sbx` where coreutils is
# GNU, so `stat -c%s` is the matching size flag — same choice as the
# agent-side rotation code in sbx-helpers.nix.
dd if=/dev/zero of="$audit_dir/sbx-agent.log" bs=1048576 count=11 >/dev/null 2>&1
big_size=$(stat -c%s "$audit_dir/sbx-agent.log" 2>/dev/null || echo 0)
FLOX_ENV_CACHE="$audit_dir" sbx-agent -- true
rotated_size=$(stat -c%s "$audit_dir/sbx-agent.log.1" 2>/dev/null || echo 0)
new_size=$(stat -c%s "$audit_dir/sbx-agent.log" 2>/dev/null || echo 0)
if [[ "$rotated_size" -eq "$big_size" && "$new_size" -gt 0 && "$new_size" -lt 10485760 ]]; then
  _record_pass "audit log rotates to .log.1 when >10 MB"
else
  _record_fail "audit log rotation" "big=$big_size rotated=$rotated_size new=$new_size"
fi
rm -f "$audit_dir/sbx-agent.log" "$audit_dir/sbx-agent.log.1"

# --- --log-max-size override (SBX_LOG_MAX_SIZE surfaces this) -------
# Six tests covering: default unchanged, smaller cap rotates earlier,
# larger cap defers rotation, 0 disables, invalid value errors, and
# forwarding into sbx-proxy's event=start line.

# (a) smaller cap: 5 MiB threshold, 6 MiB pre-populated → rotate
rm -f "$audit_dir/sbx-agent.log" "$audit_dir/sbx-agent.log.1"
dd if=/dev/zero of="$audit_dir/sbx-agent.log" bs=1048576 count=6 >/dev/null 2>&1
pre_size=$(stat -c%s "$audit_dir/sbx-agent.log" 2>/dev/null || echo 0)
FLOX_ENV_CACHE="$audit_dir" sbx-agent --log-max-size 5M -- true
rotated_5m=$(stat -c%s "$audit_dir/sbx-agent.log.1" 2>/dev/null || echo 0)
new_5m=$(stat -c%s "$audit_dir/sbx-agent.log" 2>/dev/null || echo 0)
if [[ "$rotated_5m" -eq "$pre_size" && "$new_5m" -gt 0 && "$new_5m" -lt 6291456 ]]; then
  _record_pass "--log-max-size 5M rotates a 6 MiB audit log"
else
  _record_fail "--log-max-size 5M" "pre=$pre_size rotated=$rotated_5m new=$new_5m"
fi
rm -f "$audit_dir/sbx-agent.log" "$audit_dir/sbx-agent.log.1"

# (b) larger cap: 20 MiB threshold, 11 MiB pre-populated → do NOT rotate
dd if=/dev/zero of="$audit_dir/sbx-agent.log" bs=1048576 count=11 >/dev/null 2>&1
pre_size=$(stat -c%s "$audit_dir/sbx-agent.log" 2>/dev/null || echo 0)
FLOX_ENV_CACHE="$audit_dir" sbx-agent --log-max-size 20M -- true
new_20m=$(stat -c%s "$audit_dir/sbx-agent.log" 2>/dev/null || echo 0)
# Expected: file was pre_size bytes of zeros; sbx-agent appended a
# short audit record, so the new size is pre_size + a few hundred
# bytes. .log.1 must NOT exist — no rotation fired.
if [[ ! -e "$audit_dir/sbx-agent.log.1" && "$new_20m" -gt "$pre_size" ]]; then
  _record_pass "--log-max-size 20M defers rotation for 11 MiB file"
else
  _record_fail "--log-max-size 20M" "pre=$pre_size new=$new_20m .1-exists=$([[ -e "$audit_dir/sbx-agent.log.1" ]] && echo yes || echo no)"
fi
rm -f "$audit_dir/sbx-agent.log" "$audit_dir/sbx-agent.log.1"

# (c) 0 disables rotation entirely: 11 MiB pre-populated → no rotation
dd if=/dev/zero of="$audit_dir/sbx-agent.log" bs=1048576 count=11 >/dev/null 2>&1
FLOX_ENV_CACHE="$audit_dir" sbx-agent --log-max-size 0 -- true
if [[ ! -e "$audit_dir/sbx-agent.log.1" ]]; then
  _record_pass "--log-max-size 0 disables rotation"
else
  _record_fail "--log-max-size 0" ".1 exists unexpectedly"
fi
rm -f "$audit_dir/sbx-agent.log" "$audit_dir/sbx-agent.log.1"

# (d) invalid value: sbx-agent must exit 2 with a clear error
if out=$(sbx-agent --log-max-size bogus -- true 2>&1); then
  _record_fail "--log-max-size bogus (no error)" "unexpected success: $out"
else
  rc=$?
  if [[ "$rc" -eq 2 ]] && [[ "$out" == *"invalid size value"* ]]; then
    _record_pass "--log-max-size bogus errors with rc=2"
  else
    _record_fail "--log-max-size bogus" "rc=$rc out=$out"
  fi
fi

# (e) default unchanged: omitting --log-max-size still rotates at 10 MiB
# (this is the same coverage as the existing rotation test above, but
# reasserted here to guard against a regression where the new default
# plumbing silently disables rotation when no flag is passed)
rm -f "$audit_dir/sbx-agent.log" "$audit_dir/sbx-agent.log.1"
dd if=/dev/zero of="$audit_dir/sbx-agent.log" bs=1048576 count=11 >/dev/null 2>&1
FLOX_ENV_CACHE="$audit_dir" sbx-agent -- true
if [[ -e "$audit_dir/sbx-agent.log.1" ]]; then
  _record_pass "default --log-max-size (omitted) still rotates at 10 MiB"
else
  _record_fail "default rotation regression" "no .log.1 after default-cap rotation"
fi
rm -f "$audit_dir/sbx-agent.log" "$audit_dir/sbx-agent.log.1"

# (f) proxy forwarding: --log-max-size N propagates into sbx-proxy's
# event=start line, visible as log_max_size=<bytes-form>
tmp_lms=$(mktemp -d)
FLOX_ENV_CACHE="$tmp_lms" sbx-agent --log-max-size 50M --net-allow-host "$proxy_test_host" --passenv-all -- true >/dev/null 2>&1 || true
sleep 0.2
if grep -q 'log_max_size=52428800' "$tmp_lms/sbx-proxy.log" 2>/dev/null; then
  _record_pass "--log-max-size forwards to sbx-proxy (event=start shows 52428800)"
else
  _record_fail "--log-max-size proxy forward" "$(grep event=start "$tmp_lms/sbx-proxy.log" 2>/dev/null | head -1)"
fi
rm -rf "$tmp_lms"
# Drain any lingering proxy from this section before moving on.
for _ in $(seq 1 20); do
  pgrep -f 'sbx-proxy --listen' >/dev/null 2>&1 || break
  sleep 0.1
done

# --- parse_bytes octal-trap regressions -----------------------------
# parse_bytes used to do bash arithmetic directly on the captured
# digit string, and bash's $((expr)) treats leading-zero literals
# as octal: 010 → 8, 08/09 → arithmetic error rc=1. SBX_LOG_MAX_SIZE
# from a script that zero-pads its numeric fields would silently
# misconfigure (010M → 8 MiB) or noisily explode (09M → rc=1 with
# bash's raw octal parse error). Forced base-10 normalization via
# 10#$num after the regex match fixes both. These three tests pin
# the expected behavior so the trap can't return on a refactor.

# (g) leading-zero decimal: 010M must equal 10 MiB, not 8 MiB
tmp_oct=$(mktemp -d)
FLOX_ENV_CACHE="$tmp_oct" sbx-agent --log-max-size 010M --net-allow-host "$proxy_test_host" --passenv-all -- true >/dev/null 2>&1 || true
sleep 0.2
if grep -q 'log_max_size=10485760' "$tmp_oct/sbx-proxy.log" 2>/dev/null; then
  _record_pass "parse_bytes 010M normalizes to 10 MiB (not octal 8 MiB)"
else
  _record_fail "parse_bytes 010M octal trap" "$(grep event=start "$tmp_oct/sbx-proxy.log" 2>/dev/null | sed -n 's/.*log_max_size=\([0-9]*\).*/got=\1/p')"
fi
rm -rf "$tmp_oct"
for _ in $(seq 1 20); do pgrep -f 'sbx-proxy --listen' >/dev/null 2>&1 || break; sleep 0.1; done

# (h) invalid-octal digits: 08M must succeed at 8 MiB, not blow up
# with a raw bash arithmetic error and rc=1
tmp_oct=$(mktemp -d)
if FLOX_ENV_CACHE="$tmp_oct" sbx-agent --log-max-size 08M --net-allow-host "$proxy_test_host" --passenv-all -- true >/dev/null 2>&1; then
  sleep 0.2
  if grep -q 'log_max_size=8388608' "$tmp_oct/sbx-proxy.log" 2>/dev/null; then
    _record_pass "parse_bytes 08M parses as decimal 8 MiB (not bash octal error)"
  else
    _record_fail "parse_bytes 08M wrong value" "$(grep event=start "$tmp_oct/sbx-proxy.log" 2>/dev/null | sed -n 's/.*log_max_size=\([0-9]*\).*/got=\1/p')"
  fi
else
  _record_fail "parse_bytes 08M rc!=0" "exit code $? (octal arithmetic error?)"
fi
rm -rf "$tmp_oct"
for _ in $(seq 1 20); do pgrep -f 'sbx-proxy --listen' >/dev/null 2>&1 || break; sleep 0.1; done

# (i) all-zeros: 00 must be parseable and disable rotation, not blow
# up with rc=1 from bash treating "00" as a malformed octal literal
tmp_oct=$(mktemp -d)
if FLOX_ENV_CACHE="$tmp_oct" sbx-agent --log-max-size 00 --net-allow-host "$proxy_test_host" --passenv-all -- true >/dev/null 2>&1; then
  sleep 0.2
  if grep -q 'log_max_size=0' "$tmp_oct/sbx-proxy.log" 2>/dev/null; then
    _record_pass "parse_bytes 00 normalizes to 0 (rotation disabled)"
  else
    _record_fail "parse_bytes 00 wrong value" "$(grep event=start "$tmp_oct/sbx-proxy.log" 2>/dev/null | sed -n 's/.*log_max_size=\([0-9]*\).*/got=\1/p')"
  fi
else
  _record_fail "parse_bytes 00 rc!=0" "exit code $?"
fi
rm -rf "$tmp_oct"
for _ in $(seq 1 20); do pgrep -f 'sbx-proxy --listen' >/dev/null 2>&1 || break; sleep 0.1; done

# --- sbx-here -------------------------------------------------------

section "sbx-here (legacy preset)"

pushd "$scratch" >/dev/null
run_pass "write inside PWD"          sbx-here sh -c 'echo h > here.txt && test -s here.txt'
run_fail "write to TMPDIR denied"     sbx-here sh -c 'echo nope > "$TMPDIR/here-leak.$$"'
run_fail "network denied"            sbx-here bash -c 'exec 3<>/dev/tcp/1.1.1.1/443'
popd >/dev/null

# --- profile wrappers ----------------------------------------------
# Shadow the real agent binary with a fake that echoes its argv. This
# way we can test the wrapper logic without installing the real tools.

section "profile wrappers: claude-jail / copilot-jail / codex-jail"

fake_bin=$(mktemp -d -t sbx-jail-fakebin.XXXXXX)
# Each new trap must re-enumerate every tmpdir from prior sections;
# bash has no additive trap syntax and `trap -p EXIT | sed` is fragile.
# Missing any dir here strands test artifacts on failed runs. $audit_dir
# was dropped here in the past — every section that adds a new dir now
# lives in this list, and the final trap at line ~940 adds $fake_bin
# back in after the canary section's tmpdir is spliced in.
trap 'rm -rf "$scratch" "$audit_dir" "$fake_bin" 2>/dev/null' EXIT

make_fake() {
  local name="$1"
  cat > "$fake_bin/$name" <<FAKE
#!/usr/bin/env bash
echo "fake-$name argv: \$*"
# Echo known test-marker env vars if present, so SBX_PASSENV tests can
# observe whether they survived the env-i scrub.
for v in SBX_TEST_FAKE_KEY SBX_CANARY_ENV; do
  [[ -n "\${!v:-}" ]] && echo "fake-$name env \$v=\${!v}"
done
FAKE
  chmod +x "$fake_bin/$name"
}

make_fake claude
make_fake codex
make_fake gh  # copilot-jail calls "gh copilot ..."

saved_path="$PATH"
export PATH="$fake_bin:$PATH"

run_match "claude-jail default (SBX_NET=allow implicit)" \
  "fake-claude argv: --version" \
  claude-jail --version

# Note: VAR=value goes BEFORE run_match, not after. `env VAR=value fn`
# would fail because env is a binary and can't execute shell functions.
SBX_NET=block run_match "claude-jail with SBX_NET=block override" \
  "fake-claude argv: help" \
  claude-jail help

SBX_NET='*:443' run_match "claude-jail with SBX_NET='*:443'" \
  "fake-claude argv: diag" \
  claude-jail diag

run_match "codex-jail passes args through" \
  "fake-codex argv: probe" \
  codex-jail probe

run_match "copilot-jail prepends 'copilot' to args" \
  "fake-gh argv: copilot suggest" \
  copilot-jail suggest

# Proof that the spurious '' prefix in the manifest is really gone:
# if it were still there, SBX_NET=allow would produce --net ''allow
# and sbx-agent would reject it.
SBX_NET=allow run_match "claude-jail SBX_NET=allow does not hit the ''allow bug" \
  "fake-claude argv: hello" \
  claude-jail hello

# SBX_STRICT=1 must inject --strict-reads into sbx-agent's argv. The
# fake claude is a trivial bash script that echoes and exits, so it
# doesn't need any $HOME reads — a perfect probe for "does strict mode
# get wired through the wrapper."
SBX_STRICT=1 run_match "claude-jail with SBX_STRICT=1 injects --strict-reads" \
  "fake-claude argv: strict-probe" \
  claude-jail strict-probe

# With SBX_STRICT unset, the _sbx_agent_args helper must not emit a
# stray --strict-reads flag.
unset SBX_STRICT
run_match "claude-jail with SBX_STRICT unset works" \
  "fake-claude argv: unset-probe" \
  claude-jail unset-probe

# SBX_PASSENV reaches the fake agent's environment.
export SBX_TEST_FAKE_KEY="fake-key-value"
SBX_PASSENV=SBX_TEST_FAKE_KEY run_match "SBX_PASSENV wired via wrapper helper" \
  "fake-key-value" \
  claude-jail probe
unset SBX_TEST_FAKE_KEY

# SBX_TIMEOUT reaches sbx-agent and kills a long sleep. Uses fake-sleep
# (a script that just sleeps) under the jail.
cat > "$fake_bin/claude-sleeper" <<'FAKE'
#!/usr/bin/env bash
sleep 5
echo "fake-claude-sleeper argv: $*"
FAKE
chmod +x "$fake_bin/claude-sleeper"
# Temporarily rebind claude-jail to claude-sleeper for this test only.
# Uses the same array-based pattern as the real wrappers.
_orig_claude_jail_test() {
  _sbx_agent_args
  sbx-agent "${_sbx_args[@]}" --write "$HOME/.claude" -- claude-sleeper "$@"
}
start_ts=$(date +%s)
SBX_TIMEOUT=1 _orig_claude_jail_test probe >/dev/null 2>&1
rc=$?
end_ts=$(date +%s)
elapsed=$(( end_ts - start_ts ))
if [[ $rc -ne 0 && $elapsed -lt 7 ]]; then
  _record_pass "SBX_TIMEOUT kills a slow agent (rc=$rc, elapsed=${elapsed}s)"
else
  _record_fail "SBX_TIMEOUT kill" "rc=$rc elapsed=${elapsed}s"
fi

# Proof the wrapper doesn't bypass sbx-agent's validation: passing a
# numeric IP via SBX_NET should still hit sbx-agent's SBPL-limitation
# check and fail cleanly, NOT reach the fake claude.
out=$(SBX_NET='1.2.3.4:443' claude-jail --version 2>&1 || true)
if [[ "$out" == *"only accepts '*' or 'localhost'"* ]]; then
  _record_pass "claude-jail rejects numeric-IP SBX_NET override"
else
  _record_fail "claude-jail numeric-IP rejection" "out=${out:0:200}"
fi

out=$(SBX_NET='example.com:443' claude-jail --version 2>&1 || true)
if [[ "$out" == *"only accepts '*' or 'localhost'"* ]]; then
  _record_pass "claude-jail rejects DNS-name SBX_NET override"
else
  _record_fail "claude-jail DNS override rejection" "out=${out:0:200}"
fi

# Glob-expansion regression: a pre-array version of the profile helper
# emitted flags via unquoted $(...) which would glob-expand in a cwd
# containing files matching the glob. Plant a trap file and confirm
# SBX_NET='*:443' survives the wrapper unmolested.
# NOTE: use pushd/popd, not ( cd ... ), because a subshell would lose
# the pass/fail counter increments that run_match performs.
glob_trap_dir=$(mktemp -d /tmp/sbx-glob-trap.XXXXXX)
touch "$glob_trap_dir/collision:443"
pushd "$glob_trap_dir" >/dev/null
SBX_NET='*:443' run_match "glob trap: SBX_NET='*:443' passes through wrapper unexpanded" \
  "fake-claude argv: globtest" \
  claude-jail globtest
popd >/dev/null
rm -rf "$glob_trap_dir"

# SBX_NET_ALLOW_HOSTS routes through sbx-proxy. The fake claude sees
# HTTPS_PROXY in its environment when proxy mode is active.
cat > "$fake_bin/claude-envdump" <<'FAKE'
#!/usr/bin/env bash
echo "fake-envdump HTTPS_PROXY=${HTTPS_PROXY:-UNSET}"
FAKE
chmod +x "$fake_bin/claude-envdump"
_claude_envdump_jail() {
  _sbx_agent_args
  sbx-agent "${_sbx_args[@]}" --write "$HOME/.claude" -- claude-envdump
}
SBX_NET_ALLOW_HOSTS="allowed.example.test" \
  run_match "SBX_NET_ALLOW_HOSTS injects HTTPS_PROXY into fake agent" \
  "HTTPS_PROXY=http://127.0.0.1:" \
  _claude_envdump_jail

# Without SBX_NET_ALLOW_HOSTS the fake sees UNSET for HTTPS_PROXY.
unset SBX_NET_ALLOW_HOSTS
run_match "SBX_NET_ALLOW_HOSTS unset → no HTTPS_PROXY in child" \
  "HTTPS_PROXY=UNSET" \
  _claude_envdump_jail

# --- canaries ------------------------------------------------------
# Tripwires for the five core protections. Each canary has both a
# "positive control" (the baseline behavior when the protection is
# NOT applied) and a "tripwire" (the behavior we expect when it IS).
# If either side flips, the sandbox has silently regressed.

section "canaries: tripwires for core protections"

# Randomized per run to prevent collision.
canary_tag="canary-$$-$(date +%s)"

# ----- 1. Read isolation canary -----
# Plant a known secret in $HOME outside any allowed read zone.
canary_secret_file="$HOME/.sbx-canary-$canary_tag"
printf 'CANARY-SECRET-%s\n' "$canary_tag" > "$canary_secret_file"
trap 'rm -f "$canary_secret_file" 2>/dev/null; rm -rf "$scratch" "$fake_bin" "$audit_dir" 2>/dev/null' EXIT

# Control: non-strict mode CAN read it (reads are global).
run_match "canary control: non-strict mode CAN read ~/.sbx-canary" \
  "CANARY-SECRET-$canary_tag" \
  sbx-agent -- cat "$canary_secret_file"

# Tripwire: strict mode MUST block the read.
run_fail "canary tripwire: strict mode BLOCKS ~/.sbx-canary read" \
  sbx-agent --strict-reads -- cat "$canary_secret_file"

# ----- 2. Env scrub canary -----
# Plant a fake "secret" env var; verify it's gone by default.
export SBX_CANARY_ENV="canary-env-$canary_tag"

# Control: --passenv-all passes it through.
run_match "canary control: --passenv-all DOES pass SBX_CANARY_ENV" \
  "canary-env-$canary_tag" \
  sbx-agent --passenv-all -- sh -c 'echo "$SBX_CANARY_ENV"'

# Tripwire: default mode DROPS it.
run_match "canary tripwire: default mode DROPS SBX_CANARY_ENV" \
  "DROPPED-ABC" \
  sbx-agent -- sh -c 'echo "${SBX_CANARY_ENV:-DROPPED-ABC}"'

unset SBX_CANARY_ENV

# ----- 3. Network block canary -----
# Control: --net allow lets TCP through.
run_pass "canary control: --net allow ALLOWS TCP to 1.1.1.1:443" \
  sbx-agent --net allow -- bash -c 'exec 3<>/dev/tcp/1.1.1.1/443'

# Tripwire: --net block actually denies.
run_fail "canary tripwire: --net block DENIES TCP to 1.1.1.1:443" \
  sbx-agent --net block -- bash -c 'exec 3<>/dev/tcp/1.1.1.1/443'

# ----- 4. Write scoping canary -----
# Plant a target file outside PWD/TMPDIR. Default sbx-agent must
# refuse to touch it. (We can't verify this by file state alone —
# rc of "sh -c 'echo > /file'" only reflects the sh exit, so we
# check both rc and the file's unchanged content.)
canary_outside="/tmp/sbx-canary-outside-$canary_tag"
rm -f "$canary_outside"
echo "UNTOUCHED" > "$canary_outside"
sbx-agent -- sh -c "echo violated > '$canary_outside'" 2>/dev/null || true
if [[ "$(cat "$canary_outside")" == "UNTOUCHED" ]]; then
  _record_pass "canary tripwire: default mode BLOCKS writes outside PWD/TMPDIR"
else
  _record_fail "canary tripwire: write scoping" "file was modified"
fi
rm -f "$canary_outside"

# ----- 5. Fork canary -----
# Regression guard: the Birdcage-derived strict preamble must still
# allow fork+pipe. If someone accidentally drops (allow process-fork),
# pipes break immediately and every multi-process workload dies.
run_pass "canary tripwire: strict mode PERMITS fork+pipe (Birdcage regression)" \
  sbx-agent --strict-reads -- sh -c 'cat /etc/hosts | head -1'

# ----- 6. Proxy canaries -----
# Tripwire that proxy mode actually confines network to localhost.
# Control: without proxy, --net allow permits TCP to 1.1.1.1:443.
run_pass "canary control: --net allow ALLOWS direct TCP to 1.1.1.1:443" \
  sbx-agent --net allow -- bash -c 'exec 3<>/dev/tcp/1.1.1.1/443'

# Tripwire: with --net-allow-host, direct TCP to 1.1.1.1:443 is
# BLOCKED (the sandbox only permits TCP to the proxy's ephemeral
# port on 127.0.0.1).
run_fail "canary tripwire: proxy mode BLOCKS direct TCP to 1.1.1.1:443" \
  sbx-agent --net-allow-host "allowed.example.test" -- \
    bash -c 'exec 3<>/dev/tcp/1.1.1.1/443'

# Tripwire: proxy denies a CONNECT to a host that's not on the list.
# Uses macOS-native nc (no Command Line Tools required).
proxy_deny_out=$(sbx-agent --net-allow-host "allowed.example.test" --passenv-all -- bash -c '
authority="${HTTPS_PROXY#http://}"
phost="${authority%:*}"
pport="${authority#*:}"
printf "CONNECT attacker.example.com:443 HTTP/1.1\r\nHost: attacker.example.com:443\r\n\r\n" \
  | /usr/bin/nc -w 2 "$phost" "$pport"
' 2>&1)
if [[ "$proxy_deny_out" == *"403"* ]]; then
  _record_pass "canary tripwire: proxy returns 403 for non-allowlisted host"
else
  _record_fail "canary: proxy deny" "out=${proxy_deny_out:0:200}"
fi

# Tripwire: SSRF guard refuses to dial loopback even when the user
# allowlists it. This is the key hardening from the patched proxy.
# Uses /usr/bin/curl to drive a real TLS handshake through the proxy.
tmp_ssrf_canary=$(mktemp -d)
FLOX_ENV_CACHE="$tmp_ssrf_canary" \
  sbx-agent --net-allow-host localhost --passenv-all -- bash -c '
authority="${HTTPS_PROXY#http://}"
/usr/bin/curl -sS -o /dev/null \
  --proxy "http://$authority" \
  --max-time 5 \
  -k \
  https://localhost:443/ 2>/dev/null || true
' >/dev/null 2>&1 || true
sleep 0.3
# Tight regex: same as the primary SSRF test. Requires a single log
# line where reason begins with `dial_failed` AND the err payload
# contains `blocked` (the SSRF-guard marker from resolveAndDial).
if grep -Eq 'reason=dial_failed[^ ]* .*blocked' \
     "$tmp_ssrf_canary/sbx-proxy.log" 2>/dev/null; then
  _record_pass "canary tripwire: SSRF guard refuses localhost dial"
else
  _record_fail "canary: SSRF guard" \
    "log tail: $(tail -3 "$tmp_ssrf_canary/sbx-proxy.log" 2>/dev/null)"
fi
rm -rf "$tmp_ssrf_canary"

# ----- 7. Clipboard canary (static + behavioral) -----
# macOS's pboard service is a Mach-based system service registered
# by /usr/libexec/pboard under "com.apple.pasteboard.1" and the
# newer "com.apple.coreservices.uauseractivitypasteboardclient.xpc"
# XPC service. The sandbox policy must deny mach-lookup for those
# names so that pbcopy/pbpaste can't reach the clipboard from
# inside the jail.
#
# We check this two ways:
#
#   a) STATIC: grep each built helper script for the literal SBPL
#      deny rules. This verifies the code change is in effect.
#      Runs anywhere; doesn't depend on pasteboard access.
#
#   b) BEHAVIORAL: if the outer shell has pasteboard access, plant
#      a randomized canary on the clipboard and confirm that
#      `sbx-agent -- /usr/bin/pbpaste` cannot read it. If the
#      outer shell cannot round-trip the clipboard (common in SSH
#      sessions, tmux without a pasteboard bridge, or shells that
#      inherited from a context without GUI pasteboard access),
#      this check is SKIPPED — not failed. The static check above
#      already covers code correctness; the behavioral check is a
#      live tripwire for when it's runnable.

# Static: iterate over the three helper binaries and verify each
# contains BOTH expected deny rule lines. Counts must match:
#   sbx-run:    1 of each (permissive policy only)
#   sbx-cwd:    1 of each (permissive policy only)
#   sbx-agent:  2 of each (permissive + strict preambles)
for _clip_bin_entry in "sbx-run:1" "sbx-cwd:1" "sbx-agent:2"; do
  _clip_bin="${_clip_bin_entry%:*}"
  _clip_want="${_clip_bin_entry#*:}"
  _clip_script=$(command -v "$_clip_bin" 2>/dev/null)
  if [[ -z "$_clip_script" ]]; then
    _record_fail "static: $_clip_bin on PATH" "command -v returned empty"
    continue
  fi
  # Use `|| true` not `|| echo 0` — grep -c already prints "0" when
  # there are no matches AND exits 1; adding `echo 0` would produce
  # the two-line string "0\n0" which breaks string equality below.
  _clip_got_pb=$(grep -c '(deny mach-lookup (global-name-prefix "com\.apple\.pasteboard"))' "$_clip_script" 2>/dev/null || true)
  _clip_got_ua=$(grep -c '(deny mach-lookup (global-name-prefix "com\.apple\.coreservices\.uauseractivitypasteboard"))' "$_clip_script" 2>/dev/null || true)
  if [[ "$_clip_got_pb" == "$_clip_want" && "$_clip_got_ua" == "$_clip_want" ]]; then
    _record_pass "static: $_clip_bin contains $_clip_want × pasteboard deny rule(s)"
  else
    _record_fail "static: $_clip_bin pasteboard deny" \
      "expected $_clip_want of each, got pasteboard=$_clip_got_pb uauser=$_clip_got_ua"
  fi
done

# Behavioral: only meaningful if the outer shell can actually
# round-trip the pasteboard. If the round-trip probe fails (e.g.
# SSH session with no pasteboard bridge, or this shell's TCC has
# denied pasteboard access), skip gracefully — the static check
# above has already verified the code change is in effect.
if command -v pbcopy >/dev/null 2>&1 && command -v pbpaste >/dev/null 2>&1; then
  _clip_saved=$(pbpaste 2>/dev/null || printf '')
  _clip_probe="sbx-clipboard-probe-$$"
  printf '%s' "$_clip_probe" | pbcopy 2>/dev/null || true
  if [[ "$(pbpaste 2>/dev/null)" == "$_clip_probe" ]]; then
    _clip_canary="CLIPBOARD-CANARY-$$-$RANDOM"
    printf '%s' "$_clip_canary" | pbcopy
    # --timeout 5 is defensive: if a jailed pbpaste ever retries or
    # hangs on the denied mach-lookup, the timeout prevents the test
    # from blocking indefinitely and leaving the user's clipboard
    # unrestored.
    _clip_out=$(sbx-agent --timeout 5 -- /usr/bin/pbpaste 2>&1 || true)
    # Restore whatever the user had on the clipboard before the test.
    printf '%s' "$_clip_saved" | pbcopy
    if [[ "$_clip_out" != *"$_clip_canary"* ]]; then
      _record_pass "behavioral: jailed pbpaste cannot read clipboard canary"
    else
      _record_fail "behavioral: clipboard leak" \
        "jailed pbpaste returned the canary '$_clip_canary'"
    fi
  else
    # Pre-flight failed — restore (likely empty) and skip gracefully.
    printf '%s' "$_clip_saved" | pbcopy 2>/dev/null || true
    _record_skip "behavioral: clipboard leak (live)" \
      "outer shell can't round-trip pasteboard (SSH? tmux? TCC?); static check above covers correctness"
  fi
else
  _record_skip "behavioral: clipboard leak (live)" \
    "pbcopy/pbpaste not found on PATH"
fi

# --- summary --------------------------------------------------------

printf '\n\033[1m### summary ###\033[0m\n'
printf '  PASS=%d  FAIL=%d  SKIP=%d\n' "$pass" "$fail" "$skip"

if [[ $fail -eq 0 ]]; then
  if [[ $skip -eq 0 ]]; then
    printf '  \033[32mALL TESTS PASSED\033[0m\n'
  else
    printf '  \033[32mALL TESTS PASSED\033[0m (%d skipped)\n' "$skip"
  fi
  exit 0
else
  printf '  \033[31m%d TEST(S) FAILED\033[0m\n' "$fail"
  exit 1
fi
