#define main ApplicationMain
#import "App.m"
#undef main
#define CHECK(x) do { if(!(x)) { fprintf(stderr,"FAILED: %s\n",#x); return 1; } } while(0)
int main(void) {
    @autoreleasepool {
        NSString *dir=[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        App *app=[App new]; app.logPath=[dir stringByAppendingPathComponent:@"test.log"];
        app.worker=dispatch_queue_create("test.log",DISPATCH_QUEUE_SERIAL);
        NSDate *start=[NSDate dateWithTimeIntervalSince1970:1000];
        for(int i=0;i<180;i++) [app sample:@"lid=closed network_cached=reachable thermal=nominal" at:[start dateByAddingTimeInterval:i*5]];
        CHECK(app.count==180);
        [app flush];
        NSString *text=[NSString stringWithContentsOfFile:app.logPath encoding:NSUTF8StringEncoding error:nil];
        CHECK([text containsString:@"samples=180"] && [text containsString:@"max_gap=5.0s"]);
        CHECK([text componentsSeparatedByString:@"\n"].count==2);
        [app sample:@"lid=open thermal=nominal" at:[start dateByAddingTimeInterval:910]];
        [app sample:@"lid=closed thermal=nominal" at:[start dateByAddingTimeInterval:915]];
        CHECK(app.count==1);
        [app sample:@"network_cached=failed thermal=nominal" at:[start dateByAddingTimeInterval:920]];
        CHECK(app.count==0);
        text=[NSString stringWithContentsOfFile:app.logPath encoding:NSUTF8StringEncoding error:nil];
        CHECK([text containsString:@"failed"]);
        NSMutableData *large=[NSMutableData dataWithLength:1024*1024+1];
        [large writeToFile:app.logPath atomically:YES]; Append(app.logPath,@"new\n");
        CHECK([NSFileManager.defaultManager fileExistsAtPath:[app.logPath stringByAppendingString:@".1"]]);
        CHECK([[NSString stringWithContentsOfFile:app.logPath encoding:NSUTF8StringEncoding error:nil] isEqual:@"new\n"]);
        // The resident fd survives an external inode swap and rotation, and stays 0600.
        [large writeToFile:app.logPath atomically:YES];
        [app log:@"rotated"];
        [app flush];
        CHECK([NSFileManager.defaultManager fileExistsAtPath:[app.logPath stringByAppendingString:@".1"]]);
        text=[NSString stringWithContentsOfFile:app.logPath encoding:NSUTF8StringEncoding error:nil];
        CHECK([text containsString:@"rotated"]);
        struct stat rmode; CHECK(stat(app.logPath.fileSystemRepresentation,&rmode)==0);
        CHECK((rmode.st_mode & 0777)==0600);

        // Unknown reads must never be reported as successfully disabled.
        CHECK(DecodeSleepState(NULL)==SleepUnknown);
        CHECK(DecodeSleepState(CFSTR("false"))==SleepUnknown);
        CHECK(DecodeSleepState(kCFBooleanFalse)==SleepOff);
        CHECK(DecodeSleepState(kCFBooleanTrue)==SleepOn);
        // Tighten existing files, not only newly created ones.
        chmod(app.logPath.fileSystemRepresentation,0644);
        Append(app.logPath,@"private\n");
        struct stat mode; CHECK(stat(app.logPath.fileSystemRepresentation,&mode)==0);
        CHECK((mode.st_mode & 0777)==0600);
        CHECK(PrivateDirectory(dir)); CHECK(stat(dir.fileSystemRepresentation,&mode)==0);
        CHECK((mode.st_mode & 0777)==0700);
        NSString *lockPath=[dir stringByAppendingPathComponent:@"app.lock"];
        int first=InstanceLock(lockPath); CHECK(first>=0);
        CHECK(InstanceLock(lockPath)<0); // A second launch cannot own the session.
        CHECK((fcntl(first,F_GETFD)&FD_CLOEXEC)!=0); // Guard exec cannot inherit the app lock.
        close(first); int replacement=InstanceLock(lockPath); CHECK(replacement>=0); close(replacement);
        struct proc_bsdinfo identity={0};
        CHECK(proc_pidinfo(getpid(),PROC_PIDTBSDINFO,0,&identity,sizeof(identity))==sizeof(identity));
        CHECK(GuardIdentityMatches(getpid(),identity.pbi_start_tvsec,identity.pbi_start_tvusec));
        CHECK(!GuardIdentityMatches(getpid(),identity.pbi_start_tvsec+1,identity.pbi_start_tvusec));
        CHECK(!GuardIdentityMatches(0,0,0));
        // Liveness requires the recorded identity, not mere PID existence (zombies, PID reuse).
        app.guardPID=getpid(); app.guardStartSec=identity.pbi_start_tvsec; app.guardStartUsec=identity.pbi_start_tvusec;
        CHECK([app guardIsAlive]);
        app.guardStartSec=identity.pbi_start_tvsec+1;
        CHECK(![app guardIsAlive]); // A same-user process that reused the PID is not the guard.
        app.guardPID=0;
        CHECK(![app guardIsAlive]);
        // The PROC exit source reaps the exited child: no zombie is left behind.
        app.owned=NO; app.active=NO; app.busy=NO; // never self-heal (never run pmset) in tests
        pid_t victim=fork();
        if(victim==0) _exit(0);
        CHECK(victim>0);
        usleep(200000); // let the child exit and linger as a zombie
        app.guardPID=victim;
        [app watchGuardExit];
        NSDate *giveUp=[NSDate dateWithTimeIntervalSinceNow:5];
        while(app.guardProcSource && [giveUp timeIntervalSinceNow]>0)
            [[NSRunLoop mainRunLoop] runMode:NSDefaultRunLoopMode beforeDate:giveUp];
        CHECK(app.guardProcSource==nil);
        errno=0;
        int childStatus=0;
        CHECK(waitpid(victim,&childStatus,WNOHANG)<0 && errno==ECHILD); // handler already reaped it
        // The Run variant surfaces exit codes so tool failures are detectable.
        int runStatus=-1;
        RunLimit(@"/usr/bin/true",@[],10,&runStatus); CHECK(runStatus==0);
        RunLimit(@"/usr/bin/false",@[],10,&runStatus); CHECK(runStatus!=0);

        // Brake decision matrix: BrakeReason(thermal, thermalUnknown, battery, batteryUnknown, onAC, lowPower, floor, deadline, now).
        NSDate *now=[NSDate dateWithTimeIntervalSince1970:10000];
        NSDate *past=[now dateByAddingTimeInterval:-1];
        NSDate *future=[now dateByAddingTimeInterval:600];
        CHECK([BrakeReason(0,0,80,0,YES,NO,20,past,now) isEqual:@"timer"]);
        CHECK(BrakeReason(0,0,80,0,YES,NO,20,future,now)==nil);
        CHECK(BrakeReason(0,0,80,0,NO,NO,20,future,now)==nil);
        CHECK([BrakeReason(0,0,10,0,NO,NO,20,future,now) isEqual:@"battery_floor"]);
        CHECK(BrakeReason(0,0,10,0,YES,NO,20,future,now)==nil);
        CHECK([BrakeReason(0,0,80,0,NO,YES,20,future,now) isEqual:@"low_power_mode"]);
        CHECK(BrakeReason(0,0,80,0,YES,YES,20,future,now)==nil);
        CHECK([BrakeReason(0,0,50,0,NO,NO,50,future,now) isEqual:@"battery_floor"]);
        CHECK(BrakeReason(0,0,51,0,NO,NO,50,future,now)==nil);
        CHECK([BrakeReason(0,0,10,0,NO,YES,20,past,now) isEqual:@"timer"]);
        CHECK(BrakeReason(0,0,80,0,NO,NO,20,nil,now)==nil);
        // Unreadable battery brakes only after three consecutive misses, and never on AC.
        CHECK(BrakeReason(0,0,-1,2,NO,NO,20,nil,now)==nil);
        CHECK([BrakeReason(0,0,-1,3,NO,NO,20,nil,now) isEqual:@"battery_unknown"]);
        CHECK(BrakeReason(0,0,-1,3,YES,NO,20,nil,now)==nil);
        // Thermal outranks every other reason.
        CHECK(BrakeReason(1,0,80,0,YES,NO,20,nil,now)==nil);
        CHECK([BrakeReason(2,0,10,3,NO,YES,20,past,now) isEqual:@"thermal"]);
        CHECK(BrakeReason(-1,2,80,0,YES,NO,20,nil,now)==nil);
        CHECK([BrakeReason(-1,3,10,0,NO,NO,20,past,now) isEqual:@"thermal_unknown"]);
        // Exit codes round-trip; normal stops, startup failures and signals are not brakes.
        for(NSString *r in BrakeReasons()) CHECK([BrakeReasonForExit(W_EXITCODE(BrakeExitCode(r),0)) isEqual:r]);
        CHECK(BrakeReasonForExit(W_EXITCODE(0,0))==nil);
        CHECK(BrakeReasonForExit(W_EXITCODE(3,0))==nil);
        CHECK(BrakeReasonForExit(W_EXITCODE(10+(int)BrakeReasons().count,0))==nil);
        CHECK(BrakeReasonForExit(SIGKILL)==nil);
        // Every brake reason except thermal has its own notification head.
        for(NSString *r in BrakeReasons()) if(![r isEqual:@"thermal"]) CHECK(StringsTable()[[@"brake." stringByAppendingString:r]]!=nil);
        // Session boundaries: teardown clears every per-session field and records the end.
        app.owned=YES; app.active=YES;
        app.sessionDeadline=[NSDate dateWithTimeIntervalSinceNow:60];
        app.lastLog=[NSDate date]; app.networkTime=[NSDate date];
        app.count=2; app.sampleKey=@"lid=closed thermal=nominal";
        app.rangeStart=[NSDate dateWithTimeIntervalSinceNow:-10]; app.rangeEnd=[NSDate date];
        [app endSessionWithReason:@"session_ended"];
        CHECK(app.owned==NO && app.sessionDeadline==nil && app.lastLog==nil && app.networkTime==nil);
        [app flush]; // drain: the end record is queued, not synchronous
        text=[NSString stringWithContentsOfFile:app.logPath encoding:NSUTF8StringEncoding error:nil];
        CHECK([text containsString:@"session_ended"] && [text containsString:@"samples=2"]);
        // A fresh session must not inherit the previous session's throttle or network cache.
        app.lastLog=[NSDate date]; app.networkTime=[NSDate date];
        [app beginSessionWithGuard:0 startSec:0 startUsec:0 deadline:[NSDate dateWithTimeIntervalSinceNow:60]];
        CHECK(app.owned && app.active && app.lastLog==nil && app.networkTime==nil && app.sessionDeadline!=nil);
        [app endSessionWithReason:nil];
        CHECK(app.owned==NO && app.sessionDeadline==nil);
        // Toggle-failure alerts are routed by consequence, not one generic message.
        CHECK([ToggleAlertTitle(NO,2,nil) isEqualToString:@"toggle.guardstuck.title"]);
        CHECK([ToggleAlertTitle(NO,3,nil) isEqualToString:@"toggle.restorefail.title"]);
        CHECK([ToggleAlertTitle(YES,0,@"toggle.fail.guard.body") isEqualToString:@"toggle.fail.guard.title"]);
        CHECK([ToggleAlertTitle(YES,0,@"toggle.restorefail.body") isEqualToString:@"toggle.restorefail.title"]);
        CHECK([ToggleAlertTitle(YES,0,@"toggle.fail.pmset.body") isEqualToString:@"alert.title"]);
        // The stuck-guard outcome means the settings were never touched: no emergency command there.
        CHECK(![Pair(@"toggle.guardstuck.body",1) containsString:@"disablesleep"]);
        CHECK(![Pair(@"toggle.guardstuck.body",2) containsString:@"disablesleep"]);
        // Legacy log-dir migration: move when only the old exists, never touch a live new dir.
        NSString *home=[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        NSString *oldLogs=[home stringByAppendingPathComponent:@"Library/Logs/LidAwake"];
        NSString *newLogs=[home stringByAppendingPathComponent:@"Library/Logs/KeepClam"];
        [NSFileManager.defaultManager createDirectoryAtPath:oldLogs withIntermediateDirectories:YES attributes:nil error:nil];
        CHECK([@"old" writeToFile:[oldLogs stringByAppendingPathComponent:@"legacy.log"] atomically:YES encoding:NSUTF8StringEncoding error:nil]);
        CHECK(MigrateLegacyLogs(home));
        CHECK([NSFileManager.defaultManager fileExistsAtPath:[newLogs stringByAppendingPathComponent:@"legacy.log"]]);
        CHECK(![NSFileManager.defaultManager fileExistsAtPath:oldLogs]);
        CHECK(!MigrateLegacyLogs(home)); // nothing left to move
        [NSFileManager.defaultManager createDirectoryAtPath:oldLogs withIntermediateDirectories:YES attributes:nil error:nil];
        CHECK([@"x" writeToFile:[oldLogs stringByAppendingPathComponent:@"legacy.log"] atomically:YES encoding:NSUTF8StringEncoding error:nil]);
        CHECK([@"sentinel" writeToFile:[newLogs stringByAppendingPathComponent:@"keep.log"] atomically:YES encoding:NSUTF8StringEncoding error:nil]);
        CHECK(!MigrateLegacyLogs(home)); // an existing new directory wins
        NSString *newContent=[NSString stringWithContentsOfFile:[newLogs stringByAppendingPathComponent:@"keep.log"] encoding:NSUTF8StringEncoding error:nil];
        CHECK([newContent isEqual:@"sentinel"]);
        CHECK([NSFileManager.defaultManager fileExistsAtPath:[oldLogs stringByAppendingPathComponent:@"legacy.log"]]);
        // Remaining-time formatting boundaries, both languages.
        CHECK([@"59 分钟" isEqualToString:FormatInterval(59*60.0,1)]);
        CHECK([@"1 小时 0 分" isEqualToString:FormatInterval(60*60.0,1)]);
        CHECK([@"1 分钟" isEqualToString:FormatInterval(30,1)]);
        CHECK([@"59 min" isEqualToString:FormatInterval(59*60.0,2)]);
        CHECK([@"1 h 0 min" isEqualToString:FormatInterval(60*60.0,2)]);
        CHECK([@"1 min" isEqualToString:FormatInterval(30,2)]);
        // Custom setting input: whole numbers inside the range only.
        CHECK(ParseBoundedInteger(@"45",1,1440)==45);
        CHECK(ParseBoundedInteger(@" 5 ",5,95)==5);
        CHECK(ParseBoundedInteger(@"95",5,95)==95);
        CHECK(ParseBoundedInteger(@"4",5,95)==-1);
        CHECK(ParseBoundedInteger(@"96",5,95)==-1);
        CHECK(ParseBoundedInteger(@"",1,1440)==-1);
        CHECK(ParseBoundedInteger(@"1.5",1,1440)==-1);
        CHECK(ParseBoundedInteger(@"20%",5,95)==-1);
        CHECK(ParseBoundedInteger(@"abc",1,1440)==-1);
        // Every localization entry must have non-empty zh and en strings.
        for(NSString *key in StringsTable()) {
            NSArray<NSString *> *pair=StringsTable()[key];
            CHECK(pair.count==2 && pair[0].length>0 && pair[1].length>0);
        }
        // Exercise the live IOKit power-source bridge so malformed CF key usage cannot crash the app.
        BOOL onAC=NO; NSInteger battery=BatteryPercent(&onAC);
        CHECK(battery==-1 || (battery>=0 && battery<=100));
        puts("PASS: aggregation, state changes, immediate errors, rotation, brake reasons, exit codes, power-source read");
    }
    return 0;
}
