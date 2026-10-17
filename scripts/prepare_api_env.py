"""Prepare the API runtime configuration without printing private values."""

import argparse
import json
import os
from pathlib import Path
import re
import sys


PUBLIC_KEYS = {"SUPABASE_JWKS_URL", "SUPABASE_ISSUER", "SUPABASE_AUDIENCE", "ADMIN_EMAIL", "RECONCILE_HISTORY_ENABLED"}
PRIVATE_KEYS = ("POSTGRES_PASSWORD", "PIPELINE_SERVICE_TOKEN")
# The deployment sources this file as shell input as well as using it for Compose.
SAFE_VALUE = re.compile(r"[A-Za-z0-9_./:@,+%=\-]*", re.ASCII)


def prepare_runtime(base, public):
    if not isinstance(public, dict) or set(public) != PUBLIC_KEYS:
        raise ValueError("Public configuration must contain exactly the pilot runtime settings")
    for key, value in public.items():
        if not isinstance(value, str) or not value or not SAFE_VALUE.fullmatch(value):
            raise ValueError(f"Invalid public setting: {key}")
    issuer = public["SUPABASE_ISSUER"]
    if not re.fullmatch(r"https://[a-z0-9]+\.supabase\.co/auth/v1", issuer):
        raise ValueError("Invalid SUPABASE_ISSUER")
    if public["SUPABASE_JWKS_URL"] != issuer + "/.well-known/jwks.json":
        raise ValueError("SUPABASE_JWKS_URL must belong to SUPABASE_ISSUER")
    if public["SUPABASE_AUDIENCE"] != "authenticated":
        raise ValueError("SUPABASE_AUDIENCE must be authenticated")
    if not re.fullmatch(r"[^@]+@[^@]+\.[^@]+", public["ADMIN_EMAIL"]):
        raise ValueError("Invalid ADMIN_EMAIL")
    if public["RECONCILE_HISTORY_ENABLED"] not in ("true", "false"):
        raise ValueError("RECONCILE_HISTORY_ENABLED must be true or false")

    settings = {}
    for number, line in enumerate(base.splitlines(), 1):
        if not re.fullmatch(r"[A-Z_]+=[^\s]*", line):
            raise ValueError(f"PULSE_ENV malformed at line {number}")
        key, value = line.split("=", 1)
        if key in settings:
            raise ValueError(f"PULSE_ENV duplicate key at line {number}")
        settings[key] = value
    for key in PRIVATE_KEYS:
        value = settings.get(key, "")
        if not value or "<" in value or ">" in value:
            raise ValueError(f"PULSE_ENV requires an existing non-placeholder {key}")

    settings.update(public)
    for number, value in enumerate(settings.values(), 1):
        if not SAFE_VALUE.fullmatch(value):
            raise ValueError(f"PULSE_ENV contains an unsafe shell value at entry {number}")
    return "".join(f"{key}={value}\n" for key, value in settings.items())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        public = json.loads(args.config.read_text())
        runtime = prepare_runtime(os.environ.get("PULSE_ENV", ""), public)
        descriptor = os.open(args.output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(descriptor, "w") as output:
            output.write(runtime)
    except (OSError, json.JSONDecodeError):
        print("Cannot read public configuration or create a new private runtime file", file=sys.stderr)
        return 1
    except ValueError as error:
        print(str(error), file=sys.stderr)
        return 1
    print("API runtime configuration validated; existing private credentials preserved")
    return 0


if __name__ == "__main__":
    sys.exit(main())
