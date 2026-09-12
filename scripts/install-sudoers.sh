#!/bin/zsh
# Installs the KeepClam sudoers whitelist: passwordless execution of exactly
# two commands (/usr/bin/pmset -a disablesleep 0 and 1) for the current user.
# Nothing else is allowed through this rule.
set -eu

RULE_FILE="/etc/sudoers.d/keepclam"
USER_NAME="$(id -un)"
RULE="${USER_NAME} ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1"

TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT
printf '%s\n' "$RULE" > "$TMP"

if [ -f "$RULE_FILE" ]; then
  if sudo /usr/bin/cmp -s "$TMP" "$RULE_FILE"; then
    echo "KeepClam 免密授权已安装，无需重复操作。"
    exit 0
  fi
  echo "错误：$RULE_FILE 已存在但内容与本脚本预期不一致。" >&2
  echo "请先检查：sudo cat $RULE_FILE" >&2
  exit 1
fi

# Validate syntax before touching sudoers; abort if invalid.
if ! sudo /usr/sbin/visudo -cf "$TMP"; then
  echo "错误：规则未通过语法校验，已取消安装。" >&2
  exit 1
fi

sudo /usr/bin/install -m 0440 -o root -g wheel "$TMP" "$RULE_FILE"
if [ ! -f "$RULE_FILE" ]; then
  echo "错误：白名单安装后未找到 $RULE_FILE。" >&2
  exit 1
fi
echo "已安装 KeepClam 免密授权：$RULE_FILE"
echo "规则内容（仅此两条命令免密）："
echo "  $RULE"
echo "验证：sudo -n /usr/bin/pmset -a disablesleep 1 && pmset -g | grep SleepDisabled && sudo -n /usr/bin/pmset -a disablesleep 0"
echo "移除：zsh scripts/uninstall-sudoers.sh"
