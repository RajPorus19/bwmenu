# bwmenu

A fast, terminal-based Bitwarden password selector for Arch Linux. It uses the
Bitwarden CLI (`bw`), `fzf` for fuzzy searching, and a local JSON cache so that
**Bitwarden is contacted only once at startup** — never while you search,
navigate, or select an entry.

```
export BW_SESSION="$(bw unlock --raw)"
bwmenu
```

Select an entry and its password is copied to the clipboard immediately.

## How it works

1. On launch, `bwmenu` validates your Bitwarden session (unlocking once if
   needed).
2. It runs `bw sync` (so entries added on other devices are picked up),
   then `bw list items` (and `bw list folders`) **once**, writing the
   result to a local cache and atomically replacing the previous one. A
   spinner (`Fetching vault...`) is shown while this happens.
3. The menu records are generated **once** from that cache and handed to
   `fzf`, which filters them entirely in memory.
4. Selection, field resolution (password/username/URI/TOTP), and copying all
   read from the local cache. **No Bitwarden command runs after the menu
   opens.** The menu stays open after each action, so you can copy any number
   of entries in one session; press Esc/Ctrl-C to exit.

The cache files live next to the script:

```
bwmenu/
├── bwmenu          # main script
├── lib/bwmenu.py   # JSON parsing + TOTP helper (never talks to Bitwarden)
├── vault.json      # full `bw list items` output (generated, never committed)
├── folders.json    # `bw list folders` output, for folder names (generated)
├── README.md
├── .gitignore
└── tests/
    ├── run_tests.sh
    └── mock/
```

`vault.json` is the single source of truth for the menu. It preserves the
complete item data (logins, secure notes, cards, identities, custom fields) as
returned by the CLI; nothing is reduced to a names/username index.

## Security warning

`vault.json` contains your **entire vault in plaintext**, including passwords
and secure notes. File permissions (`600`) protect it from other local users,
but not from processes running as you, or malware with equivalent access. This
is the deliberate trade-off that makes selection instant and fully offline.

If you want the same speed with less risk, place the cache on an
encrypted filesystem or an encrypted mount. You can relocate the cache with
`BW_MENU_CACHE_DIR` (see below) to point it at such a location.

## Dependencies

Arch Linux:

```
sudo pacman -S bitwarden-cli fzf wl-clipboard
```

`wl-clipboard` provides `wl-copy` for Wayland. On X11, install either
`xclip` or `xsel` instead (or as well):

```
sudo pacman -S xclip
```

JSON parsing and TOTP generation are handled by a bundled Python 3 script
(`lib/bwmenu.py`) using only the standard library, so `python3` is the only
other requirement — `jq` is **not** needed (see Design notes).

## Setup and usage

1. Log in to the Bitwarden CLI once:

   ```
   bw login
   ```

2. Unlock the vault and export the session key, then run `bwmenu`:

   ```
   export BW_SESSION="$(bw unlock --raw)"
   bwmenu
   ```

   The session key is held only in your shell environment for the lifetime of
   the shell. It is **never** written to disk by `bwmenu` and never embedded in
   the project. Avoid pasting `bw unlock --raw` output into files or command
   history that may be logged.

3. Make it executable and (optionally) link it onto your `PATH`:

   ```
   chmod +x bwmenu
   ln -s "$PWD/bwmenu" ~/.local/bin/bwmenu
   ```

If you launch `bwmenu` with no `BW_SESSION` set, it will attempt
`bw unlock --raw` once (prompting for your master password). If the vault is
locked or the session is invalid, it prints how to unlock and exits — it never
re-prompts in a loop.

## Menu and keys

Entries are shown as `name`, `username`, `URI`, and `folder` (all searchable);
internal item IDs are hidden. The list is sorted alphabetically by name and
fuzzy-matched across name, username, URI, and folder.

The menu **stays open after every action**, so you can copy several entries in
one go; your search query is preserved between selections. Press Esc/Ctrl-C to
close it.

| Key         | Action                       |
|-------------|------------------------------|
| Enter       | copy password (default)      |
| Ctrl-U      | copy username                |
| Ctrl-Y      | copy URI                     |
| Ctrl-T      | copy TOTP code               |
| Ctrl-O      | open the item's website      |
| Esc / Ctrl-C | exit the menu               |

TOTP is computed locally from the cached seed (SHA1/SHA256/SHA512, custom
period/digits honoured via the otpauth URI). If an entry has no TOTP seed,
Ctrl-T reports it rather than calling Bitwarden.

## Clipboard

- Wayland: `wl-copy` (from `wl-clipboard`).
- X11: `xclip -selection clipboard`, falling back to `xsel --clipboard --input`.

The utility is auto-detected from your session (`WAYLAND_DISPLAY` /
`DISPLAY`). Secrets are piped to the clipboard tool over stdin — never placed
in command-line arguments, never echoed, never logged. If no clipboard tool is
installed, `bwmenu` errors out without exposing anything.

## Cache and refresh behaviour

- The refresh writes to a temporary file (umask `077`), validates it is a JSON
  array, then `mv`s it into place atomically and sets mode `600`.
- If `bw list items` fails or returns invalid JSON, the previous good cache is
  left untouched and `bwmenu` exits with an error — it does **not** silently
  fall back to stale data.
- Before refreshing, `bwmenu` runs `bw sync` so the cache reflects entries
  added on other devices (browser extension, web vault, phone). If the sync
  fails, it warns and continues with the previous cache.
- `bwmenu --no-sync` skips the `bw sync` step and refreshes from the CLI's
  local cache (faster when you've already synced recently).
- `bwmenu --offline` skips the refresh entirely and uses the existing cache
  (useful when you have no network or want zero Bitwarden contact). It also
  implies no sync.
- Folder names are optional display metadata; if their refresh fails, the menu
  still works without them.

## Environment variables

| Variable              | Purpose                                              |
|-----------------------|------------------------------------------------------|
| `BW_SESSION`          | Bitwarden session key (validated, never stored)      |
| `BW_MENU_CACHE_DIR`   | Override cache directory (default: script directory) |
| `BW_MENU_TERMINAL`    | Terminal to relaunch in when run without a TTY       |
| `BW_MENU_NO_RELAUNCH` | Set to `1` to disable the terminal relaunch          |

## Testing

The test suite uses mock vault data and fake `bw`/`fzf`/`clipboard` binaries —
no real Bitwarden, clipboard, or network:

```
bash tests/run_tests.sh
```

It covers cache refresh/atomicity/permissions, failed-refresh preservation,
offline mode, duplicate names, missing fields, all copy actions, TOTP
correctness (RFC 6238 vectors), cancellation, and that passwords never reach
stdout or the `fzf` list.

## Troubleshooting

- **"missing dependency"** — install the missing package (see Dependencies).
- **"BW_SESSION is invalid or expired"** — the key expires after inactivity.
  Refresh it with `export BW_SESSION="$(bw unlock --raw)"`.
- **"vault refresh failed"** — the session is likely invalid or the CLI is not
  authenticated. Run `bw status` and `bw login`/`bw unlock` manually.
- **"no clipboard utility found"** — install `wl-clipboard` (Wayland) or
  `xclip`/`xsel` (X11).
- **"no login entries found"** — the vault has no login-type items (secure
  notes, cards, and identities are cached but not shown; this is a password
  menu).
- **Menu doesn't appear when launched from a hotkey** — ensure a terminal
  (`st`, `alacritty`, …) is installed, or set `BW_MENU_TERMINAL`.

## Design notes

- **Python instead of `jq`.** JSON parsing and TOTP use Python 3's standard
  library. This removes the `jq` dependency (Python is required for TOTP
  anyway) and keeps all cache access in one auditable file. The performance
  goal is unaffected: the cache is parsed once per invocation, and `fzf` does
  the interactive filtering in memory.
- **No session persistence.** The original design cached the session key in
  `~/.cache`. That has been removed: `bwmenu` only ever reads `BW_SESSION`
  from the environment or captures a fresh key from `bw unlock --raw` for the
  duration of the run.
- **Known limitation.** Command substitution strips trailing newlines, so a
  password ending in newline characters would lose them on copy. Such
  passwords are rare in practice.

## Security checklist

- [x] `vault.json` / `folders.json` and temp files are gitignored.
- [x] Cache and temp files are mode `600`, written under umask `077`.
- [x] Secrets never appear in stdout, stderr, argv, or the `fzf` list.
- [x] No `bw get`/`bw list`/Bitwarden call after the menu opens.
- [x] `BW_SESSION` is never written to disk.
- [x] Failed refresh never clobbers a valid cache.
