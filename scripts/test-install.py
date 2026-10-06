#!/usr/bin/env python3
"""在临时目录中验证安装与更新，使用真实签名和 ZIP；不启动应用或修改系统权限。"""

import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import stat
import subprocess
import tempfile
import unittest
import zipfile


ROOT = Path(__file__).resolve().parents[1]
INSTALLER = ROOT / "scripts/install.sh"
APP = ROOT / "build/KeepClam.app"
VERSION = "0.2.0"
ASSET = f"KeepClam-{VERSION}.zip"


# 安装脚本要在 UTF-8 区域设置下运行（macOS 默认）；Bash 3.2 在此设置下对 $变量 后紧跟的
# 多字节字符有特殊处理，所以测试子进程固定使用 UTF-8，并在多个区域设置下检查在线安装路径。
UTF8_LOCALES = ("en_US.UTF-8", "zh_CN.UTF-8")


def command(*args):
    return subprocess.run(args, check=True, capture_output=True, text=True, errors="replace")


class InstallerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not APP.is_dir():
            raise RuntimeError("请先运行 zsh scripts/build-native.command")
        cls.fixture_tmp = tempfile.TemporaryDirectory(prefix="keepclam-fixture-")
        cls.fixture = Path(cls.fixture_tmp.name) / "KeepClam.app"
        shutil.copytree(APP, cls.fixture)
        cls.set_plist(cls.fixture, CFBundleShortVersionString=VERSION, CFBundleVersion=VERSION)
        command("/usr/bin/codesign", "--force", "--sign", "-", str(cls.fixture))
        command("/usr/bin/codesign", "--verify", "--strict", str(cls.fixture))

    @classmethod
    def tearDownClass(cls):
        cls.fixture_tmp.cleanup()

    @staticmethod
    def set_plist(app, **changes):
        path = app / "Contents/Info.plist"
        values = plistlib.loads(path.read_bytes())
        values.update(changes)
        path.write_bytes(plistlib.dumps(values))

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="keepclam-install-test-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.local = self.root / "Downloaded release"
        self.local.mkdir()
        self.app_dir = self.root / "My Applications"
        self.dest = self.app_dir / "KeepClam.app"
        self.archive = self.local / ASSET
        self.package(self.fixture)

    def package(self, app):
        self.archive.unlink(missing_ok=True)
        command("/usr/bin/ditto", "-c", "-k", "--norsrc", "--noextattr", "--keepParent", str(app), str(self.archive))
        self.write_checksum()

    def write_checksum(self):
        digest = hashlib.sha256(self.archive.read_bytes()).hexdigest()
        (self.local / "SHA256SUMS").write_text(f"{digest}  {ASSET}\n")

    def old_app(self):
        self.app_dir.mkdir()
        shutil.copytree(APP, self.dest)
        (self.dest / "preserve-me.txt").write_text("previous installation")

    def assert_old_preserved(self):
        self.assertEqual((self.dest / "preserve-me.txt").read_text(), "previous installation")

    def run_installer(self, extra=(), overrides="", local=True, trust=True, locale="en_US.UTF-8", env_extra=None,
                      stub_stopped=True, app_dir=True):
        # macOS 的沙箱可能禁止枚举系统进程，本机也可能正运行着真实的 KeepClam；测试子进程
        # 从不枚举真实进程：要么整体跳过运行检查，要么只替换进程列表，检查逻辑本身照常执行。
        # 其余下载解析、解压、签名校验、隔离属性及文件替换均执行真实实现。
        # 同时让本机是否装有 Homebrew 版 KeepClam 不影响测试。
        stubs = ('require_stopped() { :; };' if stub_stopped
                 else 'legacy_running() { return 1; }; keepclam_processes() { :; };')
        script = ('source "$1"; shift; ' + stubs + ' homebrew_cask_installed() { return 1; };\n'
                  + overrides + '\nmain "$@"')
        args = ["--no-open", "--language", "en"]
        if app_dir:
            args += ["--app-dir", str(self.app_dir)]
        if local:
            args += ["--local", str(self.local)]
        if trust:
            args += ["--trust"]
        env = os.environ.copy()
        env.pop("LC_MESSAGES", None)
        env.pop("LANG", None)
        env.update(LC_ALL=locale, TEST_RELEASE_DIR=str(self.local), TEST_DOWNLOAD_LOG=str(self.root / "downloads.log"))
        env.update(env_extra or {})
        return subprocess.run(
            ["/bin/bash", "-c", script, "installer-test", str(INSTALLER), *args, *extra],
            stdin=subprocess.DEVNULL, capture_output=True, text=True, errors="replace", env=env,
            start_new_session=True, timeout=30,
        )

    def assert_failure(self, result, message):
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn(message, result.stderr)

    def test_fresh_install_with_spaces(self):
        result = self.run_installer()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Release checksum verified", result.stdout)
        command("/usr/bin/codesign", "--verify", "--strict", str(self.dest))
        self.assertEqual(list(self.app_dir.iterdir()), [self.dest])

    def test_successful_replacement(self):
        self.old_app()
        result = self.run_installer()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.dest / "preserve-me.txt").exists())
        values = plistlib.loads((self.dest / "Contents/Info.plist").read_bytes())
        self.assertEqual(values["CFBundleShortVersionString"], VERSION)
        self.assertEqual(list(self.app_dir.iterdir()), [self.dest])

    def test_corrupt_download_keeps_old_app(self):
        self.old_app()
        with self.archive.open("ab") as stream:
            stream.write(b"corrupted download")
        self.assert_failure(self.run_installer(), "Checksum mismatch")
        self.assert_old_preserved()

    def test_missing_checksum_does_not_create_target(self):
        (self.local / "SHA256SUMS").unlink()
        self.assert_failure(self.run_installer(), "same directory")
        self.assertFalse(self.app_dir.exists())

    def test_duplicate_checksum_is_rejected(self):
        sums = self.local / "SHA256SUMS"
        sums.write_text(sums.read_text() * 2)
        self.assert_failure(self.run_installer(), "unique valid checksum")
        self.assertFalse(self.app_dir.exists())

    def test_checksum_for_other_file_is_not_used(self):
        sums = self.local / "SHA256SUMS"
        sums.write_text(sums.read_text().replace(ASSET, "../../other-file"))
        self.assert_failure(self.run_installer(), "unique valid checksum")

    def test_invalid_signature_keeps_old_app(self):
        self.old_app()
        altered = self.root / "altered" / "KeepClam.app"
        shutil.copytree(self.fixture, altered)
        with (altered / "Contents/MacOS/KeepClam").open("ab") as stream:
            stream.write(b"modified executable")
        self.package(altered)
        self.assert_failure(self.run_installer(), "integrity check failed")
        self.assert_old_preserved()

    def test_wrong_bundle_identity_is_rejected(self):
        altered = self.root / "altered" / "KeepClam.app"
        shutil.copytree(self.fixture, altered)
        self.set_plist(altered, CFBundleIdentifier="org.example.other-app")
        command("/usr/bin/codesign", "--force", "--sign", "-", str(altered))
        self.package(altered)
        self.assert_failure(self.run_installer(), "identity, version")
        self.assertFalse(self.app_dir.exists())

    def test_wrong_bundle_version_is_rejected(self):
        altered = self.root / "altered" / "KeepClam.app"
        shutil.copytree(self.fixture, altered)
        self.set_plist(altered, CFBundleShortVersionString="0.9.0")
        command("/usr/bin/codesign", "--force", "--sign", "-", str(altered))
        self.package(altered)
        self.assert_failure(self.run_installer(), "identity, version")

    def test_archive_traversal_is_rejected_before_extraction(self):
        for entry in ("../escape", "KeepClam.app/Contents/../../../escape", "KeepClam.app/.."):
            with self.subTest(entry=entry):
                self.package(self.fixture)
                with zipfile.ZipFile(self.archive, "a") as archive:
                    archive.writestr(entry, "do not extract")
                self.write_checksum()
                result = self.run_installer()
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(self.app_dir.exists())
                self.assertFalse((self.root / "escape").exists())

    def test_archive_symlink_is_rejected_before_extraction(self):
        entry = zipfile.ZipInfo("KeepClam.app/Contents/linked-file")
        entry.create_system = 3
        entry.external_attr = (stat.S_IFLNK | 0o777) << 16
        with zipfile.ZipFile(self.archive, "a") as archive:
            archive.writestr(entry, "../../../escape")
        self.write_checksum()
        self.assert_failure(self.run_installer(), "contains symlinks")
        self.assertFalse(self.app_dir.exists())

    def test_target_symlink_is_not_replaced(self):
        self.app_dir.mkdir()
        self.dest.symlink_to(self.fixture, target_is_directory=True)
        self.assert_failure(self.run_installer(), "target app is a symlink")
        self.assertTrue(self.dest.is_symlink())

    def test_unrelated_target_is_not_replaced(self):
        self.app_dir.mkdir()
        self.dest.write_text("unrelated file")
        self.assert_failure(self.run_installer(), "different file already occupies")
        self.assertEqual(self.dest.read_text(), "unrelated file")

    def test_target_changed_during_download_is_not_replaced(self):
        overrides = '''checks=0
require_stopped() {
  checks=$((checks + 1))
  if [ "$checks" -gt 1 ]; then printf 'other file' > "$INSTALL_DEST"; fi
}'''
        self.assert_failure(self.run_installer(overrides=overrides), "different file already occupies")
        self.assertEqual(self.dest.read_text(), "other file")
        self.assertEqual(list(self.app_dir.iterdir()), [self.dest])

    def test_root_install_directory_is_rejected(self):
        self.assert_failure(self.run_installer(extra=["--app-dir", "/"]), "filesystem root")
        self.assertFalse(self.app_dir.exists())

    def test_running_app_blocks_installation(self):
        self.old_app()
        overrides = 'require_stopped() { fail "应用正在运行。" "The app is running."; }'
        self.assert_failure(self.run_installer(overrides=overrides), "app is running")
        self.assert_old_preserved()

    def test_app_started_during_installation_blocks_replacement(self):
        self.old_app()
        overrides = '''checks=0
require_stopped() {
  checks=$((checks + 1))
  if [ "$checks" -gt 1 ]; then fail "应用正在运行。" "The app is running."; fi
}'''
        self.assert_failure(self.run_installer(overrides=overrides), "app is running")
        self.assert_old_preserved()
        self.assertEqual(list(self.app_dir.iterdir()), [self.dest])

    @staticmethod
    def process_list(*lines):
        body = "".join(f"printf '%s\\n' '{line}'; " for line in lines)
        return "keepclam_processes() { : ; " + body + "}"

    def test_running_state_classification(self):
        uid = os.getuid()
        cases = {
            "none": [],
            "app": [f"101 {uid} /Applications/KeepClam.app/Contents/MacOS/KeepClam"],
            "session": [f"101 {uid} /Applications/KeepClam.app/Contents/MacOS/KeepClam",
                        f"102 {uid} /Applications/KeepClam.app/Contents/MacOS/KeepClam --guard 101 4"],
            "other_user": [f"101 {uid + 1} /Applications/KeepClam.app/Contents/MacOS/KeepClam"],
        }
        for expected, lines in cases.items():
            with self.subTest(expected=expected):
                script = ('source "$1"; legacy_running() { return 1; }; '
                          + self.process_list(*lines) + '; running_state')
                result = self.run_script(script, "en_US.UTF-8")
                self.assertEqual(result.stdout.strip(), expected, result.stderr)
        result = self.run_script('source "$1"; legacy_running() { return 0; }; running_state', "en_US.UTF-8")
        self.assertEqual(result.stdout.strip(), "legacy")

    def test_session_blocks_installation(self):
        self.old_app()
        uid = os.getuid()
        overrides = self.process_list(f"101 {uid} /x/KeepClam.app/Contents/MacOS/KeepClam",
                                      f"102 {uid} /x/KeepClam.app/Contents/MacOS/KeepClam --guard 101 4")
        self.assert_failure(self.run_installer(overrides=overrides, stub_stopped=False), "lid-closed session is running")
        self.assert_old_preserved()

    def test_other_users_app_blocks_installation(self):
        self.old_app()
        overrides = self.process_list(f"101 {os.getuid() + 1} /x/KeepClam.app/Contents/MacOS/KeepClam")
        self.assert_failure(self.run_installer(overrides=overrides, stub_stopped=False), "Another user is running")
        self.assert_old_preserved()

    def test_legacy_app_blocks_installation(self):
        self.old_app()
        result = self.run_installer(overrides="legacy_running() { return 0; }", stub_stopped=False)
        self.assert_failure(result, "legacy LidAwake")
        self.assert_old_preserved()

    def test_unknown_process_state_cancels_installation(self):
        self.old_app()
        result = self.run_installer(overrides="keepclam_processes() { return 1; }", stub_stopped=False)
        self.assert_failure(result, "Could not check for running apps")
        self.assert_old_preserved()

    def spawn_fake_app(self):
        # 用一个只会等待信号的小程序模拟正在运行的菜单栏应用（复制的系统程序换路径后会被系统
        # 结束，所以现场编译）。经由 bash 后台启动，退出后由 launchd 回收，不会残留僵尸进程。
        # 测试只会结束这个进程，从不碰本机真实的 KeepClam。
        fake = self.root / "KeepClam"
        source = self.root / "fake-app.c"
        source.write_text("#include <unistd.h>\nint main(void) { for (;;) pause(); }\n")
        command("/usr/bin/clang", "-o", str(fake), str(source))
        pid = int(subprocess.run(["/bin/bash", "-c", f'"{fake}" >/dev/null 2>&1 & echo $!'],
                                 capture_output=True, text=True, check=True).stdout)
        self.addCleanup(lambda: subprocess.run(["/bin/kill", "-KILL", str(pid)], capture_output=True))
        return pid

    @staticmethod
    def alive(pid):
        return subprocess.run(["/bin/kill", "-0", str(pid)], capture_output=True).returncode == 0

    def test_running_app_is_quit_before_replacement(self):
        self.old_app()
        pid = self.spawn_fake_app()
        overrides = f'keepclam_processes() {{ /bin/ps -ww -o pid=,uid=,args= -p {pid} 2>/dev/null || true; }}'
        result = self.run_installer(overrides=overrides, stub_stopped=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("it will be quit before installing", result.stdout)
        self.assertIn("Quitting the running KeepClam", result.stdout)
        self.assertFalse(self.alive(pid))
        self.assertFalse((self.dest / "preserve-me.txt").exists())

    def test_running_app_is_not_quit_when_installation_fails(self):
        self.old_app()
        pid = self.spawn_fake_app()
        with self.archive.open("ab") as stream:
            stream.write(b"corrupted download")
        overrides = f'keepclam_processes() {{ /bin/ps -ww -o pid=,uid=,args= -p {pid} 2>/dev/null || true; }}'
        self.assert_failure(self.run_installer(overrides=overrides, stub_stopped=False), "Checksum mismatch")
        self.assertTrue(self.alive(pid))
        self.assert_old_preserved()

    def test_session_started_before_quit_blocks_replacement(self):
        self.old_app()
        uid = os.getuid()
        # 进程列表在子 shell 中读取，用文件记录调用次数。
        counter = self.root / "process-checks"
        overrides = f'''keepclam_processes() {{
  printf x >> "{counter}"
  printf '%s\\n' "101 {uid} /x/KeepClam.app/Contents/MacOS/KeepClam"
  if [ "$(/usr/bin/wc -c < "{counter}")" -gt 1 ]; then printf '%s\\n' "102 {uid} /x/KeepClam.app/Contents/MacOS/KeepClam --guard 101 4"; fi
}}'''
        self.assert_failure(self.run_installer(overrides=overrides, stub_stopped=False), "lid-closed session is running")
        self.assert_old_preserved()

    def app_dirs(self, system_writable=True):
        system, personal = self.root / "System Applications", self.root / "Home Applications"
        system.mkdir()
        personal.mkdir()
        if not system_writable:
            system.chmod(0o555)
            self.addCleanup(system.chmod, 0o755)
        return system, personal, f"standard_app_dirs() {{ printf '%s\\n' '{system}' '{personal}'; }}"

    def test_default_location_without_existing_install_is_system(self):
        system, personal, overrides = self.app_dirs()
        result = self.run_installer(overrides=overrides, app_dir=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((system / "KeepClam.app").is_dir())
        self.assertFalse((personal / "KeepClam.app").exists())

    def test_default_location_falls_back_to_personal_when_system_is_read_only(self):
        system, personal, overrides = self.app_dirs(system_writable=False)
        result = self.run_installer(overrides=overrides, app_dir=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((personal / "KeepClam.app").is_dir())

    def test_update_keeps_existing_personal_location(self):
        system, personal, overrides = self.app_dirs()
        shutil.copytree(APP, personal / "KeepClam.app")
        result = self.run_installer(overrides=overrides, app_dir=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((system / "KeepClam.app").exists())
        values = plistlib.loads((personal / "KeepClam.app/Contents/Info.plist").read_bytes())
        self.assertEqual(values["CFBundleShortVersionString"], VERSION)

    def test_update_prefers_system_copy_and_warns_about_duplicate(self):
        system, personal, overrides = self.app_dirs()
        shutil.copytree(APP, system / "KeepClam.app")
        shutil.copytree(APP, personal / "KeepClam.app")
        (personal / "KeepClam.app/preserve-me.txt").write_text("personal copy")
        result = self.run_installer(overrides=overrides, app_dir=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("another copy of KeepClam", result.stderr)
        self.assertEqual((personal / "KeepClam.app/preserve-me.txt").read_text(), "personal copy")

    def test_existing_read_only_system_install_is_not_duplicated(self):
        system, personal, overrides = self.app_dirs()
        shutil.copytree(APP, system / "KeepClam.app")
        system.chmod(0o555)
        self.addCleanup(system.chmod, 0o755)
        self.assert_failure(self.run_installer(overrides=overrides, app_dir=False), "can't write there")
        self.assertFalse((personal / "KeepClam.app").exists())

    def test_failed_replacement_restores_old_app(self):
        self.old_app()
        overrides = '''publish_app() {
  /bin/mv "$INSTALL_DEST" "$INSTALL_STAGE/previous.app"
  return 1
}'''
        result = self.run_installer(overrides=overrides)
        self.assert_failure(result, "Could not replace")
        self.assertIn("previous app was restored", result.stderr)
        self.assert_old_preserved()
        self.assertEqual(list(self.app_dir.iterdir()), [self.dest])

    def test_failed_restore_preserves_backup(self):
        self.old_app()
        overrides = '''publish_app() {
  /bin/mv "$INSTALL_DEST" "$INSTALL_STAGE/previous.app"
  /bin/mkdir "$INSTALL_DEST"
  printf 'other installation' > "$INSTALL_DEST/other.txt"
  return 1
}'''
        result = self.run_installer(overrides=overrides)
        self.assert_failure(result, "previous app is preserved at")
        self.assertEqual((self.dest / "other.txt").read_text(), "other installation")
        backups = list(self.app_dir.glob(".keepclam-install.*/previous.app/preserve-me.txt"))
        self.assertEqual(len(backups), 1)
        self.assertEqual(backups[0].read_text(), "previous installation")

    def test_noninteractive_install_requires_explicit_choice(self):
        self.assert_failure(self.run_installer(trust=False), "interactive terminal is required")
        self.assertFalse(self.app_dir.exists())

    def test_yes_does_not_replace_local_trust_choice(self):
        self.assert_failure(self.run_installer(extra=["--yes"], trust=False), "interactive terminal is required")
        self.assertFalse(self.app_dir.exists())

    def test_conflicting_trust_options_are_rejected(self):
        self.assert_failure(self.run_installer(extra=["--keep-quarantine"]), "only one trust option")

    def test_trust_removes_only_installed_apps_quarantine(self):
        attribute = "com.apple.quarantine"
        value = "0083;00000000;KeepClamInstallTests;"
        command("/usr/bin/xattr", "-w", attribute, value, str(self.archive))
        result = self.run_installer()
        self.assertEqual(result.returncode, 0, result.stderr)
        attrs = command("/usr/bin/xattr", "-lr", str(self.dest)).stdout
        self.assertNotIn(attribute, attrs)
        self.assertEqual(command("/usr/bin/xattr", "-p", attribute, str(self.archive)).stdout.strip(), value)

    def test_keep_quarantine_preserves_download_attribute(self):
        attribute = "com.apple.quarantine"
        command("/usr/bin/xattr", "-w", attribute, "0083;00000000;KeepClamInstallTests;", str(self.archive))
        result = self.run_installer(extra=["--keep-quarantine"], trust=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(attribute, command("/usr/bin/xattr", "-lr", str(self.dest)).stdout)

    @staticmethod
    def fake_download():
        return '''download() {
  printf '%s\\n' "$1" >> "$TEST_DOWNLOAD_LOG"
  local base="https://github.com/LCROSSY/KeepClam/releases/download/" ver
  case "$1" in
    "https://api.github.com/repos/LCROSSY/KeepClam/releases?per_page=20")
      [ -z "${TEST_API_FAIL:-}" ] || return 22
      /bin/cp "$TEST_RELEASE_DIR/releases.json" "$2" ;;
    "https://github.com/LCROSSY/KeepClam/releases.atom")
      [ -f "$TEST_RELEASE_DIR/releases.atom" ] || return 22
      /bin/cp "$TEST_RELEASE_DIR/releases.atom" "$2" ;;
    "${base}v0.2.0/KeepClam-0.2.0.zip")
      /bin/cp "$TEST_RELEASE_DIR/KeepClam-0.2.0.zip" "$2" ;;
    "${base}v0.2.0/SHA256SUMS")
      /bin/cp "$TEST_RELEASE_DIR/SHA256SUMS" "$2" ;;
    "${base}"v*/SHA256SUMS)
      ver="${1#"${base}v"}"
      ver="${ver%/SHA256SUMS}"
      [ -f "$TEST_RELEASE_DIR/SHA256SUMS.$ver" ] || return 22
      /bin/cp "$TEST_RELEASE_DIR/SHA256SUMS.$ver" "$2" ;;
    *) return 22 ;;
  esac
}'''

    def test_preview_discovery_skips_drafts_and_incomplete_releases(self):
        def release(tag, draft=False, sums=True):
            assets = [{"name": f"KeepClam-{tag[1:]}.zip"}]
            if sums:
                assets.append({"name": "SHA256SUMS"})
            return {"tag_name": tag, "draft": draft, "prerelease": True, "assets": assets}

        metadata = [release("v9.0.0", draft=True), release("v0.3.0", sums=False), release("v../../bad"), release("v0.2.0")]
        (self.local / "releases.json").write_text(json.dumps(metadata))
        result = self.run_installer(local=False, overrides=self.fake_download())
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Installed KeepClam 0.2.0", result.stdout)
        self.assertEqual(len((self.root / "downloads.log").read_text().splitlines()), 3)

    def test_explicit_version_does_not_need_release_api(self):
        result = self.run_installer(extra=["--version", "v0.2.0"], local=False, overrides=self.fake_download())
        self.assertEqual(result.returncode, 0, result.stderr)
        urls = (self.root / "downloads.log").read_text().splitlines()
        self.assertEqual(len(urls), 2)
        self.assertTrue(all(url.startswith("https://github.com/LCROSSY/KeepClam/releases/download/v0.2.0/") for url in urls))

    def test_network_failure_keeps_old_app(self):
        self.old_app()
        result = self.run_installer(local=False, overrides="download() { return 22; }")
        self.assert_failure(result, "Could not fetch releases")
        self.assertIn("--version", result.stderr)
        self.assert_old_preserved()

    def write_atom(self, tags):
        entries = "".join(
            f'<entry><title>{tag}</title>'
            f'<link rel="alternate" type="text/html" href="https://github.com/LCROSSY/KeepClam/releases/tag/{tag}"/></entry>\n'
            for tag in tags
        )
        feed = ('<?xml version="1.0" encoding="UTF-8"?>\n<feed xmlns="http://www.w3.org/2005/Atom">'
                '<link rel="alternate" type="text/html" href="https://github.com/LCROSSY/KeepClam/releases"/>\n'
                + entries + "</feed>\n")
        (self.local / "releases.atom").write_text(feed)

    def test_rate_limited_api_falls_back_to_release_feed(self):
        self.write_atom(["v0.9.0", "v../bad", "v0.3.0", "v0.2.0", "v0.1.0"])
        # v0.9.0 没有校验文件；v0.3.0 的校验文件没有对应 ZIP。
        (self.local / "SHA256SUMS.0.3.0").write_text(f"{'0' * 64}  KeepClam-0.1.0.zip\n")
        result = self.run_installer(local=False, trust=False, extra=["--yes"],
                                    overrides=self.fake_download(), env_extra={"TEST_API_FAIL": "1"})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Installed KeepClam 0.2.0", result.stdout)
        base = "https://github.com/LCROSSY/KeepClam/releases/download/"
        self.assertEqual((self.root / "downloads.log").read_text().splitlines(), [
            "https://api.github.com/repos/LCROSSY/KeepClam/releases?per_page=20",
            "https://github.com/LCROSSY/KeepClam/releases.atom",
            base + "v0.9.0/SHA256SUMS", base + "v0.3.0/SHA256SUMS", base + "v0.2.0/SHA256SUMS",
            base + "v0.2.0/KeepClam-0.2.0.zip", base + "v0.2.0/SHA256SUMS",
        ])

    def test_release_feed_probes_at_most_five_versions(self):
        self.write_atom(["v0.9.0", "v0.8.0", "v0.7.0", "v0.6.0", "v0.5.0", "v0.2.0"])
        self.old_app()
        result = self.run_installer(local=False, trust=False, extra=["--yes"],
                                    overrides=self.fake_download(), env_extra={"TEST_API_FAIL": "1"})
        self.assert_failure(result, "No complete release found")
        self.assertEqual(len((self.root / "downloads.log").read_text().splitlines()), 2 + 5)
        self.assert_old_preserved()

    def test_api_and_release_feed_failure_keeps_old_app(self):
        self.old_app()
        result = self.run_installer(local=False, trust=False, extra=["--yes"],
                                    overrides=self.fake_download(), env_extra={"TEST_API_FAIL": "1"})
        self.assert_failure(result, "Could not fetch releases")
        self.assertIn("--version", result.stderr)
        self.assert_old_preserved()

    def test_online_install_requires_confirmation_without_tty(self):
        self.old_app()
        result = self.run_installer(extra=["--version", "0.2.0"], local=False, trust=False, overrides=self.fake_download())
        self.assert_failure(result, "interactive terminal is required")
        self.assertIn("--yes", result.stderr)
        self.assertIn("Release source: https://github.com/LCROSSY/KeepClam/releases/tag/v0.2.0", result.stdout)
        self.assert_old_preserved()

    def test_online_yes_installs_without_prompt(self):
        result = self.run_installer(extra=["--version", "0.2.0", "--yes"], local=False, trust=False,
                                    overrides=self.fake_download())
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Installed KeepClam 0.2.0", result.stdout)
        command("/usr/bin/codesign", "--verify", "--strict", str(self.dest))

    def test_online_trust_options_act_as_confirmation(self):
        for option in ("--trust", "--keep-quarantine"):
            with self.subTest(option=option):
                self.assertFalse(self.app_dir.exists())
                result = self.run_installer(extra=["--version", "0.2.0", option], local=False, trust=False,
                                            overrides=self.fake_download())
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertNotIn("Privacy & Security", result.stdout)
                shutil.rmtree(self.app_dir)

    def test_online_install_under_utf8_locales(self):
        # 回归：Bash 3.2 在 UTF-8 下会把 $变量 后的多字节字符并入变量名，set -u 时直接报错。
        for locale in UTF8_LOCALES:
            for language in ("en", "zh"):
                with self.subTest(locale=locale, language=language):
                    result = self.run_installer(extra=["--version", "0.2.0", "--yes", "--language", language],
                                                local=False, trust=False, overrides=self.fake_download(), locale=locale)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertNotIn("unbound variable", result.stderr)
                    self.assertIn("Installed KeepClam 0.2.0" if language == "en" else "安装完成：KeepClam 0.2.0", result.stdout)
                    shutil.rmtree(self.app_dir)

    def test_error_messages_under_utf8_locales(self):
        for locale in UTF8_LOCALES:
            with self.subTest(locale=locale):
                result = self.run_installer(extra=["--app-dir", "relative", "--language", "zh"], locale=locale)
                self.assert_failure(result, "安装目录必须是绝对路径。")

    def test_homebrew_install_is_not_replaced(self):
        self.old_app()
        result = self.run_installer(overrides="homebrew_cask_installed() { return 0; }")
        self.assert_failure(result, "brew upgrade --cask keepclam")
        self.assert_old_preserved()
        self.assertEqual(list(self.app_dir.iterdir()), [self.dest])

    def test_homebrew_cask_without_existing_app_installs(self):
        result = self.run_installer(overrides="homebrew_cask_installed() { return 0; }")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_homebrew_detection_uses_caskroom_directories(self):
        prefix = self.root / "brew"
        script = 'source "$1"; homebrew_cask_installed'
        def detect(**env_extra):
            env = {**os.environ, "HOMEBREW_PREFIX": str(prefix), **env_extra}
            return subprocess.run(["/bin/bash", "-c", script, "t", str(INSTALLER)], env=env,
                                  capture_output=True, text=True, errors="replace").returncode
        (prefix / "Caskroom/keepclam").mkdir(parents=True)
        self.assertEqual(detect(), 0)

    def run_script(self, script, locale, env_extra=None):
        env = {k: v for k, v in os.environ.items() if k not in ("LC_ALL", "LC_MESSAGES", "LANG")}
        env.update(LC_ALL=locale)
        env.update(env_extra or {})
        return subprocess.run(["/bin/bash", "-c", script, "t", str(INSTALLER)], env=env, stdin=subprocess.DEVNULL,
                              capture_output=True, text=True, errors="replace", timeout=30)

    def test_language_detection(self):
        detect = 'source "$1"; apple_language() { printf "%s" "$TEST_APPLE_LANGUAGE"; }; detect_language'
        cases = [
            ("zh_CN.UTF-8", "en-US", "zh"),
            ("en_US.UTF-8", "zh-Hans-CN", "en"),
            ("C", "zh-Hans-CN", "zh"),
            ("C", "zh-Hant-TW", "zh"),
            ("C", "en-US", "en"),
            ("POSIX", "", "en"),
        ]
        for locale, apple, expected in cases:
            with self.subTest(locale=locale, apple=apple):
                result = self.run_script(detect, locale, {"TEST_APPLE_LANGUAGE": apple})
                self.assertEqual(result.stdout.strip(), expected, result.stderr)

    def test_language_flag_overrides_detection(self):
        script = 'source "$1"; shift; main --app-dir relative'
        zh = self.run_script(script, "zh_CN.UTF-8")
        self.assert_failure(zh, "安装目录必须是绝对路径")
        en = self.run_script(script + ' --language en', "zh_CN.UTF-8")
        self.assert_failure(en, "must be an absolute path")
        auto_en = self.run_script(script, "en_US.UTF-8")
        self.assert_failure(auto_en, "must be an absolute path")

    def test_help_works_without_installing(self):
        for locale in UTF8_LOCALES + ("C",):
            with self.subTest(locale=locale):
                result = self.run_script('/bin/bash "$1" --help', locale)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("--keep-quarantine", result.stdout)
                self.assertIn("--yes", result.stdout)
        self.assertFalse(self.app_dir.exists())

    def test_piped_script_runs_with_arguments(self):
        # curl … | bash -s -- … 时 BASH_SOURCE 为空；脚本仍应执行 main 并接收参数。
        for locale in UTF8_LOCALES:
            with self.subTest(locale=locale):
                env = {k: v for k, v in os.environ.items() if k not in ("LC_MESSAGES", "LANG")}
                env.update(LC_ALL=locale)
                result = subprocess.run(["/bin/bash", "-s", "--", "--help"], input=INSTALLER.read_text(encoding="utf-8"),
                                        capture_output=True, text=True, errors="replace", env=env, timeout=30)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("--language zh|en", result.stdout)
                self.assertNotIn("unbound variable", result.stderr)

    def test_sourcing_does_not_run_main(self):
        result = self.run_script('source "$1"; echo sourced', "en_US.UTF-8")
        self.assertEqual(result.stdout.strip(), "sourced", result.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)
