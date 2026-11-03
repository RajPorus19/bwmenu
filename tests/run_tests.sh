#!/usr/bin/env bash
# bwmenu test suite — mock vault data + fake bw/fzf/clipboard binaries.
# No real Bitwarden, no real clipboard, no network. Safe to run anywhere.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HELPER="$ROOT/lib/bwmenu.py"
MOCK="$ROOT/tests/mock"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf 'ok   - %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL - %s\n' "$1"; }
short() { printf '%s' "$1" | head -c 80; }
assert_eq() {  # desc expected actual
    if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 — expected [$(short "$2")], got [$(short "$3")]"; fi
}
assert_contains() {  # desc haystack needle
    case "$2" in *"$3"*) ok "$1" ;; *) bad "$1 — [$(short "$3")] not found"; esac
}
assert_not_contains() {  # desc haystack needle
    case "$2" in *"$3"*) bad "$1 — unexpectedly contains [$(short "$3")]";; *) ok "$1" ;; esac
}

section() { printf '\n== %s ==\n' "$1"; }

# ---------------------------------------------------------------------------
# Unit tests: lib/bwmenu.py
# ---------------------------------------------------------------------------
section "helper unit tests"

records="$(python3 "$HELPER" records "$MOCK/items.json" "$MOCK/folders.json")"

assert_eq "records: 6 login rows" "6" "$(printf '%s\n' "$records" | grep -c .)"
assert_not_contains "records: secure note excluded" "$records" "Secure Note"
assert_not_contains "records: card excluded" "$records" "Credit Card"
assert_not_contains "records: password never leaked" "$records" "gh-pass-123"
assert_not_contains "records: note body never leaked" "$records" "sensitive-note-content"

assert_eq "records: sorted" "Arch Linux" "$(printf '%s\n' "$records" | head -n1 | cut -f1)"

assert_contains "records: folder name resolved" "$records" "$(printf 'GitHub\tzoomer@example.com\thttps://github.com\tWork')"

minimal="$(printf '%s\n' "$records" | grep '^Minimal')"
assert_eq "records: minimal username empty" "" "$(printf '%s\n' "$minimal" | cut -f2)"
assert_eq "records: minimal uri empty" "" "$(printf '%s\n' "$minimal" | cut -f3)"
assert_eq "records: minimal id preserved" "id-minimal" "$(printf '%s\n' "$minimal" | cut -f5)"

assert_eq "records: duplicate name distinct ids" "2" \
    "$(printf '%s\n' "$records" | grep '^Mail' | cut -f5 | sort -u | grep -c .)"

assert_eq "get password" "gh-pass-123" "$(python3 "$HELPER" get "$MOCK/items.json" id-github password)"
assert_eq "get username" "zoomer@example.com" "$(python3 "$HELPER" get "$MOCK/items.json" id-github username)"
assert_eq "get uri" "https://archlinux.org" "$(python3 "$HELPER" get "$MOCK/items.json" id-arch uri)"
assert_eq "get missing username" "" "$(python3 "$HELPER" get "$MOCK/items.json" id-minimal username)"
if python3 "$HELPER" get "$MOCK/items.json" no-such-id password >/dev/null 2>&1; then
    bad "get unknown id exits non-zero"
else
    ok "get unknown id exits non-zero"
fi

totp="$(python3 "$HELPER" get "$MOCK/items.json" id-totp totp)"
case "$totp" in [0-9][0-9][0-9][0-9][0-9][0-9]) ok "get totp returns 6 digits" ;; *) bad "get totp returned [$totp]" ;; esac
assert_eq "totp-code RFC6238 T=59" "287082" \
    "$(python3 "$HELPER" totp-code GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ 59)"
assert_eq "totp-code RFC6238 T=1111111109" "081804" \
    "$(python3 "$HELPER" totp-code GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ 1111111109)"

if python3 "$HELPER" validate "$MOCK/items.json"; then ok "validate array" ; else bad "validate array"; fi
echo '{"a":1}' > "$WORK/notarray.json"
if python3 "$HELPER" validate "$WORK/notarray.json"; then bad "validate object rejected"; else ok "validate object rejected"; fi
echo 'not json' > "$WORK/bad.json"
if python3 "$HELPER" validate "$WORK/bad.json"; then bad "validate garbage rejected"; else ok "validate garbage rejected"; fi

# ---------------------------------------------------------------------------
# Integration tests: full script with fakes
# ---------------------------------------------------------------------------
section "integration tests (fakes)"

FAKE="$WORK/bin"
mkdir -p "$FAKE" "$WORK/cache" "$WORK/workdir"

cat > "$FAKE/bw" <<'EOF'
#!/usr/bin/env bash
printf 'bw %s\n' "$*" >> "$BW_CALL_LOG"
case "${1:-}" in
  unlock)
    if [ "${2:-}" = "--check" ]; then exit 0; fi
    if [ "${2:-}" = "--raw" ]; then printf 'TESTSESSIONKEY\n'; exit 0; fi
    exit 0 ;;
  list)
    case "${2:-}" in
      items)
        if [ "${BW_FAIL_ITEMS:-0}" = "1" ]; then echo 'not json'; exit 1; fi
        cat "$BW_ITEMS_SRC"; exit 0 ;;
      folders)
        cat "$BW_FOLDERS_SRC"; exit 0 ;;
    esac ;;
esac
exit 0
EOF

# Emulates fzf's --print-query + --expect output for bwmenu's loop. Consumes
# one script line per invocation: "<key>\t<select>\t<query>". Logs the --query
# value it received, then exits 130 once the script is exhausted (Esc).
cat > "$FAKE/fzf" <<'EOF'
#!/usr/bin/env bash
cat > "$FZF_STDIN_FILE"

# log the --query value this invocation received (form: --query=VALUE)
q=""
for a in "$@"; do
    case "$a" in
        --query=*) q="${a#--query=}" ;;
    esac
done
printf '%s\n' "$q" >> "$FZF_QUERY_LOG"

n=0
[ -f "$FZF_COUNT_FILE" ] && n=$(cat "$FZF_COUNT_FILE" 2>/dev/null || echo 0)
n=$((n + 1))
printf '%s\n' "$n" > "$FZF_COUNT_FILE"

line="$(sed -n "${n}p" "$FZF_SCRIPT_FILE" 2>/dev/null)"
[ -z "$line" ] && exit 130

# Split "<key>\t<select>\t<query>" literally (read/IFS would skip a leading
# tab and break the empty-key case).
key="${line%%$'\t'*}"
rest="${line#*$'\t'}"
sel="${rest%%$'\t'*}"
query="${rest#*$'\t'}"

mapfile -t lines < "$FZF_STDIN_FILE"
record="${lines[0]}"
if [ "$sel" = "__RAW__" ]; then
    record="${query:-}"
elif [ -n "$sel" ]; then
    for l in "${lines[@]}"; do
        case "$l" in *"$sel"*) record="$l"; break ;; esac
    done
fi

printf '%s\n' "${query:-}"
if [ -n "$key" ]; then printf '%s\n' "$key"; else printf '\n'; fi
printf '%s\n' "$record"
exit 0
EOF

cat > "$FAKE/xclip" <<'EOF'
#!/usr/bin/env bash
if [ "${BW_TEST_CLIP_FAIL:-0}" = "1" ]; then exit 1; fi
cat > "$CLIP_FILE"
exit 0
EOF

chmod +x "$FAKE/bw" "$FAKE/fzf" "$FAKE/xclip"

# Run bwmenu with the fakes and a private cache dir (never touches the repo).
# $1 = fzf script ("key\tselect\tquery" per line), rest = bwmenu args.
run_bwmenu() {
    local script="$1"; shift
    : > "$WORK/fzf_count"
    : > "$WORK/fzf_query.log"
    printf '%s\n' "$script" > "$WORK/fzf_script"
    (
        cd "$WORK/workdir"
        BW_MENU_NO_RELAUNCH=1 \
        BW_MENU_CACHE_DIR="$WORK/cache" \
        BW_SESSION="TESTSESSION" \
        DISPLAY=:99 \
        BW_ITEMS_SRC="$MOCK/items.json" \
        BW_FOLDERS_SRC="$MOCK/folders.json" \
        BW_CALL_LOG="$WORK/bw_calls.log" \
        FZF_STDIN_FILE="$WORK/fzf_stdin.txt" \
        FZF_COUNT_FILE="$WORK/fzf_count" \
        FZF_SCRIPT_FILE="$WORK/fzf_script" \
        FZF_QUERY_LOG="$WORK/fzf_query.log" \
        CLIP_FILE="$WORK/clip.txt" \
        PATH="$FAKE:$PATH" \
        "$ROOT/bwmenu" "$@"
    )
}

# 1. Fresh run: refresh builds a valid cache, restricted perms, copies password,
#    then the loop's next (exhausted) fzf call cancels cleanly.
: > "$WORK/bw_calls.log"; : > "$WORK/clip.txt"
out="$(run_bwmenu $'\tGitHub' 2>&1)"
assert_eq "run: exit code 0" "0" "$?"
if python3 "$HELPER" validate "$WORK/cache/vault.json"; then ok "run: cache is valid JSON array"; else bad "run: cache is valid JSON array"; fi
assert_eq "run: cache perms 600" "600" "$(stat -c '%a' "$WORK/cache/vault.json")"
assert_eq "run: folders cache perms 600" "600" "$(stat -c '%a' "$WORK/cache/folders.json")"
assert_eq "run: password copied to clipboard" "gh-pass-123" "$(cat "$WORK/clip.txt")"
assert_contains "run: confirmation names item" "$out" "Password copied: GitHub"
assert_not_contains "run: password never in stdout" "$out" "gh-pass-123"
assert_contains "run: refresh called bw list items" "$(cat "$WORK/bw_calls.log")" "list items"
assert_contains "run: refresh called bw list folders" "$(cat "$WORK/bw_calls.log")" "list folders"
assert_contains "run: sync called before refresh" "$(cat "$WORK/bw_calls.log")" "sync"
assert_not_contains "run: no bw get after menu" "$(cat "$WORK/bw_calls.log")" "get"

# 2. Passwords never reach fzf's stdin.
assert_not_contains "run: fzf stdin has no password" "$(cat "$WORK/fzf_stdin.txt")" "gh-pass-123"
assert_not_contains "run: fzf stdin has no secret" "$(cat "$WORK/fzf_stdin.txt")" "arch-secret"

# 3. Duplicate names: select by unique username substring -> correct password.
: > "$WORK/clip.txt"
run_bwmenu $'\tb@example.com' --offline >/dev/null 2>&1
assert_eq "dup: selecting by username copies right password" "mail-pass-B" "$(cat "$WORK/clip.txt")"

# 4. Missing fields don't break: minimal entry still copies its password.
: > "$WORK/clip.txt"
run_bwmenu $'\tMinimal' --offline >/dev/null 2>&1
assert_eq "missing-fields: password copied" "min-pass" "$(cat "$WORK/clip.txt")"

# 5. Ctrl-U action copies username.
: > "$WORK/clip.txt"
run_bwmenu $'ctrl-u\tGitHub' --offline >/dev/null 2>&1
assert_eq "ctrl-u: username copied" "zoomer@example.com" "$(cat "$WORK/clip.txt")"

# 6. Ctrl-Y action copies URI.
: > "$WORK/clip.txt"
run_bwmenu $'ctrl-y\tArch Linux' --offline >/dev/null 2>&1
assert_eq "ctrl-y: uri copied" "https://archlinux.org" "$(cat "$WORK/clip.txt")"

# 7. Ctrl-T copies a 6-digit TOTP.
: > "$WORK/clip.txt"
run_bwmenu $'ctrl-t\tTOTP Test' --offline >/dev/null 2>&1
case "$(cat "$WORK/clip.txt")" in
  [0-9][0-9][0-9][0-9][0-9][0-9]) ok "ctrl-t: 6-digit TOTP copied" ;;
  *) bad "ctrl-t: got [$(cat "$WORK/clip.txt")]" ;;
esac

# 8. Offline mode performs no vault refresh (no `bw list`), but still copies.
: > "$WORK/bw_calls.log"; : > "$WORK/clip.txt"
run_bwmenu $'\tGitHub' --offline >/dev/null 2>&1
assert_not_contains "offline: no vault refresh (list items)" "$(cat "$WORK/bw_calls.log")" "list items"
assert_not_contains "offline: no vault refresh (list folders)" "$(cat "$WORK/bw_calls.log")" "list folders"
assert_eq "offline: password still copied from cache" "gh-pass-123" "$(cat "$WORK/clip.txt")"

# 8b. --no-sync skips bw sync but still refreshes from the local cache.
: > "$WORK/bw_calls.log"; : > "$WORK/clip.txt"
run_bwmenu $'\tGitHub' --no-sync >/dev/null 2>&1
assert_not_contains "no-sync: no bw sync" "$(cat "$WORK/bw_calls.log")" "sync"
assert_contains "no-sync: still refreshes items" "$(cat "$WORK/bw_calls.log")" "list items"
assert_eq "no-sync: password copied" "gh-pass-123" "$(cat "$WORK/clip.txt")"

# 9. Cancel (exhausted script = Esc) exits 0 and copies nothing.
rm -f "$WORK/clip.txt"
run_bwmenu "" --offline >/dev/null 2>&1
rc=$?
assert_eq "cancel: exit 0" "0" "$rc"
if [ -f "$WORK/clip.txt" ]; then bad "cancel: nothing copied"; else ok "cancel: nothing copied"; fi

# 10. Failed refresh preserves the previous good cache.
cp "$MOCK/items.json" "$WORK/cache/vault.json"
chmod 600 "$WORK/cache/vault.json"
if BW_FAIL_ITEMS=1 run_bwmenu "" >/dev/null 2>&1; then
    bad "failed refresh: non-zero exit"
else
    ok "failed refresh: non-zero exit"
fi
assert_eq "failed refresh: previous cache intact" \
    "$(python3 "$HELPER" get "$MOCK/items.json" id-github password)" \
    "$(python3 "$HELPER" get "$WORK/cache/vault.json" id-github password)"

# 11. Clipboard failure reports the error, keeps the menu open (exit 0), and
#     never leaks the secret.
: > "$WORK/clip.txt"
out="$(BW_TEST_CLIP_FAIL=1 run_bwmenu $'\tGitHub' --offline 2>&1)"
assert_eq "clip fail: exit 0 (menu stayed open)" "0" "$?"
assert_contains "clip fail: error reported" "$out" "clipboard copy failed"
assert_not_contains "clip fail: secret not in output" "$out" "gh-pass-123"

# 12. Loop: multiple copies in one session, then Esc. fzf runs once per action
#     plus one final cancel.
: > "$WORK/clip.txt"
out="$(run_bwmenu $'\tGitHub\tgit\nctrl-u\tArch Linux\n\tMinimal' --offline 2>&1)"
assert_eq "loop: 4 fzf calls (3 actions + 1 cancel)" "4" "$(cat "$WORK/fzf_count")"
assert_eq "loop: last copy wins clipboard" "min-pass" "$(cat "$WORK/clip.txt")"
assert_contains "loop: first confirm" "$out" "Password copied: GitHub"
assert_contains "loop: second confirm" "$out" "Username copied: Arch Linux"
assert_contains "loop: third confirm" "$out" "Password copied: Minimal"

# 13. Query is restored between loop iterations.
assert_eq "loop: query restored on 2nd call" "git" "$(sed -n '2p' "$WORK/fzf_query.log")"

# 14. No-match + Enter (raw query, no tab) reports and keeps looping.
out="$(run_bwmenu $'\t__RAW__\tnomatch' --offline 2>&1)"
assert_eq "no-match: exit 0" "0" "$?"
assert_contains "no-match: message shown" "$out" "no matching entry"

# ---------------------------------------------------------------------------
section "summary"
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
