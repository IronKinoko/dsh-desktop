#!/bin/zsh

set -euo pipefail

readonly REPO_ROOT="${0:A:h:h}"
readonly PROJECT_PATH="${REPO_ROOT}/dsh-desktop.xcodeproj"
readonly DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-/tmp/dsh-desktop-derived}"
readonly CONFIGURATION="Release"
readonly APP_NAME="Deepseek Harness"
readonly BUILT_APP="${DERIVED_DATA_PATH}/Build/Products/${CONFIGURATION}/${APP_NAME}.app"
readonly INSTALLED_APP="/Applications/${APP_NAME}.app"

echo "Building unsigned ${CONFIGURATION}..."
xcodebuild \
  -project "${PROJECT_PATH}" \
  -scheme dsh-desktop \
  -configuration "${CONFIGURATION}" \
  -derivedDataPath "${DERIVED_DATA_PATH}" \
  CODE_SIGNING_ALLOWED=NO \
  build

if [[ ! -d "${BUILT_APP}" ]]; then
  echo "error: built app not found at ${BUILT_APP}" >&2
  exit 1
fi

echo "Stopping ${APP_NAME}..."
pkill -TERM -x "${APP_NAME}" 2>/dev/null || true
sleep 1
pkill -KILL -x "${APP_NAME}" 2>/dev/null || true

echo "Deploying to ${INSTALLED_APP}..."
rm -rf "${INSTALLED_APP}"
ditto "${BUILT_APP}" "${INSTALLED_APP}"

echo "Deployment complete: ${INSTALLED_APP}"
