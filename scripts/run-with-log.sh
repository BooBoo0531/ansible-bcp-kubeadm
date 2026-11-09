#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

for name in "$@"; do
  log="report/${name}.log"
  {
    echo "# Command: ansible-playbook playbooks/${name}.yml"
    echo "# Date:    $(date '+%Y-%m-%d %H:%M:%S %z')"
    echo
  } > "$log"
  ansible-playbook "playbooks/${name}.yml" 2>&1 | tee -a "$log"
done
