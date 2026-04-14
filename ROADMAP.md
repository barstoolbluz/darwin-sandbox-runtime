# sbx-agent Roadmap

Working backlog for the sbx-agent sandbox jail suite. Organized by
priority and category. Pick any item, read its "What/Where/How"
section, and act. No item should require re-deriving context from
conversation history.

## What this project is

A suite of macOS `sandbox-exec`-based jails for AI coding agents.
Three layers:

- **`sbx-run` / `sbx-cwd` / `sbx-agent`** — policy-generating helpers
  that emit SBPL and call `/usr/bin/sandbox-exec` directly. The
  primary tool is `sbx-agent`; the other two are simpler presets.
- **`sbx-proxy`** — a hardened local HTTP CONNECT proxy (Go, ~970
  lines) that `sbx-agent` auto-starts when `--net-allow-host` is
  used. Does hostname-level network allowlisting that SBPL can't,
  because sandbox-exec's network filter only accepts `*` and
  `localhost` as hosts. Preserves end-to-end TLS.
- **11 per-agent profile wrappers** in the runtime env's
  `[profile.common]`: `claude-jail`, `codex-jail`, `gemini-jail`,
  `copilot-jail`, `crush-jail`, `opencode-jail`, `openclaw-jail`,
  `nullclaw-jail`, `zeroclaw-jail`, `nanobot-jail`, `nanocoder-jail`.
  Each is a 3-line function that calls `sbx-agent` with that tool's
  state-dir allowances.

### Threat model this closes today

- Agent reading/writing files outside `$PWD`, `$TMPDIR`, and a
  configured state dir.
- Agent opening TCP to arbitrary hosts when `--net-allow-host` or
  `--net block` is configured.
- Agent reading `$HOME/.ssh`, `$HOME/.aws`, `$HOME/.gnupg`, browser
  cookies, keychain metadata under `--strict-reads`.
- API keys / tokens in the parent shell env propagating into the
  agent (scrubbed by default; reinjected only via `--passenv`).
- Fork bombs / runaway CPU / fd exhaustion via `--timeout`,
  `--max-cpu`, `--max-procs`, `--max-files`.
- SSRF pivot: an allowlisted hostname resolving to a loopback or
  private IP is refused at dial by the hardened proxy's IP filter.
- Undetected policy changes: every invocation is recorded in
  `$FLOX_ENV_CACHE/sbx-agent.log` + `$FLOX_ENV_CACHE/sbx-proxy.log`.

### Known gaps (details in the backlog below)

- Clipboard access via `pbpaste` is unrestricted.
- TCC grants (Full Disk Access, Screen Recording, Camera, Mic,
  Accessibility) inherited from the parent Terminal.
- `ps aux` and `sysctl` leak host/process inventory.
- Signal delivery to other user processes is allowed.
- Inherited file descriptors from the parent shell can bypass
  `--strict-reads` for whatever was already open.
- Writes inside the allowed scope are not undoable (use git).
- Memory limits are not enforceable on macOS (kernel returns EINVAL
  on `RLIMIT_AS` / `RLIMIT_DATA` / `RLIMIT_RSS`).

## Current state (2026-04-14)

- **Test baseline**: `PASS=146 FAIL=0 SKIP=1` from
  `~/dev/sbx/test-jail.sh` running inside `flox activate -d
  ~/dev/sbx -- bash test-jail.sh`. Pass lines in output match
  reported count exactly. The 1 SKIP is the clipboard canary's
  live-behavioral half, which only runs when the outer shell can
  round-trip the macOS pasteboard (see item #1 notes). Static
  checks cover the code-correctness half always.
- **Go unit tests**: run automatically at every `flox build
  sbx-proxy` via `buildGoModule`'s `checkPhase`. ~11 table-driven
  tests covering byte-loopback via `net.Pipe` injection, fragmented
  ClientHello parsing, SNI mismatch rejection, allowlist wildcard
  semantics, SSRF IP filter, loopback-listen enforcement, header
  size bounds, atomic port-file writes.
- **Store paths (pinned in `~/dev/sbx/.flox/env/manifest.toml`)**:
  - `sbx` → `/nix/store/5dwg6sb6ysvm3h5aaaxa6mp88kl8rhi0-sbx-unstable-2026-04-13`
  - `sbx-helpers` → `/nix/store/dq804l5ivn8inkm7vi6kql0rbrqzvwqs-sbx-helpers`
    (includes pasteboard mach-lookup deny from item #1 + the
    `--dump-policy` flag from item #2 — both shipped 2026-04-14)
  - `sbx-proxy` → `/nix/store/29bn0v567b0jh9647rniwkyycbvqs1jy-sbx-proxy-0.1.0`
    (hardened: loopback-only listen, SSRF IP filter, SNI enforcement,
    conn limits, timeouts, graceful shutdown, bounded header reads)
- **Key files**:
  - `~/dev/builds/build-sbx/.flox/proxy/main.go` — hardened proxy
    Go source (~970 lines, stdlib-only)
  - `~/dev/builds/build-sbx/.flox/proxy/main_test.go` — Go unit
    tests (~400 lines)
  - `~/dev/builds/build-sbx/.flox/pkgs/sbx-proxy.nix` —
    `buildGoModule` expression for the proxy
  - `~/dev/builds/build-sbx/.flox/pkgs/sbx-helpers.nix` — three
    `writeShellApplication`s for `sbx-run`, `sbx-cwd`, `sbx-agent`
    (~700 lines incl. embedded shell scripts)
  - `~/dev/sbx/.flox/env/manifest.toml` — runtime env installing
    all three packages plus the 11 profile wrappers
  - `~/dev/sbx/test-jail.sh` — 127-assertion bash test suite
  - `~/dev/sbx/ROADMAP.md` — this file

## Priority order (do these first)

Ranked by `(value to user) / (effort to me)`. Higher = do sooner.

1. **Close the clipboard leak** (Security) — **[NEEDS TESTING]**
   Code shipped 2026-04-14; behavioral verification blocked on the
   need for a shell with live pasteboard access.
   - **What shipped**:
     - Verified the real Mach service names via `plutil -p` on
       `/System/Library/LaunchAgents/com.apple.pboard.plist`:
       `com.apple.pasteboard.1` and
       `com.apple.coreservices.uauseractivitypasteboardclient.xpc`,
       both registered by `/usr/libexec/pboard`.
     - Added two prefix-match deny rules to **four** policy-
       construction sites in `sbx-helpers.nix`: `sbx-run`,
       `sbx-cwd`, `sbx-agent` permissive mode, `sbx-agent` strict
       mode. Prefix form chosen over exact-match for forward
       compatibility.
     - Rebuilt → `sbx-helpers` store path now
       `zf5b3blziwj53qifp9r7hskcw01l2kvj`. Manifest bumped.
     - Added `test-jail.sh` canary block #7 with **static check**
       (grep each built helper for the expected rule count — 1 for
       sbx-run, 1 for sbx-cwd, 2 for sbx-agent) and **skippable
       behavioral check** (plant canary, run jailed pbpaste,
       assert canary not readable, restore clipboard).
     - Added `_record_skip` + `skip=` counter + SKIP reporting in
       `test-jail.sh` summary so behavioral checks can degrade
       gracefully when prerequisites aren't met.
   - **Audit findings (all green)**:
     - `grep -c` on built scripts: sbx-run=1/1, sbx-cwd=1/1,
       sbx-agent=2/2 (two SBPL preamble paths × two rules each).
     - Rule placement: deny rules come AFTER `(allow default)` in
       the permissive path and AFTER `(allow mach*)` in the strict
       path. SBPL last-match-wins semantics override the broader
       allows as intended.
     - `sandbox-exec` parses all three SBPL filter forms
       (`global-name`, `global-name-prefix`, `global-name-regex`).
       Prefix form chosen; tested via dry-run with `/bin/echo ok`.
     - Existing 127 assertions still pass after the rebuild; no
       regressions from the Mach-lookup deny rules.
     - New static tests pass: 3 (one per helper binary).
     - Full run from the Claude Code Bash-tool environment:
       `PASS=130 FAIL=0 SKIP=1`. The 1 SKIP is the behavioral
       check because the tool's own shell sandbox has no
       pasteboard access — which is the graceful-degrade case we
       built it for.
   - **What still needs verification (live, on a real shell)**:
     - Run `./test-jail.sh` from a shell that DOES have live
       pasteboard access — i.e., a local Terminal.app or iTerm2
       running on the Mac Mini directly (not SSH'd in, not tmux
       without pasteboard bridge, not a context where TCC denies
       pasteboard). Expected: `PASS=131 FAIL=0 SKIP=0`.
     - Or verify manually by running
       `printf 'tripwire-%s' $RANDOM | pbcopy; sbx-agent -- pbpaste`
       and confirming the output does NOT contain the tripwire.
     - The user's primary dev setup is **SSH from a Linux laptop
       to the Mac Mini**. macOS `com.apple.pboard` is a per-GUI-
       session LaunchAgent bound to the Aqua session; SSH
       connections establish a POSIX session that isn't attached
       to the Aqua launchd namespace, so `pbcopy`/`pbpaste`
       silently no-op in SSH. This is baseline macOS, not a
       flox or sbx issue. Workarounds exist
       (`reattach-to-user-namespace`, `launchctl asuser`) but
       aren't worth installing just for the canary. The live
       tripwire will fire correctly from a direct Terminal.app
       session on the Mac Mini or from Screen Sharing (which
       runs inside the Aqua session).
     - **Not yet verified**: that blocking these Mach services
       doesn't break any real agent's terminal/TTY setup. Will be
       exercised during priority #3 (real-agent end-to-end). The
       deny is easy to revert or narrow to exact-match if a real
       agent depends on the pasteboard for non-secret-reading
       purposes.

2. ~~**Add `sbx-agent --dump-policy`**~~ **[SHIPPED 2026-04-14]**
   - **Behavior**: prints the built SBPL policy to stdout and
     exits 0. No exec, no env_args, no audit log, no ulimits, no
     proxy startup. Pure dry-run / preview.
   - **Dump mode semantics**:
     - Works without a command after `--` (no "command specified"
       check).
     - Runs path canonicalization, `--net` validation, and the
       `--net` / `--net-allow-host` mutual-exclusion check (catches
       user errors even in preview).
     - For `--net-allow-host`: uses a literal `<PROXY_PORT>`
       placeholder in the dumped policy; does NOT start sbx-proxy,
       does NOT require it on PATH.
     - Output goes to stdout; stderr stays clean.
     - `--passenv KEY` unset warning is suppressed in dump mode
       (env_args construction is skipped entirely). Users
       debugging passenv should drop `--dump-policy`.
   - **Tests** (16 in `test-jail.sh` — 11 from initial
     implementation + 5 added during post-ship audit →
     `PASS=146 FAIL=0 SKIP=1`):
     1. basic permissive preamble contents
     2. strict preamble: `deny default`, `allow process-fork`,
        `(import "system.sb")`
     3. `--net block` shows `(deny network*)`
     4. `--net allow` does NOT add a redundant `(deny network*)`
     5. `--write /tmp/foo` canonicalizes to `/private/tmp/foo`
     6. `--net-allow-host` produces `localhost:<PROXY_PORT>`
        placeholder AND no proxy process is started (pgrep
        baseline check)
     7. no command argument required
     8. **tripwire**: `-- /usr/bin/touch /tmp/canary-$$` does NOT
        create the canary file (proves no exec leak)
     9. **tripwire**: no audit log written under a fresh
        `FLOX_ENV_CACHE`
     10. `--net 'example.com:443'` (invalid DNS name) still
         errors out in dump mode (validation preserved)
     11. output goes to stdout, not stderr (verified by
         redirecting stderr to /dev/null)
     12. command arguments after `--` are discarded, not echoed
         (sentinel string must NOT appear in dump output)
     13. `--passenv NONEXIST` in dump mode does NOT emit the
         "not set in environment" warning (env_args skipped)
     14. strict-mode `--read` is read-only; `--write` is
         read+write (strict mode's write-implies-read rule)
     15. `--no-tmpdir` suppresses the TMPDIR write rule in the
         dumped policy
     16. `--net` / `--net-allow-host` mutex enforced even in
         dump mode (preserves user-error checking)
   - **Store path**: sbx-helpers now
     `dq804l5ivn8inkm7vi6kql0rbrqzvwqs`.
   - **Audit**: interrogated the plan against 11 edge cases
     (stdout vs stderr, audit log in dump mode, command
     requirement, proxy handling, placeholder format, env_args
     warnings, check_path_safe, set -u init, --help interaction,
     validator preservation, stdout capture) before touching
     code. Two issues surfaced during validation: test for
     stdout channel and test for preserved input validation,
     both added to the test list.

3. **Run a real agent end-to-end**. Pick `claude-jail` (the most
   confident wrapper) and run a real `claude` binary through it
   against a simple task. Discover the actual `--read`/`--write`
   paths it needs. Fix the `claude-jail` function in the runtime
   manifest's `[profile.common]` accordingly. This is the biggest
   single risk right now because the nine "best-guess" wrappers
   could all be wrong in ways we haven't seen. Repeat for at least
   `codex-jail` and `gemini-jail` once confirmed those binaries are
   installed on the user's machine.

4. **`SBX_PROXY_FLAGS` passthrough** (Usability, flexibility). A new
   env var that the `_sbx_agent_args` helper splits and passes
   through to `sbx-agent`, which in turn passes each token as an
   extra flag to the `sbx-proxy` invocation. Unlocks
   `--tls-sni-policy=off`, `--dial-timeout=30s`,
   `--tunnel-max-lifetime=1h`, `--max-conns=128` without editing the
   helper. Test: set `SBX_PROXY_FLAGS='--tls-sni-policy=off'` and
   verify the proxy log records `tls_sni_policy="off"` at startup.

5. **Tighten the SSRF regression test**. Currently in
   `test-jail.sh`, the SSRF test greps for
   `(dial_failed|blocked|no safe|no successful safe|event=deny)` —
   any deny marker counts as a pass, which means an SNI parse error
   would also pass. Change the regex to require
   `reason=dial_failed.*blocked` specifically. Run the test, confirm
   the proxy actually reaches the dial step (which requires curl
   sending a valid ClientHello), and make sure the test now asserts
   on that exact marker.

6. **Audit log: preserve the original `--net` value**. Currently
   when a user passes `--net '*:443,*:80'` the audit log records
   `net=hosts` (the internal mode name). Fix: save `net_mode_orig`
   before overwriting, emit both fields (`net=hosts
   net_orig="*:443,*:80"`). Five-line change in the
   `write_audit_record` function in `sbx-helpers.nix`.

7. **Log rotation** (Operational). `$FLOX_ENV_CACHE/sbx-agent.log`
   and `$FLOX_ENV_CACHE/sbx-proxy.log` grow forever. Simple fix: in
   `sbx-agent`, before appending to the audit log, check if it's
   >10 MB and if so rename to `.log.1`. Crude but sufficient. Same
   for the proxy log via a `--log-max-size` flag.

8. **Commit to git**. Everything is staged but not committed. In
   both `~/dev/builds/build-sbx` and `~/dev/sbx`. One `git commit`
   per repo. Don't push anywhere (user rule: no pushes).

9. **Clean up stray test artifacts** in `~/dev/sbx`:
   `agent-pwd.txt`, `in.txt`, `inside2.txt`, `here.txt`. These are
   left over from `sbx-cwd`/`sbx-here` tests that use `$PWD` as
   scratch. Fix the tests to use `mktemp -d` consistently and clean
   up in an `EXIT` trap.

10. **Write a README.md**. One page. "What this is, when to use it,
    when not to, how to run the tests, how to re-pin the store
    paths when the proxy/helpers change, where the logs live."
    Living in `~/dev/sbx/README.md`. This is the onboarding doc for
    someone else (or future-you on a fresh machine).

## Backlog: security gaps

These close real-world leak vectors. Each one has a canary tripwire
we should add when the fix lands, so regressions fail the test suite
loudly.

### S1 — Clipboard access via pbpaste (Priority #1 above)

**Where**: SBPL preamble in `sbx-helpers.nix`, both the
`(allow default)` and `(deny default)` paths.

**What**: add `(deny mach-lookup (global-name-prefix
"com.apple.pasteboard"))` after the existing `(allow default)` /
after `(allow mach*)` in the preamble.

**Verify**: canary test that pre-populates the clipboard with
`pbcopy` then runs `sbx-agent -- pbpaste` and asserts the output
does NOT contain the canary string. Add to `test-jail.sh` canary
section.

### S2 — TCC grants inherited from parent Terminal

**Where**: documentation primarily. There's no SBPL rule that
revokes a TCC grant from a child process — TCC is a
process-attribute permission the kernel enforces before sandbox-exec
gets involved.

**What**: document in README that the jail inherits Full Disk
Access, Screen Recording, Camera, Mic, and Accessibility grants
from the parent Terminal. Recommend running jails from a dedicated
Terminal profile that has NO TCC grants. For the paranoid: a
dedicated Terminal.app that the user has never clicked "Allow" in
any TCC prompt for.

**Verify**: impossible to verify programmatically (we can't
introspect TCC state from userspace cleanly). Document-only.

### S3 — ps / sysctl / process introspection leaks

**Where**: `sbx-helpers.nix`, both preambles.

**What**: add `(deny sysctl-read (sysctl-name "kern.proc.*"))` and
`(deny system-info (info-type "processes"))` — tentative names,
need to verify against actual SBPL vocabulary. Check that
`ps`/`top`/`htop` still work for the agent's own PID (many tools
check their own process info at startup).

**Verify**: canary test that runs `ps aux` inside the jail and
asserts that processes outside the jail's subtree are NOT listed
(or the command fails entirely). May need to accept "command
fails" as the behavior — many tools will break, so this should
probably be strict-mode only, not default.

### S4 — Signal delivery to other user processes

**Where**: `sbx-helpers.nix`, the default preamble has `(allow
default)` which permits signals globally; strict preamble has
`(allow signal (target others))`.

**What**: change strict preamble to `(allow signal (target same-pgid))`
or similar, restricting signals to the agent's own process group.
The agent can still signal its own children but not unrelated
processes. Default mode stays permissive because changing it would
break many tools that signal helpers.

**Verify**: canary test that runs `kill -0 1` (init) inside the jail
in strict mode and asserts it fails with EPERM or Operation not
permitted.

### S5 — Inherited file descriptors bypass --strict-reads

**Where**: `sbx-agent`, in the final exec block before the actual
exec.

**What**: close all fds >= 3 before the final exec chain. Bash
supports `{3..1023} ; do exec {fd}>&-; done` but it's clunky and
slow. The clean approach: `exec > >(:) 2> >(:) 0< /dev/null` to
reset stdio, then use a subprocess-specific closeall. Alternative:
use the `close_fds` option on macOS's exec (not sure if bash
exposes this).

**Verify**: canary test that opens an fd in the parent shell on a
sensitive file, runs the jail, and asserts the agent can NOT read
through that fd.

### S6 — Audit log tamper resistance

**Where**: new write path in `sbx-agent`.

**What**: currently the audit log is a plain append-only text file.
An attacker (or a buggy agent that escapes write scoping somehow)
could rewrite history. Optional upgrade: chain records with HMAC
keyed on a secret in `~/.config/sbx-agent/audit.key` readable only
by the user. Each record includes a hash of the previous record.
A chain-break is detectable. Overkill for v1 but a tracked item.

**Verify**: golden log file with known chain, attempt to mutate a
middle record, confirm the verification tool reports the break.

## Backlog: bugs I noticed but didn't fix

### B1 — `net=hosts` in audit log (Priority #6)

See priority list.

### B2 — SSRF regression test accepts any deny (Priority #5)

See priority list.

### B3 — `_sbx_agent_args` uses a global `_sbx_args` array

**Where**: runtime manifest `[profile.common]` in the
`_sbx_agent_args` function.

**What**: the array is a global. Two wrappers called in the same
shell share state. Not breaking in practice (each wrapper
re-populates before use), but could bite in a pipeline or
backgrounded call. Fix: make `_sbx_args` a local of the CALLER
function by having `_sbx_agent_args` print shell code the caller
`eval`s. Or accept the global and document it.

**Verify**: test that calls two wrappers in sequence with different
`SBX_*` values and confirms the second call doesn't inherit
leftover args from the first.

### B4 — `local_safe` array naming in `sbx-agent`

**Where**: `sbx-helpers.nix`, `sbxAgent` text block, search for
`local_safe=(`.

**What**: cosmetic — not a bash `local` declaration, just a
variable whose name contains "local". Rename to `safe_vars` or
`env_whitelist`.

**Verify**: test suite still passes.

### B5 — Audit log quoting of values with embedded quotes

**Where**: `sbx-helpers.nix`, `write_audit_record` function.

**What**: current format is `key="value"` where values can contain
unescaped `"`. An agent argv like `foo "bar"` corrupts parsing.
Fix options: (a) switch to JSON lines (cleanest, but requires
escaping inside bash); (b) escape `"` in values to `\"`; (c) use
`%q` (which double-escapes and is ugly but unambiguous). Pick one.

**Verify**: run a jail with `argv=["echo", "hello \"world\""]` and
assert the log line round-trips through the intended parser.

### B6 — Stray files in ~/dev/sbx (Priority #9)

See priority list.

### B7 — Concurrent-proxies test has a timing race

**Where**: `test-jail.sh`, "concurrent sbx-agent invocations start
independent proxies" test.

**What**: uses `sleep 0.5` as a window to count live proxies. On a
fast machine both may finish before the count; on a slow machine
both may not have started yet. Fix: use `wait -n` or a more
deterministic sync point. Alternatively, verify by log file
timestamps from distinct PIDs.

**Verify**: run the test suite 10 times in a row with no FAIL.

### B8 — `pkill -f 'sbx-proxy --listen'` pattern is fragile

**Where**: `test-jail.sh`, cleanup traps and drain loops.

**What**: matching `sbx-proxy --listen` in `pgrep -f` could catch
unrelated processes (e.g., a shell that has the string in its
history). Fix: match the full `/nix/store/...-sbx-proxy` path.

**Verify**: grep the test output for unexpected kills.

## Backlog: untested but claimed

### U1 — TLS cert pinning through the proxy

**Claimed**: the proxy preserves end-to-end TLS, so clients that
pin a specific server cert continue to work.

**Reality**: never demonstrated. No test actually pins a cert and
verifies it works through the proxy.

**What to do**: write an integration test that uses a known
cert-pinning client (e.g., `curl --pinnedpubkey`) against a real
HTTPS endpoint (example.com or similar) through the proxy. Verify
the handshake succeeds and the pinned cert is what the client
actually sees.

### U2 — HTTP/2 through CONNECT tunneling

**Claimed**: HTTP/2 works because the proxy is a dumb byte pipe
after CONNECT.

**Reality**: never demonstrated. Most HTTP/2 negotiation happens
via ALPN inside the TLS session, which IS end-to-end, so it
SHOULD work — but unverified.

**What to do**: use `curl --http2 --proxy http://127.0.0.1:PORT
https://http2.github.io/` through the proxy and verify
`:status: 200` appears in `-v` output with HTTP/2 framing.

### U3 — Nine of the 11 agent wrappers have never been tested

**Claimed**: `codex-jail`, `gemini-jail`, `crush-jail`,
`opencode-jail`, `openclaw-jail`, `nullclaw-jail`, `zeroclaw-jail`,
`nanobot-jail`, `nanocoder-jail` jail their respective tools
correctly.

**Reality**: marked `# TODO: verify state dir` in the manifest.
Nine guesses based on common conventions.

**What to do**: for each agent, run it through its jail wrapper
against a trivial task. Iterate on `--read` / `--write` paths
until the agent runs cleanly. Update the wrapper in
`[profile.common]`. See Priority #3 above.

### U4 — Audit log concurrency under real load

**Claimed**: 10 parallel writes produce 10 clean lines because
POSIX guarantees atomic append for sub-PIPE_BUF writes.

**Reality**: tested with 10 concurrent invocations. Never tested
with 1000 or with lines near the 4 KB PIPE_BUF boundary.

**What to do**: stress test with 1000 concurrent invocations and
verify line integrity. Optionally: add a length check in
`write_audit_record` that rejects writes >3.5 KB (giving headroom
below PIPE_BUF).

### U5 — Real agent behavior under strict mode

**Claimed**: strict mode will break tools that read `$HOME/.gitconfig`
etc. User can iterate by adding `--read` entries.

**Reality**: never run a real agent under strict mode. The
iteration loop is hypothetical.

**What to do**: part of Priority #3. Run `SBX_STRICT=1 claude-jail`,
observe the first failure, add the appropriate `--read`, reactivate,
retry. Record the canonical `--read` list for at least claude.

## Backlog: usability

### Ux1 — No `--dump-policy` mode (Priority #2)

See priority list.

### Ux2 — No `SBX_PROXY_FLAGS` passthrough (Priority #4)

See priority list.

### Ux3 — No `sbx-agent --list` for running sandboxes

**What**: implement `sbx-agent --list` that shows currently-running
sandboxes with PID, start time, policy summary, argv. Implementation:
scan `pgrep -f sbx-proxy` output and correlate with audit log
records. Or: each jail invocation writes a lock file to
`$FLOX_ENV_CACHE/running/<pid>.json`, cleans up on exit.

**Verify**: start 3 jails, `sbx-agent --list` shows 3, kill one,
shows 2.

### Ux4 — No config file, env-var soup only

**What**: add support for `~/.config/sbx-agent/default.conf` (or
`$PWD/.sbx-agent.conf`) that sets default `SBX_*` values for all
jails run under that shell. Precedence: explicit env var >
per-project config > user config > built-in default.

**Verify**: set `net-allow-hosts` in a config file, run a jail,
confirm the proxy receives those hosts.

### Ux5 — Prompt doesn't indicate jail is active

**What**: option to set `PS1` / `PROMPT` to reflect that the
current shell is running under a jail. Tricky because the jail IS
the exec'd child, not a shell — the child IS the agent. Maybe not
applicable. Consider: add a shell var like `SBX_JAIL_ACTIVE=1` in
the exported env and let users put it in their own prompt.

### Ux6 — Error messages are terse

**What**: improve error output. E.g., `SBX_NET='foo:443'` currently
errors with "sbx-agent: sandbox-exec only accepts '*' or 'localhost'
as the host ...". Add a "did you mean?" line suggesting `*:443`.

### Ux7 — No interactive mode for discovering read paths

**What**: a new `--interactive-discover` flag that, on first
denial, prompts the user: "[denied] read of ~/.gitconfig — allow
for this session? (y/N)". On yes, adds a `--read` to the running
policy... wait, you can't modify an SBPL policy mid-run. You'd
have to kill and restart with the new read path. Viable but
non-trivial.

**Defer**: too complex for v1.

## Backlog: operational

### O1 — No CI

**What**: a GitHub Actions workflow that runs `test-jail.sh` on
every push. Blocked by "we don't push anywhere" — no remote. So
this is "when we decide to push to a public repo."

**Alternative**: a local git hook that runs `test-jail.sh` on
commit. Simpler.

### O2 — No versioning / store path stability

**What**: `sbx-proxy` is pinned at `version = "0.1.0"` in
`sbx-proxy.nix` forever. Bump it on every change to `main.go`.
Similarly for `sbx-helpers`. Nix itself won't complain but the
audit trail is better.

**Also**: each time we bump a store path, the old one still exists
in `/nix/store` until GC. Document how to `nix-collect-garbage`
old builds.

### O3 — Lockstep rebuild of `sbx-helpers` + `sbx-proxy`

**What**: when `main.go` changes, `sbx-proxy` rebuilds and gets a
new store path, but `sbx-helpers` doesn't automatically know. The
runtime manifest has to be edited to bump the proxy's store path.
Possible fix: in the manifest, reference both packages by a
version identifier that can be updated in one edit. Or: introduce
a top-level build target (`flox build all`) that rebuilds both
and updates the manifest automatically. Overkill for v1.

### O4 — Log rotation (Priority #7)

See priority list.

### O5 — No way to clear / rotate audit log from inside the env

**What**: a helper command `sbx-audit clear` or `sbx-audit rotate`
that moves the current log to `.1` and truncates. Or document
`truncate -s 0 $FLOX_ENV_CACHE/sbx-agent.log` as the UX.

### O6 — Git not committed (Priority #8)

See priority list.

### O7 — README missing (Priority #10)

See priority list.

## Backlog: code quality

### C1 — `sbx-helpers.nix` is a 700+ line monolith

**What**: three embedded shell scripts in Nix indented strings.
Painful to navigate. Options: (a) split each helper into its own
`.nix` file; (b) extract shell source to `.flox/helpers/*.sh` and
`builtins.readFile` them into the Nix expressions (but `writeShellApplication`
wants the script body without a shebang, which complicates the
extraction).

**Defer**: works now, refactoring is pure churn. Address if the
file grows past 1000 lines.

### C2 — `test-jail.sh` is 800+ lines with duplicated patterns

**What**: `run_pass` / `run_fail` / `run_match` are defined once but
used differently across sections. Cleanup traps are merged via a
crude `trap -p EXIT | sed` hack. Some sections use subshells (fixed
earlier but the pattern could recur). Could be refactored into a
small test-framework header sourced from multiple test files.

**Defer**: works now. Revisit if we add another 100 tests.

### C3 — No shellcheck on `test-jail.sh`

**What**: `writeShellApplication` runs shellcheck on the helpers,
but `test-jail.sh` is a plain `.sh` file not linted anywhere. Add
`shellcheck test-jail.sh` to whatever CI we eventually have. Or
run manually before commits.

### C4 — No doc of threat model outside ROADMAP.md

**What**: the threat model is in this file's preamble and in the
inline comments of `sbx-helpers.nix`. A dedicated `THREAT_MODEL.md`
would help a reviewer understand what the jail does and doesn't
protect against without reading 1000+ lines of code and 100K
tokens of chat history.

**Candidate**: extract the "Known gaps" section of this file plus
the recipe-based threat analysis from chat into `~/dev/sbx/THREAT_MODEL.md`.

## Out of scope (explicitly not on this roadmap)

- **Native Linux port**. The architecture would work (swap
  sandbox-exec for Landlock/seccomp) but is a rewrite. Birdcage
  already does it for the crate-level. Not a goal.
- **MDM / enterprise distribution**. Single-user tool.
- **VM-based fallback** (Lima, Orbstack, tart). Different product.
  If you need that level of isolation you know it.
- **Memory limits**. Kernel doesn't support settable `RLIMIT_AS` on
  macOS. Can't fix from userspace. VM is the only answer.
- **Rollback of writes**. Use git. Stop wanting this.
- **HTTP_PROXY support in sbx-proxy**. Plain HTTP is out. HTTPS
  only via CONNECT.
- **HTTP/3 / QUIC**. Not supported by the CONNECT proxy model and
  blocked by the sandbox's UDP deny. Agents fall back to HTTP/2.
- **IP allowlisting in the proxy**. SSRF guard refuses private/
  loopback/reserved; public IPs are allowed via hostname
  allowlist. IP literals in `--allow-host` are rejected at startup.
- **Dynamic allowlist reload**. Restart the proxy.
- **Request body inspection / modification**. The proxy is a pure
  byte pipe after CONNECT. Never terminates TLS. No content
  inspection.
- **Publishing to FloxHub**. `flox publish` was forbidden in the
  original packaging doc; still forbidden.

## Change history

- **2026-04-14** — Initial roadmap written. Test baseline
  `PASS=127 FAIL=0`. Three store paths pinned. Ten priority items
  queued. Nine best-guess wrappers flagged for real-agent
  verification.
- **2026-04-14** — Priority #1 code shipped (needs testing):
  clipboard leak closed in source. `sbx-helpers` rebuilt with
  Mach-lookup deny for `com.apple.pasteboard*` and
  `com.apple.coreservices.uauseractivitypasteboard*`. New store
  path `zf5b3blziwj53qifp9r7hskcw01l2kvj`. `test-jail.sh` gained
  a static-check trio (grep the built helpers for the rule —
  always runnable) plus a skippable behavioral check (plant
  canary, run jailed pbpaste, assert not readable, restore).
  `_record_skip` and a `skip=` counter were added so the
  behavioral check degrades gracefully. Test baseline from the
  Claude Code tool environment: `PASS=130 FAIL=0 SKIP=1`. The 1
  SKIP is the behavioral half, expected to pass as a live
  tripwire when the user runs `test-jail.sh` from a shell with
  real pasteboard access (local Terminal.app on the Mac Mini,
  not SSH/tmux).
- **2026-04-14** — Priority #2 shipped: `sbx-agent --dump-policy`
  flag added. Prints the built SBPL policy to stdout and exits
  0 without running anything (no env_args, no audit log, no
  ulimits, no proxy startup, no exec). In `--net-allow-host`
  dump mode, uses a `<PROXY_PORT>` placeholder instead of
  starting the proxy. Plan was interrogated against 11 edge
  cases before implementation; two test cases were added as a
  result of validation. 11 new tests added (`PASS=141 FAIL=0
  SKIP=1`, up from 130/0/1). `sbx-helpers` rebuilt with
  clipboard deny + dump-policy; new store path
  `dq804l5ivn8inkm7vi6kql0rbrqzvwqs`. Manifest bumped.
