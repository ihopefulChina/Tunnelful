#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_root="$(cd "$script_dir/.." && pwd)"
cd "$project_root"

exclude_globs=(
  'scripts/check-public-content.sh'
  'scripts/verify-release.sh'
  '.git/**'
  '.build/**'
  'app/.build/**'
  'website/node_modules/**'
  'website/dist/**'
  'website/.next/**'
  'website/.vinext/**'
  'website/.wrangler/**'
  'release/**'
)

rg_args=(
  --hidden
  --pcre2
  --text
  --files-with-matches
)
git_pathspec=(.)
for excluded in "${exclude_globs[@]}"; do
  rg_args+=(--glob "!$excluded")
  git_pathspec+=(":(exclude)$excluded")
done

search_pattern() {
  local pattern="$1"
  local output
  local status

  if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    if command -v rg >/dev/null 2>&1; then
      local tracked_file
      local -a tracked_files=()
      while IFS= read -r -d '' tracked_file; do
        tracked_files+=("$tracked_file")
      done < <(git ls-files -z -- "${git_pathspec[@]}")
      if [[ ${#tracked_files[@]} -eq 0 ]]; then
        return
      fi
      if output="$(rg "${rg_args[@]}" -- "$pattern" "${tracked_files[@]}" 2>&1)"; then
        printf '%s\n' "$output"
        return
      else
        status=$?
      fi
      if [[ $status -eq 1 ]]; then
        return
      fi
      printf '%s\n' "$output" >&2
      return "$status"
    fi

    if output="$(git grep --name-only -a -P -e "$pattern" -- "${git_pathspec[@]}" 2>&1)"; then
      printf '%s\n' "$output"
      return
    else
      status=$?
    fi
    if [[ $status -eq 1 ]]; then
      return
    fi
    printf '%s\n' "$output" >&2
    return "$status"
  fi

  if command -v rg >/dev/null 2>&1; then
    if output="$(rg "${rg_args[@]}" --no-ignore -- "$pattern" . 2>&1)"; then
      printf '%s\n' "$output"
      return
    else
      status=$?
    fi
    if [[ $status -eq 1 ]]; then
      return
    fi
    printf '%s\n' "$output" >&2
    return "$status"
  fi

  echo '需要 ripgrep，或在 Git 仓库中运行此检查。' >&2
  return 2
}

failed=0
check_pattern() {
  local label="$1"
  local pattern="$2"
  local output
  output="$(search_pattern "$pattern")"
  if [[ -n "$output" ]]; then
    echo "[$label] 发现需要处理的公开内容：" >&2
    printf '%s\n' "$output" >&2
    failed=1
  fi
}

if [[ -n "${TUNNELFUL_PRIVATE_SCAN_PATTERN:-}" ]]; then
  check_pattern '私有内容' "$TUNNELFUL_PRIVATE_SCAN_PATTERN"
fi
check_pattern '本机绝对路径' "(?:/Users|/home)/[^/[:space:]\"']+/"
check_pattern '私钥' '-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----'
check_pattern 'Cloudflare 凭据字段' "[\"'](?:AccountTag|TunnelSecret)[\"'][[:space:]]*:"
check_pattern '疑似 JWT' '\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b'
check_pattern '疑似明文 API Token' '\b(?:CF_API_TOKEN|CLOUDFLARE_API_TOKEN)[[:space:]]*=[[:space:]]*[^<[:space:]]{12,}'
check_pattern '固定 UUID' '\b(?!00000000-0000-4000-8000-000000000000\b)[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}\b'

if [[ $failed -ne 0 ]]; then
  exit 1
fi

version="$(tr -d '[:space:]' < VERSION)"
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]]; then
  echo "VERSION 格式无效：$version" >&2
  exit 1
fi
if ! grep -Fq "export const releaseVersion = '${version}';" website/app/release.ts; then
  echo "website/app/release.ts 的 releaseVersion 必须与 VERSION ($version) 一致。" >&2
  exit 1
fi

feed_url="$(awk -F ' = ' '/^INFOPLIST_KEY_SUFeedURL / { print $2 }' app/Config/Product.xcconfig | tr -d '[:space:]')"
public_key="$(awk -F ' = ' '/^INFOPLIST_KEY_SUPublicEDKey / { print $2 }' app/Config/Product.xcconfig | tr -d '[:space:]')"
if [[ -z "$feed_url" ]] || ! grep -Fq "\"$feed_url\"" app/TunnelApp/Core/AppUpdater.swift; then
  echo "AppUpdater.feedURL 必须与 Product.xcconfig 的 SUFeedURL 一致。" >&2
  exit 1
fi
if [[ -z "$public_key" ]] || ! grep -Fq "\"$public_key\"" app/TunnelApp/Core/AppUpdater.swift; then
  echo "AppUpdater.publicEDKey 必须与 Product.xcconfig 的 SUPublicEDKey 一致。" >&2
  exit 1
fi
if ! grep -Fq "<string>$feed_url</string>" app/TunnelApp/Info.plist \
  || ! grep -Fq "<string>$public_key</string>" app/TunnelApp/Info.plist; then
  echo "Info.plist 必须包含与 Product.xcconfig 一致的 Sparkle 源地址和公钥。" >&2
  exit 1
fi
if ! grep -Fq '<sparkle:shortVersionString>' appcast.xml \
  || ! grep -Fq '<sparkle:shortVersionString>' website/public/appcast.xml; then
  echo "仓库内 appcast.xml 必须是有效的 Sparkle 更新源。正式版本由发版工作流生成后再同步。" >&2
  exit 1
fi

python3 "$script_dir/inject-appcast-hardware.py" --self-test

echo '公开内容检查通过。'
