#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${ROOT}"

echo "==> 1/3 Syntax check"
bash -n install.sh
bash -n fix-phpbolt.sh

echo "==> 2/3 Built-in self-test (env/composer/bolt helpers)"
POWERPS_SELFTEST=1 \
POWERPS_CORE_DIR="${POWERPS_CORE_DIR:-${ROOT}/../powerps-core}" \
 bash install.sh

echo "==> 3/3 Docker E2E (optional, run on VPS only)"
echo "Safe daily check: done above."
echo "Full install test: I_UNDERSTAND_DOCKER_E2E=1 ./run_test_env.sh"
echo "  (Never use --privileged / host cgroup mounts — can crash the host.)"

echo ""
echo "All automated smoke tests passed."
