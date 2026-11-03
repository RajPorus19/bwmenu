#!/usr/bin/env python3
"""bwmenu helper — parse the local vault cache, resolve items, compute TOTP.

This module reads only local JSON files. It never contacts Bitwarden and is
the single place that touches the cache, so secrets stay out of shell code.

Commands
--------
validate <file>                     exit 0 iff <file> is a JSON array
records <vault.json> [folders.json] print TSV rows (name, username, uri,
                                    folder, id) for login items, sorted
get <vault.json> <id> <field>      print one field value (no trailing NL);
                                    field in name|username|password|uri|totp
totp-code <secret|otpauth://...> <unix_ts>   print TOTP at a fixed time (tests)
"""

import base64
import hashlib
import hmac
import json
import struct
import sys
import time
import urllib.parse


def load(path):
    with open(path, "r", encoding="utf-8") as fh:
        return json.load(fh)


def sanitize(value):
    """Make a value safe for a tab/newline-delimited fzf record."""
    if value is None:
        return ""
    return str(value).replace("\t", " ").replace("\n", " ").replace("\r", " ")


def totp(seed, now=None):
    """Return a TOTP code from a raw base32 secret or an otpauth:// URI.

    Defaults to SHA1 / 30s / 6 digits, honouring the otpauth parameters when
    present. Returns "" on missing or malformed input.
    """
    if not seed:
        return ""
    digits = 6
    period = 30
    algorithm = "sha1"
    secret = seed
    if seed.startswith("otpauth://"):
        query = seed.partition("?")[2]
        params = urllib.parse.parse_qs(query)
        secret = params.get("secret", [""])[0]
        digits = int(params.get("digits", ["6"])[0])
        period = int(params.get("period", ["30"])[0])
        algorithm = params.get("algorithm", ["SHA1"])[0].lower()
    secret = secret.upper().replace(" ", "").rstrip("=")
    secret += "=" * (-len(secret) % 8)
    if not secret:
        return ""
    try:
        key = base64.b32decode(secret)
    except Exception:
        return ""
    if algorithm not in ("sha1", "sha256", "sha512"):
        algorithm = "sha1"
    if now is None:
        now = int(time.time())
    counter = now // period
    msg = struct.pack(">Q", counter)
    digest = hmac.new(key, msg, getattr(hashlib, algorithm)).digest()
    offset = digest[-1] & 0x0F
    code = (struct.unpack(">I", digest[offset:offset + 4])[0] & 0x7FFFFFFF) % (10 ** digits)
    return str(code).zfill(digits)


def first_uri(login):
    for u in login.get("uris") or []:
        if isinstance(u, dict) and u.get("uri"):
            return u["uri"]
    return ""


def find_item(items, item_id):
    for it in items:
        if isinstance(it, dict) and it.get("id") == item_id:
            return it
    return None


def main(argv):
    if not argv:
        sys.exit("usage: bwmenu.py <command> [args...]")
    cmd = argv[0]

    if cmd == "validate":
        try:
            data = load(argv[1])
        except Exception:
            sys.exit(1)
        sys.exit(0 if isinstance(data, list) else 1)

    if cmd == "records":
        vault = argv[1]
        folders_path = argv[2] if len(argv) > 2 else ""
        try:
            items = load(vault)
        except Exception:
            sys.exit(1)
        if not isinstance(items, list):
            sys.exit(1)

        folder_names = {}
        if folders_path:
            try:
                for f in load(folders_path):
                    if isinstance(f, dict) and f.get("id"):
                        folder_names[f["id"]] = f.get("name") or ""
            except Exception:
                pass

        rows = []
        for it in items:
            if not isinstance(it, dict):
                continue
            login = it.get("login")
            if not isinstance(login, dict):
                continue
            iid = it.get("id")
            if not iid:
                continue
            name = sanitize(it.get("name")) or "(unnamed)"
            username = sanitize(login.get("username"))
            uri = sanitize(first_uri(login))
            folder = sanitize(folder_names.get(it.get("folderId"), ""))
            rows.append("\t".join([name, username, uri, folder, iid]))
        rows.sort(key=lambda r: r.lower())
        print("\n".join(rows))
        sys.exit(0)

    if cmd == "get":
        vault = argv[1]
        item_id = argv[2]
        field = argv[3]
        try:
            items = load(vault)
        except Exception:
            sys.exit(1)
        item = find_item(items, item_id)
        if item is None:
            sys.exit(2)
        login = item.get("login") or {}
        value = ""
        if field == "name":
            value = sanitize(item.get("name")) or "(unnamed)"
        elif field == "username":
            value = login.get("username") or ""
        elif field == "password":
            value = login.get("password") or ""
        elif field == "uri":
            value = first_uri(login)
        elif field == "totp":
            value = totp(login.get("totp"))
        sys.stdout.write(str(value))
        sys.exit(0)

    if cmd == "totp-code":
        seed = argv[1]
        ts = int(argv[2])
        print(totp(seed, now=ts))
        sys.exit(0)

    sys.exit("unknown command: %s" % cmd)


if __name__ == "__main__":
    main(sys.argv[1:])
