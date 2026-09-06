#!/usr/bin/env bash
set -euo pipefail
convertor_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ ! -x "$convertor_root/.venv/bin/python" ]]; then
  python3 -m venv "$convertor_root/.venv"
  "$convertor_root/.venv/bin/python" -m pip install -r "$convertor_root/requirements.txt"
fi
bash "$convertor_root/build_validator.sh"
exec "$convertor_root/.venv/bin/python" "$convertor_root/convert.py" "$@"
