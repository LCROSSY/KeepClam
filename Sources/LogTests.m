#define main ApplicationMain
#import "App.m"
#undef main
#define CHECK(x) do { if(!(x)) { fprintf(stderr,"FAILED: %s\n",#x); return 1; } } while(0)
int main(void) {
    @autoreleasepool {
        NSString *dir=[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        App *app=[App new]; app.logPath=[dir stringByAppendingPathComponent:@"test.log"];
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

        // Auto-stop decision matrix.
        NSDate *now=[NSDate dateWithTimeIntervalSince1970:10000];
        NSDate *past=[now dateByAddingTimeInterval:-1];
        NSDate *future=[now dateByAddingTimeInterval:600];
        CHECK([AutoStopReason(80,YES,NO,20,past,now) isEqual:@"timer"]);
        CHECK(AutoStopReason(80,YES,NO,20,future,now)==nil);
        CHECK(AutoStopReason(80,NO,NO,20,future,now)==nil);
        CHECK([AutoStopReason(10,NO,NO,20,future,now) isEqual:@"battery_floor"]);
        CHECK(AutoStopReason(10,YES,NO,20,future,now)==nil);
        CHECK([AutoStopReason(80,NO,YES,20,future,now) isEqual:@"low_power_mode"]);
        CHECK(AutoStopReason(80,YES,YES,20,future,now)==nil);
        CHECK(AutoStopReason(-1,NO,NO,20,future,now)==nil);
        CHECK([AutoStopReason(50,NO,NO,50,future,now) isEqual:@"battery_floor"]);
        CHECK(AutoStopReason(51,NO,NO,50,future,now)==nil);
        CHECK([AutoStopReason(10,NO,YES,20,past,now) isEqual:@"timer"]);
        CHECK(AutoStopReason(80,NO,NO,20,nil,now)==nil);
        // Remaining-time formatting boundaries, both languages.
        CHECK([@"59 分钟" isEqualToString:FormatInterval(59*60.0,1)]);
        CHECK([@"1 小时 0 分" isEqualToString:FormatInterval(60*60.0,1)]);
        CHECK([@"1 分钟" isEqualToString:FormatInterval(30,1)]);
        CHECK([@"59 min" isEqualToString:FormatInterval(59*60.0,2)]);
        CHECK([@"1 h 0 min" isEqualToString:FormatInterval(60*60.0,2)]);
        CHECK([@"1 min" isEqualToString:FormatInterval(30,2)]);
        // Every localization entry must have non-empty zh and en strings.
        for(NSString *key in StringsTable()) {
            NSArray<NSString *> *pair=StringsTable()[key];
            CHECK(pair.count==2 && pair[0].length>0 && pair[1].length>0);
        }
        // Exercise the live IOKit power-source bridge so malformed CF key usage cannot crash the app.
        BOOL onAC=NO; NSInteger battery=BatteryPercent(&onAC);
        CHECK(battery==-1 || (battery>=0 && battery<=100));
        puts("PASS: aggregation, state changes, immediate errors, rotation, auto-stop reasons, power-source read");
    }
    return 0;
}
