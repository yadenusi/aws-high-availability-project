"""Operational commands for the storefront.

Usage:
    python manage.py init-db     create tables and seed products (idempotent)
    python manage.py check       probe the database and cache and print the result
"""

import json
import sys

import data


def main(argv):
    command = argv[1] if len(argv) > 1 else ""
    if command == "init-db":
        data.init_db()
        print("schema ready")
        return 0
    if command == "check":
        status = data.dependency_status()
        print(json.dumps(status, indent=2))
        return 0 if all(item["ok"] for item in status.values()) else 1
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
