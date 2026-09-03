#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_root="$(cd "$script_dir/.." && pwd)"
product_config="$project_root/app/Config/Product.xcconfig"
release_version_file="$project_root/VERSION"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo '发布包只能在 macOS 上构建。' >&2
  exit 1
fi

for command_name in xcodebuild codesign hdiutil ditto lipo plutil shasum strip; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "缺少发布命令：$command_name" >&2
    exit 1
  fi
done

version="$(tr -d '[:space:]' < "$release_version_file")"
app_version="$(sed -nE 's/^[[:space:]]*MARKETING_VERSION[[:space:]]*=[[:space:]]*([^[:space:]]+).*/\1/p' "$product_config" | head -n 1)"
configured_release_version="$(sed -nE 's/^[[:space:]]*TUNNELFUL_RELEASE_VERSION[[:space:]]*=[[:space:]]*([^[:space:]]+).*/\1/p' "$product_config" | head -n 1)"
expected_app_version="${version%%-*}"
if [[ -z "$version" || -z "$app_version" || -z "$configured_release_version" ]]; then
  echo '未能读取发布版本或应用版本。' >&2
  exit 1
fi
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]]; then
  echo "发布版本格式无效：$version" >&2
  exit 1
fi
if [[ "$app_version" != "$expected_app_version" ]]; then
  echo "应用版本 $app_version 与发布基础版本 $expected_app_version 不一致。" >&2
  exit 1
fi
if [[ "$configured_release_version" != "$version" ]]; then
  echo "应用完整版本 $configured_release_version 与根目录发布版本 $version 不一致。" >&2
  exit 1
fi

if [[ $# -gt 1 ]]; then
  echo '用法：scripts/build-release.sh [输出目录]' >&2
  exit 1
fi

output_dir="${1:-$project_root/release}"
if [[ "$output_dir" != /* ]]; then
  output_dir="$project_root/$output_dir"
fi
mkdir -p "$output_dir"

work_dir="$(mktemp -d -t tunnelful-release)"
cleanup() {
  if [[ -n "${work_dir:-}" && "$work_dir" == */tunnelful-release.* && -d "$work_dir" ]]; then
    rm -rf "$work_dir"
  fi
}
trap cleanup EXIT

app_name='Tunnelful.app'
release_architectures=(arm64 x86_64)

build_release_for_architecture() {
  local architecture="$1"
  local architecture_name
  local derived_data="$work_dir/DerivedData-$architecture"
  local stage_dir="$work_dir/stage-$architecture"
  local dmg_name="Tunnelful-$version-$architecture.dmg"
  local sha_name="$dmg_name.sha256"

  case "$architecture" in
    arm64) architecture_name='Apple 芯片' ;;
    x86_64) architecture_name='Intel' ;;
    *)
      echo "不支持的发布架构：$architecture" >&2
      exit 1
      ;;
  esac

  echo "构建 Tunnelful ${version}（${architecture_name} / ${architecture}）…"
  xcodebuild \
    -quiet \
    -project "$project_root/app/TunnelApp.xcodeproj" \
    -scheme TunnelApp \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -derivedDataPath "$derived_data" \
    ARCHS="$architecture" \
    ONLY_ACTIVE_ARCH=NO \
    CODE_SIGNING_ALLOWED=NO \
    TUNNELFUL_RELEASE_VERSION="$version" \
    build

  local built_app="$derived_data/Build/Products/Release/$app_name"
  if [[ ! -d "$built_app" ]]; then
    echo "没有找到 $architecture 构建产物：$built_app" >&2
    exit 1
  fi

  local built_info_plist="$built_app/Contents/Info.plist"
  # Xcode 的自动 Info.plist 生成器不会稳定写入自定义 INFOPLIST_KEY_*；
  # 发布包在签名前显式落盘，并立即回读校验。
  if plutil -extract TunnelfulReleaseVersion raw "$built_info_plist" >/dev/null 2>&1; then
    plutil -replace TunnelfulReleaseVersion -string "$version" "$built_info_plist"
  else
    plutil -insert TunnelfulReleaseVersion -string "$version" "$built_info_plist"
  fi
  local embedded_release_version
  if ! embedded_release_version="$(plutil -extract TunnelfulReleaseVersion raw "$built_info_plist" 2>/dev/null)"; then
    echo "$architecture 应用 Info.plist 缺少 TunnelfulReleaseVersion。" >&2
    exit 1
  fi
  if [[ "$embedded_release_version" != "$version" ]]; then
    echo "$architecture 应用完整版本 $embedded_release_version 与发布版本 $version 不一致。" >&2
    exit 1
  fi

  mkdir -p "$stage_dir"
  ditto "$built_app" "$stage_dir/$app_name"
  ditto "$project_root/LICENSE" "$stage_dir/LICENSE"
  ditto "$project_root/THIRD_PARTY_NOTICES.md" "$stage_dir/THIRD_PARTY_NOTICES.md"
  ln -s /Applications "$stage_dir/Applications"

  local binary="$stage_dir/$app_name/Contents/MacOS/Tunnelful"
  echo "移除 $architecture 发布二进制中的调试符号与本机构建路径…"
  strip -S -x "$binary"

  echo "为 $architecture 应用 ad-hoc 签名…"
  codesign --force --deep --sign - --timestamp=none --options runtime "$stage_dir/$app_name"
  codesign --verify --deep --strict --verbose=2 "$stage_dir/$app_name"

  local actual_architecture
  actual_architecture="$(lipo -archs "$binary")"
  if [[ "$actual_architecture" != "$architecture" ]]; then
    echo "发布二进制架构不符合预期；预期 $architecture，实际 $actual_architecture。" >&2
    exit 1
  fi

  rm -f "$output_dir/$dmg_name" "$output_dir/$sha_name"
  hdiutil create \
    -volname 'Tunnelful' \
    -srcfolder "$stage_dir" \
    -ov \
    -format UDZO \
    "$output_dir/$dmg_name"
  hdiutil verify "$output_dir/$dmg_name"

  (
    cd "$output_dir"
    shasum -a 256 "$dmg_name" > "$sha_name"
  )

  echo "发布产物：$output_dir/$dmg_name"
  echo "校验文件：$output_dir/$sha_name"
}

for release_architecture in "${release_architectures[@]}"; do
  build_release_for_architecture "$release_architecture"
done

echo '注意：此发布包仅为 ad-hoc 签名，未使用 Developer ID，也未经过 Apple 公证。'
