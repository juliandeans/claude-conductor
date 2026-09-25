#!/usr/bin/env python3
"""Queries Codex' quota via the local app server.

Uses `codex app-server --stdio` with line-delimited JSON-RPC (no
LSP content-length framing) and calls the method account/rateLimits/read
-- a pure account endpoint, costs 0 tokens (no model call).
Waits for the initialize response before sending the actual request
(event-driven, no blind sleep) -- avoids a race condition
where the follow-up request arrives before the handshake completes.
"""
import json
import subprocess
import sys
import threading
import time


def send(proc, obj):
    proc.stdin.write((json.dumps(obj) + "\n").encode())
    proc.stdin.flush()


def read_messages(proc, out):
    for line in proc.stdout:
        line = line.strip()
        if not line:
            continue
        try:
            out.append(json.loads(line))
        except json.JSONDecodeError:
            pass


def wait_for_id(out, msg_id, timeout):
    deadline = time.time() + timeout
    while time.time() < deadline:
        for m in out:
            if m.get("id") == msg_id:
                return m
        time.sleep(0.05)
    return None


def main():
    try:
        proc = subprocess.Popen(
            ["codex", "app-server", "--stdio"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
    except OSError as e:
        print(json.dumps({"error": f"codex CLI not found or failed to start: {e}"}),
              file=sys.stderr)
        sys.exit(1)
    out = []
    t = threading.Thread(target=read_messages, args=(proc, out), daemon=True)
    t.start()

    send(proc, {
        "jsonrpc": "2.0", "id": 1, "method": "initialize",
        "params": {"clientInfo": {"name": "quota-check", "version": "1.0.0"}},
    })
    init_result = wait_for_id(out, 1, timeout=5)
    if init_result is None or "result" not in init_result:
        print(json.dumps({"error": "codex app-server did not respond to initialize within 5s"}),
              file=sys.stderr)
        proc.kill()
        sys.exit(1)

    # Protocol-mandated notification after initialize -- schema verified via
    # `codex app-server generate-json-schema --out <dir>` (ClientNotification.json,
    # title "InitializedNotification", method enum exactly "initialized", no
    # params). No id field, since it is a notification, not a request.
    send(proc, {"jsonrpc": "2.0", "method": "initialized"})

    send(proc, {"jsonrpc": "2.0", "id": 2, "method": "account/rateLimits/read", "params": {}})
    result = wait_for_id(out, 2, timeout=5)

    proc.terminate()
    try:
        proc.wait(timeout=2)
    except subprocess.TimeoutExpired:
        proc.kill()

    if result is None or "result" not in result:
        err = result.get("error") if result else "no response from codex app-server"
        print(json.dumps({"error": err}), file=sys.stderr)
        sys.exit(1)

    limits = result["result"].get("rateLimits")
    if limits is None:
        print(json.dumps({"error": "unexpected response structure: missing rateLimits"}),
              file=sys.stderr)
        sys.exit(1)

    primary = limits.get("primary") or {}
    secondary = limits.get("secondary") or {}
    credits = result["result"].get("rateLimitResetCredits", {})

    # Earliest expiry among the *available* reset credits -- several
    # are possible, even if currently only one was observed. Without an
    # available credit the field stays null (no expiry to warn about).
    available_credits = [c for c in credits.get("credits", []) if c.get("status") == "available"]
    earliest_expiry = min(
        (c.get("expiresAt") for c in available_credits if c.get("expiresAt") is not None),
        default=None,
    )

    print(json.dumps({
        "used_pct_primary": primary.get("usedPercent", 0),
        "resets_at_primary": primary.get("resetsAt"),
        "used_pct_secondary": secondary.get("usedPercent", 0),
        "resets_at_secondary": secondary.get("resetsAt"),
        "reset_credits_available": credits.get("availableCount", 0),
        "reset_credit_expires_at": earliest_expiry,
        "plan_type": limits.get("planType"),
    }))


if __name__ == "__main__":
    main()
