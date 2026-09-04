#!/usr/bin/env bash
set -euo pipefail

minimum_xcode_major='26'
minimum_macos_sdk='26.0'

for command_name in xcode-select xcodebuild xcrun; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "缺少构建工具：$command_name" >&2
    exit 1
  fi
done

selected_developer_dir="${DEVELOPER_DIR:-$(xcode-select -p)}"
if [[ ! -d "$selected_developer_dir" ]]; then
  echo "Xcode 开发者目录不存在：$selected_developer_dir" >&2
  exit 1
fi

version_at_least() {
  local actual="$1"
  local minimum="$2"
  local actual_major actual_minor minimum_major minimum_minor

  if [[ ! "$actual" =~ ^[0-9]+([.][0-9]+){0,2}$ || ! "$minimum" =~ ^[0-9]+([.][0-9]+){0,2}$ ]]; then
    return 1
  fi

  IFS=. read -r actual_major actual_minor _ <<< "$actual"
  IFS=. read -r minimum_major minimum_minor _ <<< "$minimum"
  actual_minor="${actual_minor:-0}"
  minimum_minor="${minimum_minor:-0}"

  (( 10#$actual_major > 10#$minimum_major )) ||
    (( 10#$actual_major == 10#$minimum_major && 10#$actual_minor >= 10#$minimum_minor ))
}

xcode_version_output="$(xcodebuild -version)"
xcode_version="$(awk 'NR == 1 && $1 == "Xcode" { print $2 }' <<< "$xcode_version_output")"
macos_sdk_version="$(xcrun --sdk macosx --show-sdk-version)"
macos_sdk_path="$(xcrun --sdk macosx --show-sdk-path)"

if [[ "$xcode_version" != "$minimum_xcode_major" && "$xcode_version" != "$minimum_xcode_major".* ]]; then
  echo "发布与 CI 必须使用 Xcode ${minimum_xcode_major}，当前为：${xcode_version:-未知}。" >&2
  exit 1
fi
if ! version_at_least "$macos_sdk_version" "$minimum_macos_sdk"; then
  echo "macOS SDK 必须不低于 ${minimum_macos_sdk}，当前为：${macos_sdk_version:-未知}。" >&2
  exit 1
fi

echo "开发者目录：$selected_developer_dir"
printf '%s\n' "$xcode_version_output"
echo "macOS SDK：$macos_sdk_version"
echo "SDK 路径：$macos_sdk_path"
