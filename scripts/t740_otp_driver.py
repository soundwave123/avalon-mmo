#!/usr/bin/env python3
"""T-740 E2E driver — drives the one-time-password flow over a real WebSocket.

Invoked by scripts/test-t740-otp-e2e.sh, which owns the isolated gateway + Postgres. This half
speaks the wire protocol only: every claim below is a frame the gateway actually sent.

The success paths run FIRST on purpose. The gateway's rate limiter keys on the source IP, so
every connection from this script shares one budget of 5 failures per minute — the moment the
rate-limit phase starts, no further login can succeed.

Usage: t740_otp_driver.py <ws_url> <otp_user> <otp> <chosen_password> <normal_user> <normal_pw>
"""

import asyncio
import json
import sys

from websockets.asyncio.client import connect

RECV_TIMEOUT = 15
LOGIN_FAILURE_BUDGET = 5  # LoginRateLimiter(5, 60_000) in server/gateway/scripts/main.gd

failures = []


def check(condition, message, detail=""):
    print(("  PASS  " if condition else "  FAIL  ") + message + (f"  [{detail}]" if detail and not condition else ""))
    if not condition:
        failures.append(message)


async def exchange(ws, request):
    await ws.send(json.dumps(request))
    return json.loads(await asyncio.wait_for(ws.recv(), timeout=RECV_TIMEOUT))


async def single(url, request):
    """One request on its own fresh connection — how the real client logs in each time."""
    async with connect(url) as ws:
        return await exchange(ws, request)


def login(username, password):
    return {"type": "login", "username": username, "password": password, "build": ""}


async def main():
    url, otp_user, otp, chosen, normal_user, normal_pw = sys.argv[1:7]

    print("\n1+2. first login with the one-time password, then set_password on the SAME socket")
    async with connect(url) as ws:
        first = await exchange(ws, login(otp_user, otp))
        check(
            first.get("type") == "password_change_required",
            "a one-time password is answered with password_change_required, not a session",
            first,
        )
        check(first.get("min_length") == 8, "the gateway states the 8-character minimum", first)
        check("access_token" not in first, "no token is issued before the password is chosen", first)

        done = await exchange(
            ws,
            {"type": "set_password", "username": otp_user, "password": otp, "new_password": chosen},
        )
        check(done.get("type") == "login_ok", "set_password logs the player straight in", done)
        check(bool(done.get("access_token")), "an access token came back in the same round trip")
        check(bool(done.get("refresh_token")), "a refresh token came back too")
        check(int(done.get("world", {}).get("port", 0)) > 0, "the world address rides along", done)
        check(done.get("select") is False, "a fresh account drops straight in (no roster screen)")

    print("\n3. the personal password works on a brand-new connection")
    relog = await single(url, login(otp_user, chosen))
    check(relog.get("type") == "login_ok", "relogin with the chosen password succeeds", relog)
    check(bool(relog.get("access_token")), "and issues a session like any normal account")

    print("\n4. an account that is not on a one-time password is untouched")
    settled = await single(url, login(normal_user, normal_pw))
    check(
        settled.get("type") == "login_ok",
        "a settled account still logs in with no password step",
        settled,
    )

    print("\n5. the one-time password is dead (these count against the rate limiter)")
    dead = await single(url, login(otp_user, otp))
    check(
        dead.get("type") == "login_err" and dead.get("reason") == "invalid_credentials",
        "the spent one-time password no longer logs in",
        dead,
    )
    replay = await single(
        url,
        {
            "type": "set_password",
            "username": otp_user,
            "password": otp,
            "new_password": "a third password",
        },
    )
    check(
        replay.get("type") == "set_password_err" and replay.get("reason") == "invalid_credentials",
        "a replayed one-time password cannot set the password a second time",
        replay,
    )

    print("\n6. set_password spends the SAME budget as login")
    spent = 2  # the two failures above
    while spent < LOGIN_FAILURE_BUDGET:
        await single(url, login(otp_user, "definitely-not-the-password"))
        spent += 1
    limited_login = await single(url, login(otp_user, chosen))
    check(
        limited_login.get("reason") == "rate_limited",
        "the login budget is exhausted after 5 failures",
        limited_login,
    )
    limited_set = await single(
        url,
        {
            "type": "set_password",
            "username": otp_user,
            "password": otp,
            "new_password": "yet another password",
        },
    )
    check(
        limited_set.get("type") == "set_password_err"
        and limited_set.get("reason") == "rate_limited",
        "set_password is refused by that same exhausted budget — not a second unmetered door",
        limited_set,
    )

    print()
    if failures:
        print(f"DRIVER FAIL — {len(failures)} assertion(s):")
        for message in failures:
            print(f"  - {message}")
        return 1
    print("DRIVER PASS — the full one-time-password flow held over real WebSocket")
    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
