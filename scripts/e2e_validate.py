#!/usr/bin/env python3
"""E2E validate_session test — connects to master via WebSocket, tests tokens."""
import asyncio
import json
import os
import sys
import websockets

VALID_TOKEN = os.environ["VALID_TOKEN"]
REVOKED_TOKEN = os.environ["REVOKED_TOKEN"]
INVALID_TOKEN = os.environ["INVALID_TOKEN"]

MASTER_URI = "ws://127.0.0.1:9100"

async def send_request(ws, method: str, params: dict) -> dict:
    req = {"id": 1, "method": method, "params": params}
    await ws.send(json.dumps(req))
    resp_raw = await asyncio.wait_for(ws.recv(), timeout=5)
    return json.loads(resp_raw)

async def main():
    async with websockets.connect(MASTER_URI) as ws:
        tests_run = 0
        tests_passed = 0
        tests_failed = 0

        # Test 1: Valid token
        tests_run += 1
        print("\n--- TEST 1: Valid token (should return success=true, username=testuser) ---")
        resp = await send_request(ws, "validate_session", {"token": VALID_TOKEN})
        print(f"Raw response: {json.dumps(resp)}")
        result = resp.get("result", {})
        if result.get("success", False) and result.get("username") == "testuser":
            tests_passed += 1
            print(f"PASS: Valid token validated — username={result['username']} (DB-backed)")
        else:
            tests_failed += 1
            print(f"FAIL: Expected success=true,username=testuser, got: {json.dumps(result)}")

        # Test 2: Revoked token
        tests_run += 1
        print("\n--- TEST 2: Revoked token (should return success=false, reason=revoked) ---")
        resp = await send_request(ws, "validate_session", {"token": REVOKED_TOKEN})
        print(f"Raw response: {json.dumps(resp)}")
        result = resp.get("result", {})
        if not result.get("success", True) and result.get("reason") == "revoked":
            tests_passed += 1
            print("PASS: Revoked token correctly rejected — reason=revoked (DB-backed)")
        else:
            tests_failed += 1
            print(f"FAIL: Expected success=false,reason=revoked, got: {json.dumps(result)}")

        # Test 3: Garbage/invalid token
        tests_run += 1
        print("\n--- TEST 3: Garbage token (should return success=false, reason=...) ---")
        resp = await send_request(ws, "validate_session", {"token": INVALID_TOKEN})
        print(f"Raw response: {json.dumps(resp)}")
        result = resp.get("result", {})
        if not result.get("success", True) and result.get("reason"):
            tests_passed += 1
            print(f"PASS: Garbage token rejected — reason={result['reason']}")
        else:
            tests_failed += 1
            print(f"FAIL: Expected success=false with a reason, got: {json.dumps(result)}")

        # Summary
        print(f"\n=== E2E TEST RESULTS ===")
        print(f"Passed: {tests_passed}, Failed: {tests_failed}, Total: {tests_run}")
        if tests_failed == 0:
            print("ALL E2E TESTS PASSED")
        else:
            print("SOME E2E TESTS FAILED")
        sys.exit(1 if tests_failed > 0 else 0)

if __name__ == "__main__":
    asyncio.run(main())
