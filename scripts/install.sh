#!/bin/bash
# macOS 自带工具即可运行；兼容系统自带的 Bash 3.2。
set -euo pipefail

REPOSITORY="LCROSSY/KeepClam"
BUNDLE_ID="io.github.LCROSSY.keepclam"
INSTALL_TMP=""
INSTALL_STAGE=""
INSTALL_DEST=""
INSTALL_COMMITTED=0
INSTALL_APP_RUNNING=0
INSTALL_APP_QUIT=0
INSTALL_LANGUAGE="zh"

say() {
  if [ "$INSTALL_LANGUAGE" = "en" ]; then
    printf '%s\n' "$2"
  else
    printf '%s\n' "$1"
  fi
}

fail() {
  say "$1" "$2" >&2
  exit 1
}

# 未指定 --language 时：先看环境变量中的语言，再看系统首选语言；任何失败都回落到英文。
apple_language() {
  /usr/bin/defaults read -g AppleLanguages 2>/dev/null |
    /usr/bin/awk '{ gsub(/[^A-Za-z0-9_-]/, ""); if ($0 != "") { print; exit } }' || true
}

detect_language() {
  local name="${LC_ALL:-${LC_MESSAGES:-${LANG:-}}}" first
  case "${name}" in
    zh*) printf 'zh\n'; return 0 ;;
    ""|C|C.*|POSIX) ;;
    *) printf 'en\n'; return 0 ;;
  esac
  first=$(apple_language) || first=""
  case "${first}" in zh*) printf 'zh\n' ;; *) printf 'en\n' ;; esac
}

usage() {
  cat <<'EOF'
KeepClam 免费安装 / Free installation

  bash install.sh [options]

  --version VERSION     指定版本（含预览版） / Select a release, including previews
  --local DIRECTORY     使用目录中的 ZIP 和 SHA256SUMS / Use downloaded release files
  --app-dir DIRECTORY   安装目录（绝对路径） / Applications directory (absolute path)
  --yes                 在线安装时直接确认，无需交互 / Confirm an online install without a prompt
  --trust               安装并信任 KeepClam，仅移除该应用的下载隔离标记
                        Install and trust KeepClam; remove only its quarantine attribute
  --keep-quarantine     仅安装，不移除下载隔离标记 / Install without removing quarantine
  --no-open             安装后不打开 / Do not launch after installation
  --language zh|en      输出语言 / Output language (default: from system settings)
  --help                显示帮助 / Show help

在线安装会显示版本与来源，按回车或输入 y 确认；非交互运行请加 --yes。
--local 使用已下载的文件，会询问信任方式；非交互运行必须明确选择 --trust 或 --keep-quarantine。
默认装回已有 KeepClam 所在的目录；应用正在运行（未开启合盖运行）时会先退出，装完重新打开。
Online installs show the version and source, then ask you to confirm (Enter or y); add --yes when non-interactive.
--local asks how to trust a downloaded ZIP; non-interactive runs require --trust or --keep-quarantine.
Updates go to the existing install location. A running app (with no lid-closed session) is quit first and reopened afterwards.
EOF
}

cleanup() {
  local status=$?
  trap - EXIT HUP INT TERM
  if [ -n "$INSTALL_STAGE" ] && [ -d "$INSTALL_STAGE" ]; then
    if [ "$INSTALL_COMMITTED" -eq 0 ] && [ -e "$INSTALL_STAGE/previous.app" ]; then
      if [ ! -e "$INSTALL_DEST" ] && [ ! -L "$INSTALL_DEST" ] &&
          /bin/mv "$INSTALL_STAGE/previous.app" "$INSTALL_DEST"; then
        say "安装未完成，已恢复原来的应用。" "Installation did not finish; the previous app was restored." >&2
        if [ "$INSTALL_APP_QUIT" -eq 1 ]; then
          say "安装前退出的 KeepClam 需要你手动重新打开。" "KeepClam was quit before installing; reopen it manually." >&2
        fi
      else
        say "原来的应用保留在：${INSTALL_STAGE}/previous.app" "The previous app is preserved at: ${INSTALL_STAGE}/previous.app" >&2
        INSTALL_STAGE=""
        status=1
      fi
    fi
    if [ -n "$INSTALL_STAGE" ]; then /bin/rm -rf "$INSTALL_STAGE"; fi
  fi
  if [ -n "$INSTALL_TMP" ]; then /bin/rm -rf "$INSTALL_TMP"; fi
  exit "$status"
}

download() {
  /usr/bin/curl -q --fail --location --silent --show-error \
    --proto '=https' --proto-redir '=https' --connect-timeout 15 \
    --max-time 300 --retry 2 --output "$2" "$1"
}

valid_version() {
  [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z][0-9A-Za-z.+-]*)?$ ]]
}

# /releases/latest 不包含预览版。只选择同时有 ZIP 和校验文件的已发布版本。
release_version() {
  local metadata="$1" i j tag name has_zip has_sums
  for ((i = 0; i < 20; i++)); do
    tag=$(/usr/bin/plutil -extract "$i.tag_name" raw -o - "$metadata" 2>/dev/null) || break
    [[ "$tag" = v* ]] && valid_version "${tag#v}" || continue
    [ "$(/usr/bin/plutil -extract "$i.draft" raw -o - "$metadata" 2>/dev/null)" = "false" ] || continue
    has_zip=0
    has_sums=0
    for ((j = 0; j < 100; j++)); do
      name=$(/usr/bin/plutil -extract "$i.assets.$j.name" raw -o - "$metadata" 2>/dev/null) || break
      if [ "$name" = "KeepClam-${tag#v}.zip" ]; then has_zip=1; fi
      if [ "$name" = "SHA256SUMS" ]; then has_sums=1; fi
    done
    if [ "$has_zip" -eq 1 ] && [ "$has_sums" -eq 1 ]; then
      printf '%s\n' "${tag#v}"
      return 0
    fi
  done
  return 1
}

# 只取指定文件名的校验值；不按校验清单中的其他文件名读取本地文件。
checksum_for() {
  /usr/bin/awk -v name="$1" 'NF == 2 && ($2 == name || $2 == "*" name) { print tolower($1) }' "$2"
}

# API 受频率限制时改用发布订阅源（含预览版、不含草稿）。按新到旧最多探测 5 个版本，
# 只接受校验文件中列有对应 ZIP 的版本。
feed_release_version() {
  local feed="$1" tags="$INSTALL_TMP/feed-tags" sums="$INSTALL_TMP/probe-SHA256SUMS" tag version attempts=0
  /usr/bin/grep -o 'releases/tag/[^"<>?#]*' "$feed" | /usr/bin/sed 's#^releases/tag/##' > "$tags" || true
  while IFS= read -r tag; do
    [[ "$tag" = v* ]] && valid_version "${tag#v}" || continue
    version="${tag#v}"
    attempts=$((attempts + 1))
    [ "$attempts" -le 5 ] || break
    download "https://github.com/${REPOSITORY}/releases/download/v${version}/SHA256SUMS" "$sums" 2>/dev/null || continue
    [[ "$(checksum_for "KeepClam-${version}.zip" "$sums")" =~ ^[0-9a-f]{64}$ ]] || continue
    printf '%s\n' "$version"
    return 0
  done < "$tags"
  return 1
}

# 只向标准输出打印版本号；提示信息写到标准错误。
discover_version() {
  say "正在查找可安装的发布版（包含预览版）…" "Looking for an installable release, including previews…" >&2
  if download "https://api.github.com/repos/${REPOSITORY}/releases?per_page=20" "$INSTALL_TMP/releases.json" 2>/dev/null; then
    release_version "$INSTALL_TMP/releases.json" ||
      fail "没有找到安装文件齐全的发布版，请用 --version 指定版本。" "No complete release found; select a version with --version."
    return 0
  fi
  say "GitHub API 暂不可用（可能已达频率限制），改用发布订阅源。" "The GitHub API is unavailable (possibly rate-limited); using the release feed instead." >&2
  download "https://github.com/${REPOSITORY}/releases.atom" "$INSTALL_TMP/releases.atom" 2>/dev/null ||
    fail "无法获取发布列表。请稍后重试，或用 --version 指定版本、--local 使用已下载文件。" \
      "Could not fetch releases. Retry later, select a version with --version, or use downloaded files with --local."
  feed_release_version "$INSTALL_TMP/releases.atom" ||
    fail "没有找到安装文件齐全的发布版，请用 --version 指定版本。" "No complete release found; select a version with --version."
}

# Homebrew 安装的应用应由 Homebrew 更新，避免两套安装互相覆盖。
homebrew_cask_installed() {
  local prefix
  for prefix in "${HOMEBREW_PREFIX:-}" /opt/homebrew /usr/local; do
    [ -n "${prefix}" ] && [ -d "${prefix}/Caskroom/keepclam" ] && return 0
  done
  return 1
}

legacy_running() {
  local status=0
  /usr/bin/pgrep -x LidAwake >/dev/null 2>&1 || status=$?
  [ "$status" -le 1 ] || return 2
  return "$status"
}

# 每行输出一个 KeepClam 进程：「PID UID 命令行」。无法枚举进程时返回非零。
keepclam_processes() {
  local pids pid status=0
  pids=$(/usr/bin/pgrep -x KeepClam 2>/dev/null) || status=$?
  [ "$status" -le 1 ] || return 1
  for pid in $pids; do
    /bin/ps -ww -o pid=,uid=,args= -p "$pid" 2>/dev/null || true
  done
}

# 输出 none / app / session / other_user / legacy。守护进程与应用是同一个可执行文件，
# 以 --guard 参数运行；它在运行就说明合盖运行会话正在进行。
running_state() {
  local status=0 list pid uid args state=none
  legacy_running || status=$?
  [ "$status" -ne 2 ] || return 1
  if [ "$status" -eq 0 ]; then printf 'legacy\n'; return 0; fi
  list=$(keepclam_processes) || return 1
  while read -r pid uid args; do
    [ -n "$pid" ] || continue
    case " ${args} " in *" --guard "*|*" --stop "*) printf 'session\n'; return 0 ;; esac
    if [ "$uid" != "$(/usr/bin/id -u)" ]; then state=other_user; elif [ "$state" = none ]; then state=app; fi
  done <<< "$list"
  printf '%s\n' "$state"
}

# 合盖运行会话、旧版 LidAwake 或其他用户的 KeepClam 在运行时拒绝安装；
# 只有当前用户的菜单栏应用在运行时，记下来，替换前再自动退出。
require_stopped() {
  local state
  state=$(running_state) || fail "无法确认应用是否正在运行，已取消安装。" "Could not check for running apps; installation cancelled."
  INSTALL_APP_RUNNING=0
  case "$state" in
    none) ;;
    app) INSTALL_APP_RUNNING=1 ;;
    session) fail "合盖运行正在进行中。请先在菜单中关闭合盖运行，再重新安装。" \
      "A lid-closed session is running. Turn it off from the menu, then run the installer again." ;;
    legacy) fail "请先退出旧版 LidAwake，再安装 KeepClam。" "Quit the legacy LidAwake app before installing KeepClam." ;;
    *) fail "其他用户正在运行 KeepClam，请等对方退出后再安装。" "Another user is running KeepClam; install after they quit it." ;;
  esac
}

# 没有合盖运行会话时，应用不持有需要恢复的系统状态，直接结束即可。
# 不用 AppleScript 退出，避免触发「自动化」权限弹窗。
quit_running_app() {
  local list pid uid args i
  say "正在退出运行中的 KeepClam…" "Quitting the running KeepClam…"
  list=$(keepclam_processes) || fail "无法确认应用是否正在运行，已取消安装。" "Could not check for running apps; installation cancelled."
  while read -r pid uid args; do
    [ -n "$pid" ] || continue
    case " ${args} " in *" --guard "*|*" --stop "*)
      fail "合盖运行正在进行中。请先在菜单中关闭合盖运行，再重新安装。" \
        "A lid-closed session is running. Turn it off from the menu, then run the installer again." ;;
    esac
    /bin/kill -TERM "$pid" 2>/dev/null || true
  done <<< "$list"
  INSTALL_APP_QUIT=1
  for ((i = 0; i < 50; i++)); do
    list=$(keepclam_processes) || fail "无法确认应用是否正在运行，已取消安装。" "Could not check for running apps; installation cancelled."
    [ -n "$list" ] || return 0
    /bin/sleep 0.1
  done
  fail "KeepClam 未能退出，请手动退出后重新安装。" "KeepClam did not quit; quit it manually and run the installer again."
}

# 标准应用目录：系统「应用程序」和个人应用目录。
standard_app_dirs() {
  printf '%s\n' /Applications "${HOME}/Applications"
}

is_keepclam_app() {
  [ -d "$1" ] && [ "$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$1/Contents/Info.plist" 2>/dev/null)" = "$BUNDLE_ID" ]
}

# 未指定 --app-dir 时沿用已安装的位置，避免装出两份；没有安装过时，优先系统目录。
default_app_dir() {
  local system personal
  { IFS= read -r system; IFS= read -r personal; } < <(standard_app_dirs)
  if is_keepclam_app "${system}/KeepClam.app"; then
    [ -w "$system" ] || fail "KeepClam 已安装在 ${system}，但当前用户没有写入权限。请用管理员账户更新，或用 --app-dir 指定目录。" \
      "KeepClam is installed in ${system}, but you can't write there. Update from an admin account, or choose a directory with --app-dir."
    if is_keepclam_app "${personal}/KeepClam.app"; then
      say "注意：${personal} 中还有一份 KeepClam，本次更新 ${system} 中的那份，建议删除多余的一份。" \
        "Note: another copy of KeepClam is in ${personal}. Updating the one in ${system}; consider removing the extra copy." >&2
    fi
    printf '%s\n' "$system"
  elif is_keepclam_app "${personal}/KeepClam.app" || [ ! -w "$system" ]; then
    printf '%s\n' "$personal"
  else
    printf '%s\n' "$system"
  fi
}

verify_app() {
  local app="$1" version="$2" plist="$1/Contents/Info.plist"
  [ -d "$app" ] && [ ! -L "$app" ] && [ -f "$plist" ] &&
    [ "$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$plist" 2>/dev/null)" = "$BUNDLE_ID" ] &&
    [ "$(/usr/bin/plutil -extract CFBundleExecutable raw -o - "$plist" 2>/dev/null)" = "KeepClam" ] &&
    [ "$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$plist" 2>/dev/null)" = "$version" ] &&
    [ -x "$app/Contents/MacOS/KeepClam" ] &&
    /usr/bin/codesign --verify --strict "$app" >/dev/null 2>&1
}

require_safe_target() {
  [ ! -L "$INSTALL_DEST" ] || fail "目标应用是符号链接，请通过原安装方式更新。" "The target app is a symlink; update it through its original installer."
  if [ -e "$INSTALL_DEST" ]; then
    [ -d "$INSTALL_DEST" ] &&
      [ "$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$INSTALL_DEST/Contents/Info.plist" 2>/dev/null)" = "$BUNDLE_ID" ] ||
      fail "目标位置已有其他文件，已取消安装：${INSTALL_DEST}" "A different file already occupies the target: ${INSTALL_DEST}"
  fi
}

publish_app() {
  if [ -e "$INSTALL_DEST" ]; then
    /bin/mv "$INSTALL_DEST" "$INSTALL_STAGE/previous.app" || return 1
  fi
  /bin/mv "$INSTALL_STAGE/KeepClam.app" "$INSTALL_DEST" || return 1
  INSTALL_COMMITTED=1
}

main() {
  local version="" local_dir="" app_dir="" trust="" confirmed=0 launch=1
  local archive sums asset expected actual entry choice argument
  INSTALL_LANGUAGE=$(detect_language)
  while [ "$#" -gt 0 ]; do
    argument="$1"
    case "$argument" in
      --version|--local|--app-dir|--language)
        [ "$#" -ge 2 ] && [ -n "$2" ] || fail "${argument} 缺少参数。" "Missing value for ${argument}."
        case "$argument" in
          --version) version="${2#v}" ;;
          --local) local_dir="$2" ;;
          --app-dir) app_dir="$2" ;;
          --language) INSTALL_LANGUAGE="$2" ;;
        esac
        shift 2 ;;
      --trust|--keep-quarantine)
        [ -z "$trust" ] || fail "请只选择一种信任方式。" "Choose only one trust option."
        trust="$argument"
        shift ;;
      --yes|-y) confirmed=1; shift ;;
      --no-open) launch=0; shift ;;
      --help|-h) usage; return 0 ;;
      *) fail "未知选项：${argument}。使用 --help 查看帮助。" "Unknown option: ${argument}. Use --help for help." ;;
    esac
  done

  case "$INSTALL_LANGUAGE" in zh|en) ;; *) fail "语言必须为 zh 或 en。" "Language must be zh or en." ;; esac
  [ -z "$version" ] || valid_version "$version" || fail "版本号格式不正确。" "Invalid version number."
  [ "$(/usr/bin/uname -s)" = "Darwin" ] || fail "安装脚本只支持 macOS。" "This installer supports macOS only."
  [ "$(/usr/bin/id -u)" -ne 0 ] || fail "请使用普通用户运行，无需 sudo。" "Run as your regular user; sudo is not needed."
  local system_version
  system_version=$(/usr/bin/sw_vers -productVersion)
  [ "${system_version%%.*}" -ge 13 ] || fail "KeepClam 需要 macOS 13 或更高版本。" "KeepClam requires macOS 13 or later."

  if [ -z "$app_dir" ]; then
    app_dir=$(default_app_dir)
  fi
  [[ "$app_dir" = /* ]] || fail "安装目录必须是绝对路径。" "The applications directory must be an absolute path."
  app_dir="${app_dir%/}"
  [ -n "$app_dir" ] || fail "请选择应用目录，不能安装到文件系统根目录。" "Choose an applications directory, not the filesystem root."
  INSTALL_DEST="$app_dir/KeepClam.app"
  require_safe_target
  if [ -e "$INSTALL_DEST" ] && homebrew_cask_installed; then
    fail "检测到 Homebrew 安装的 KeepClam，请运行 brew upgrade --cask keepclam 更新，避免两套安装互相覆盖。" \
      "KeepClam is installed with Homebrew; run brew upgrade --cask keepclam to update it instead of replacing it here."
  fi
  require_stopped
  INSTALL_TMP=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/keepclam-install.XXXXXX")
  trap cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' HUP TERM

  if [ -n "$local_dir" ]; then
    [ -d "$local_dir" ] || fail "找不到安装包目录：${local_dir}" "Release directory not found: ${local_dir}"
    local_dir=$(cd "$local_dir" && pwd -P)
    if [ -z "$version" ]; then
      for archive in "$local_dir"/KeepClam-*.zip; do
        [ -f "$archive" ] || continue
        [ -z "$version" ] || fail "目录内有多个版本，请用 --version 指定。" "Multiple releases found; select one with --version."
        asset="${archive##*/}"
        version="${asset#KeepClam-}"
        version="${version%.zip}"
      done
    fi
    valid_version "$version" || fail "目录中没有有效的 KeepClam 安装包。" "No valid KeepClam release ZIP found."
    asset="KeepClam-${version}.zip"
    [ -f "$local_dir/$asset" ] && [ -f "$local_dir/SHA256SUMS" ] ||
      fail "请把 ${asset} 和 SHA256SUMS 放在同一目录。" "Place ${asset} and SHA256SUMS in the same directory."
    /bin/cp "$local_dir/$asset" "$INSTALL_TMP/$asset"
    /bin/cp "$local_dir/SHA256SUMS" "$INSTALL_TMP/SHA256SUMS"
  else
    if [ -z "$version" ]; then
      version=$(discover_version)
    fi
    asset="KeepClam-${version}.zip"
    say "正在下载 KeepClam ${version}…" "Downloading KeepClam ${version}…"
    download "https://github.com/${REPOSITORY}/releases/download/v${version}/${asset}" "$INSTALL_TMP/$asset" &&
      download "https://github.com/${REPOSITORY}/releases/download/v${version}/SHA256SUMS" "$INSTALL_TMP/SHA256SUMS" ||
      fail "下载失败，尚未替换已安装的应用。" "Download failed; the installed app has not been replaced."
  fi

  archive="$INSTALL_TMP/$asset"
  sums="$INSTALL_TMP/SHA256SUMS"
  # 只校验要安装的 ZIP。
  expected=$(checksum_for "$asset" "$sums")
  [[ "$expected" =~ ^[0-9a-f]{64}$ ]] || fail "校验文件缺少唯一有效的 ${asset} 校验值。" "No unique valid checksum for ${asset}."
  actual=$(/usr/bin/shasum -a 256 "$archive" | /usr/bin/awk '{print $1}')
  [ "$expected" = "$actual" ] || fail "安装包校验失败，请重新下载。" "Checksum mismatch; download the release again."
  say "安装包校验通过。" "Release checksum verified."

  # 此项目的发布包不包含符号链接；解压前拒绝越界路径和链接。
  /usr/bin/unzip -Z1 "$archive" > "$INSTALL_TMP/entries" || fail "安装包不是有效的 ZIP。" "The release is not a valid ZIP."
  [ -s "$INSTALL_TMP/entries" ] || fail "安装包为空。" "The release ZIP is empty."
  while IFS= read -r entry; do
    case "$entry" in KeepClam.app/|KeepClam.app/*) ;; *) fail "安装包包含非预期文件。" "Unexpected file in the release ZIP." ;; esac
    case "/${entry%/}/" in *'/../'*|*'/./'*|*'//'*|*\\*) fail "安装包包含无效路径。" "Unsafe path in the release ZIP." ;; esac
  done < "$INSTALL_TMP/entries"
  /usr/bin/unzip -Z -l "$archive" > "$INSTALL_TMP/modes" || fail "无法读取安装包内容。" "Could not inspect the release ZIP."
  if /usr/bin/awk '$1 ~ /^l[-rwxstST]+$/ { found=1 } END { exit !found }' "$INSTALL_TMP/modes"; then
    fail "安装包包含符号链接，已取消安装。" "The release ZIP contains symlinks; installation cancelled."
  fi
  /usr/bin/ditto -x -k "$archive" "$INSTALL_TMP/unpacked" || fail "解压安装包失败。" "Could not extract the release."
  verify_app "$INSTALL_TMP/unpacked/KeepClam.app" "$version" ||
    fail "应用身份、版本或签名完整性检查失败。" "App identity, version or signature integrity check failed."

  say "安装版本：${version}" "Version: ${version}"
  say "安装来源：https://github.com/${REPOSITORY}/releases/tag/v${version}" "Release source: https://github.com/${REPOSITORY}/releases/tag/v${version}"
  say "安装位置：${INSTALL_DEST}" "Install location: ${INSTALL_DEST}"
  say "此版本使用临时签名，未经过 Apple 公证。" "This release is ad-hoc signed and has not been notarized by Apple."
  if [ "$INSTALL_APP_RUNNING" -eq 1 ]; then
    if [ "$launch" -eq 1 ]; then
      say "KeepClam 正在运行：确认后会先退出它，安装完成后重新打开。" "KeepClam is running: it will be quit before installing and reopened afterwards."
    else
      say "KeepClam 正在运行：确认后会先退出它。" "KeepClam is running: it will be quit before installing."
    fi
  fi
  if [ -z "$local_dir" ]; then
    # 在线下载的文件没有下载隔离标记，信任选项没有区别，只需确认一次。
    if [ -z "$trust" ] && [ "$confirmed" -eq 0 ]; then
      say "按回车或输入 y 安装 KeepClam，其他输入取消。" "Press Enter or y to install KeepClam; anything else cancels."
      choice=""
      if ! { IFS= read -r choice < /dev/tty; } 2>/dev/null; then
        fail "需要交互终端；非交互运行请添加 --yes 确认安装。" "An interactive terminal is required; add --yes to confirm a non-interactive install."
      fi
      case "$choice" in
        ""|y|Y|yes|YES|Yes) ;;
        *) say "已取消安装。" "Installation cancelled."; return 0 ;;
      esac
    fi
    [ -n "$trust" ] || trust="--trust"
  elif [ -z "$trust" ]; then
    say "1：安装并信任 KeepClam（仅移除该应用的下载隔离标记）" "1: Install and trust KeepClam (remove only this app's quarantine attribute)"
    say "2：仅安装，不移除下载隔离标记" "2: Install without removing quarantine"
    say "其他输入或直接回车：取消" "Any other input, or Enter: cancel"
    choice=""
    if ! { IFS= read -r choice < /dev/tty; } 2>/dev/null; then
      fail "需要交互终端；请明确选择 --trust 或 --keep-quarantine。" "An interactive terminal is required; choose --trust or --keep-quarantine explicitly."
    fi
    case "$choice" in
      1) trust="--trust" ;;
      2) trust="--keep-quarantine" ;;
      *) say "已取消安装。" "Installation cancelled."; return 0 ;;
    esac
  fi

  /bin/mkdir -p "$app_dir" || fail "无法创建安装目录，可用 --app-dir 指定个人应用目录。" "Could not create the applications directory; select a personal directory with --app-dir."
  [ -w "$app_dir" ] || fail "安装目录不可写，可使用 --app-dir \"\$HOME/Applications\"。" "The directory is not writable; use --app-dir \"\$HOME/Applications\"."
  INSTALL_STAGE=$(/usr/bin/mktemp -d "$app_dir/.keepclam-install.XXXXXX")
  /usr/bin/ditto "$INSTALL_TMP/unpacked/KeepClam.app" "$INSTALL_STAGE/KeepClam.app" || fail "复制应用失败。" "Could not copy the app."
  verify_app "$INSTALL_STAGE/KeepClam.app" "$version" || fail "复制后的应用未通过完整性检查。" "The staged app failed integrity verification."
  if [ "$trust" = "--trust" ]; then
    /usr/bin/xattr -dr com.apple.quarantine "$INSTALL_STAGE/KeepClam.app" || fail "无法移除该应用的下载隔离标记。" "Could not remove this app's quarantine attribute."
  fi
  require_stopped
  if [ "$INSTALL_APP_RUNNING" -eq 1 ]; then
    quit_running_app
    require_stopped
    [ "$INSTALL_APP_RUNNING" -eq 0 ] || fail "KeepClam 未能退出，请手动退出后重新安装。" "KeepClam did not quit; quit it manually and run the installer again."
  fi
  require_safe_target
  publish_app || fail "替换应用失败。" "Could not replace the app."
  say "安装完成：KeepClam ${version}" "Installed KeepClam ${version}."
  if [ -n "$local_dir" ] && [ "$trust" = "--keep-quarantine" ]; then
    say "若首次打开被拦截，确认来源可信后，到「系统设置 → 隐私与安全性 → 仍要打开」放行。" \
      "If first launch is blocked, verify the source and use System Settings → Privacy & Security → Open Anyway."
  fi
  say "合盖无人值守前，请在应用菜单中安装免密授权。" "Before unattended lid-closed use, install passwordless authorization from the app menu."
  if [ "$launch" -eq 1 ] && ! /usr/bin/open "$INSTALL_DEST"; then
    say "应用已安装，请从安装目录手动打开。" "The app is installed; open it from its installation directory." >&2
  fi
}

# 直接运行或通过管道（curl … | bash）运行时执行；被 source 时不自动执行。
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
  main "$@"
fi
