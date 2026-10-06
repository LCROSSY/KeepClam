# KeepClam 🦪

[![CI](https://github.com/LCROSSY/KeepClam/actions/workflows/ci.yml/badge.svg)](https://github.com/LCROSSY/KeepClam/actions/workflows/ci.yml)

**盖子合上，任务继续跑。** ｜ [English](README.md)

KeepClam 是一个小巧的 macOS 菜单栏应用：合上笔记本盖子，MacBook 照常运行。适合过夜编译、大文件下载、数据同步，也适合合盖后还要继续干活的编程智能体（Codex、Claude Code 等）。用电池就行，不必外接显示器。

**KeepClam 提供主动过热保护**：独立的守护进程每 5 秒检查一次系统热状态，触发保护时尝试恢复正常睡眠并请求电脑休眠。

## 为什么需要它

`caffeinate` 和电源断言类工具（Caffeine、KeepingYouAwake、Amphetamine）只能防止系统因闲置而入睡，一合盖就失效了。在用户态，唯一能挡住合盖睡眠的是内核的 `SleepDisabled` 开关（`sudo pmset -a disablesleep 1`）。KeepClam 做的事，就是给这个开关配上安全网：

- 🌡️ **过热保护**：独立守护进程每 5 秒读取一次 macOS 官方热压力等级。一旦达到「过高 / 严重过热」，或者连续 3 次读不到数据，就记下日志、恢复睡眠、立即休眠。
- 🛟 **崩溃兜底**：守护进程独立于应用存活。应用退出或崩溃后，守护进程发现父进程没了，会马上恢复睡眠——不会留下一个还在生效的 `SleepDisabled 1`。
- 🔋 **自动结束**：可以设定时（1 / 2 / 4 小时 / 不限，或自定义 1 分钟–24 小时）和电池电量下限（10% / 20% / 30%，或自定义 5%–95%，默认 20%）；系统进入低电量模式、或连续读不到电量时也会自动结束。这些判断都在守护进程里完成，应用界面卡住也不影响；合盖状态下结束时会立即休眠（仅恢复睡眠设置并不会让合上的 Mac 睡着）。
- 🖥️ **合盖即灭屏**：不接外接显示器时，合盖后 macOS 会自行关闭内屏（`pmset -g log` 可见 `Display is turned off`），无需额外处理。
- 👁️ **状态真实**：菜单栏每次刷新都从内核重新读取实际状态；如果是通过其他途径开启的，会明确标注。
- 📜 **会话日志**：自动记录盖子开合、网络连通性和热状态（相同状态合并成一条），随时可以回看「昨晚合盖期间到底发生了什么」。
- 🌐 **双语界面**：简体中文 / English，在「设置」里切换，即时生效、无需重启。

## 安装

**系统要求**：macOS 13 及以上。安装包是通用二进制（Apple Silicon 上实测过；Intel 版随包附带，但没在真机上测过）。

### 免费安装脚本（推荐）

不需要 Xcode 或 Homebrew。在「终端」中运行：

```sh
curl -fsSL --proto '=https' --proto-redir '=https' https://raw.githubusercontent.com/LCROSSY/KeepClam/main/scripts/install.sh | bash
```

脚本直接运行，不会留下文件。它会下载安装文件齐全的发布版（包含预览版），校验安装包和应用完整性；GitHub API 达到频率限制时会改用发布订阅源。然后显示版本、来源、安装位置，按回车（或输入 `y`）安装，输入其他内容取消。通过脚本下载的文件没有下载隔离标记，因此不需要单独选择信任方式。没有终端的非交互环境可添加 `--yes` 直接确认。

默认安装到「应用程序」；如果该目录不可写，会使用 `~/Applications`。安装完成后打开菜单栏应用。更新时也可以再次运行脚本，但必须先结束合盖运行并退出旧应用；如果 KeepClam 是通过 Homebrew 安装的，脚本会停止并提示你运行 `brew upgrade --cask keepclam` 更新。

输出语言跟随系统语言，可用 `--language zh` 或 `--language en` 指定。需要指定版本、使用个人应用目录或安装后暂不打开时，在 `bash -s --` 之后添加选项：

```sh
curl -fsSL --proto '=https' --proto-redir '=https' https://raw.githubusercontent.com/LCROSSY/KeepClam/main/scripts/install.sh | bash -s -- --version 0.2.0 --app-dir "$HOME/Applications" --no-open
```

当前发布版使用临时签名，未经过 Apple 公证。「安装并信任」是你主动信任这个应用；安装包校验用于发现下载损坏，不等于 Apple 公证。安装脚本不会自动配置合盖运行所需的免密授权，合盖无人值守前仍需在应用菜单中授权。

### 已下载安装包（离线安装）

新发布版会附带 `install.sh`；已有发布版没有该文件时，可从仓库下载 [scripts/install.sh](scripts/install.sh)。将脚本、`KeepClam-<版本号>.zip` 和 `SHA256SUMS` 放在同一目录，在该目录运行：

```sh
shasum -a 256 -c --ignore-missing SHA256SUMS && bash install.sh --local .
```

浏览器下载的 ZIP 带有下载隔离标记，所以离线安装会询问信任方式：输入 **1** 安装并信任 KeepClam（仅移除这个应用的下载隔离标记，通常可以直接打开），输入 **2** 仅安装、不移除下载隔离标记，直接回车取消。没有终端时请添加 `--trust` 或 `--keep-quarantine`。目录中有多个版本时，用 `--version` 指定要安装的版本。查看全部选项：`bash install.sh --help`；输出语言可用 `--language zh|en` 指定。

### Homebrew

```sh
brew install --cask LCROSSY/tap/keepclam
```

后续更新：先运行 `brew update`，再运行 `brew upgrade --cask keepclam`。

### 首次打开

通过 Homebrew 或手动解压安装后，如果 macOS 阻止打开，确认应用来源可信后，先尝试打开一次，再前往「系统设置 → 隐私与安全性 → 仍要打开」，按提示确认。具体步骤参见 [Apple 官方说明](https://support.apple.com/zh-cn/102445)。

也可以用终端仅移除已安装 KeepClam 的下载隔离标记：

```sh
xattr -dr com.apple.quarantine "/Applications/KeepClam.app"
```

如果安装在个人应用目录，请将路径改为 `"$HOME/Applications/KeepClam.app"`。此操作不代表应用经过 Apple 公证。

### 手动安装

从 [发布页](https://github.com/LCROSSY/KeepClam/releases) 下载 `KeepClam-<版本号>.zip` 和 `SHA256SUMS`。将它们放在同一目录，运行 `shasum -a 256 -c --ignore-missing SHA256SUMS` 校验（新发布版的清单中还列有 `install.sh`）后，解压并将 **KeepClam.app** 拖入「应用程序」。

### 从源码构建

需要先安装 Xcode Command Line Tools（已安装 Xcode 的用户可跳过）：

```sh
xcode-select --install
```

安装完成后运行：

```sh
git clone https://github.com/LCROSSY/KeepClam.git
cd KeepClam
zsh scripts/build-native.command
open build/KeepClam.app
```

构建产物位于 `build/KeepClam.app`，也可以将它拖进「应用程序」文件夹。

## 免密授权（sudoers 白名单）

切换 `SleepDisabled` 需要 root 权限。KeepClam 不让你每次开关都输一遍管理员密码，而是提供一条一次性的 sudoers 规则，范围极窄。在菜单里点「免密授权」，或者运行：

```sh
zsh scripts/install-sudoers.sh
```

这条规则只放行下面两条命令，没有通配符，除此之外什么都不允许：

```
<你的用户名> ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1
```

- 查看已安装的规则：`sudo cat /etc/sudoers.d/keepclam`
- 移除规则：`zsh scripts/uninstall-sudoers.sh`（之后开关恢复为每次弹窗输密码）

不装白名单也能正常使用，只是每次开关都会弹出管理员密码框。

如果要合盖后无人值守，务必在合盖前装好白名单：后台的守护进程和自动结束走的是免密通道（`sudo -n`），人不在时无法弹出密码框。

## 登录时启动

将应用安装到「应用程序」后，在「设置 → 登录时启动」中开启。该选项默认关闭，只会自动启动菜单栏应用，不会自动开启合盖运行或恢复旧会话。如果需要系统批准，点击该选项可打开系统登录项设置。卸载前请关闭此选项。

替换已安装的应用前，请先结束会话并退出正在运行的应用。

## 使用方法

1. 启动 KeepClam，菜单栏出现状态指示（`○ KeepClam` 关闭，`● KeepClam` 开启）。
2. 点「开启合盖运行」。首次使用建议先装好上面的免密白名单。
3. 需要的话，在「设置」里选好自动结束时长、电池下限和界面语言。
4. 合上盖子，任务继续跑。
5. 过热保护在后台全程值守；日志在 `~/Library/Logs/KeepClam/`。

过热触发、定时结束、电量不足等关键事件都会发系统通知，开盖后就能看到。

## 应急恢复

万一出问题，一条命令就能恢复系统默认的睡眠行为：

```sh
sudo pmset -a disablesleep 0     # 然后确认：
pmset -g | grep SleepDisabled    # 不应再出现 "SleepDisabled 1"
```

## 安全须知

- 请自担风险。`disablesleep` 是 macOS 没有在系统设置里公开的全局电源参数；macOS 大版本升级后请重新验证。
- 过热保护是软件层面的尽力而为——它读取的是 Apple 官方热压力等级，不是摄氏温度。别把正在运行的合盖 MacBook 塞进包里，注意通风散热。

## 常见问题

**为什么显示热等级而不是摄氏温度？** Apple Silicon 不向普通权限的程序提供稳定统一的 CPU 温度接口。KeepClam 用的是 `NSProcessInfo.thermalState`（正常 / 略高 / 过高 / 严重过热）——macOS 自己决定降频时，看的就是这个信号。

**守护进程自己挂了怎么办？** 应用最多 5 秒就会发现守护缺失：记一条 `guard_missing` 日志、发一条通知，然后立刻自己动手恢复睡眠；如果恢复失败，会通知你手动执行应急命令。守护进程只是普通用户进程，同一用户的程序可以杀掉它——这是个人工具接受的取舍（同类工具都是如此）。

**应用崩溃了，定时还有效吗？** 应用一死，守护进程马上发现父进程消失，在一个检查周期内就恢复睡眠——比任何定时器都更严格的「自动结束」。

## 开发

```sh
zsh scripts/build-native.command        # 构建应用
clang -fobjc-arc -framework Cocoa -framework IOKit -framework UserNotifications -framework ServiceManagement \
      Sources/LogTests.m -o build/LogTests && ./build/LogTests   # 运行测试
python3 scripts/test-install.py          # 在临时目录中验证安装与更新
```

整个应用就一个 Objective-C/AppKit 源文件，没有 Xcode 工程，零依赖。CI 每次 push 都会构建并验证应用和安装流程；Release 附安装脚本及 ZIP、脚本的 SHA-256 校验和。

## 许可

[MIT](LICENSE)
