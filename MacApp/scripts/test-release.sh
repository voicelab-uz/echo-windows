#!/bin/bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
/bin/bash -n scripts/release.sh scripts/create-installer-dmg.sh
PYTHONDONTWRITEBYTECODE=1 python3 Tests/InstallerLayoutRegression.py
python3 Tests/ReleaseWorkflowRegression.py
PYTHONDONTWRITEBYTECODE=1 python3 Tests/PushProfileRegression.py
PYTHONDONTWRITEBYTECODE=1 python3 Tests/UpdatePublicationRegression.py
PYTHONDONTWRITEBYTECODE=1 python3 Tests/GitHubPublicationRegression.py
PYTHONDONTWRITEBYTECODE=1 python3 Tests/ReleaseRetentionRegression.py
