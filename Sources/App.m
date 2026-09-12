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
#import <ServiceManagement/ServiceManagement.h>
#import <libproc.h>

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
static void Append(NSString *path,NSString *line) {
    int lock=open([[path stringByAppendingString:@".lock"] fileSystemRepresentation],O_CREAT|O_RDWR|O_NOFOLLOW|O_CLOEXEC,0600);
    if(lock<0) return;
    fchmod(lock,0600);
    flock(lock,LOCK_EX);
    struct stat st;
    int existing=open(path.fileSystemRepresentation,O_RDONLY|O_NOFOLLOW|O_CLOEXEC);
    if(existing>=0) { fchmod(existing,0600); close(existing); }
    if(lstat(path.fileSystemRepresentation,&st)==0 && S_ISREG(st.st_mode) && st.st_size>1024*1024) {
        NSFileManager *fm=NSFileManager.defaultManager;
        [fm removeItemAtPath:[path stringByAppendingString:@".3"] error:nil];
        for(int i=2;i>=1;i--) [fm moveItemAtPath:[path stringByAppendingFormat:@".%d",i] toPath:[path stringByAppendingFormat:@".%d",i+1] error:nil];
        [fm moveItemAtPath:path toPath:[path stringByAppendingString:@".1"] error:nil];
    }
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

static NSString *Run(NSString *path, NSArray *args) {
    NSTask *task=[NSTask new]; task.launchPath=path; task.arguments=args;
    NSPipe *pipe=[NSPipe pipe]; task.standardOutput=pipe; task.standardError=pipe;
    @try { [task launch];
        dispatch_source_t timeout=dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,dispatch_get_global_queue(QOS_CLASS_UTILITY,0));
        dispatch_source_set_timer(timeout,dispatch_time(DISPATCH_TIME_NOW,10*NSEC_PER_SEC),DISPATCH_TIME_FOREVER,0);
        dispatch_source_set_event_handler(timeout,^{ if(task.running) kill(task.processIdentifier,SIGKILL); }); dispatch_resume(timeout);
        NSData *data=[pipe.fileHandleForReading readDataToEndOfFile]; [task waitUntilExit]; dispatch_source_cancel(timeout);
        return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
    } @catch(NSException *e) { return @"unknown"; }
}
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
// In-app localization: table maps key -> @[zh, en]; LogTests enforces both entries are non-empty.
static NSDictionary<NSString *,NSArray<NSString *> *> *StringsTable(void) {
    static NSDictionary *t; static dispatch_once_t once;
    dispatch_once(&once,^{
        t=@{
            @"menu.enable":@[@"开启合盖运行",@"Enable Lid-Closed Running"],
            @"menu.disable":@[@"关闭合盖运行",@"Disable Lid-Closed Running"],
            @"menu.thermal":@[@"系统热状态：%@",@"Thermal state: %@"],
            @"menu.thermal.idle":@[@"采样已停止",@"Sampling stopped"],
            @"menu.detail.idle":@[@"开启后每 5 秒检查过热，无运行时限",@"On enable: overheat checked every 5 s, no time limit"],
            @"menu.detail.session.timed":@[@"保护会话中 · 剩余 %@ · 每 5 秒检查过热",@"Protected session · %@ left · overheat checked every 5 s"],
            @"menu.detail.session.open":@[@"保护会话中 · 无时限 · 每 5 秒检查过热",@"Protected session · no time limit · overheat checked every 5 s"],
            @"menu.detail.external":@[@"外部开启的状态；请关闭后重新开启以启用保护",@"Enabled externally; turn off and on again here to get protection"],
            @"menu.login":@[@"登录时启动",@"Launch at Login"],
            @"menu.login.approval":@[@"登录时启动：等待系统批准…",@"Launch at Login: Approval Required…"],
            @"state.unknown":@[@"无法确认系统睡眠状态，请尝试恢复睡眠",@"Sleep state unavailable; try restoring sleep"],
            @"menu.settings":@[@"设置",@"Settings"],
            @"menu.duration":@[@"自动结束",@"Auto-Stop"],
            @"dur.none":@[@"无限",@"Unlimited"],
            @"dur.1800":@[@"30 分钟",@"30 min"],
            @"dur.3600":@[@"1 小时",@"1 h"],
            @"dur.7200":@[@"2 小时",@"2 h"],
            @"dur.14400":@[@"4 小时",@"4 h"],
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
            @"auth.off":@[@"免密授权：未安装 — 点击安装",@"Passwordless sudo: not installed — click to install"],
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
            @"auth.installed.view.body":@[@"白名单 /etc/sudoers.d/keepclam 仅授权以下两条命令免密执行：\n\n%@\n\n查看实际内容：sudo cat /etc/sudoers.d/keepclam\n移除授权：运行 scripts/uninstall-sudoers.sh",@"The whitelist /etc/sudoers.d/keepclam authorizes exactly these two commands without a password:\n\n%@\n\nInspect it: sudo cat /etc/sudoers.d/keepclam\nRemove it: run scripts/uninstall-sudoers.sh"],
            @"auth.installed.body":@[@"以后开关合盖运行不再需要输入管理员密码。可用 scripts/uninstall-sudoers.sh 移除。",@"Toggling no longer needs an admin password. Remove anytime with scripts/uninstall-sudoers.sh."],
            @"toggle.fail.pmset.body":@[@"无法设置系统睡眠策略。可在菜单中选择「免密授权：未安装 — 点击安装」一次性授权，或重试输入管理员密码。",@"Could not set the system sleep policy. Install the passwordless whitelist from the menu, or retry with the admin password."],
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
            @"notify.autostop.timer":@[@"定时时间已到，已恢复合盖睡眠。",@"Timer elapsed; normal sleep restored."],
            @"notify.autostop.battery":@[@"电量已降至 %ld%% 下限，已恢复合盖睡眠。",@"Battery hit the %ld%% floor; normal sleep restored."],
            @"notify.autostop.lowpower":@[@"系统进入低电量模式，已恢复合盖睡眠。",@"Low Power Mode activated; normal sleep restored."],
            @"notify.autostop.fail":@[@"自动结束未能恢复系统睡眠，请手动执行：sudo pmset -a disablesleep 0",@"Auto-stop could not restore sleep. Please run: sudo pmset -a disablesleep 0"],
            @"notify.thermal":@[@"过热保护已触发，已尝试恢复睡眠并请求休眠，请查看日志确认结果",@"Overheat protection attempted to restore sleep and requested sleep now; check logs for the result"],
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

// Pure auto-stop decision shared by the app loop and tests. Returns a reason key or nil.
static NSString *AutoStopReason(NSInteger batteryPct,BOOL onAC,BOOL lowPower,NSInteger floorPct,NSDate *deadline,NSDate *now) {
    if(deadline && [now timeIntervalSinceDate:deadline]>=0) return @"timer";
    if(!onAC) {
        if(lowPower) return @"low_power_mode";
        if(batteryPct>=0 && batteryPct<=floorPct) return @"battery_floor";
    }
    return nil;
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
static NSString *LockPath(void){ return [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/KeepClam/guard.lock"]; }

static void GuardLog(NSString *event) {
    Append(LogFilePath(),[NSString stringWithFormat:@"%@ | %@ | thermal=%@\n",NSDate.date,event,ThermalToken()]);
}
static void GuardNotify(void) {
    Run(@"/usr/bin/osascript",@[@"-e",[NSString stringWithFormat:@"display notification \"%@\" with title \"KeepClam\" sound name \"Glass\"",L(@"notify.thermal")]]);
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
    signal(SIGTERM,Stop); signal(SIGHUP,Stop); signal(SIGINT,Stop);
    NSInteger initial=NSProcessInfo.processInfo.thermalState;
    if(initial<0 || initial>=2) { close(lock); close(ready); return 3; }
    if(Enabled()!=SleepOn) { close(lock); close(ready); return 4; }
    if(ready>=0) { write(ready,"1",1); close(ready); }
    unsigned unknown=0;
    while(!stopping && getppid()==parent && Enabled()==SleepOn) {
        NSInteger state=NSProcessInfo.processInfo.thermalState;
        unknown=state<0 ? unknown+1 : 0;
        if(state>=2 || unknown>=3) {
            BOOL restored=SetSleepDisabledNoPrompt(NO);
            Run(@"/usr/bin/pmset",@[@"sleepnow"]);
            GuardLog(restored?@"PROTECTION_TRIGGER: sleep restored, sleepnow requested":@"PROTECTION_RESTORE_FAILED: sleepnow requested");
            GuardNotify();
            close(lock);
            return 0;
        }
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

@interface App : NSObject <NSApplicationDelegate, NSMenuDelegate>
@property NSStatusItem *item;
@property NSMenuItem *loginItem;

@property NSMenuItem *toggleItem;
@property NSMenuItem *thermalItem;
@property NSMenuItem *detailItem;
@property NSMenuItem *authItem;
@property NSTimer *timer;
@property NSString *logPath;
@property NSDate *lastLog;
@property BOOL busy;
@property BOOL owned;
@property BOOL active;
@property BOOL sampling;
@property dispatch_queue_t worker;
@property NSString *sampleKey;
@property NSDate *rangeStart;
@property NSDate *rangeEnd;
@property NSUInteger count;
@property NSTimeInterval maxGap;
@property NSDate *networkTime;
@property NSString *networkResult;
@property pid_t guardPID;
@property NSUInteger generation;
@property NSDate *sessionDeadline;
@end

@implementation App
- (NSInteger)sessionDuration { return MAX(0,[NSUserDefaults.standardUserDefaults integerForKey:@"duration"]); }
- (NSInteger)batteryFloor { NSInteger f=[NSUserDefaults.standardUserDefaults integerForKey:@"battery_floor"]; return f>0?f:20; }
- (NSString *)ruleText {
    return [NSString stringWithFormat:@"%@ ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1",NSUserName()];
}
- (BOOL)sudoersFilePresent { return [NSFileManager.defaultManager fileExistsAtPath:@"/etc/sudoers.d/keepclam"]; }
- (void)log:(NSString *)event {
    Append(self.logPath,[NSString stringWithFormat:@"%@ | %@\n",[NSDate date],event]);
}
- (void)flush {
    if(!self.count) return;
    [self log:[NSString stringWithFormat:@"summary start=%@ end=%@ samples=%lu max_gap=%.1fs | %@",self.rangeStart,self.rangeEnd,(unsigned long)self.count,self.maxGap,self.sampleKey]];
    self.count=0; self.sampleKey=nil;
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
// Builds the whole menu; called again on language switch so titles take effect immediately.
- (void)buildMenu {
    NSMenu *menu=[NSMenu new]; menu.delegate=self;
    [self add:@"KeepClam" action:nil menu:menu];
    self.toggleItem=[self add:L(@"menu.enable") action:@selector(toggle:) menu:menu];
    self.thermalItem=[self add:L(@"menu.thermal.idle") action:nil menu:menu];
    self.detailItem=[self add:L(@"menu.detail.idle") action:nil menu:menu];
    [menu addItem:NSMenuItem.separatorItem];
    NSMenuItem *settings=[self add:L(@"menu.settings") action:nil menu:menu]; NSMenu *sm=[NSMenu new];
    self.loginItem=[self add:L(@"menu.login") action:@selector(loginChanged:) menu:sm];
    [self refreshLogin];
    NSMenuItem *duration=[self add:L(@"menu.duration") action:nil menu:sm]; NSMenu *dur=[NSMenu new];
    for(NSNumber *n in @[@0,@1800,@3600,@7200,@14400]) {
        NSString *key=n.intValue==0?@"dur.none":(n.intValue==1800?@"dur.1800":(n.intValue==3600?@"dur.3600":(n.intValue==7200?@"dur.7200":@"dur.14400")));
        NSMenuItem *i=[self add:L(key) action:@selector(durationChanged:) menu:dur]; i.tag=n.integerValue;
        i.state=i.tag==self.sessionDuration?NSControlStateValueOn:NSControlStateValueOff;
    }
    duration.submenu=dur;
    NSMenuItem *floorItem=[self add:L(@"menu.floor") action:nil menu:sm]; NSMenu *flr=[NSMenu new];
    for(NSNumber *n in @[@5,@10,@15,@20,@30,@50]) {
        NSMenuItem *i=[self add:[NSString stringWithFormat:@"%ld%%",(long)n.integerValue] action:@selector(floorChanged:) menu:flr]; i.tag=n.integerValue;
        i.state=i.tag==self.batteryFloor?NSControlStateValueOn:NSControlStateValueOff;
    }
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
    settings.submenu=sm;
    self.authItem=[self add:L(@"auth.off") action:@selector(authAction:) menu:menu];
    [menu addItem:NSMenuItem.separatorItem];
    [self add:L(@"menu.help") action:@selector(help:) menu:menu];
    [menu addItem:NSMenuItem.separatorItem];
    [self add:L(@"menu.quit") action:@selector(quit:) menu:menu];
    self.item.menu=menu;
}
- (void)applicationDidFinishLaunching:(NSNotification *)note {
    NSImage *appIcon=[[NSImage alloc] initWithContentsOfFile:[NSBundle.mainBundle pathForResource:@"AppIcon" ofType:@"icns"]];
    if(appIcon) NSApp.applicationIconImage=appIcon;
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
- (void)durationChanged:(NSMenuItem *)sender {
    [NSUserDefaults.standardUserDefaults setInteger:sender.tag forKey:@"duration"];
    for(NSMenuItem *i in sender.menu.itemArray) i.state=i==sender?NSControlStateValueOn:NSControlStateValueOff;
    if(self.active && self.owned) self.sessionDeadline=sender.tag>0?[NSDate dateWithTimeIntervalSinceNow:sender.tag]:nil;
    [self flush];
    [self log:[NSString stringWithFormat:@"session_duration=%ld",(long)sender.tag]];
    [self tick:nil];
}
- (void)floorChanged:(NSMenuItem *)sender {
    [NSUserDefaults.standardUserDefaults setInteger:sender.tag forKey:@"battery_floor"];
    for(NSMenuItem *i in sender.menu.itemArray) i.state=i==sender?NSControlStateValueOn:NSControlStateValueOff;
    [self flush];
    [self log:[NSString stringWithFormat:@"battery_floor=%ld%%",(long)sender.tag]];
    [self tick:nil];
}
- (void)tick:(id)sender {
    if(self.busy || self.sampling) return;
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
        self.detailItem.title=L(@"state.unknown");
        if(self.owned) [self performAutoStop:@"state_unknown"];
        return;
    }
    BOOL authInstalled=[NSFileManager.defaultManager fileExistsAtPath:@"/etc/sudoers.d/keepclam"];
    self.authItem.title=authInstalled?L(@"auth.on"):L(@"auth.off");
    self.toggleItem.title=enabled?L(@"menu.disable"):L(@"menu.enable");
    self.item.button.title=enabled?@"● KeepClam":@"○ KeepClam";
    self.thermalItem.title=enabled?[NSString stringWithFormat:L(@"menu.thermal"),Thermal()]:L(@"menu.thermal.idle");
    if(self.active && !enabled) { [self flush]; [self log:@"session_ended"]; self.owned=NO; self.lastLog=nil; self.networkTime=nil; self.sessionDeadline=nil; }
    if(!self.active && enabled) [self log:@"session_observed_enabled"];
    self.active=enabled;
    if(enabled && self.owned && kill(self.guardPID,0)!=0 && errno!=EPERM) {
        self.owned=NO; self.sessionDeadline=nil; [self log:@"guard_missing: protection unavailable"];
        [self notify:L(@"notify.guard_missing")];
        // The app outlives the guard and holds the same whitelist, so it retries the restore itself.
        if(!self.busy) { self.busy=YES; self.generation++; dispatch_async(self.worker, ^{
            BOOL restored=SetSleepDisabledNoPrompt(NO);
            dispatch_async(dispatch_get_main_queue(), ^{
                self.busy=NO;
                if(restored) [self log:@"guard_missing_restored"];
                else {
                    [self log:@"guard_missing_restore_failed: sudo -n pmset could not restore sleep"];
                    [self notify:L(@"notify.guard_missing_fail")];
                }
            });
        }); }
        return;
    }
    if(!enabled) self.detailItem.title=L(@"menu.detail.idle");
    else if(self.owned && self.sessionDeadline) self.detailItem.title=[NSString stringWithFormat:L(@"menu.detail.session.timed"),FormatInterval([self.sessionDeadline timeIntervalSinceNow],LangIndex())];
    else if(self.owned) self.detailItem.title=L(@"menu.detail.session.open");
    else self.detailItem.title=L(@"menu.detail.external");
    if(enabled && self.owned) {
        BOOL onAC=NO; NSInteger batt=BatteryPercent(&onAC);
        NSString *reason=AutoStopReason(batt,onAC,NSProcessInfo.processInfo.isLowPowerModeEnabled,self.batteryFloor,self.sessionDeadline,NSDate.date);
        if(reason) { [self performAutoStop:reason]; return; }
    }
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
- (void)performAutoStop:(NSString *)reason {
    if(self.busy) return;
    self.busy=YES; self.generation++;
    [self flush];
    [self log:[NSString stringWithFormat:@"auto_stop=%@",reason]];
    NSString *text;
    if([reason isEqualToString:@"timer"]) text=L(@"notify.autostop.timer");
    else if([reason isEqualToString:@"battery_floor"]) text=[NSString stringWithFormat:L(@"notify.autostop.battery"),(long)self.batteryFloor];
    else if([reason isEqualToString:@"state_unknown"]) text=L(@"state.unknown");
    else text=L(@"notify.autostop.lowpower");
    // Guard teardown can block for tens of seconds; keep it off the main thread so the menu stays responsive.
    dispatch_async(self.worker, ^{
        int r=StopGuardNoPrompt();
        BOOL restored=Enabled()==SleepOff;
        dispatch_async(dispatch_get_main_queue(), ^{
            self.owned=NO; self.active=NO; self.sessionDeadline=nil; self.lastLog=nil; self.networkTime=nil;
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
        a.informativeText=[NSString stringWithFormat:L(@"auth.installed.view.body"),[self ruleText]];
        [a runModal]; return;
    }
    NSString *cmd=[NSString stringWithFormat:@"tmp=$(/usr/bin/mktemp); trap '/bin/rm -f \"$tmp\"' EXIT; /usr/bin/printf '%%s\\n' %@ > \"$tmp\" && /usr/sbin/visudo -cf \"$tmp\" >/dev/null && /usr/bin/install -m 0440 -o root -g wheel \"$tmp\" /etc/sudoers.d/keepclam",Quote([self ruleText])];
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
        BOOL onAC=NO; BatteryPercent(&onAC);
        NSString *problem=(!onAC && NSProcessInfo.processInfo.isLowPowerModeEnabled)?@"toggle.lowpower":nil;
        if(NSProcessInfo.processInfo.thermalState<0 || NSProcessInfo.processInfo.thermalState>=2) problem=@"toggle.hot";
        if(problem) { NSAlert *a=[NSAlert new]; a.messageText=L(problem); [a runModal]; return; }
    }
    self.busy=YES; self.generation++;
    dispatch_async(self.worker, ^{
        pid_t pid=-1; BOOL ok=NO; NSString *problem=nil;
        if(enable) {
            if(SetSleepDisabled(YES)) {
                pid=StartGuard(getpid()); ok=pid>0;
                if(!ok) problem=SetSleepDisabled(NO)?@"toggle.fail.guard.body":@"toggle.restorefail.body";
            } else problem=@"toggle.fail.pmset.body";
        } else { ok=StopGuard()==0; if(!ok) problem=@"toggle.restorefail.body"; }
        dispatch_async(dispatch_get_main_queue(), ^{
            self.busy=NO;
            if(ok) {
                [self flush]; self.owned=enable; self.active=enable;
                self.guardPID=enable?pid:0;
                self.sessionDeadline=enable && self.sessionDuration>0?[NSDate dateWithTimeIntervalSinceNow:self.sessionDuration]:nil;
                [self log:enable?@"session_enabled_guard_confirmed":@"session_disabled"];
                if(enable) { [self requestNotifyAuth]; if(![self sudoersFilePresent]) [self offerAuthInstallGuide]; }
            } else { NSAlert *a=[NSAlert new]; a.messageText=L(@"alert.title"); a.informativeText=L(problem); [a runModal]; }
            [self tick:nil];
        });
    });
}
- (void)logs:(id)sender { [self flush]; [NSWorkspace.sharedWorkspace openURL:[NSURL fileURLWithPath:self.logPath]]; }
- (void)help:(id)sender {
    NSAlert *a=[NSAlert new]; a.messageText=@"KeepClam";
    NSImage *appIcon=[[NSImage alloc] initWithContentsOfFile:[NSBundle.mainBundle pathForResource:@"AppIcon" ofType:@"icns"]];
    if(appIcon) a.icon=appIcon;
    a.informativeText=L(@"help.body");
    [a addButtonWithTitle:L(@"help.close")];
    [a addButtonWithTitle:L(@"help.github")];
    if([a runModal]==NSAlertSecondButtonReturn)
        [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:@"https://github.com/LCROSSY/KeepClam"]];
}
- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender {
    if(self.busy) return NSTerminateCancel;
    self.busy=YES; self.generation++;
    dispatch_async(self.worker, ^{
        BOOL ok=StopGuard()==0;
        dispatch_async(dispatch_get_main_queue(), ^{
            self.busy=NO;
            if(ok) { [self flush]; if(self.active) [self log:@"session_ended_application_quit"]; }
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
