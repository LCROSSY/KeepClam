#import <Cocoa/Cocoa.h>
#import <UserNotifications/UserNotifications.h>
#import <IOKit/IOKitLib.h>
#import <IOKit/ps/IOPowerSources.h>
#import <IOKit/ps/IOPSKeys.h>
#import <signal.h>
#import <unistd.h>
#import <stdlib.h>
#import <string.h>
#import <math.h>
#import <sys/file.h>
#import <sys/stat.h>
#import <fcntl.h>
#import <poll.h>
#import <errno.h>
#import <sys/wait.h>
#import <ServiceManagement/ServiceManagement.h>
#import <libproc.h>
#import <Security/Security.h>
#import "Uninstall.m"
// Exported by Security.framework; its SecTranslocate.h header is absent from the Command Line Tools SDK.
extern Boolean SecTranslocateIsTranslocatedURL(CFURLRef path,bool *isTranslocated,CFErrorRef *error);

static BOOL PrivateDirectory(NSString *path) {
    if(![NSFileManager.defaultManager createDirectoryAtPath:path withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:nil]) return NO;
    int fd=open(path.fileSystemRepresentation,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
    if(fd<0) return NO;
    BOOL ok=fchmod(fd,0700)==0; close(fd); return ok;
}
static int InstanceLock(NSString *path) {
    int fd=open(path.fileSystemRepresentation,O_CREAT|O_RDWR|O_NOFOLLOW|O_CLOEXEC,0600);
    if(fd<0) return -1;
    if(flock(fd,LOCK_EX|LOCK_NB)!=0) { close(fd); return -1; }
    fchmod(fd,0600); return fd;
}
// Rotates path to path.1..3; the caller holds the log's flock. Shared by the guard's
// per-line Append and the app's resident-fd writer.
static void RotateLog(NSString *path) {
    NSFileManager *fm=NSFileManager.defaultManager;
    [fm removeItemAtPath:[path stringByAppendingString:@".3"] error:nil];
    for(int i=2;i>=1;i--) [fm moveItemAtPath:[path stringByAppendingFormat:@".%d",i] toPath:[path stringByAppendingFormat:@".%d",i+1] error:nil];
    [fm moveItemAtPath:path toPath:[path stringByAppendingString:@".1"] error:nil];
}
static void Append(NSString *path,NSString *line) {
    int lock=open([[path stringByAppendingString:@".lock"] fileSystemRepresentation],O_CREAT|O_RDWR|O_NOFOLLOW|O_CLOEXEC,0600);
    if(lock<0) return;
    fchmod(lock,0600);
    flock(lock,LOCK_EX);
    struct stat st;
    int existing=open(path.fileSystemRepresentation,O_RDONLY|O_NOFOLLOW|O_CLOEXEC);
    if(existing>=0) { fchmod(existing,0600); close(existing); }
    if(lstat(path.fileSystemRepresentation,&st)==0 && S_ISREG(st.st_mode) && st.st_size>1024*1024) RotateLog(path);
    int fd=open(path.fileSystemRepresentation,O_CREAT|O_WRONLY|O_APPEND|O_NOFOLLOW|O_CLOEXEC,0600);
    if(fd>=0) {
        fchmod(fd,0600);
        NSData *data=[line dataUsingEncoding:NSUTF8StringEncoding];
        const char *bytes=data.bytes; size_t left=data.length;
        while(left) { ssize_t n=write(fd,bytes,left); if(n<0 && errno==EINTR) continue; if(n<=0) break; bytes+=n; left-=n; }
        fsync(fd); close(fd);
    }
    flock(lock,LOCK_UN); close(lock);
}

// Runs a tool to completion and returns merged stdout/stderr. `limit` bounds a runaway
// task with SIGKILL; outStatus receives its termination status (-1 when launch failed).
static NSString *RunLimitWithEnvironment(NSString *path,NSArray *args,NSTimeInterval limit,int *outStatus,NSDictionary *environment) {
    NSTask *task=[NSTask new]; task.launchPath=path; task.arguments=args;
    if(environment) task.environment=environment;
    NSPipe *pipe=[NSPipe pipe]; task.standardOutput=pipe; task.standardError=pipe;
    @try { [task launch];
        dispatch_source_t timeout=dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,dispatch_get_global_queue(QOS_CLASS_UTILITY,0));
        dispatch_source_set_timer(timeout,dispatch_time(DISPATCH_TIME_NOW,(int64_t)(limit*NSEC_PER_SEC)),DISPATCH_TIME_FOREVER,0);
        dispatch_source_set_event_handler(timeout,^{ if(task.running) kill(task.processIdentifier,SIGKILL); }); dispatch_resume(timeout);
        NSData *data=[pipe.fileHandleForReading readDataToEndOfFile]; [task waitUntilExit]; dispatch_source_cancel(timeout);
        if(outStatus) *outStatus=task.terminationStatus;
        return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
    } @catch(NSException *e) { if(outStatus) *outStatus=-1; return @"unknown"; }
}
static NSString *RunLimit(NSString *path,NSArray *args,NSTimeInterval limit,int *outStatus) { return RunLimitWithEnvironment(path,args,limit,outStatus,nil); }
static NSString *Run(NSString *path, NSArray *args) { return RunLimit(path,args,10,NULL); }
typedef NS_ENUM(NSInteger, SleepState) { SleepUnknown=-1, SleepOff=0, SleepOn=1 };
static SleepState DecodeSleepState(CFTypeRef value) {
    if(!value || CFGetTypeID(value)!=CFBooleanGetTypeID()) return SleepUnknown;
    return CFBooleanGetValue(value)?SleepOn:SleepOff;
}
static SleepState Enabled(void) {
    io_registry_entry_t entry=IORegistryEntryFromPath(kIOMainPortDefault,"IOPower:/IOPowerConnection/IOPMrootDomain");
    if(!entry) entry=IOServiceGetMatchingService(kIOMainPortDefault,IOServiceMatching("IOPMrootDomain"));
    if(!entry) return SleepUnknown;
    CFTypeRef value=IORegistryEntryCreateCFProperty(entry,CFSTR("SleepDisabled"),kCFAllocatorDefault,0);
    SleepState enabled=DecodeSleepState(value);
    if(value) CFRelease(value); IOObjectRelease(entry); return enabled;
}
// Lid state straight from the same registry entry; an unreadable value counts as open,
// so a brake never forces sleep on a user who may be sitting in front of the machine.
static BOOL LidClosed(void) {
    io_registry_entry_t entry=IOServiceGetMatchingService(kIOMainPortDefault,IOServiceMatching("IOPMrootDomain"));
    if(!entry) return NO;
    CFTypeRef value=IORegistryEntryCreateCFProperty(entry,CFSTR("AppleClamshellState"),kCFAllocatorDefault,0);
    BOOL closed=value && CFGetTypeID(value)==CFBooleanGetTypeID() && CFBooleanGetValue(value);
    if(value) CFRelease(value); IOObjectRelease(entry); return closed;
}
// In-app localization: table maps key -> @[zh, en]; LogTests enforces both entries are non-empty.
static NSDictionary<NSString *,NSArray<NSString *> *> *StringsTable(void) {
    static NSDictionary *t; static dispatch_once_t once;
    dispatch_once(&once,^{
        t=@{
            @"menu.enable":@[@"开启合盖运行",@"Enable Lid-Closed Running"],
            @"menu.disable":@[@"关闭合盖运行",@"Disable Lid-Closed Running"],
            @"menu.thermal":@[@"热状态：%@",@"Thermal: %@"],
            @"menu.thermal.protected":@[@"热状态：%@ · 每 5 秒检查",@"Thermal: %@ · 5 s checks"],
            @"menu.thermal.idle":@[@"采样已停止",@"Sampling stopped"],
            @"menu.detail.idle":@[@"开启后保护 · 无时限",@"On enable: protected · unlimited"],
            @"menu.detail.idle.timed":@[@"开启后保护 · 限时 %@",@"On enable: protected · %@"],
            @"menu.detail.session.timed":@[@"保护中 · 剩余 %@",@"Protected · %@ left"],
            @"menu.detail.session.open":@[@"保护中 · 无时限",@"Protected · no time limit"],
            @"menu.detail.external":@[@"外部开启 · 未受保护",@"Enabled externally · unprotected"],
            @"menu.detail.external.recovery":@[@"关闭后重新开启以启用保护",@"Turn off, then on here for protection"],
            @"menu.detail.guard.missing":@[@"保护已中断",@"Protection interrupted"],
            @"menu.detail.guard.restoring":@[@"正在恢复睡眠…",@"Restoring sleep…"],
            @"menu.login":@[@"登录时启动",@"Launch at Login"],
            @"menu.login.approval":@[@"登录时启动：等待系统批准…",@"Launch at Login: Approval Required…"],
            @"menu.detail.unknown":@[@"无法确认系统睡眠状态",@"Sleep state unavailable"],
            @"menu.detail.unknown.recovery":@[@"请尝试恢复睡眠",@"Try restoring sleep"],
            @"state.unknown":@[@"无法确认系统睡眠状态，请尝试恢复睡眠",@"Sleep state unavailable; try restoring sleep"],
            @"menu.settings":@[@"设置",@"Settings"],
            @"menu.duration":@[@"自动结束",@"Auto-Stop"],
            @"dur.none":@[@"无限",@"Unlimited"],
            @"dur.3600":@[@"1 小时",@"1 h"],
            @"dur.7200":@[@"2 小时",@"2 h"],
            @"dur.14400":@[@"4 小时",@"4 h"],
            @"menu.custom":@[@"自定义…",@"Custom…"],
            @"menu.custom.value":@[@"自定义（%@）…",@"Custom (%@)…"],
            @"custom.duration.title":@[@"自定义自动结束时间",@"Custom Auto-Stop Time"],
            @"custom.floor.title":@[@"自定义电池下限",@"Custom Battery Floor"],
            @"custom.range":@[@"请输入 %ld–%ld 之间的整数（单位：%@）",@"Enter a whole number from %ld to %ld (%@)"],
            @"custom.unit.min":@[@"分钟",@"minutes"],
            @"custom.ok":@[@"确定",@"OK"],
            @"custom.cancel":@[@"取消",@"Cancel"],
            @"menu.floor":@[@"电池下限",@"Battery Floor"],
            @"menu.frequency":@[@"日志频率",@"Log Frequency"],
            @"freq.5":@[@"5 秒",@"5 s"],
            @"freq.60":@[@"1 分钟",@"1 min"],
            @"freq.900":@[@"15 分钟",@"15 min"],
            @"menu.language":@[@"语言",@"Language"],
            @"lang.system":@[@"跟随系统",@"System"],
            @"lang.zh":@[@"简体中文",@"简体中文"],
            @"lang.en":@[@"English",@"English"],
            @"menu.logs":@[@"查看运行日志",@"View Logs"],
            @"menu.uninstall":@[@"卸载 KeepClam…",@"Uninstall KeepClam…"],
            @"uninstall.title":@[@"卸载 KeepClam？",@"Uninstall KeepClam?"],
            @"uninstall.body":@[@"将停止合盖运行并恢复允许睡眠，关闭登录时启动，移除免密授权，并永久删除当前应用、日志与设置。可能需要管理员密码。\n\n其他电源配置不会重置；系统管理的历史记录不在清理范围内。",@"This stops lid-closed running, restores normal sleep, disables launch at login, removes passwordless sudo, and permanently deletes this app, its logs and settings. An admin password may be required.\n\nOther power settings are preserved. System-managed history is outside the cleanup scope."],
            @"uninstall.confirm":@[@"卸载",@"Uninstall"],
            @"uninstall.progress":@[@"正在卸载…",@"Uninstalling…"],
            @"uninstall.incomplete":@[@"清理尚未完成",@"Cleanup incomplete"],
            @"uninstall.retry":@[@"请重试卸载或退出",@"Retry uninstall or quit"],
            @"uninstall.remaining":@[@"应用已删除，但以下文件未能清理，请按路径手动处理：\n\n%@",@"The app was removed, but these files could not be cleaned up. Remove the listed paths manually:\n\n%@"],
            @"uninstall.broken":@[@"应用已被部分或全部删除，以下清理未完成。请按所列路径处理残留，或重新安装后重试。KeepClam 将退出：\n\n%@",@"The app was partially or fully removed, but cleanup did not finish. Remove the listed remnants manually, or reinstall and retry. KeepClam will quit:\n\n%@"],
            @"uninstall.signature.failed":@[@"无法确认当前运行代码的签名身份，已拒绝管理员删除。",@"The running code's signing identity could not be verified. Privileged deletion was refused."],
            @"uninstall.failed.title":@[@"未能完成卸载",@"Uninstall Could Not Finish"],
            @"uninstall.failed.body":@[@"合盖运行已停止。以下步骤未完成，应用将保留；已完成的清理不会撤销：\n\n%@",@"Lid-closed running has stopped. The following step did not finish; the app will be kept. Completed cleanup will not be undone:\n\n%@"],
            @"uninstall.restore.failed":@[@"未能确认保护进程停止及睡眠恢复，已取消卸载，尚未删除文件。\n\n%@",@"The guard could not be confirmed stopped and normal sleep restored. Uninstall was cancelled; no files have been deleted.\n\n%@"],
            @"uninstall.login.failed":@[@"无法关闭登录时启动：%@",@"Could not disable launch at login: %@"],
            @"uninstall.sudoers.changed":@[@"免密授权文件的内容或类型已改变，已保留它。请检查 /etc/sudoers.d/keepclam 后重试。",@"The passwordless sudo file has changed or is not a regular file. It was preserved. Check /etc/sudoers.d/keepclam before retrying."],
            @"uninstall.admin.failed":@[@"管理员授权被取消或未能完成：%@",@"Admin authorization was cancelled or failed: %@"],
            @"uninstall.translocated":@[@"KeepClam 正在从系统的临时隔离位置运行，无法定位实际的应用文件，未做任何更改。请先在访达中把 KeepClam.app 移到「应用程序」文件夹，重新打开后再卸载。",@"KeepClam is running from a temporary translocated location, so the actual app file could not be located. Nothing was changed. Move KeepClam.app to the Applications folder in Finder, reopen it, then uninstall."],
            @"uninstall.brew.failed":@[@"Homebrew 卸载未完成，请运行 brew uninstall --cask keepclam 重试：%@",@"Homebrew uninstall did not finish. Retry with brew uninstall --cask keepclam: %@"],
            @"auth.off":@[@"安装免密授权…",@"Install Passwordless Sudo…"],
            @"auth.on":@[@"免密授权：已安装",@"Passwordless sudo: installed"],
            @"menu.help":@[@"使用说明",@"Help"],
            @"menu.quit":@[@"退出并恢复睡眠",@"Quit and Restore Sleep"],
            @"thermal.0":@[@"正常",@"Nominal"],
            @"thermal.1":@[@"略高",@"Fair"],
            @"thermal.2":@[@"过高",@"Serious"],
            @"thermal.3":@[@"严重过热",@"Critical"],
            @"thermal.unknown":@[@"无法读取",@"Unavailable"],
            @"unit.min":@[@"%ld 分钟",@"%ld min"],
            @"unit.hour.min":@[@"%ld 小时 %ld 分",@"%ld h %ld min"],
            @"alert.title":@[@"操作未完成",@"Action Not Completed"],
            @"auth.guide.title":@[@"建议安装免密授权",@"Install the Passwordless Whitelist?"],
            @"auth.guide.body":@[@"本次已通过管理员授权开启。安装 KeepClam 的受限 sudoers 白名单后，后续开关和无人值守的过热保护即可免密恢复睡眠；白名单只放行两条固定 pmset 命令。",@"This session was enabled with an admin prompt. Installing KeepClam's scoped sudoers whitelist lets later toggles and unattended thermal restores run without a password; the whitelist allows exactly two fixed pmset commands."],
            @"auth.guide.install":@[@"安装免密授权",@"Install Whitelist"],
            @"auth.guide.later":@[@"暂不安装",@"Not Now"],
            @"auth.installed.title":@[@"免密授权已安装",@"Passwordless Whitelist Installed"],
            @"auth.installed.view.body":@[@"白名单 %@ 仅授权以下两条命令免密执行：\n\n%@\n\n查看实际内容：sudo cat %@\n移除授权：运行 scripts/uninstall-sudoers.sh",@"The whitelist %@ authorizes exactly these two commands without a password:\n\n%@\n\nInspect it: sudo cat %@\nRemove it: run scripts/uninstall-sudoers.sh"],
            @"auth.installed.body":@[@"以后开关合盖运行不再需要输入管理员密码。可用 scripts/uninstall-sudoers.sh 移除。",@"Toggling no longer needs an admin password. Remove anytime with scripts/uninstall-sudoers.sh."],
            @"toggle.fail.pmset.body":@[@"无法设置系统睡眠策略。可在菜单中选择「安装免密授权…」一次性授权，或重试输入管理员密码。",@"Could not set the system sleep policy. Install the passwordless whitelist from the menu, or retry with the admin password."],
            @"toggle.fail.guard.title":@[@"保护进程启动失败",@"Failed to Start the Guard"],
            @"toggle.fail.guard.body":@[@"已恢复系统睡眠设置，请重试。",@"Sleep settings were restored; please try again."],
            @"toggle.lowpower":@[@"当前处于低电量模式（电池供电），不适合开启合盖运行",@"Low Power Mode is on (on battery) — not a good time to start lid-closed running"],
            @"toggle.hot":@[@"当前热状态不适合开启合盖运行",@"The current thermal state is too hot to start lid-closed running"],
            @"toggle.guardstuck.title":@[@"旧保护进程未能退出",@"The Existing Guard Did Not Exit"],
            @"toggle.guardstuck.body":@[@"系统睡眠设置未改变。请稍后重试。",@"Sleep settings are unchanged. Please try again later."],
            @"toggle.restorefail.title":@[@"未能恢复系统睡眠",@"Could Not Restore Sleep"],
            @"toggle.restorefail.body":@[@"请手动执行：sudo pmset -a disablesleep 0",@"Please run manually: sudo pmset -a disablesleep 0"],
            @"quit.restorefail.title":@[@"退出前未能恢复系统睡眠，已取消退出",@"Could Not Restore Sleep Before Quit — Quit Cancelled"],
            @"quit.restorefail.body":@[@"请先处理系统睡眠状态，或手动执行：sudo pmset -a disablesleep 0",@"Resolve the sleep state first, or run manually: sudo pmset -a disablesleep 0"],
            @"help.body":@[@"合上屏幕，继续运行。\n\n通过菜单栏开启或结束，也可设置自动结束。\n使用时请保持通风。更多说明与反馈请访问 GitHub。",@"Keep calm. Keep the lid closed. Keep running.\n\nStart or stop from the menu bar, or set an automatic stop.\nKeep your Mac ventilated. Visit GitHub for guides and feedback."],
            @"help.github":@[@"访问 GitHub",@"View on GitHub"],
            @"help.close":@[@"关闭",@"Close"],
            @"notify.guard_missing":@[@"KeepClam 保护进程已丢失，正在自动恢复合盖睡眠。",@"KeepClam lost its guard; restoring normal sleep automatically."],
            @"notify.guard_missing_fail":@[@"合盖睡眠自动恢复失败，请手动执行：sudo pmset -a disablesleep 0",@"Automatic restore failed. Please run: sudo pmset -a disablesleep 0"],
            @"notify.autostop.fail":@[@"自动结束未能恢复系统睡眠，请手动执行：sudo pmset -a disablesleep 0",@"Auto-stop could not restore sleep. Please run: sudo pmset -a disablesleep 0"],
            @"brake.timer":@[@"定时时间已到，",@"Timer elapsed; "],
            @"brake.battery_floor":@[@"电量已降至 %ld%% 下限，",@"Battery hit the %ld%% floor; "],
            @"brake.battery_unknown":@[@"连续无法读取电量，",@"Battery level unreadable; "],
            @"brake.low_power_mode":@[@"系统进入低电量模式，",@"Low Power Mode activated; "],
            @"brake.thermal_unknown":@[@"连续无法读取系统热状态，",@"Thermal state unreadable; "],
            @"brake.parent_exit":@[@"KeepClam 已退出，",@"KeepClam exited; "],
            @"brake.sleep":@[@"已恢复睡眠并请求立即休眠。",@"normal sleep restored and sleep requested now."],
            @"brake.awake":@[@"已恢复睡眠设置。",@"normal sleep restored."],
            @"toggle.lowbattery":@[@"电量已不高于电池下限，不适合开启合盖运行",@"Battery is at or below the floor — not a good time to start lid-closed running"],
            @"notify.thermal":@[@"过热保护已触发，已尝试恢复睡眠并请求休眠，请查看日志确认结果",@"Overheat protection attempted to restore sleep and requested sleep now; check logs for the result"],
            @"notify.thermal.restorefail":@[@"过热保护已触发，但合盖睡眠未能确认恢复。请手动执行：sudo pmset -a disablesleep 0",@"Overheat protection triggered, but normal lid sleep could not be confirmed restored. Please run: sudo pmset -a disablesleep 0"],
            @"notify.thermal.sleepfail":@[@"过热保护已触发，但系统未能休眠，机器仍在运行。请查看运行日志确认原因。",@"Overheat protection triggered, but the system did not sleep and the machine is still running. Check the logs."],
            @"legacy.running.title":@[@"检测到旧版 LidAwake 正在运行",@"Legacy LidAwake Is Still Running"],
            @"legacy.running.body":@[@"请先退出旧版 LidAwake 再使用 KeepClam；两个应用同时运行会争用系统睡眠设置。本次启动未修改系统睡眠设置。",@"Quit the legacy LidAwake app before using KeepClam; running both would fight over the same system sleep settings. This launch changed no sleep settings."],
        };
    });
    return t;
}
// Language preference: 0 system, 1 zh, 2 en.
static int LangIndex(void) {
    NSInteger pref=[NSUserDefaults.standardUserDefaults integerForKey:@"language"];
    if(pref==1) return 1;
    if(pref==2) return 2;
    NSString *first=NSLocale.preferredLanguages.firstObject ?: @"";
    return [first hasPrefix:@"zh"] ? 1 : 2;
}
static NSString *Pair(NSString *key,int lang) {
    NSArray *p=StringsTable()[key];
    if(!p || p.count<2) return key;
    NSString *s=lang==2?p[1]:p[0];
    return s.length?s:(lang==2?p[0]:p[1]);
}
static NSString *L(NSString *key) { return Pair(key,LangIndex()); }
// Pure remaining-time formatting shared by the app loop and tests. lang: 1 zh, 2 en.
static NSString *FormatInterval(NSTimeInterval left,int lang) {
    NSInteger mins=MAX(0,(NSInteger)round(left/60.0));
    if(mins<60) return [NSString stringWithFormat:Pair(@"unit.min",lang),(long)MAX(1,mins)];
    return [NSString stringWithFormat:Pair(@"unit.hour.min",lang),(long)(mins/60),(long)(mins%60)];
}
// Stable English tokens for log records; UI labels come from Thermal().
static NSString *ThermalToken(void) {
    NSInteger n=NSProcessInfo.processInfo.thermalState;
    return n>=0 && n<4 ? @[@"nominal",@"fair",@"serious",@"critical"][n] : @"unknown";
}
static NSString *Thermal(void) {
    NSInteger n=NSProcessInfo.processInfo.thermalState;
    return n>=0 && n<4 ? L([NSString stringWithFormat:@"thermal.%ld",(long)n]) : L(@"thermal.unknown");
}
static NSString *Quote(NSString *s) { return [NSString stringWithFormat:@"'%@'",[s stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"]]; }

// Battery level in percent (first battery power source); -1 when unavailable. onAC reports charger presence.
static NSInteger BatteryPercent(BOOL *onAC) {
    if(onAC) *onAC=NO;
    CFTypeRef info=IOPSCopyPowerSourcesInfo(); if(!info) return -1;
    CFArrayRef list=IOPSCopyPowerSourcesList(info); if(!list) { CFRelease(info); return -1; }
    NSInteger pct=-1; BOOL ac=NO;
    for(CFIndex i=0;i<CFArrayGetCount(list);i++) {
        CFTypeRef ps=CFArrayGetValueAtIndex(list,i);
        CFDictionaryRef desc=IOPSGetPowerSourceDescription(info,ps); if(!desc) continue;
        CFTypeRef state=CFDictionaryGetValue(desc,CFSTR(kIOPSPowerSourceStateKey));
        if(state && CFGetTypeID(state)==CFStringGetTypeID() && CFEqual(state,CFSTR(kIOPSACPowerValue))) ac=YES;
        else if(state && CFGetTypeID(state)==CFStringGetTypeID() && CFEqual(state,CFSTR(kIOPSBatteryPowerValue))) {
            CFTypeRef cur=CFDictionaryGetValue(desc,CFSTR(kIOPSCurrentCapacityKey));
            CFTypeRef max=CFDictionaryGetValue(desc,CFSTR(kIOPSMaxCapacityKey));
            if(cur && max && CFGetTypeID(cur)==CFNumberGetTypeID() && CFGetTypeID(max)==CFNumberGetTypeID()) {
                NSInteger c=0,m=0; CFNumberGetValue(cur,kCFNumberNSIntegerType,&c); CFNumberGetValue(max,kCFNumberNSIntegerType,&m); if(m>0) pct=c*100/m;
            }
        }
    }
    CFRelease(list); CFRelease(info);
    if(onAC) *onAC=ac;
    return pct;
}

static NSInteger BatteryFloorSetting(void) {
    NSInteger f=[NSUserDefaults.standardUserDefaults integerForKey:@"battery_floor"]; return f>0?f:20;
}
// Pure parser for custom settings: a whole number in [min,max] (surrounding spaces
// allowed), else -1.
static NSInteger ParseBoundedInteger(NSString *text,NSInteger min,NSInteger max) {
    NSScanner *scanner=[NSScanner scannerWithString:[text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet]];
    NSInteger value=0;
    if(![scanner scanInteger:&value] || !scanner.isAtEnd || value<min || value>max) return -1;
    return value;
}
// Pure brake decision shared by the guard loop, the enable pre-check and tests. Returns a
// stable reason token or nil. Unknown counts are consecutive failed reads; the battery
// ones only matter on battery power.
static NSString *BrakeReason(NSInteger thermal,unsigned thermalUnknown,NSInteger batteryPct,unsigned batteryUnknown,BOOL onAC,BOOL lowPower,NSInteger floorPct,NSDate *deadline,NSDate *now) {
    if(thermal>=2) return @"thermal";
    if(thermalUnknown>=3) return @"thermal_unknown";
    if(deadline && [now timeIntervalSinceDate:deadline]>=0) return @"timer";
    if(!onAC) {
        if(lowPower) return @"low_power_mode";
        if(batteryPct>=0 && batteryPct<=floorPct) return @"battery_floor";
        if(batteryUnknown>=3) return @"battery_unknown";
    }
    return nil;
}
// The guard reports a planned brake through its exit code (10 + index), so the app can
// tell it apart from a lost guard. Startup failures use 1-5 and never collide.
static NSArray<NSString *> *BrakeReasons(void) {
    return @[@"thermal",@"thermal_unknown",@"battery_floor",@"battery_unknown",@"low_power_mode",@"timer",@"parent_exit"];
}
static int BrakeExitCode(NSString *reason) {
    NSUInteger i=[BrakeReasons() indexOfObject:reason]; return i==NSNotFound?1:10+(int)i;
}
static NSString *BrakeReasonForExit(int status) {
    if(!WIFEXITED(status)) return nil;
    int code=WEXITSTATUS(status);
    return code>=10 && code<10+(int)BrakeReasons().count ? BrakeReasons()[code-10] : nil;
}

// Alert title keys for a failed toggle, routed by consequence. Disabling: 2 = the old
// guard never exited, so the system sleep settings were never touched; 3 = it exited but
// the restore is unconfirmed. Enabling: a failed guard start gets its own title; when the
// fallback restore also failed, that failure is the more urgent fact.
static NSString *ToggleAlertTitle(BOOL enable,int stopResult,NSString *body) {
    if(!enable) return stopResult==2?@"toggle.guardstuck.title":@"toggle.restorefail.title";
    if([body isEqualToString:@"toggle.fail.guard.body"]) return @"toggle.fail.guard.title";
    if([body isEqualToString:@"toggle.restorefail.body"]) return @"toggle.restorefail.title";
    return @"alert.title";
}

// Privileged pmset flip: passwordless via the sudoers whitelist first, admin prompt as fallback.
static BOOL SetSleepDisabledNoPrompt(BOOL on) {
    Run(@"/usr/bin/sudo",@[@"-n",@"/usr/bin/pmset",@"-a",@"disablesleep",on?@"1":@"0"]);
    return Enabled()==(on?SleepOn:SleepOff);
}
static BOOL SetSleepDisabled(BOOL on) {
    if(SetSleepDisabledNoPrompt(on)) return YES;
    NSString *script=[NSString stringWithFormat:@"do shell script \"/usr/bin/pmset -a disablesleep %@\" with administrator privileges",on?@"1":@"0"];
    void (^prompt)(void)=^{
        NSAppleScript *fallback=[[NSAppleScript alloc] initWithSource:script];
        NSDictionary *error=nil; [fallback executeAndReturnError:&error];
    };
    if(NSThread.isMainThread) prompt(); else dispatch_sync(dispatch_get_main_queue(),prompt);
    return Enabled()==(on?SleepOn:SleepOff);
}

static NSString *LogDir(void){ return [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Logs/KeepClam"]; }
static NSString *LogFilePath(void){ return [LogDir() stringByAppendingPathComponent:@"运行日志.log"]; }
// One-time migration of the legacy LidAwake log directory into the new location. Runs
// before the new directory is ever created; an existing new directory always wins.
// Returns whether a move happened.
static BOOL MigrateLegacyLogs(NSString *home) {
    NSString *old=[home stringByAppendingPathComponent:@"Library/Logs/LidAwake"];
    NSString *new=[home stringByAppendingPathComponent:@"Library/Logs/KeepClam"];
    if(![NSFileManager.defaultManager fileExistsAtPath:old] || [NSFileManager.defaultManager fileExistsAtPath:new]) return NO;
    return [NSFileManager.defaultManager moveItemAtPath:old toPath:new error:nil];
}
// Single source of truth for the whitelist location; presence checks, install and
// uninstall must all agree. Fixed literal with no shell metacharacters, so it can be
// interpolated into the install command as-is.
static NSString *SudoersPath(void){ return @"/etc/sudoers.d/keepclam"; }
static const NSInteger UninstallAuthorizationChangedStatus=3; // privileged removal's "rule changed" exit
static NSString *LockPath(void){ return [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/KeepClam/guard.lock"]; }

static void GuardLog(NSString *event) {
    Append(LogFilePath(),[NSString stringWithFormat:@"%@ | %@ | thermal=%@\n",NSDate.date,event,ThermalToken()]);
}
// The guard has no bundle, so notifications go through osascript. Its cold start can be
// slow and the restore actions must not wait on it: bound it hard, then move on.
static void GuardNotifyText(NSString *body) {
    RunLimit(@"/usr/bin/osascript",@[@"-e",[NSString stringWithFormat:@"display notification \"%@\" with title \"KeepClam\" sound name \"Glass\"",body]],2,NULL);
}
static void GuardNotify(void) { GuardNotifyText(L(@"notify.thermal")); }

// Single brake for every stop condition: evidence first, then notification, restore, and
// sleep when the lid is closed (or on overheat). Clearing SleepDisabled alone does not
// re-trigger lid sleep — the system only falls back to idle sleep, which a running task's
// assertion blocks — so sleep must be requested explicitly. Returns the exit code.
static int Brake(NSString *reason,int lock) {
    // Evidence first: the alarm is fsynced before anything can interrupt this path,
    // including the sleep this trigger is about to request.
    GuardLog([NSString stringWithFormat:@"PROTECTION_TRIGGER reason=%@",reason]);
    BOOL sleepNow=[reason isEqualToString:@"thermal"] || LidClosed();
    // The notification must reach the center before sleep can take effect.
    if([reason isEqualToString:@"thermal"]) GuardNotify();
    else {
        NSString *head=[reason isEqualToString:@"battery_floor"]?[NSString stringWithFormat:L(@"brake.battery_floor"),(long)BatteryFloorSetting()]:L([@"brake." stringByAppendingString:reason]);
        GuardNotifyText([head stringByAppendingString:L(sleepNow?@"brake.sleep":@"brake.awake")]);
    }
    BOOL restored=SetSleepDisabledNoPrompt(NO);
    if(!restored) {
        GuardLog(@"PROTECTION_RESTORE_FAILED: could not restore lid sleep");
        GuardNotifyText(L(@"notify.thermal.restorefail"));
    }
    if(sleepNow) {
        int sleepStatus=-1;
        RunLimit(@"/usr/bin/pmset",@[@"sleepnow"],10,&sleepStatus);
        if(sleepStatus==0) GuardLog(@"PROTECTION_SLEEPNOW: sleep now requested");
        else {
            GuardLog([NSString stringWithFormat:@"PROTECTION_SLEEPNOW_FAILED: pmset sleepnow exited with status %d",sleepStatus]);
            GuardNotifyText(L(@"notify.thermal.sleepfail"));
        }
    } else GuardLog(@"PROTECTION_RESTORED: lid open, no sleep requested");
    close(lock);
    return BrakeExitCode(reason);
}

// User-space protection process. Restores sleep via the whitelist (sudo -n) or the admin prompt.
static volatile sig_atomic_t stopping=0;
static void Stop(int sig) { stopping=1; }
static int Guard(pid_t parent,int ready) {
    if(parent<=1) return 1;
    if(!PrivateDirectory([LockPath() stringByDeletingLastPathComponent])) return -1;
    int lock=open(LockPath().fileSystemRepresentation,O_CREAT|O_RDWR|O_NOFOLLOW|O_CLOEXEC,0600);
    if(lock<0 || flock(lock,LOCK_EX|LOCK_NB)!=0) { if(ready>=0) close(ready); return 2; }
    struct proc_bsdinfo identity={0};
    if(proc_pidinfo(getpid(),PROC_PIDTBSDINFO,0,&identity,sizeof(identity))!=sizeof(identity)) { close(lock); return 5; }
    ftruncate(lock,0); dprintf(lock,"%d %llu %llu",getpid(),identity.pbi_start_tvsec,identity.pbi_start_tvusec);
    // Never trust the inherited mask: a blocked SIGTERM here makes the guard impossible to stop.
    sigset_t unblock; sigemptyset(&unblock);
    sigaddset(&unblock,SIGTERM); sigaddset(&unblock,SIGHUP); sigaddset(&unblock,SIGINT);
    sigprocmask(SIG_UNBLOCK,&unblock,NULL);
    signal(SIGTERM,Stop); signal(SIGHUP,Stop); signal(SIGINT,Stop);
    NSInteger initial=NSProcessInfo.processInfo.thermalState;
    if(initial<0 || initial>=2) { close(lock); close(ready); return 3; }
    if(Enabled()!=SleepOn) { close(lock); close(ready); return 4; }
    if(ready>=0) { write(ready,"1",1); close(ready); }
    unsigned thermalUnknown=0,batteryUnknown=0;
    while(!stopping && Enabled()==SleepOn) @autoreleasepool { // drained per cycle: sessions run for hours
        if(getppid()!=parent) return Brake(@"parent_exit",lock);
        NSInteger thermal=NSProcessInfo.processInfo.thermalState;
        thermalUnknown=thermal<0 ? thermalUnknown+1 : 0;
        BOOL onAC=NO; NSInteger battery=BatteryPercent(&onAC);
        batteryUnknown=(!onAC && battery<0) ? batteryUnknown+1 : 0;
        // Settings are shared through the app's preferences, so changes apply mid-session.
        CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication);
        NSTimeInterval deadline=[NSUserDefaults.standardUserDefaults doubleForKey:@"session_deadline"];
        NSString *reason=BrakeReason(thermal,thermalUnknown,battery,batteryUnknown,onAC,NSProcessInfo.processInfo.isLowPowerModeEnabled,
                                     BatteryFloorSetting(),deadline>0?[NSDate dateWithTimeIntervalSince1970:deadline]:nil,NSDate.date);
        if(reason) return Brake(reason,lock);
        sleep(5);
    }
    BOOL restored=SetSleepDisabledNoPrompt(NO);
    GuardLog(restored?@"GUARD_STOP: sleep restored":@"GUARD_RESTORE_FAILED: could not confirm sleep restored");
    close(lock);
    return 0;
}

// Detached child with a pipe handshake; same-user, no privileges needed.
static pid_t StartGuard(pid_t parent) {
    if(!PrivateDirectory([LockPath() stringByDeletingLastPathComponent])) return -1;
    int fds[2]; if(pipe(fds)!=0) return -1;
    const char *exe=strdup(NSBundle.mainBundle.executablePath.fileSystemRepresentation);
    char parentArg[32],pipeArg[32];
    snprintf(parentArg,sizeof(parentArg),"%d",parent); snprintf(pipeArg,sizeof(pipeArg),"%d",fds[1]);
    pid_t child=fork();
    if(child==0) {
        close(fds[0]); setsid();
        // fork inherits the caller's signal mask (GCD worker threads run with signals blocked)
        // and exec preserves it; without this the guard can never be signalled to stop.
        sigset_t empty; sigemptyset(&empty); sigprocmask(SIG_SETMASK,&empty,NULL);
        int null=open("/dev/null",O_RDWR); dup2(null,0); dup2(null,1); dup2(null,2); close(null);
        // Exec a fresh Foundation runtime after fork.
        execl(exe,"KeepClam","--guard",parentArg,pipeArg,(char *)NULL);
        _exit(1);
    }
    free((void *)exe); close(fds[1]); struct pollfd p={fds[0],POLLIN,0}; char ok=0;
    if(child>0 && poll(&p,1,15000)>0) read(fds[0],&ok,1);
    close(fds[0]);
    if(ok!='1') { if(child>0) kill(child,SIGTERM); return -1; }
    return child;
}

// Terminates the guard (waiting for its lock) and restores sleep. 0=ok 2=guard stuck 3=still enabled.
static BOOL GuardIdentityMatches(pid_t pid,unsigned long long seconds,unsigned long long micros) {
    if(pid<=1) return NO;
    struct proc_bsdinfo info={0}; char path[PROC_PIDPATHINFO_MAXSIZE]={0};
    if(proc_pidinfo(pid,PROC_PIDTBSDINFO,0,&info,sizeof(info))!=sizeof(info)) return NO;
    if(info.pbi_uid!=getuid() || info.pbi_start_tvsec!=seconds || info.pbi_start_tvusec!=micros) return NO;
    if(proc_pidpath(pid,path,sizeof(path))<=0) return NO;
    return [[NSString stringWithUTF8String:path] isEqualToString:NSBundle.mainBundle.executablePath];
}
static int StopGuardWithPrompt(BOOL allowPrompt) {
    int fd=open(LockPath().fileSystemRepresentation,O_RDWR|O_NOFOLLOW|O_CLOEXEC);
    if(fd>=0) {
        if(flock(fd,LOCK_EX|LOCK_NB)!=0) {
            char buf[128]={0}; pread(fd,buf,sizeof(buf)-1,0); int pid=0; unsigned long long seconds=0,micros=0;
            if(sscanf(buf,"%d %llu %llu",&pid,&seconds,&micros)!=3 || !GuardIdentityMatches(pid,seconds,micros)) { close(fd); return 2; }
            if(kill(pid,SIGTERM)!=0 && errno!=ESRCH) { close(fd); return 2; }
            BOOL acquired=NO;
            for(int i=0;i<150;i++) { if(flock(fd,LOCK_EX|LOCK_NB)==0) { acquired=YES; break; } usleep(100000); }
            if(!acquired) { close(fd); return 2; }
        }
        close(fd);
    }
    if(allowPrompt) SetSleepDisabled(NO); else SetSleepDisabledNoPrompt(NO);
    return Enabled()==SleepOff?0:3;
}
static int StopGuard(void) { return StopGuardWithPrompt(YES); }
static int StopGuardNoPrompt(void) { return StopGuardWithPrompt(NO); }

@interface App : NSObject <NSApplicationDelegate, NSMenuDelegate, NSMenuItemValidation>
@property NSStatusItem *item;
@property NSMenuItem *loginItem;

@property NSMenuItem *toggleItem;
@property NSMenuItem *thermalItem;
@property NSMenuItem *detailItem;
@property NSMenuItem *recoveryItem;
@property NSMenuItem *authItem;
@property NSTimer *timer;
@property NSString *logPath;
@property NSDate *lastLog;
@property BOOL busy;
@property BOOL owned;
@property BOOL active;
@property BOOL sampling;
@property BOOL uninstalling;
@property BOOL uninstallRecoveryOnly;
@property dispatch_queue_t worker;
@property int logFD; // resident log fd, touched only on self.worker; -1 until opened
@property NSString *sampleKey;
@property NSDate *rangeStart;
@property NSDate *rangeEnd;
@property NSUInteger count;
@property NSTimeInterval maxGap;
@property NSDate *networkTime;
@property NSString *networkResult;
@property pid_t guardPID;
@property unsigned long long guardStartSec;
@property unsigned long long guardStartUsec;
@property dispatch_source_t guardProcSource;
@property NSUInteger generation;
@property (nonatomic) NSDate *sessionDeadline;
@end

@implementation App
- (instancetype)init {
    if(self=[super init]) _logFD=-1;
    return self;
}
- (NSInteger)sessionDuration { return MAX(0,[NSUserDefaults.standardUserDefaults integerForKey:@"duration"]); }
- (NSInteger)batteryFloor { return BatteryFloorSetting(); }
// The guard enforces the deadline, so every assignment is mirrored into the shared
// preferences it reads each cycle (0 = no deadline).
- (void)setSessionDeadline:(NSDate *)deadline {
    _sessionDeadline=deadline;
    [NSUserDefaults.standardUserDefaults setDouble:deadline?deadline.timeIntervalSince1970:0 forKey:@"session_deadline"];
}
- (NSString *)ruleText {
    return [NSString stringWithFormat:@"%@ ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1",NSUserName()];
}
- (BOOL)sudoersFilePresent { return [NSFileManager.defaultManager fileExistsAtPath:SudoersPath()]; }
// Log writes never run on the main thread: they are appended by self.worker so a busy
// disk cannot stall the menu. Ordering is guaranteed by the queue, durability by fsync.
- (void)log:(NSString *)event {
    if(self.uninstalling || self.uninstallRecoveryOnly) return;
    NSString *line=[NSString stringWithFormat:@"%@ | %@\n",[NSDate date],event];
    dispatch_async(self.worker,^{ [self writeLine:line]; });
}
// Runs on self.worker only. Keeps the fd open across writes and rebuilds it after a
// rotation — ours (size over 1 MB) or the guard's (detected by the inode mismatch).
// Cross-process mutual exclusion stays with the flock; the mode stays 0600.
- (void)writeLine:(NSString *)line {
    if(self.uninstalling || self.uninstallRecoveryOnly || !self.logPath) return;
    NSString *path=self.logPath;
    int lock=open([[path stringByAppendingString:@".lock"] fileSystemRepresentation],O_CREAT|O_RDWR|O_NOFOLLOW|O_CLOEXEC,0600);
    if(lock<0) return;
    fchmod(lock,0600);
    flock(lock,LOCK_EX);
    struct stat pst;
    BOOL rotate=NO;
    if(self.logFD>=0) {
        struct stat fst;
        if(fstat(self.logFD,&fst)!=0 || !S_ISREG(fst.st_mode)
           || lstat(path.fileSystemRepresentation,&pst)!=0 || pst.st_ino!=fst.st_ino) {
            close(self.logFD); self.logFD=-1;
        } else if(fst.st_size>1024*1024) rotate=YES;
    }
    if(rotate) RotateLog(path);
    if(self.logFD<0) {
        self.logFD=open(path.fileSystemRepresentation,O_CREAT|O_WRONLY|O_APPEND|O_NOFOLLOW|O_CLOEXEC,0600);
        if(self.logFD>=0) fchmod(self.logFD,0600);
    }
    if(self.logFD>=0) {
        NSData *data=[line dataUsingEncoding:NSUTF8StringEncoding];
        const char *bytes=data.bytes; size_t left=data.length;
        while(left) { ssize_t n=write(self.logFD,bytes,left); if(n<0 && errno==EINTR) continue; if(n<=0) break; bytes+=n; left-=n; }
        fsync(self.logFD);
    }
    flock(lock,LOCK_UN); close(lock);
}
// Returns after every queued line is on disk. While a teardown owns the worker the wait
// is skipped: that path can sync to the main queue for the admin prompt, and waiting
// here could deadlock. Callers on the main thread only.
- (void)flush {
    if(self.count) {
        [self log:[NSString stringWithFormat:@"summary start=%@ end=%@ samples=%lu max_gap=%.1fs | %@",self.rangeStart,self.rangeEnd,(unsigned long)self.count,self.maxGap,self.sampleKey]];
        self.count=0; self.sampleKey=nil;
    }
    if(!self.busy) dispatch_sync(self.worker,^{});
}
- (void)sample:(NSString *)key at:(NSDate *)now {
    NSTimeInterval gap=self.rangeEnd?[now timeIntervalSinceDate:self.rangeEnd]:0;
    NSInteger interval=[NSUserDefaults.standardUserDefaults integerForKey:@"interval"];
    if(self.count && (![key isEqual:self.sampleKey] || gap>interval*2+5 || [now timeIntervalSinceDate:self.rangeStart]>=900)) [self flush];
    if(!self.count) { self.rangeStart=now; self.maxGap=0; self.sampleKey=key; }
    else self.maxGap=MAX(self.maxGap,gap);
    self.rangeEnd=now; self.count++;
    // Abnormal samples are durable immediately; normal samples are summarized.
    if([key containsString:@"failed"] || ![key containsString:@"thermal=nominal"]) [self flush];
}
// Ask for notification permission once, at first enable — not at the first notification.
- (void)requestNotifyAuth {
    if([NSUserDefaults.standardUserDefaults boolForKey:@"notification_prompted"]) return;
    [NSUserDefaults.standardUserDefaults setBool:YES forKey:@"notification_prompted"];
    @try {
        UNUserNotificationCenter *center=UNUserNotificationCenter.currentNotificationCenter;
        if(center) [center requestAuthorizationWithOptions:UNAuthorizationOptionAlert completionHandler:^(BOOL granted, NSError *error){
            (void)granted; (void)error;
        }];
    } @catch(NSException *e) {}
}
- (void)notify:(NSString *)body {
    if(self.uninstalling) return;
    @try {
        if(!NSClassFromString(@"UNUserNotificationCenter")) return;
        UNUserNotificationCenter *center=UNUserNotificationCenter.currentNotificationCenter;
        if(!center) return;
        UNMutableNotificationContent *content=[UNMutableNotificationContent new];
        content.title=@"KeepClam"; content.body=body;
        UNNotificationRequest *req=[UNNotificationRequest requestWithIdentifier:NSUUID.UUID.UUIDString content:content trigger:nil];
        [center addNotificationRequest:req withCompletionHandler:nil];
    } @catch(NSException *e) {}
}
- (NSMenuItem *)add:(NSString *)title action:(SEL)action menu:(NSMenu *)menu {
    NSMenuItem *i=[[NSMenuItem alloc] initWithTitle:title action:action keyEquivalent:@""]; i.target=self; [menu addItem:i]; return i;
}
- (NSString *)idleDetail {
    NSInteger duration=self.sessionDuration;
    return duration>0?[NSString stringWithFormat:L(@"menu.detail.idle.timed"),FormatInterval(duration,LangIndex())]:L(@"menu.detail.idle");
}
// Builds the whole menu; called again on language switch so titles take effect immediately.
- (void)buildMenu {
    NSMenu *menu=[NSMenu new]; menu.delegate=self;
    [self add:@"KeepClam" action:nil menu:menu];
    self.toggleItem=[self add:L(@"menu.enable") action:@selector(toggle:) menu:menu];
    self.thermalItem=[self add:L(@"menu.thermal.idle") action:nil menu:menu];
    self.detailItem=[self add:[self idleDetail] action:nil menu:menu];
    // Keep recovery instructions on their own row so warnings do not widen every item.
    self.recoveryItem=[self add:@"" action:nil menu:menu];
    self.recoveryItem.hidden=YES;
    [menu addItem:NSMenuItem.separatorItem];
    NSMenuItem *settings=[self add:L(@"menu.settings") action:nil menu:menu]; NSMenu *sm=[NSMenu new];
    self.loginItem=[self add:L(@"menu.login") action:@selector(loginChanged:) menu:sm];
    [self refreshLogin];
    NSMenuItem *duration=[self add:L(@"menu.duration") action:nil menu:sm]; NSMenu *dur=[NSMenu new];
    NSArray *durations=@[@0,@3600,@7200,@14400];
    for(NSNumber *n in durations) {
        NSMenuItem *i=[self add:L([NSString stringWithFormat:@"dur.%@",n.intValue==0?@"none":n.stringValue]) action:@selector(durationChanged:) menu:dur]; i.tag=n.integerValue;
        i.state=i.tag==self.sessionDuration?NSControlStateValueOn:NSControlStateValueOff;
    }
    // A non-preset value is shown on the custom item itself, so the checkmark never disappears.
    BOOL customDuration=![durations containsObject:@(self.sessionDuration)];
    NSMenuItem *durCustom=[self add:customDuration?[NSString stringWithFormat:L(@"menu.custom.value"),FormatInterval(self.sessionDuration,LangIndex())]:L(@"menu.custom") action:@selector(customDuration:) menu:dur];
    durCustom.state=customDuration?NSControlStateValueOn:NSControlStateValueOff;
    duration.submenu=dur;
    NSMenuItem *floorItem=[self add:L(@"menu.floor") action:nil menu:sm]; NSMenu *flr=[NSMenu new];
    NSArray *floors=@[@10,@20,@30];
    for(NSNumber *n in floors) {
        NSMenuItem *i=[self add:[NSString stringWithFormat:@"%ld%%",(long)n.integerValue] action:@selector(floorChanged:) menu:flr]; i.tag=n.integerValue;
        i.state=i.tag==self.batteryFloor?NSControlStateValueOn:NSControlStateValueOff;
    }
    BOOL customFloor=![floors containsObject:@(self.batteryFloor)];
    NSMenuItem *flrCustom=[self add:customFloor?[NSString stringWithFormat:L(@"menu.custom.value"),[NSString stringWithFormat:@"%ld%%",(long)self.batteryFloor]]:L(@"menu.custom") action:@selector(customFloor:) menu:flr];
    flrCustom.state=customFloor?NSControlStateValueOn:NSControlStateValueOff;
    floorItem.submenu=flr;
    NSMenuItem *frequency=[self add:L(@"menu.frequency") action:nil menu:sm]; NSMenu *sub=[NSMenu new];
    for(NSNumber *n in @[@5,@60,@900]) {
        NSString *key=n.intValue==5?@"freq.5":(n.intValue==60?@"freq.60":@"freq.900");
        NSMenuItem *i=[self add:L(key) action:@selector(interval:) menu:sub]; i.tag=n.integerValue;
        i.state=i.tag==[NSUserDefaults.standardUserDefaults integerForKey:@"interval"]?NSControlStateValueOn:NSControlStateValueOff;
    }
    frequency.submenu=sub;
    [sm addItem:NSMenuItem.separatorItem];
    NSMenuItem *language=[self add:L(@"menu.language") action:nil menu:sm]; NSMenu *lang=[NSMenu new];
    NSInteger pref=[NSUserDefaults.standardUserDefaults integerForKey:@"language"];
    for(NSNumber *n in @[@0,@1,@2]) {
        NSMenuItem *i=[self add:L(n.intValue==0?@"lang.system":(n.intValue==1?@"lang.zh":@"lang.en")) action:@selector(languageChanged:) menu:lang]; i.tag=n.integerValue;
        i.state=i.tag==pref?NSControlStateValueOn:NSControlStateValueOff;
    }
    language.submenu=lang;
    [sm addItem:NSMenuItem.separatorItem];
    [self add:L(@"menu.logs") action:@selector(logs:) menu:sm];
    [sm addItem:NSMenuItem.separatorItem];
    [self add:L(@"menu.uninstall") action:@selector(uninstall:) menu:sm];
    settings.submenu=sm;
    self.authItem=[self add:L(@"auth.off") action:@selector(authAction:) menu:menu];
    [menu addItem:NSMenuItem.separatorItem];
    [self add:L(@"menu.help") action:@selector(help:) menu:menu];
    [menu addItem:NSMenuItem.separatorItem];
    [self add:L(@"menu.quit") action:@selector(quit:) menu:menu];
    self.item.menu=menu;
}
- (void)applicationDidFinishLaunching:(NSNotification *)note {
    // Alerts fall back to a placeholder icon when the bundle isn't registered with Launch
    // Services, so the icon is set explicitly. Only reps up to 256 px are kept: alerts draw
    // it at 64 pt, and the 1024 px rep would stay decoded in memory (~8 MB) for the whole run.
    NSImage *full=[[NSImage alloc] initWithContentsOfFile:[NSBundle.mainBundle pathForResource:@"AppIcon" ofType:@"icns"]];
    NSImage *appIcon=[[NSImage alloc] initWithSize:NSMakeSize(128,128)];
    for(NSImageRep *rep in full.representations) if(rep.pixelsWide<=256) [appIcon addRepresentation:rep];
    if(appIcon.representations.count) NSApp.applicationIconImage=appIcon;
    // One-time migration of the legacy LidAwake log directory, strictly before this
    // launch creates anything in the new location. An existing new directory wins.
    MigrateLegacyLogs(NSHomeDirectory());
    NSString *dir=LogDir();
    PrivateDirectory(dir);
    self.logPath=LogFilePath();
    for(NSString *name in [NSFileManager.defaultManager contentsOfDirectoryAtPath:dir error:nil]) {
        int fd=open([[dir stringByAppendingPathComponent:name] fileSystemRepresentation],O_RDONLY|O_NOFOLLOW|O_CLOEXEC);
        if(fd>=0) { struct stat st; if(fstat(fd,&st)==0 && S_ISREG(st.st_mode)) fchmod(fd,0600); close(fd); }
    }
    Append(self.logPath,@"");
    if(![NSUserDefaults.standardUserDefaults integerForKey:@"interval"]) [NSUserDefaults.standardUserDefaults setInteger:5 forKey:@"interval"];
    if(![NSUserDefaults.standardUserDefaults integerForKey:@"battery_floor"]) [NSUserDefaults.standardUserDefaults setInteger:20 forKey:@"battery_floor"];
    self.item=[NSStatusBar.systemStatusBar statusItemWithLength:NSVariableStatusItemLength];
    self.item.button.title=@"◉ KeepClam";
    [self buildMenu];
    // A still-running legacy LidAwake would fight this app over the same sleep settings.
    if([Run(@"/usr/bin/pgrep",@[@"-x",@"LidAwake"]) length]) {
        NSAlert *a=[NSAlert new];
        a.messageText=L(@"legacy.running.title");
        a.informativeText=L(@"legacy.running.body");
        [a runModal];
    }
    self.worker=dispatch_queue_create("io.github.keepclam.sampling",DISPATCH_QUEUE_SERIAL);
    self.timer=[NSTimer scheduledTimerWithTimeInterval:5 target:self selector:@selector(tick:) userInfo:nil repeats:YES];
    [self tick:nil];
}
- (void)refreshLogin {
    SMAppServiceStatus status=SMAppService.mainAppService.status;
    self.loginItem.title=L(status==SMAppServiceStatusRequiresApproval?@"menu.login.approval":@"menu.login");
    self.loginItem.state=status==SMAppServiceStatusEnabled?NSControlStateValueOn:(status==SMAppServiceStatusRequiresApproval?NSControlStateValueMixed:NSControlStateValueOff);
}
- (void)menuWillOpen:(NSMenu *)menu { [self refreshLogin]; [self tick:nil]; }
- (void)loginChanged:(id)sender {
    SMAppService *service=SMAppService.mainAppService;
    if(service.status==SMAppServiceStatusRequiresApproval) { [SMAppService openSystemSettingsLoginItems]; return; }
    NSError *error=nil;
    if(service.status==SMAppServiceStatusEnabled) [service unregisterAndReturnError:&error];
    else [service registerAndReturnError:&error];
    if(error) { NSAlert *a=[NSAlert new]; a.messageText=L(@"alert.title"); a.informativeText=error.localizedDescription; [a runModal]; }
    [self refreshLogin];
}
- (void)interval:(NSMenuItem *)sender {
    [NSUserDefaults.standardUserDefaults setInteger:sender.tag forKey:@"interval"];
    for(NSMenuItem *i in sender.menu.itemArray) i.state=i==sender?NSControlStateValueOn:NSControlStateValueOff;
    [self flush];
    if(self.active) [self log:[NSString stringWithFormat:@"log_interval=%ld",(long)sender.tag]];
}
- (void)languageChanged:(NSMenuItem *)sender {
    [NSUserDefaults.standardUserDefaults setInteger:sender.tag forKey:@"language"];
    for(NSMenuItem *i in sender.menu.itemArray) i.state=i==sender?NSControlStateValueOn:NSControlStateValueOff;
    [self flush];
    [self log:[NSString stringWithFormat:@"language=%ld",(long)sender.tag]];
    [self buildMenu];
    [self tick:nil];
}
- (void)durationChanged:(NSMenuItem *)sender { [self applyDuration:sender.tag]; }
- (void)floorChanged:(NSMenuItem *)sender { [self applyFloor:sender.tag]; }
// Presets and custom values share one apply path; the menu is rebuilt so the checkmark
// and the custom item's label always reflect the stored value.
- (void)applyDuration:(NSInteger)seconds {
    [NSUserDefaults.standardUserDefaults setInteger:seconds forKey:@"duration"];
    if(self.active && self.owned) self.sessionDeadline=seconds>0?[NSDate dateWithTimeIntervalSinceNow:seconds]:nil;
    [self flush];
    [self log:[NSString stringWithFormat:@"session_duration=%ld",(long)seconds]];
    [self buildMenu];
    [self tick:nil];
}
- (void)applyFloor:(NSInteger)percent {
    [NSUserDefaults.standardUserDefaults setInteger:percent forKey:@"battery_floor"];
    [self flush];
    [self log:[NSString stringWithFormat:@"battery_floor=%ld%%",(long)percent]];
    [self buildMenu];
    [self tick:nil];
}
// Asks for one integer in [min,max]; returns -1 on cancel or invalid input (after saying why).
- (NSInteger)askNumber:(NSString *)title unit:(NSString *)unit min:(NSInteger)min max:(NSInteger)max current:(NSInteger)current {
    NSAlert *a=[NSAlert new]; a.messageText=title;
    a.informativeText=[NSString stringWithFormat:L(@"custom.range"),(long)min,(long)max,unit];
    NSTextField *field=[[NSTextField alloc] initWithFrame:NSMakeRect(0,0,120,24)];
    if(current>0) field.stringValue=[NSString stringWithFormat:@"%ld",(long)current];
    a.accessoryView=field;
    [a addButtonWithTitle:L(@"custom.ok")]; [a addButtonWithTitle:L(@"custom.cancel")];
    [NSApp activateIgnoringOtherApps:YES];
    a.window.initialFirstResponder=field;
    if([a runModal]!=NSAlertFirstButtonReturn) return -1;
    NSInteger value=ParseBoundedInteger(field.stringValue,min,max);
    if(value<0) { NSAlert *bad=[NSAlert new]; bad.messageText=a.informativeText; [bad runModal]; }
    return value;
}
- (void)customDuration:(id)sender {
    NSInteger mins=[self askNumber:L(@"custom.duration.title") unit:L(@"custom.unit.min") min:1 max:1440 current:self.sessionDuration/60];
    if(mins>0) [self applyDuration:mins*60];
}
- (void)customFloor:(id)sender {
    NSInteger pct=[self askNumber:L(@"custom.floor.title") unit:@"%" min:5 max:95 current:self.batteryFloor];
    if(pct>0) [self applyFloor:pct];
}
// Single session teardown: persist pending summaries, record why the session ended,
// then reset every per-session field. All end paths (tick's external close, auto-stop,
// toggle off) go through this so no path leaves state behind differently.
- (void)endSessionWithReason:(NSString *)reason {
    [self flush];
    if(reason) [self log:reason];
    self.owned=NO; self.sessionDeadline=nil; self.lastLog=nil; self.networkTime=nil;
    self.guardPID=0; [self watchGuardExit];
}
// Single session start: drain the old session's writes, reset sampling throttle and
// network cache so the first sample of the new session reflects reality, and arm the
// guard exit watch. `pid` is 0 in tests, where no guard exists.
- (void)beginSessionWithGuard:(pid_t)pid startSec:(unsigned long long)sec startUsec:(unsigned long long)usec deadline:(NSDate *)deadline {
    [self flush];
    self.owned=YES; self.active=YES;
    self.guardPID=pid; self.guardStartSec=sec; self.guardStartUsec=usec;
    [self watchGuardExit];
    self.lastLog=nil; self.networkTime=nil;
    self.sessionDeadline=deadline;
}
// Liveness is identity-based, not kill(pid,0): a zombie answers kill(pid,0) as alive and
// PIDs get reused, so require the exact start-time identity recorded at guard start.
- (BOOL)guardIsAlive {
    return self.guardPID>0 && GuardIdentityMatches(self.guardPID,self.guardStartSec,self.guardStartUsec);
}
// Shared by the exit-event handler and the periodic tick: record the loss, tell the user,
// and self-heal — this app holds the same whitelist, so it restores sleep itself.
- (void)handleGuardMissing {
    self.owned=NO; self.sessionDeadline=nil;
    self.thermalItem.hidden=NO;
    self.thermalItem.title=[NSString stringWithFormat:L(@"menu.thermal"),Thermal()];
    self.detailItem.title=L(@"menu.detail.guard.missing");
    self.recoveryItem.title=L(@"menu.detail.guard.restoring");
    self.recoveryItem.hidden=NO;
    [self log:@"guard_missing: protection unavailable"];
    [self notify:L(@"notify.guard_missing")];
    if(self.busy) return;
    self.busy=YES; self.generation++;
    dispatch_async(self.worker, ^{
        BOOL restored=SetSleepDisabledNoPrompt(NO);
        dispatch_async(dispatch_get_main_queue(), ^{
            self.busy=NO;
            if(restored) [self log:@"guard_missing_restored"];
            else {
                [self log:@"guard_missing_restore_failed: sudo -n pmset could not restore sleep"];
                [self notify:L(@"notify.guard_missing_fail")];
            }
            [self tick:nil];
        });
    });
}
// Watches the guard for exit so it is reaped promptly (no zombie) and a mid-tick loss is
// handled immediately. Re-arming cancels the previous source.
- (void)watchGuardExit {
    dispatch_source_t old=self.guardProcSource;
    self.guardProcSource=nil;
    if(old) dispatch_source_cancel(old);
    pid_t pid=self.guardPID;
    if(pid<=0) return;
    dispatch_source_t source=dispatch_source_create(DISPATCH_SOURCE_TYPE_PROC,(uintptr_t)pid,DISPATCH_PROC_EXIT,dispatch_get_main_queue());
    dispatch_source_set_event_handler(source,^{
        if(self.guardProcSource==source) { self.guardProcSource=nil; dispatch_source_cancel(source); }
        int status=0; pid_t reaped;
        do { reaped=waitpid(pid,&status,WNOHANG); } while(reaped<0 && errno==EINTR);
        if(self.guardPID!=pid || !self.active || !self.owned || self.busy) return;
        // A planned brake: the guard already restored, slept and notified; only record it.
        NSString *brake=reaped==pid?BrakeReasonForExit(status):nil;
        if(brake) {
            [self endSessionWithReason:[NSString stringWithFormat:@"session_ended reason=%@",brake]];
            self.active=NO;
            [self tick:nil];
            return;
        }
        // A planned teardown owns the outcome; only an unattended exit self-heals here.
        [self handleGuardMissing];
    });
    dispatch_resume(source);
    self.guardProcSource=source;
}
- (void)tick:(id)sender {
    if(self.uninstallRecoveryOnly || self.uninstalling || self.busy || self.sampling) return;
    self.sampling=YES;
    NSUInteger generation=self.generation;
    dispatch_async(self.worker, ^{
    SleepState state=Enabled();
    BOOL enabled=state==SleepOn;
    dispatch_async(dispatch_get_main_queue(), ^{
    self.sampling=NO;
    if(self.busy || generation!=self.generation) return;
    if(state==SleepUnknown) {
        self.item.button.title=@"? KeepClam";
        self.toggleItem.title=L(@"menu.disable");
        self.thermalItem.hidden=YES;
        self.detailItem.title=L(@"menu.detail.unknown");
        self.recoveryItem.title=L(@"menu.detail.unknown.recovery");
        self.recoveryItem.hidden=NO;
        if(self.owned) [self performAutoStop:@"state_unknown"];
        return;
    }
    BOOL authInstalled=[NSFileManager.defaultManager fileExistsAtPath:SudoersPath()];
    self.authItem.title=authInstalled?L(@"auth.on"):L(@"auth.off");
    self.toggleItem.title=enabled?L(@"menu.disable"):L(@"menu.enable");
    self.item.button.title=enabled?@"● KeepClam":@"○ KeepClam";
    if(self.active && !enabled) [self endSessionWithReason:@"session_ended"];
    if(!self.active && enabled) [self log:@"session_observed_enabled"];
    self.active=enabled;
    if(enabled && self.owned && ![self guardIsAlive]) {
        [self handleGuardMissing];
        return;
    }
    self.thermalItem.hidden=NO;
    self.thermalItem.title=enabled?[NSString stringWithFormat:L(self.owned?@"menu.thermal.protected":@"menu.thermal"),Thermal()]:L(@"menu.thermal.idle");
    if(!enabled) self.detailItem.title=[self idleDetail];
    else if(self.owned && self.sessionDeadline) self.detailItem.title=[NSString stringWithFormat:L(@"menu.detail.session.timed"),FormatInterval([self.sessionDeadline timeIntervalSinceNow],LangIndex())];
    else if(self.owned) self.detailItem.title=L(@"menu.detail.session.open");
    else self.detailItem.title=L(@"menu.detail.external");
    self.recoveryItem.title=L(@"menu.detail.external.recovery");
    self.recoveryItem.hidden=!(enabled && !self.owned);
    if(enabled && (!self.lastLog || -self.lastLog.timeIntervalSinceNow>=[NSUserDefaults.standardUserDefaults integerForKey:@"interval"])) {
        self.sampling=YES;
        BOOL probe=!self.networkTime || -self.networkTime.timeIntervalSinceNow>=60;
        dispatch_async(self.worker, ^{
        NSString *lid=Run(@"/usr/sbin/ioreg",@[@"-r",@"-n",@"IOPMrootDomain",@"-d",@"1"]);
        BOOL closed=[lid rangeOfString:@"\"AppleClamshellState\" = Yes"].location!=NSNotFound;
        NSString *network=probe?Run(@"/usr/bin/curl",@[@"-s",@"-I",@"--connect-timeout",@"2",@"--max-time",@"2",@"https://1.1.1.1"]):nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            self.sampling=NO;
            if(!self.active || self.busy || generation!=self.generation) return;
            if(probe) { self.networkTime=NSDate.date; self.networkResult=[network containsString:@"HTTP/"]?@"reachable":@"failed"; }
            [self sample:[NSString stringWithFormat:@"lid=%@ network_cached=%@ thermal=%@",closed?@"closed":@"open_or_unknown",self.networkResult,ThermalToken()] at:NSDate.date]; self.lastLog=NSDate.date;
        });
        });
    }
    });
    });
}
// Only for a sleep state the app can no longer read; every other stop condition is a
// guard brake (see Brake).
- (void)performAutoStop:(NSString *)reason {
    if(self.busy) return;
    self.busy=YES; self.generation++;
    [self flush];
    [self log:[NSString stringWithFormat:@"auto_stop=%@",reason]];
    [self endSessionWithReason:nil];
    NSString *text=L(@"state.unknown");
    // Guard teardown can block for tens of seconds; keep it off the main thread so the menu stays responsive.
    dispatch_async(self.worker, ^{
        int r=StopGuardNoPrompt();
        BOOL restored=Enabled()==SleepOff;
        dispatch_async(dispatch_get_main_queue(), ^{
            self.active=NO;
            self.busy=NO;
            if(r!=0 || !restored) {
                [self log:@"auto_stop_restore_failed: sudo -n pmset could not restore sleep"];
                [self notify:L(@"notify.autostop.fail")];
            } else [self notify:text];
            [self tick:nil];
        });
    });
}
- (BOOL)authorize:(NSString *)command {
    NSString *escaped=[[command stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"] stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];
    NSAppleScript *script=[[NSAppleScript alloc] initWithSource:[NSString stringWithFormat:@"do shell script \"%@\" with administrator privileges",escaped]];
    NSDictionary *error=nil; NSAppleEventDescriptor *result=[script executeAndReturnError:&error];
    if(error) { NSAlert *alert=[NSAlert new]; alert.messageText=L(@"alert.title"); alert.informativeText=[error description]; [alert runModal]; return NO; }
    (void)result;
    return YES;
}
- (void)offerAuthInstallGuide {
    if([self sudoersFilePresent] || [NSUserDefaults.standardUserDefaults boolForKey:@"authorization_guidance_shown"]) return;
    [NSUserDefaults.standardUserDefaults setBool:YES forKey:@"authorization_guidance_shown"];
    NSAlert *a=[NSAlert new]; a.messageText=L(@"auth.guide.title");
    a.informativeText=L(@"auth.guide.body");
    [a addButtonWithTitle:L(@"auth.guide.install")]; [a addButtonWithTitle:L(@"auth.guide.later")];
    if([a runModal]==NSAlertFirstButtonReturn) [self authAction:self.authItem];
}
- (void)authAction:(NSMenuItem *)sender {
    if([self sudoersFilePresent]) {
        NSAlert *a=[NSAlert new]; a.messageText=L(@"auth.installed.title");
        a.informativeText=[NSString stringWithFormat:L(@"auth.installed.view.body"),SudoersPath(),[self ruleText],SudoersPath()];
        [a runModal]; return;
    }
    NSString *cmd=[NSString stringWithFormat:@"tmp=$(/usr/bin/mktemp); trap '/bin/rm -f \"$tmp\"' EXIT; /usr/bin/printf '%%s\\n' %@ > \"$tmp\" && /usr/sbin/visudo -cf \"$tmp\" >/dev/null && /usr/bin/install -m 0440 -o root -g wheel \"$tmp\" %@",Quote([self ruleText]),SudoersPath()];
    if([self authorize:cmd] && [self sudoersFilePresent]) {
        [self flush]; [self log:@"sudoers_installed"];
        NSAlert *a=[NSAlert new]; a.messageText=L(@"auth.installed.title"); a.informativeText=L(@"auth.installed.body"); [a runModal];
    }
    [self tick:nil];
}
- (void)toggle:(id)sender {
    if(self.busy) return;
    BOOL enable=Enabled()==SleepOff;
    if(enable) {
        // Same decision the guard applies, so a session never starts already due to brake.
        BOOL onAC=NO; NSInteger batt=BatteryPercent(&onAC);
        NSInteger thermal=NSProcessInfo.processInfo.thermalState;
        NSString *reason=BrakeReason(thermal,thermal<0?3:0,batt,0,onAC,NSProcessInfo.processInfo.isLowPowerModeEnabled,self.batteryFloor,nil,NSDate.date);
        NSString *problem=nil;
        if([reason hasPrefix:@"thermal"]) problem=@"toggle.hot";
        else if([reason isEqualToString:@"low_power_mode"]) problem=@"toggle.lowpower";
        else if([reason isEqualToString:@"battery_floor"]) problem=@"toggle.lowbattery";
        if(problem) { NSAlert *a=[NSAlert new]; a.messageText=L(problem); [a runModal]; return; }
        // Published before the guard starts: its first cycle must not see a stale deadline.
        self.sessionDeadline=self.sessionDuration>0?[NSDate dateWithTimeIntervalSinceNow:self.sessionDuration]:nil;
    }
    self.busy=YES; self.generation++;
    dispatch_async(self.worker, ^{
        pid_t pid=-1; BOOL ok=NO; NSString *problem=nil; int stopResult=0;
        unsigned long long startSec=0,startUsec=0;
        if(enable) {
            if(SetSleepDisabled(YES)) {
                pid=StartGuard(getpid()); ok=pid>0;
                if(ok) {
                    // Record the guard's start-time identity now, before the PID could ever be reused.
                    struct proc_bsdinfo info={0};
                    if(proc_pidinfo(pid,PROC_PIDTBSDINFO,0,&info,sizeof(info))==sizeof(info)) { startSec=info.pbi_start_tvsec; startUsec=info.pbi_start_tvusec; }
                }
                else problem=SetSleepDisabled(NO)?@"toggle.fail.guard.body":@"toggle.restorefail.body";
            } else problem=@"toggle.fail.pmset.body";
        } else {
            stopResult=StopGuard(); ok=stopResult==0;
            if(!ok) problem=stopResult==2?@"toggle.guardstuck.body":@"toggle.restorefail.body";
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            self.busy=NO;
            if(ok) {
                if(enable) {
                    [self beginSessionWithGuard:pid startSec:startSec startUsec:startUsec deadline:self.sessionDeadline];
                    [self log:@"session_enabled_guard_confirmed"];
                    [self requestNotifyAuth];
                    if(![self sudoersFilePresent]) [self offerAuthInstallGuide];
                } else {
                    [self endSessionWithReason:@"session_disabled"];
                    self.active=NO;
                }
            } else {
                if(enable) self.sessionDeadline=nil;
                [self log:[NSString stringWithFormat:@"toggle_failed enable=%d stop_guard=%d problem=%@",enable?1:0,stopResult,problem?:@"none"]];
                NSAlert *a=[NSAlert new];
                a.messageText=L(ToggleAlertTitle(enable,stopResult,problem));
                a.informativeText=L(problem); [a runModal];
            }
            [self tick:nil];
        });
    });
}
- (void)logs:(id)sender { [self flush]; [NSWorkspace.sharedWorkspace openURL:[NSURL fileURLWithPath:self.logPath]]; }
- (void)help:(id)sender {
    NSAlert *a=[NSAlert new]; a.messageText=@"KeepClam"; // icon: applicationIconImage, set at launch
    a.informativeText=L(@"help.body");
    [a addButtonWithTitle:L(@"help.close")];
    [a addButtonWithTitle:L(@"help.github")];
    if([a runModal]==NSAlertSecondButtonReturn)
        [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:@"https://github.com/LCROSSY/KeepClam"]];
}
// Narrow operations keep the destructive flow testable with temporary bundles.
- (NSString *)uninstallAppPath { return NSBundle.mainBundle.bundlePath; }
- (NSString *)uninstallBundleID { return NSBundle.mainBundle.bundleIdentifier; }
- (NSString *)uninstallHome {
    char resolved[PATH_MAX];
    return realpath(NSHomeDirectory().fileSystemRepresentation,resolved)?[NSString stringWithUTF8String:resolved]:NSHomeDirectory();
}
- (int)uninstallRestoreSleep { return StopGuard(); }
- (BOOL)uninstallUnregisterLogin:(NSError **)error {
    SMAppService *service=SMAppService.mainAppService;
    if(service.status==SMAppServiceStatusNotRegistered || service.status==SMAppServiceStatusNotFound) return YES;
    return [service unregisterAndReturnError:error];
}
- (BOOL)uninstallAdminCommand:(NSString *)command error:(NSError **)error {
    __block BOOL ok=NO;
    __block NSError *failure=nil;
    void (^authorize)(void)=^{
        NSString *escaped=[[command stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"] stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];
        NSAppleScript *script=[[NSAppleScript alloc] initWithSource:[NSString stringWithFormat:@"do shell script \"%@\" with administrator privileges",escaped]];
        NSDictionary *details=nil;
        ok=[script executeAndReturnError:&details]!=nil;
        if(!ok) failure=[self uninstallAdminError:details];
    };
    if(NSThread.isMainThread) authorize(); else dispatch_sync(dispatch_get_main_queue(),authorize);
    if(error) *error=failure;
    return ok;
}
// The code keeps the AppleScript error number: -128 is a cancelled prompt, and a
// positive number is the shell command's exit status.
- (NSError *)uninstallAdminError:(NSDictionary *)details {
    NSString *reason=details[NSAppleScriptErrorMessage] ?: @"Authorization failed";
    return [NSError errorWithDomain:UninstallErrorDomain code:[details[NSAppleScriptErrorNumber] integerValue]
        userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:L(@"uninstall.admin.failed"),reason]}];
}
- (NSString *)uninstallAuthorizationPath { return SudoersPath(); }
// Runs as root. Exits 3 when the rule is no longer exactly ours or not a regular
// file; a rule that disappeared before the prompt finished counts as removed.
- (NSString *)uninstallAuthorizationCommand:(NSString *)path {
    NSString *file=Quote(path);
    return [NSString stringWithFormat:@"if [ ! -e %@ ] && [ ! -L %@ ]; then exit 0; fi; [ ! -L %@ ] && [ -f %@ ] || exit %ld; /usr/bin/printf '%%s\\n' %@ | /usr/bin/cmp -s - %@ || exit %ld; /bin/rm -f %@",
        file,file,file,file,(long)UninstallAuthorizationChangedStatus,Quote([self ruleText]),file,(long)UninstallAuthorizationChangedStatus,file];
}
- (BOOL)uninstallRemoveAuthorization:(NSError **)error {
    NSString *path=[self uninstallAuthorizationPath];
    struct stat st;
    if(lstat(path.fileSystemRepresentation,&st)!=0) {
        if(errno==ENOENT) return YES;
        return UninstallFailure(error,path,@"Cannot inspect passwordless authorization",errno);
    }
    NSString *expected=[[self ruleText] stringByAppendingString:@"\n"];
    if(!S_ISREG(st.st_mode))
        return UninstallFailure(error,path,L(@"uninstall.sudoers.changed"),EINVAL);
    // Installed rules are root:wheel 0440, so ordinary users may not read them.
    NSError *readError=nil;
    NSString *actual=[NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:&readError];
    if(actual && ![actual isEqualToString:expected])
        return UninstallFailure(error,path,L(@"uninstall.sudoers.changed"),EINVAL);
    // Recheck content in the privileged operation; do not run user-writable code as root.
    NSError *adminError=nil;
    if(![self uninstallAdminCommand:[self uninstallAuthorizationCommand:path] error:&adminError]) {
        if(adminError.code==UninstallAuthorizationChangedStatus)
            return UninstallFailure(error,path,L(@"uninstall.sudoers.changed"),EINVAL);
        if(error) *error=adminError;
        return NO;
    }
    if(lstat(path.fileSystemRepresentation,&st)!=0 && errno==ENOENT) return YES;
    return UninstallFailure(error,path,@"Authorization file could not be removed",EACCES);
}
- (NSString *)uninstallBrewForApp:(NSString *)appPath { return UninstallHomebrewForApp(appPath,@[@"/opt/homebrew",@"/usr/local"]); }
- (NSString *)uninstallTrustedRequirement:(NSError **)error {
    SecCodeRef running=NULL; CFDictionaryRef info=NULL; SecRequirementRef requirement=NULL;
    OSStatus status=SecCodeCopySelf(kSecCSDefaultFlags,&running);
    if(status==errSecSuccess) status=SecCodeCopySigningInformation((SecStaticCodeRef)running,kSecCSDefaultFlags,&info);
    NSData *cdhash=info?((__bridge NSDictionary *)info)[(__bridge NSString *)kSecCodeInfoUnique]:nil;
    NSMutableString *hex=[NSMutableString string];
    if([cdhash isKindOfClass:NSData.class] && cdhash.length==20) {
        const unsigned char *bytes=cdhash.bytes; for(NSUInteger i=0;i<cdhash.length;i++) [hex appendFormat:@"%02x",bytes[i]];
    } else status=errSecCSUnsigned;
    NSString *text=[NSString stringWithFormat:@"cdhash H\"%@\"",hex];
    if(status==errSecSuccess) status=SecRequirementCreateWithString((__bridge CFStringRef)text,kSecCSDefaultFlags,&requirement);
    // Dynamic validity compares the kernel's running CDHash to this exact disk
    // identity. A replaced executable cannot become its own trust anchor.
    if(status==errSecSuccess) status=SecCodeCheckValidity(running,kSecCSStrictValidate,requirement);
    if(requirement) CFRelease(requirement); if(info) CFRelease(info); if(running) CFRelease(running);
    if(status!=errSecSuccess) { UninstallFailure(error,[self uninstallAppPath],L(@"uninstall.signature.failed"),(int)status); return nil; }
    return text;
}
- (BOOL)uninstallDeleteApp:(NSString *)appPath bundleID:(NSString *)bundleID brew:(NSString *)brew error:(NSError **)error {
    if(brew) {
        int status=-1;
        NSMutableDictionary *environment=[NSProcessInfo.processInfo.environment mutableCopy];
        environment[@"HOMEBREW_NO_AUTOREMOVE"]=@"1";
        environment[@"HOMEBREW_NO_AUTO_UPDATE"]=@"1";
        NSString *output=RunLimitWithEnvironment(brew,@[@"uninstall",@"--cask",@"keepclam"],120,&status,environment);
        if(status!=0 || [NSFileManager.defaultManager fileExistsAtPath:appPath])
            return UninstallFailure(error,appPath,[NSString stringWithFormat:L(@"uninstall.brew.failed"),output],EIO);
        return YES;
    }
    if(!UninstallValidateApp(appPath,bundleID,error)) return NO;
    NSFileManager *fm=NSFileManager.defaultManager;
    BOOL needsAdmin=![fm isDeletableFileAtPath:appPath];
    for(NSString *relative in [fm enumeratorAtPath:appPath]) {
        if(![fm isDeletableFileAtPath:[appPath stringByAppendingPathComponent:relative]]) { needsAdmin=YES; break; }
    }
    if(!needsAdmin) return UninstallRemoveApp(appPath,bundleID,error);
    // Only a copy matching the current process's kernel-checked code identity may
    // run as root. Force this architecture so Rosetta cannot select another slice.
    struct stat identity;
    if(lstat(appPath.fileSystemRepresentation,&identity)!=0) return UninstallFailure(error,appPath,@"Cannot inspect application identity",errno);
    NSString *requirement=[self uninstallTrustedRequirement:error];
    if(!requirement) return NO;
#if defined(__arm64__)
    NSString *architecture=@"arm64";
#else
    NSString *architecture=@"x86_64";
#endif
    NSString *command=[NSString stringWithFormat:@"stage=$(/usr/bin/mktemp -d /private/tmp/keepclam-uninstall.XXXXXX) || exit 1; trap '/bin/rm -rf \"$stage\"' EXIT; /usr/bin/ditto %@ \"$stage/KeepClam.app\" && /usr/bin/codesign --verify --strict --architecture %@ -R %@ \"$stage/KeepClam.app\" && /usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin /usr/bin/arch -%@ \"$stage/KeepClam.app/Contents/MacOS/KeepClam\" --uninstall-remove-app %@ %@ %llu %llu",Quote(appPath),architecture,Quote([@"=" stringByAppendingString:requirement]),architecture,Quote(appPath),Quote(bundleID),(unsigned long long)identity.st_dev,(unsigned long long)identity.st_ino];
    if(![self uninstallAdminCommand:command error:error]) return NO;
    if(![fm fileExistsAtPath:appPath]) return YES;
    return UninstallFailure(error,appPath,@"Application could not be removed",EACCES);
}
- (void)uninstallClearPreferences:(NSString *)bundleID {
    [NSUserDefaults.standardUserDefaults removePersistentDomainForName:bundleID];
    CFStringRef appID=(__bridge CFStringRef)bundleID;
    CFArrayRef keys=CFPreferencesCopyKeyList(appID,kCFPreferencesCurrentUser,kCFPreferencesCurrentHost);
    if(keys) { CFPreferencesSetMultiple(NULL,keys,appID,kCFPreferencesCurrentUser,kCFPreferencesCurrentHost); CFRelease(keys); }
    CFPreferencesSynchronize(appID,kCFPreferencesCurrentUser,kCFPreferencesCurrentHost);
    CFPreferencesAppSynchronize(appID);
}
- (NSArray<NSError *> *)uninstallRemoveData:(NSString *)home bundleID:(NSString *)bundleID {
    return UninstallRemoveUserDataPreservingRuntime(home,bundleID);
}
- (void)uninstallClearNotifications {
    @try {
        UNUserNotificationCenter *center=UNUserNotificationCenter.currentNotificationCenter;
        [center removeAllPendingNotificationRequests]; [center removeAllDeliveredNotifications];
    } @catch(NSException *exception) {}
}
- (BOOL)uninstallRestoreRuntime:(NSError **)error { return UninstallPrepareRuntimeDirectories([self uninstallHome],error); }
- (void)uninstallInitializeDefaults {
    if(![NSUserDefaults.standardUserDefaults integerForKey:@"interval"]) [NSUserDefaults.standardUserDefaults setInteger:5 forKey:@"interval"];
    if(![NSUserDefaults.standardUserDefaults integerForKey:@"battery_floor"]) [NSUserDefaults.standardUserDefaults setInteger:20 forKey:@"battery_floor"];
}
- (void)uninstallResumeAfterFailure {
    NSError *error=nil;
    self.uninstallRecoveryOnly=![self uninstallRestoreRuntime:&error];
    self.uninstalling=NO; self.busy=NO;
    if(!self.uninstallRecoveryOnly) {
        [self uninstallInitializeDefaults];
        [self buildMenu];
        self.timer=[NSTimer scheduledTimerWithTimeInterval:5 target:self selector:@selector(tick:) userInfo:nil repeats:YES];
        [self tick:nil];
    } else {
        self.thermalItem.hidden=YES;
        self.detailItem.title=L(@"uninstall.incomplete");
        self.recoveryItem.title=L(@"uninstall.retry"); self.recoveryItem.hidden=NO;
    }
}
- (void)uninstallFailed:(NSString *)message sleepRestored:(BOOL)restored {
    [self uninstallResumeAfterFailure];
    NSAlert *alert=[NSAlert new]; alert.messageText=L(@"uninstall.failed.title");
    alert.informativeText=[NSString stringWithFormat:L(restored?@"uninstall.failed.body":@"uninstall.restore.failed"),message];
    [alert runModal];
}
- (BOOL)uninstallRemoveRuntime:(NSString *)home error:(NSError **)error { return UninstallRemoveRuntimeData(home,error); }
- (void)uninstallRemaining:(NSString *)message {
    NSAlert *alert=[NSAlert new]; alert.messageText=L(@"uninstall.failed.title");
    alert.informativeText=[NSString stringWithFormat:L(@"uninstall.remaining"),message]; [alert runModal];
}
- (BOOL)uninstallAppStillUsable:(NSString *)path bundleID:(NSString *)bundleID {
    if(!UninstallValidateApp(path,bundleID,NULL)) return NO;
    int status=-1;
    RunLimit(@"/usr/bin/codesign",@[@"--verify",@"--strict",path],10,&status);
    return status==0;
}
- (void)uninstallBrokenApplication:(NSString *)message {
    self.uninstallRecoveryOnly=YES;
    NSAlert *alert=[NSAlert new]; alert.messageText=L(@"uninstall.failed.title");
    alert.informativeText=[NSString stringWithFormat:L(@"uninstall.broken"),message]; [alert runModal];
    [self uninstallClearNotifications]; [self uninstallFinished];
}
- (void)uninstallFinished { _exit(0); } // Normal quit would recreate logs/preferences.
// A quarantined app opened in place runs from a read-only translocated copy; its
// bundle path is not the file the user installed and cannot be deleted.
- (BOOL)uninstallAppIsTranslocated:(NSString *)appPath {
    bool translocated=false;
    NSURL *url=[NSURL fileURLWithPath:appPath];
    if(SecTranslocateIsTranslocatedURL((__bridge CFURLRef)url,&translocated,NULL) && translocated) return YES;
    return [appPath.pathComponents containsObject:@"AppTranslocation"];
}
- (void)uninstallRefused:(NSString *)message {
    NSAlert *alert=[NSAlert new]; alert.messageText=L(@"uninstall.failed.title"); alert.informativeText=message; [alert runModal];
}
- (void)startUninstall {
    if(self.busy || self.uninstalling) return;
    NSString *appPath=[self uninstallAppPath],*bundleID=[self uninstallBundleID],*home=[self uninstallHome];
    if([self uninstallAppIsTranslocated:appPath]) { [self uninstallRefused:L(@"uninstall.translocated")]; return; }
    NSError *error=nil;
    if(!UninstallValidateApp(appPath,bundleID,&error) || !UninstallUserCleanupPaths(home,bundleID,&error)) {
        [self uninstallRefused:error.localizedDescription]; return;
    }
    NSString *brew=[self uninstallBrewForApp:appPath];
    [self flush];
    self.uninstalling=YES; self.busy=YES; self.generation++;
    [self.timer invalidate]; self.timer=nil;
    self.detailItem.title=L(@"uninstall.progress"); self.thermalItem.hidden=YES; self.recoveryItem.hidden=YES;
    dispatch_async(self.worker,^{
        int stopped=[self uninstallRestoreSleep];
        dispatch_async(dispatch_get_main_queue(),^{
            if(stopped!=0) { [self uninstallFailed:L(stopped==2?@"toggle.guardstuck.body":@"toggle.restorefail.body") sleepRestored:NO]; return; }
            [self endSessionWithReason:nil]; self.active=NO;
            NSError *failure=nil;
            if(![self uninstallUnregisterLogin:&failure]) {
                [self uninstallFailed:[NSString stringWithFormat:L(@"uninstall.login.failed"),failure.localizedDescription ?: @""] sleepRestored:YES]; return;
            }
            if(![self uninstallRemoveAuthorization:&failure]) {
                [self uninstallFailed:failure.localizedDescription ?: L(@"uninstall.sudoers.changed") sleepRestored:YES]; return;
            }
            dispatch_async(self.worker,^{
                // The queue is drained; close the resident fd before removing its directory.
                if(self.logFD>=0) { close(self.logFD); self.logFD=-1; }
                [self uninstallClearPreferences:bundleID];
                NSArray<NSError *> *failures=[self uninstallRemoveData:home bundleID:bundleID];
                NSError *removeError=nil;
                BOOL removed=failures.count==0 && [self uninstallDeleteApp:appPath bundleID:bundleID brew:brew error:&removeError];
                BOOL broken=removeError && ![self uninstallAppStillUsable:appPath bundleID:bundleID];
                NSError *runtimeError=nil;
                if(removed) [self uninstallRemoveRuntime:home error:&runtimeError];
                dispatch_async(dispatch_get_main_queue(),^{
                    if(!removed) {
                        NSMutableArray *messages=[NSMutableArray array];
                        for(NSError *e in failures) [messages addObject:e.localizedDescription];
                        if(removeError) [messages addObject:removeError.localizedDescription];
                        if(broken) {
                            [messages addObject:appPath];
                            // Keep the instance lock until exit; explicitly report
                            // its directory because a damaged app cannot retry.
                            [messages addObject:[home stringByAppendingPathComponent:@"Library/Application Support/KeepClam"]];
                            [self uninstallBrokenApplication:[messages componentsJoinedByString:@"\n\n"]]; return;
                        }
                        [self uninstallFailed:[messages componentsJoinedByString:@"\n\n"] sleepRestored:YES]; return;
                    }
                    if(runtimeError) [self uninstallRemaining:runtimeError.localizedDescription];
                    [self uninstallClearNotifications];
                    [self uninstallFinished];
                });
            });
        });
    });
}
- (void)uninstall:(id)sender {
    if(self.busy || self.uninstalling) return;
    NSAlert *alert=[NSAlert new]; alert.alertStyle=NSAlertStyleWarning;
    alert.messageText=L(@"uninstall.title"); alert.informativeText=L(@"uninstall.body");
    [alert addButtonWithTitle:L(@"custom.cancel")];
    NSButton *button=[alert addButtonWithTitle:L(@"uninstall.confirm")]; button.hasDestructiveAction=YES;
    [NSApp activateIgnoringOtherApps:YES];
    if([alert runModal]==NSAlertSecondButtonReturn) [self startUninstall];
}
- (BOOL)validateMenuItem:(NSMenuItem *)item {
    if(self.busy || self.uninstalling) return NO;
    return !self.uninstallRecoveryOnly || item.action==@selector(uninstall:) || item.action==@selector(quit:) || item.action==@selector(help:);
}
- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender {
    if(self.busy) return NSTerminateCancel;
    self.busy=YES; self.generation++;
    dispatch_async(self.worker, ^{
        BOOL ok=StopGuard()==0;
        dispatch_async(dispatch_get_main_queue(), ^{
            self.busy=NO;
            if(ok) {
                [self flush];
                if(self.active) { [self log:@"session_ended_application_quit"]; [self flush]; } // drain the end record before replying
            }
            else { NSAlert *a=[NSAlert new]; a.messageText=L(@"quit.restorefail.title"); a.informativeText=L(@"quit.restorefail.body"); [a runModal]; }
            [sender replyToApplicationShouldTerminate:ok];
        });
    });
    return NSTerminateLater;
}
- (void)quit:(id)sender {
    [NSApp terminate:nil];
}
@end
int main(int argc,const char *argv[]) {
    @autoreleasepool {
        // Internal, staged root helper: never initialize defaults, logs or NSApplication.
        if(argc==6 && strcmp(argv[1],"--uninstall-remove-app")==0) {
            if(geteuid()!=0) return 1;
            char *deviceEnd=NULL,*inodeEnd=NULL;
            errno=0;
            unsigned long long device=strtoull(argv[4],&deviceEnd,10),inode=strtoull(argv[5],&inodeEnd,10);
            if(errno || !device || !inode || !deviceEnd || *deviceEnd || !inodeEnd || *inodeEnd || argv[4][0]=='-' || argv[5][0]=='-') return 1;
            NSError *error=nil;
            BOOL ok=UninstallRemoveAppExpected([NSString stringWithUTF8String:argv[2]],[NSString stringWithUTF8String:argv[3]],device,inode,&error);
            if(!ok) fprintf(stderr,"%s\n",error.localizedDescription.UTF8String);
            return ok?0:1;
        }
        if(argc==4 && strcmp(argv[1],"--guard")==0) return Guard(atoi(argv[2]),atoi(argv[3]));
        if(argc==2 && strcmp(argv[1],"--stop")==0) return StopGuard();
        NSString *support=[LockPath() stringByDeletingLastPathComponent];
        if(!PrivateDirectory(support)) return 1;
        int instance=InstanceLock([support stringByAppendingPathComponent:@"app.lock"]);
        if(instance<0) return 0; // Never initialize the delegate or stop another instance's session.
        NSApplication *app=NSApplication.sharedApplication; App *delegate=[App new]; app.delegate=delegate;
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory]; [app run]; close(instance);
    }
    return 0;
}
