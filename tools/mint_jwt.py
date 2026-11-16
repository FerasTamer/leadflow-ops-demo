"""Mint a short-lived HS256 JWT for a tenant user (demo stand-in for the real identity provider).

usage: python tools/mint_jwt.py <tenant_id> [--forge]
  --forge  sign with a wrong key, to show that PostgREST rejects tampered tokens
The signing secret is read from the JWT_SECRET environment variable.
"""
import base64
import hashlib
import hmac
import json
import os
import sys
import time


def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def main() -> int:
    if len(sys.argv) < 2 or not sys.argv[1].isdigit():
        print(__doc__, file=sys.stderr)
        return 2
    secret = os.environ.get("JWT_SECRET", "")
    if len(secret) < 32:
        print("JWT_SECRET must be set and at least 32 characters", file=sys.stderr)
        return 2
    if "--forge" in sys.argv:
        secret = "attacker-guess-" + "x" * 32
    header = {"alg": "HS256", "typ": "JWT"}
    payload = {"role": "tenant_user", "tenant_id": int(sys.argv[1]), "exp": int(time.time()) + 900}
    signing_input = f"{b64url(json.dumps(header).encode())}.{b64url(json.dumps(payload).encode())}"
    signature = hmac.new(secret.encode(), signing_input.encode(), hashlib.sha256).digest()
    print(f"{signing_input}.{b64url(signature)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
