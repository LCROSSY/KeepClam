#!/bin/zsh
# Removes the KeepClam sudoers whitelist installed by install-sudoers.sh.
set -eu

RULE_FILE="/etc/sudoers.d/keepclam"

if [ ! -f "$RULE_FILE" ]; then
  echo "未找到 $RULE_FILE，无需卸载。"
  exit 0
fi

sudo /bin/rm -f "$RULE_FILE"
if [ -e "$RULE_FILE" ]; then
  echo "错误：无法移除 $RULE_FILE。" >&2
  exit 1
fi
echo "已移除 KeepClam 免密授权。"
echo "验证：sudo -n /usr/bin/pmset -a disablesleep 0 应再次要求密码。"
