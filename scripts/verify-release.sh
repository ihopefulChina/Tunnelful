#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_root="$(cd "$script_dir/.." && pwd)"
release_version_file="$project_root/VERSION"

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo '用法：scripts/verify-release.sh <Tunnelful.dmg> [appcast.xml]' >&2
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

appcast_path="${2:-}"
if [[ -n "$appcast_path" ]]; then
  if [[ ! -f "$appcast_path" ]]; then
    echo "更新源不存在：$appcast_path" >&2
    exit 1
  fi
  appcast_path="$(cd "$(dirname "$appcast_path")" && pwd)/$(basename "$appcast_path")"
fi

product_config="$project_root/app/Config/Product.xcconfig"
base_build="$(sed -nE 's/^[[:space:]]*CURRENT_PROJECT_VERSION[[:space:]]*=[[:space:]]*([^[:space:]]+).*/\1/p' "$product_config" | head -n 1)"
sparkle_feed_url='https://ihopefulchina.github.io/Tunnelful/appcast.xml'
sparkle_public_key='0hyxOLR9zBFNvSdozSz0hALE/wHrk72Vsad4KxqpyM0='
case "$expected_architecture" in
  arm64) expected_build="$base_build" ;;
  x86_64) expected_build="$((base_build - 1))" ;;
esac

for command_name in codesign file grep hdiutil lipo plutil shasum otool; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "缺少验证命令：$command_name" >&2
    exit 1
  fi
done

mount_dir="$(mktemp -d -t tunnelful-verify)"
device=''
sparkle_key_file=''
launch_err=''
launch_out=''
launch_pid=''
verify_home=''
cleanup() {
  if [[ -n "${launch_pid:-}" ]]; then
    kill "$launch_pid" 2>/dev/null || true
    wait "$launch_pid" 2>/dev/null || true
  fi
  if [[ -n "$device" ]]; then
    hdiutil detach "$device" -quiet || true
  fi
  if [[ -n "${sparkle_key_file:-}" && -f "$sparkle_key_file" ]]; then
    rm -f "$sparkle_key_file"
  fi
  if [[ -n "${launch_err:-}" && -f "$launch_err" ]]; then
    rm -f "$launch_err"
  fi
  if [[ -n "${launch_out:-}" && -f "$launch_out" ]]; then
    rm -f "$launch_out"
  fi
  if [[ -n "${verify_home:-}" && -d "$verify_home" ]]; then
    rm -rf "$verify_home"
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
if [[ "$build_version" != "$expected_build" ]]; then
  echo "CFBundleVersion 不符合预期；预期 $expected_build，实际 $build_version。" >&2
  exit 1
fi

feed_url="$(plutil -extract SUFeedURL raw "$info_plist")"
if [[ "$feed_url" != "$sparkle_feed_url" ]]; then
  echo "SUFeedURL 不符合预期：$feed_url" >&2
  exit 1
fi
public_key="$(plutil -extract SUPublicEDKey raw "$info_plist")"
if [[ "$public_key" != "$sparkle_public_key" ]]; then
  echo 'SUPublicEDKey 与发布用公钥不一致。' >&2
  exit 1
fi
if plutil -extract SUEnableInstallerLauncherService raw "$info_plist" >/dev/null 2>&1; then
  echo '非沙盒应用不应启用 Sparkle 安装器 XPC。' >&2
  exit 1
fi

macho_count=0
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
done < <(find "$app_path" -type f -print0)
if (( macho_count == 0 )); then
  echo '应用中没有 Mach-O 文件。' >&2
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

sparkle_binary="$app_path/Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle"
if [[ ! -f "$sparkle_binary" ]]; then
  echo '发布包缺少 Sparkle.framework。' >&2
  exit 1
fi
if ! otool -l "$binary" | grep -F '@executable_path/../Frameworks' >/dev/null; then
  echo '主程序缺少 @executable_path/../Frameworks rpath，Sparkle 无法加载。' >&2
  exit 1
fi
entitlements_xml="$(codesign -d --entitlements :- "$binary" 2>/dev/null || true)"
if ! grep -q 'com.apple.security.cs.disable-library-validation' <<< "$entitlements_xml"; then
  echo 'Hardened Runtime 下嵌入 Sparkle 需要 com.apple.security.cs.disable-library-validation。' >&2
  exit 1
fi

launch_out="$(mktemp -t tunnelful-verify-out)"
launch_err="$(mktemp -t tunnelful-verify-err)"
verify_home="$(mktemp -d -t tunnelful-verify-home)"
HOME="$verify_home" "$binary" >"$launch_out" 2>"$launch_err" &
launch_pid=$!
sleep 2
if ! kill -0 "$launch_pid" 2>/dev/null; then
  wait "$launch_pid" 2>/dev/null || true
  launch_pid=''
  echo '应用启动失败。' >&2
  if [[ -s "$launch_err" ]]; then
    cat "$launch_err" >&2
  fi
  exit 1
fi
kill "$launch_pid" 2>/dev/null || true
wait "$launch_pid" 2>/dev/null || true
launch_pid=''

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

if [[ -n "$appcast_path" ]]; then
  if ! command -v xmllint >/dev/null 2>&1; then
    echo '验证 Sparkle 更新源需要 xmllint。' >&2
    exit 1
  fi
  item_xpath="//*[local-name()='item' and *[local-name()='version' and text()='$expected_build']]"
  item_count="$(xmllint --xpath "count($item_xpath)" "$appcast_path")"
  if [[ "$item_count" != "1" ]]; then
    echo "更新源必须恰好包含内部版本 $expected_build 的一条记录。" >&2
    exit 1
  fi
  declared_length="$(xmllint --xpath "string($item_xpath/*[local-name()='enclosure']/@length)" "$appcast_path")"
  signature="$(xmllint --xpath "string($item_xpath/*[local-name()='enclosure']/@*[local-name()='edSignature'])" "$appcast_path")"
  download_url="$(xmllint --xpath "string($item_xpath/*[local-name()='enclosure']/@url)" "$appcast_path")"
  short_version="$(xmllint --xpath "string($item_xpath/*[local-name()='shortVersionString'])" "$appcast_path")"
  hardware_requirements="$(xmllint --xpath "string($item_xpath/*[local-name()='hardwareRequirements'])" "$appcast_path")"
  if [[ "$short_version" != "$expected_bundle_version" ]]; then
    echo "更新源中的短版本与应用版本不一致。" >&2
    exit 1
  fi
  if [[ "${download_url##*/}" != "$dmg_name" ]]; then
    echo "更新源未指向 $dmg_name。" >&2
    exit 1
  fi
  if [[ "$declared_length" != "$(stat -f %z "$dmg_path")" ]]; then
    echo "更新源声明的文件大小与磁盘映像不一致。" >&2
    exit 1
  fi
  if [[ -z "$signature" ]]; then
    echo '更新源缺少 Sparkle 签名。' >&2
    exit 1
  fi
  hardware_requirements_normalized="$(printf '%s' "$hardware_requirements" | tr '[:upper:]' '[:lower:]')"
  if [[ "$expected_architecture" == "arm64" ]]; then
    if [[ "$hardware_requirements_normalized" != "arm64" ]]; then
      echo 'Apple 芯片条目必须声明 sparkle:hardwareRequirements=arm64。' >&2
      exit 1
    fi
  elif [[ -n "$hardware_requirements" ]]; then
    echo 'Intel 条目不应声明 hardwareRequirements。' >&2
    exit 1
  fi
  if [[ -n "${TUNNELFUL_SPARKLE_ED_PRIVATE_KEY:-}" || -n "${TUNNELFUL_SPARKLE_ED_KEY_FILE:-}" ]]; then
    sign_update="${TUNNELFUL_SPARKLE_SIGN_UPDATE:-}"
    if [[ -z "$sign_update" && -x "$project_root/release/.sparkle-bin/sign_update" ]]; then
      sign_update="$project_root/release/.sparkle-bin/sign_update"
    fi
    if [[ -z "$sign_update" ]]; then
      sign_update="$(find /tmp/tunnelful-sparkle-2.9.2 "$project_root" -name sign_update -type f 2>/dev/null | head -n 1)"
    fi
    if [[ ! -x "$sign_update" ]]; then
      echo '无法验证 Sparkle 签名：找不到 sign_update。' >&2
      exit 1
    fi
    sparkle_key_file="$(mktemp -t tunnelful-sparkle-verify)"
    if [[ -n "${TUNNELFUL_SPARKLE_ED_KEY_FILE:-}" ]]; then
      cat "$TUNNELFUL_SPARKLE_ED_KEY_FILE" > "$sparkle_key_file"
    else
      printf '%s\n' "$TUNNELFUL_SPARKLE_ED_PRIVATE_KEY" > "$sparkle_key_file"
    fi
    chmod 600 "$sparkle_key_file"
    "$sign_update" --verify --ed-key-file "$sparkle_key_file" "$dmg_path" "$signature"
  fi
fi

echo "验证通过：$(basename "$dmg_path")"
echo "应用架构：$expected_architecture"
echo "内部版本：$expected_build"
echo '签名类型：ad-hoc；Apple 公证：未执行。'
