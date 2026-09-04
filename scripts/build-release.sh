#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_root="$(cd "$script_dir/.." && pwd)"
product_config="$project_root/app/Config/Product.xcconfig"
release_version_file="$project_root/VERSION"
entitlements_path="$project_root/app/TunnelApp/Tunnelful.entitlements"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo '发布包只能在 macOS 上构建。' >&2
  exit 1
fi

for command_name in xcodebuild codesign hdiutil ditto lipo plutil shasum strip otool install_name_tool xmllint; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "缺少发布命令：$command_name" >&2
    exit 1
  fi
done

version="$(tr -d '[:space:]' < "$release_version_file")"
app_version="$(sed -nE 's/^[[:space:]]*MARKETING_VERSION[[:space:]]*=[[:space:]]*([^[:space:]]+).*/\1/p' "$product_config" | head -n 1)"
configured_release_version="$(sed -nE 's/^[[:space:]]*TUNNELFUL_RELEASE_VERSION[[:space:]]*=[[:space:]]*([^[:space:]]+).*/\1/p' "$product_config" | head -n 1)"
configured_bundle_identifier="$(sed -nE 's/^[[:space:]]*PRODUCT_BUNDLE_IDENTIFIER[[:space:]]*=[[:space:]]*([^[:space:]]+).*/\1/p' "$product_config" | head -n 1)"
expected_bundle_identifier='app.ihopeful.Tunnelful'
legacy_identity_build_cutoff='26'
expected_app_version="${version%%-*}"
if [[ -z "$version" || -z "$app_version" || -z "$configured_release_version" || -z "$configured_bundle_identifier" ]]; then
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
if [[ "$configured_bundle_identifier" != "$expected_bundle_identifier" ]]; then
  echo "应用 Bundle ID $configured_bundle_identifier 与发布身份 $expected_bundle_identifier 不一致。" >&2
  exit 1
fi

base_build="$(sed -nE 's/^[[:space:]]*CURRENT_PROJECT_VERSION[[:space:]]*=[[:space:]]*([^[:space:]]+).*/\1/p' "$product_config" | head -n 1)"
if [[ ! "$base_build" =~ ^[0-9]+$ ]] || (( base_build < 5 )) || (( base_build % 2 == 0 )); then
  echo "CURRENT_PROJECT_VERSION 必须是大于等于 5 的奇数，以便 Apple 芯片与 Intel 使用成对且不冲突的内部版本号。" >&2
  exit 1
fi
arm64_build="$base_build"
x86_64_build="$((base_build - 1))"
if [[ ! "$legacy_identity_build_cutoff" =~ ^[0-9]+$ ]] || (( x86_64_build < legacy_identity_build_cutoff )); then
  echo "新 Bundle ID 的最低内部版本必须大于等于旧身份迁移门槛 $legacy_identity_build_cutoff。" >&2
  exit 1
fi
sparkle_feed_url='https://ihopefulchina.github.io/Tunnelful/appcast.xml'
sparkle_public_key='0hyxOLR9zBFNvSdozSz0hALE/wHrk72Vsad4KxqpyM0='
release_notes_path="$project_root/.github/release-notes/$version.md"
if [[ ! -f "$release_notes_path" ]]; then
  echo "缺少发布说明：$release_notes_path" >&2
  exit 1
fi
if [[ ! -f "$entitlements_path" ]]; then
  echo "缺少代码签名权益文件：$entitlements_path" >&2
  exit 1
fi

build_number_for_architecture() {
  case "$1" in
    arm64) printf '%s\n' "$arm64_build" ;;
    x86_64) printf '%s\n' "$x86_64_build" ;;
    *)
      echo "不支持的发布架构：$1" >&2
      exit 1
      ;;
  esac
}

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
lsregister_bin='/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister'
cleanup() {
  if [[ -n "${work_dir:-}" && "$work_dir" == */tunnelful-release.* && -d "$work_dir" ]]; then
    if [[ -x "$lsregister_bin" ]]; then
      while IFS= read -r -d '' bundle; do
        "$lsregister_bin" -u "$bundle" >/dev/null 2>&1 || true
      done < <(find "$work_dir" -name 'Tunnelful.app' -type d -print0 2>/dev/null)
    fi
    rm -rf "$work_dir"
  fi
}
trap cleanup EXIT

app_name='Tunnelful.app'
release_architectures=(arm64 x86_64)

assert_thin_macho_tree() {
  local root="$1"
  local expected_architecture="$2"
  local candidate description slices
  local macho_count=0

  while IFS= read -r -d $'\0' candidate; do
    description="$(file -b "$candidate")"
    if [[ "$description" == Mach-O* ]]; then
      slices="$(lipo -archs "$candidate" 2>/dev/null)" || {
        echo "无法读取 Mach-O 架构：$candidate" >&2
        exit 1
      }
      if [[ "$slices" != "$expected_architecture" ]]; then
        echo "预期 $candidate 仅包含 $expected_architecture，实际为：$slices" >&2
        exit 1
      fi
      macho_count=$((macho_count + 1))
    fi
  done < <(find "$root" -type f -print0)

  if (( macho_count == 0 )); then
    echo "$root 中没有 Mach-O 文件。" >&2
    exit 1
  fi
}

write_sparkle_info_keys() {
  local info_plist="$1"
  local key value
  local -a pairs=(
    SUFeedURL "$sparkle_feed_url"
    SUPublicEDKey "$sparkle_public_key"
  )
  local index
  for (( index = 0; index < ${#pairs[@]}; index += 2 )); do
    key="${pairs[index]}"
    value="${pairs[index + 1]}"
    if plutil -extract "$key" raw "$info_plist" >/dev/null 2>&1; then
      plutil -replace "$key" -string "$value" "$info_plist"
    else
      plutil -insert "$key" -string "$value" "$info_plist"
    fi
  done
  for key in SUEnableAutomaticChecks SUVerifyUpdateBeforeExtraction; do
    if plutil -extract "$key" raw "$info_plist" >/dev/null 2>&1; then
      plutil -replace "$key" -bool true "$info_plist"
    else
      plutil -insert "$key" -bool true "$info_plist"
    fi
  done
}

build_release_for_architecture() {
  local architecture="$1"
  local architecture_name
  local build_number
  local derived_data="$work_dir/DerivedData-$architecture"
  local stage_dir="$work_dir/stage-$architecture"
  local dmg_name="Tunnelful-$version-$architecture.dmg"
  local sha_name="$dmg_name.sha256"
  build_number="$(build_number_for_architecture "$architecture")"

  case "$architecture" in
    arm64) architecture_name='Apple 芯片' ;;
    x86_64) architecture_name='Intel' ;;
    *)
      echo "不支持的发布架构：$architecture" >&2
      exit 1
      ;;
  esac

  echo "构建 Tunnelful ${version}（${architecture_name} / ${architecture}，内部版本 ${build_number}）…"
  xcodebuild \
    -quiet \
    -project "$project_root/app/TunnelApp.xcodeproj" \
    -scheme TunnelApp \
    -configuration Release \
    -destination "platform=macOS,arch=$architecture" \
    -derivedDataPath "$derived_data" \
    ARCHS="$architecture" \
    ONLY_ACTIVE_ARCH=YES \
    CURRENT_PROJECT_VERSION="$build_number" \
    CODE_SIGNING_ALLOWED=NO \
    TUNNELFUL_RELEASE_VERSION="$version" \
    build

  local built_app="$derived_data/Build/Products/Release/$app_name"
  if [[ ! -d "$built_app" ]]; then
    echo "没有找到 $architecture 构建产物：$built_app" >&2
    exit 1
  fi
  if [[ ! -f "$built_app/Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle" ]]; then
    echo "$architecture 构建产物缺少 Sparkle.framework。" >&2
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
  ditto --arch "$architecture" "$built_app" "$stage_dir/$app_name"
  ditto "$project_root/LICENSE" "$stage_dir/LICENSE"
  ditto "$project_root/THIRD_PARTY_NOTICES.md" "$stage_dir/THIRD_PARTY_NOTICES.md"
  ln -s /Applications "$stage_dir/Applications"

  local staged_info="$stage_dir/$app_name/Contents/Info.plist"
  write_sparkle_info_keys "$staged_info"
  if plutil -extract TunnelfulReleaseVersion raw "$staged_info" >/dev/null 2>&1; then
    plutil -replace TunnelfulReleaseVersion -string "$version" "$staged_info"
  else
    plutil -insert TunnelfulReleaseVersion -string "$version" "$staged_info"
  fi

  local actual_build actual_feed actual_public_key
  actual_build="$(plutil -extract CFBundleVersion raw "$staged_info")"
  if [[ "$actual_build" != "$build_number" ]]; then
    echo "$architecture 内部版本 $actual_build 与预期 $build_number 不一致。" >&2
    exit 1
  fi
  actual_feed="$(plutil -extract SUFeedURL raw "$staged_info")"
  actual_public_key="$(plutil -extract SUPublicEDKey raw "$staged_info")"
  if [[ "$actual_feed" != "$sparkle_feed_url" ]]; then
    echo "$architecture 应用 Sparkle 源地址不符合预期：$actual_feed" >&2
    exit 1
  fi
  if [[ "$actual_public_key" != "$sparkle_public_key" ]]; then
    echo "$architecture 应用 Sparkle 公钥不符合预期。" >&2
    exit 1
  fi
  if plutil -extract SUEnableInstallerLauncherService raw "$staged_info" >/dev/null 2>&1; then
    echo "非沙盒应用不应启用 Sparkle 安装器 XPC。" >&2
    exit 1
  fi

  local binary="$stage_dir/$app_name/Contents/MacOS/Tunnelful"
  echo "移除 $architecture 主程序中的调试符号与本机构建路径…"
  strip -S -x "$binary"
  if ! otool -l "$binary" | grep -F '@executable_path/../Frameworks' >/dev/null; then
    echo "补写 $architecture 主程序 Frameworks rpath…"
    install_name_tool -add_rpath '@executable_path/../Frameworks' "$binary"
  fi
  assert_thin_macho_tree "$stage_dir/$app_name" "$architecture"

  echo "为 $architecture 应用 ad-hoc 签名…"
  local sparkle_framework="$stage_dir/$app_name/Contents/Frameworks/Sparkle.framework"
  codesign --force --sign - --timestamp=none --options runtime --deep "$sparkle_framework"
  codesign --force --sign - --timestamp=none --options runtime --entitlements "$entitlements_path" "$stage_dir/$app_name"
  codesign --verify --deep --strict --verbose=2 "$stage_dir/$app_name"

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

generate_sparkle_appcast() {
  local sparkle_dir generate_appcast private_key_path appcast_dir sparkle_home sign_update
  local arm64_dmg x86_64_dmg
  local appcast_item_count migration_marker_count
  sparkle_dir="$work_dir/DerivedData-arm64/SourcePackages/artifacts/sparkle/Sparkle"
  generate_appcast="$sparkle_dir/bin/generate_appcast"
  if [[ ! -x "$generate_appcast" ]]; then
    generate_appcast="$(find "$work_dir/DerivedData-arm64/SourcePackages" -name generate_appcast -type f 2>/dev/null | head -n 1)"
  fi
  arm64_dmg="$output_dir/Tunnelful-$version-arm64.dmg"
  x86_64_dmg="$output_dir/Tunnelful-$version-x86_64.dmg"

  if [[ -z "${TUNNELFUL_SPARKLE_ED_PRIVATE_KEY:-}" && -z "${TUNNELFUL_SPARKLE_ED_KEY_FILE:-}" ]]; then
    if [[ "${GITHUB_ACTIONS:-}" == "true" || "${TUNNELFUL_REQUIRE_SPARKLE_APPCAST:-}" == "1" ]]; then
      echo '发布必须提供 TUNNELFUL_SPARKLE_ED_PRIVATE_KEY 或 TUNNELFUL_SPARKLE_ED_KEY_FILE 以生成 Sparkle 更新源。' >&2
      exit 1
    fi
    echo '未提供 Sparkle 私钥，已跳过 appcast。磁盘映像仍可发布；更新源可在之后用同一对密钥补签。'
    return 0
  fi
  if [[ ! -x "$generate_appcast" ]]; then
    echo "找不到 Sparkle generate_appcast。" >&2
    exit 1
  fi

  private_key_path="$work_dir/sparkle-ed-private.key"
  if [[ -n "${TUNNELFUL_SPARKLE_ED_KEY_FILE:-}" ]]; then
    ditto "$TUNNELFUL_SPARKLE_ED_KEY_FILE" "$private_key_path"
  else
    printf '%s\n' "$TUNNELFUL_SPARKLE_ED_PRIVATE_KEY" > "$private_key_path"
  fi
  chmod 600 "$private_key_path"

  appcast_dir="$work_dir/appcast"
  sparkle_home="$work_dir/sparkle-home"
  mkdir -p "$appcast_dir" "$sparkle_home"
  ditto "$arm64_dmg" "$appcast_dir/Tunnelful-$version-arm64.dmg"
  ditto "$x86_64_dmg" "$appcast_dir/Tunnelful-$version-x86_64.dmg"
  ditto "$release_notes_path" "$appcast_dir/Tunnelful-$version-arm64.md"
  ditto "$release_notes_path" "$appcast_dir/Tunnelful-$version-x86_64.md"

  # 隔离 Sparkle 缓存，避免把解压出的 Intel 应用写进用户 Library/Caches 并被 Launch Services 索引。
  HOME="$sparkle_home" "$generate_appcast" \
    --ed-key-file "$private_key_path" \
    --download-url-prefix "https://github.com/ihopefulChina/Tunnelful/releases/download/v$version/" \
    --link "https://github.com/ihopefulChina/Tunnelful/releases/tag/v$version" \
    --informational-update-versions "<$legacy_identity_build_cutoff" \
    --embed-release-notes \
    --maximum-deltas 0 \
    "$appcast_dir"

  # 0.1.9 及更早版本使用 app.tunnelful.mac。Sparkle 把 Bundle ID 视为
  # 永久应用身份，旧身份不能安全地用普通应用包原地替换为新身份。
  # 因此所有旧 host build（arm64 最高 25、x86_64 最高 24）只看到
  # “前往网页下载”的信息型更新；新身份从 build 26 起恢复普通自更新。
  xmllint --noout "$appcast_dir/appcast.xml"
  appcast_item_count="$(xmllint --xpath "count(//*[local-name()='item'])" "$appcast_dir/appcast.xml")"
  migration_marker_count="$(xmllint --xpath "count(//*[local-name()='item']/*[local-name()='informationalUpdate']/*[local-name()='belowVersion' and text()='$legacy_identity_build_cutoff'])" "$appcast_dir/appcast.xml")"
  if [[ "$appcast_item_count" == "0" || "$migration_marker_count" != "$appcast_item_count" ]]; then
    echo "Sparkle 更新源没有为全部条目保留旧 Bundle ID 的信息型迁移门槛。" >&2
    exit 1
  fi

  ditto "$appcast_dir/appcast.xml" "$output_dir/appcast.xml"
  ditto "$appcast_dir/appcast.xml" "$project_root/appcast.xml"
  mkdir -p "$project_root/website/public" "$output_dir/.sparkle-bin"
  ditto "$appcast_dir/appcast.xml" "$project_root/website/public/appcast.xml"
  sign_update="${generate_appcast%generate_appcast}sign_update"
  if [[ -x "$sign_update" ]]; then
    ditto "$sign_update" "$output_dir/.sparkle-bin/sign_update"
  fi
  echo "Sparkle 更新源：$output_dir/appcast.xml"
}

generate_sparkle_appcast

echo '注意：此发布包仅为 ad-hoc 签名，未使用 Developer ID，也未经过 Apple 公证。'
