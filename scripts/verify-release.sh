#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_root="$(cd "$script_dir/.." && pwd)"
release_version_file="$project_root/VERSION"

if [[ $# -ne 1 ]]; then
  echo '用法：scripts/verify-release.sh <Tunnelful.dmg>' >&2
  exit 1
fi

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo '发布包验证只能在 macOS 上运行。' >&2
  exit 1
fi

dmg_path="$1"
if [[ ! -f "$dmg_path" ]]; then
  echo "磁盘映像不存在：$dmg_path" >&2
  exit 1
fi
dmg_path="$(cd "$(dirname "$dmg_path")" && pwd)/$(basename "$dmg_path")"

expected_release_version="$(tr -d '[:space:]' < "$release_version_file")"
if [[ ! "$expected_release_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]]; then
  echo "根目录发布版本格式无效：$expected_release_version" >&2
  exit 1
fi
dmg_name="$(basename "$dmg_path")"
case "$dmg_name" in
  "Tunnelful-$expected_release_version-arm64.dmg") expected_architecture='arm64' ;;
  "Tunnelful-$expected_release_version-x86_64.dmg") expected_architecture='x86_64' ;;
  *)
    echo "磁盘映像文件名与根目录版本或支持架构不一致；预期 arm64 或 x86_64 单架构包。" >&2
    exit 1
    ;;
esac

for command_name in codesign grep hdiutil lipo plutil shasum; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "缺少验证命令：$command_name" >&2
    exit 1
  fi
done

mount_dir="$(mktemp -d -t tunnelful-verify)"
device=''
cleanup() {
  if [[ -n "$device" ]]; then
    hdiutil detach "$device" -quiet || true
  fi
  if [[ -n "${mount_dir:-}" && "$mount_dir" == */tunnelful-verify.* && -d "$mount_dir" ]]; then
    rmdir "$mount_dir" 2>/dev/null || true
  fi
}
trap cleanup EXIT

hdiutil verify "$dmg_path"
sha_path="$dmg_path.sha256"
if [[ ! -f "$sha_path" ]]; then
  echo "缺少 SHA-256 校验文件：$sha_path" >&2
  exit 1
fi
(
  cd "$(dirname "$dmg_path")"
  shasum -a 256 -c "$(basename "$sha_path")"
)

attach_output="$(hdiutil attach "$dmg_path" -readonly -nobrowse -mountpoint "$mount_dir")"
device="$(printf '%s\n' "$attach_output" | awk -v mount="$mount_dir" 'index($0, mount) {print $1; exit}')"
if [[ -z "$device" ]]; then
  echo '磁盘映像已挂载，但未能识别设备。' >&2
  exit 1
fi

app_path="$mount_dir/Tunnelful.app"
binary="$app_path/Contents/MacOS/Tunnelful"
info_plist="$app_path/Contents/Info.plist"
if [[ ! -d "$app_path" || ! -x "$binary" || ! -f "$info_plist" ]]; then
  echo '磁盘映像缺少完整的 Tunnelful.app。' >&2
  exit 1
fi
if [[ ! -L "$mount_dir/Applications" ]]; then
  echo '磁盘映像缺少“应用程序”快捷入口。' >&2
  exit 1
fi
if [[ ! -f "$mount_dir/LICENSE" || ! -f "$mount_dir/THIRD_PARTY_NOTICES.md" ]]; then
  echo '磁盘映像缺少许可证或第三方声明。' >&2
  exit 1
fi

codesign --verify --deep --strict --verbose=2 "$app_path"
signing_info="$(codesign -dvvv "$app_path" 2>&1)"
if ! grep -q '^Signature=adhoc$' <<< "$signing_info"; then
  echo '当前发布包必须明确使用 ad-hoc 签名。' >&2
  exit 1
fi
if ! grep -Eq '^CodeDirectory .*flags=.*runtime' <<< "$signing_info"; then
  echo '应用签名没有启用 Hardened Runtime。' >&2
  exit 1
fi

actual_architecture="$(lipo -archs "$binary")"
if [[ "$actual_architecture" != "$expected_architecture" ]]; then
  echo "应用架构不符合磁盘映像名称；预期 $expected_architecture，实际 $actual_architecture。" >&2
  exit 1
fi

bundle_identifier="$(plutil -extract CFBundleIdentifier raw "$info_plist")"
if [[ "$bundle_identifier" != 'app.tunnelful.mac' ]]; then
  echo "Bundle ID 不符合预期：$bundle_identifier" >&2
  exit 1
fi

bundle_version="$(plutil -extract CFBundleShortVersionString raw "$info_plist")"
if [[ ! "$bundle_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "CFBundleShortVersionString 不符合 Apple 版本格式：$bundle_version" >&2
  exit 1
fi
expected_bundle_version="${expected_release_version%%-*}"
if [[ "$bundle_version" != "$expected_bundle_version" ]]; then
  echo "应用版本 $bundle_version 与发布基础版本 $expected_bundle_version 不一致。" >&2
  exit 1
fi

build_version="$(plutil -extract CFBundleVersion raw "$info_plist")"
if [[ ! "$build_version" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]]; then
  echo "CFBundleVersion 不符合 Apple 版本格式：$build_version" >&2
  exit 1
fi

if ! embedded_release_version="$(plutil -extract TunnelfulReleaseVersion raw "$info_plist" 2>/dev/null)"; then
  echo '应用 Info.plist 缺少 TunnelfulReleaseVersion。' >&2
  exit 1
fi
if [[ "$embedded_release_version" != "$expected_release_version" ]]; then
  echo "应用完整版本 $embedded_release_version 与磁盘映像版本 $expected_release_version 不一致。" >&2
  exit 1
fi

minimum_system="$(plutil -extract LSMinimumSystemVersion raw "$info_plist")"
if [[ "$minimum_system" != '14.0' && "$minimum_system" != '14.0.0' ]]; then
  echo "最低系统版本不符合预期：$minimum_system" >&2
  exit 1
fi

menu_bar_only="$(plutil -extract LSUIElement raw "$info_plist")"
if [[ "$menu_bar_only" != 'true' && "$menu_bar_only" != 'YES' ]]; then
  echo "LSUIElement 未启用：$menu_bar_only" >&2
  exit 1
fi

if find "$app_path" -type f -name cloudflared -print -quit | grep -q .; then
  echo '发布包不应捆绑 cloudflared。' >&2
  exit 1
fi

private_scan_pattern="${TUNNELFUL_PRIVATE_SCAN_PATTERN:-}"
path_scan_pattern='/Users/[^/[:space:]]+/'
if [[ -n "$private_scan_pattern" ]]; then
  path_scan_pattern="$private_scan_pattern|$path_scan_pattern"
fi
sensitive_output=''
sensitive_scan_status=0
if command -v rg >/dev/null 2>&1; then
  if sensitive_output="$({
    LC_ALL=C rg \
      --hidden \
      --no-ignore \
      --pcre2 \
      --text \
      --files-with-matches \
      -- "$path_scan_pattern" \
      "$app_path"
  } 2>&1)"; then
    sensitive_scan_status=0
  else
    sensitive_scan_status=$?
  fi
else
  artifact_file=''
  artifact_files=()
  while IFS= read -r -d '' artifact_file; do
    artifact_files+=("$artifact_file")
  done < <(find "$app_path" -type f -print0)
  if sensitive_output="$(LC_ALL=C grep -aEl "$path_scan_pattern" "${artifact_files[@]}" 2>&1)"; then
    sensitive_scan_status=0
  else
    sensitive_scan_status=$?
  fi
fi

case "$sensitive_scan_status" in
  0)
    echo '发布包中发现不应公开的域名或本机路径：' >&2
    printf '%s\n' "$sensitive_output" >&2
    exit 1
    ;;
  1)
    ;;
  *)
    echo '发布包私有内容扫描失败，已停止验证：' >&2
    printf '%s\n' "$sensitive_output" >&2
    exit "$sensitive_scan_status"
    ;;
esac

echo "验证通过：$(basename "$dmg_path")"
echo "应用架构：$expected_architecture"
echo '签名类型：ad-hoc；Apple 公证：未执行。'
