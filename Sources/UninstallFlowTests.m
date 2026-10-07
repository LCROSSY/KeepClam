// Integration tests for the asynchronous uninstall coordinator. Every system
// operation is replaced; only fixture files beneath /private/tmp are removed.
#define main ApplicationMain
#import "App.m"
#undef main

#define CHECK(...) do { if(!(__VA_ARGS__)) { fprintf(stderr,"FAILED line %d: %s\n",__LINE__,#__VA_ARGS__); return 1; } } while(0)

@interface UninstallFixture : App <NSMenuItemValidation>
@property NSString *fixtureRoot;
@property NSString *fixtureHome;
@property NSString *fixtureApp;
@property NSString *fixtureBundleID;
@property NSString *fixtureBrew;
@property NSMutableArray<NSString *> *events;
@property int restoreResult;
@property BOOL loginFails;
@property BOOL authorizationFails;
@property BOOL deleteFails;
@property BOOL done;
@property BOOL succeeded;
@property BOOL sleepRestored;
@property NSString *failure;
@property NSDate *fixtureDeadline;
@property NSUInteger unsafeCalls;
@property int fixtureInstanceFD;
@property BOOL useRealAuthorization;
@property BOOL resumeAfterFailure;
@property NSString *fixtureAuthorization;
@property BOOL runtimeFails;
@property NSString *remaining;
@property NSInteger damageAppOnDelete;
@property NSString *brokenApplication;
@property BOOL exerciseProductionRecoveryMethods;
@property NSUInteger refreshLoginCalls;
@property BOOL translocated;
@end

@implementation UninstallFixture
- (void)record:(NSString *)event { @synchronized(self.events) { [self.events addObject:event]; } }
- (NSString *)uninstallAppPath { return self.fixtureApp; }
- (NSString *)uninstallHome { return self.fixtureHome; }
- (NSString *)uninstallBundleID { return self.fixtureBundleID; }
- (NSString *)uninstallBrewForApp:(NSString *)path {
    [self record:@"brew-check"];
    if(![path isEqual:self.fixtureApp]) self.unsafeCalls++;
    return self.fixtureBrew;
}
- (int)uninstallRestoreSleep { [self record:@"restore-sleep"]; return self.restoreResult; }
- (BOOL)uninstallUnregisterLogin:(NSError **)error {
    [self record:@"unregister-login"];
    if(self.loginFails) return UninstallFailure(error,self.fixtureApp,@"fixture login unregister failed",EIO);
    return YES;
}
- (BOOL)uninstallRemoveAuthorization:(NSError **)error {
    [self record:@"remove-authorization"];
    if(self.useRealAuthorization) return [super uninstallRemoveAuthorization:error];
    if(self.authorizationFails) return UninstallFailure(error,self.fixtureApp,@"fixture administrator cancelled",-128);
    return YES;
}
- (NSString *)uninstallAuthorizationPath { return self.fixtureAuthorization; }
- (BOOL)uninstallAdminCommand:(NSString *)command error:(NSError **)error {
    if(self.useRealAuthorization) {
        [self record:@"admin-command"];
        // Never request privileges. Only the exact production script for our
        // private fixture rule runs, unprivileged, after emulating root's read access.
        if(![command isEqual:[self uninstallAuthorizationCommand:self.fixtureAuthorization]] || [command containsString:@"/etc/sudoers"]) {
            self.unsafeCalls++;
            return UninstallFailure(error,self.fixtureAuthorization,@"Unexpected privileged fixture command",EINVAL);
        }
        if(self.authorizationFails) return UninstallFailure(error,self.fixtureAuthorization,@"fixture administrator cancelled",-128);
        struct stat st;
        if(lstat(self.fixtureAuthorization.fileSystemRepresentation,&st)==0 && S_ISREG(st.st_mode) &&
           chmod(self.fixtureAuthorization.fileSystemRepresentation,0600)!=0)
            return UninstallFailure(error,self.fixtureAuthorization,@"Cannot emulate fixture rule access",errno);
        int status=-1;
        NSString *output=RunLimit(@"/bin/sh",@[@"-c",command],10,&status);
        if(status==0) return YES;
        // do shell script reports a failing command's exit status as its error number.
        if(error) *error=[NSError errorWithDomain:UninstallErrorDomain code:status userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:@"fixture command exited %d: %@",status,output]}];
        return NO;
    }
    self.unsafeCalls++;
    return UninstallFailure(error,self.fixtureApp,@"Unexpected administrator command in fixture",EACCES);
}
- (void)uninstallClearPreferences:(NSString *)bundleID {
    [self record:@"clear-preferences"];
    if(![bundleID isEqual:self.fixtureBundleID]) self.unsafeCalls++;
    // The real filesystem cleanup below removes the fixture preference file.
    // Do not mutate standardUserDefaults or the real preferences daemon.
}
- (NSArray<NSError *> *)uninstallRemoveData:(NSString *)home bundleID:(NSString *)bundleID {
    [self record:@"remove-data"];
    if(![home isEqual:self.fixtureHome] || ![bundleID isEqual:self.fixtureBundleID]) {
        self.unsafeCalls++;
        return @[[NSError errorWithDomain:UninstallErrorDomain code:EINVAL userInfo:@{NSLocalizedDescriptionKey:@"Unexpected fixture data scope"}]];
    }
    return UninstallRemoveUserDataPreservingRuntime(home,bundleID);
}
- (BOOL)fixtureLockIsExclusive {
    NSString *path=[self.fixtureHome stringByAppendingPathComponent:@"Library/Application Support/KeepClam/app.lock"];
    struct stat held,current;
    if(self.fixtureInstanceFD<0 || fstat(self.fixtureInstanceFD,&held)!=0 || lstat(path.fileSystemRepresentation,&current)!=0 ||
       held.st_dev!=current.st_dev || held.st_ino!=current.st_ino) return NO;
    int competitor=open(path.fileSystemRepresentation,O_RDWR|O_NOFOLLOW|O_CLOEXEC);
    if(competitor<0) return NO;
    BOOL locked=flock(competitor,LOCK_EX|LOCK_NB)!=0 && (errno==EWOULDBLOCK || errno==EAGAIN);
    close(competitor); return locked;
}
- (BOOL)uninstallDeleteApp:(NSString *)path bundleID:(NSString *)bundleID brew:(NSString *)brew error:(NSError **)error {
    [self record:brew ? @"delete-brew-app" : @"delete-app"];
    if(![path isEqual:self.fixtureApp] || ![bundleID isEqual:self.fixtureBundleID] ||
       (brew && ![brew isEqual:self.fixtureBrew]) || ![self fixtureLockIsExclusive]) {
        self.unsafeCalls++;
        return UninstallFailure(error,path,@"Unexpected fixture application scope",EINVAL);
    }
    if(self.deleteFails) return UninstallFailure(error,path,@"fixture bundle delete failed",EACCES);
    if(self.damageAppOnDelete) {
        BOOL changed=self.damageAppOnDelete==1 ?
            [NSFileManager.defaultManager removeItemAtPath:[path stringByAppendingPathComponent:@"Contents/Info.plist"] error:nil] :
            UninstallRemoveApp(path,bundleID,error);
        if(!changed) return NO;
        return UninstallFailure(error,path,@"fixture app changed before delete failure",EIO);
    }
    // Exercise real bundle validation and deletion without executing Homebrew.
    return UninstallRemoveApp(path,bundleID,error);
}
- (BOOL)uninstallRemoveRuntime:(NSString *)home error:(NSError **)error {
    [self record:@"remove-runtime"];
    if(![home isEqual:self.fixtureHome] || [NSFileManager.defaultManager fileExistsAtPath:self.fixtureApp]) {
        self.unsafeCalls++;
        return UninstallFailure(error,home,@"Runtime cleanup occurred before application deletion",EINVAL);
    }
    if(self.runtimeFails) return UninstallFailure(error,home,@"fixture final runtime cleanup failed",EACCES);
    return UninstallRemoveRuntimeData(home,error);
}
- (void)uninstallClearNotifications { [self record:@"clear-notifications"]; }
- (BOOL)uninstallAppIsTranslocated:(NSString *)path { return self.translocated; }
- (BOOL)fixtureProductionTranslocated:(NSString *)path { return [super uninstallAppIsTranslocated:path]; }
- (void)uninstallRefused:(NSString *)message { [self record:@"refused"]; self.failure=message; }
- (void)uninstallFailed:(NSString *)message sleepRestored:(BOOL)restored {
    [self record:@"failed"];
    self.failure=message; self.sleepRestored=restored;
    if(self.resumeAfterFailure) [self uninstallResumeAfterFailure];
    else { self.uninstalling=NO; self.busy=NO; }
    self.done=YES;
}
- (BOOL)uninstallRestoreRuntime:(NSError **)error { [self record:@"restore-runtime"]; return [super uninstallRestoreRuntime:error]; }
- (void)uninstallInitializeDefaults { [self record:@"initialize-defaults"]; }
- (void)buildMenu { [self record:@"build-menu"]; }
- (void)tick:(id)sender {
    if(self.exerciseProductionRecoveryMethods) [super tick:sender];
    else [self record:@"tick"];
}
- (void)refreshLogin { self.refreshLoginCalls++; }
- (void)fixtureProductionMenuWillOpen:(NSMenu *)menu { [super menuWillOpen:menu]; }
- (void)uninstallRemaining:(NSString *)message { [self record:@"remaining"]; self.remaining=message; }
- (BOOL)uninstallAppStillUsable:(NSString *)path bundleID:(NSString *)bundleID {
    [self record:@"verify-app-usable"];
    // These fixture executables are deliberately unsigned text files. Test the
    // real structural validation without invoking codesign on fake executables.
    return UninstallValidateApp(path,bundleID,NULL);
}
- (void)uninstallBrokenApplication:(NSString *)message {
    [self record:@"broken-application"];
    self.brokenApplication=message; self.uninstallRecoveryOnly=YES;
    if(![self fixtureLockIsExclusive]) self.unsafeCalls++;
    [self uninstallClearNotifications]; [self uninstallFinished];
}
- (void)uninstallFinished { [self record:@"finished"]; self.succeeded=self.brokenApplication==nil; self.done=YES; }
- (void)fixtureTimerFired:(NSTimer *)timer { self.unsafeCalls++; }
- (void)setSessionDeadline:(NSDate *)deadline { self.fixtureDeadline=deadline; }
- (NSDate *)sessionDeadline { return self.fixtureDeadline; }
- (void)endSessionWithReason:(NSString *)reason {
    [self record:@"end-session"];
    self.owned=NO; self.fixtureDeadline=nil; self.guardPID=0;
}
- (void)flush { [self record:@"flush"]; [super flush]; }
@end

static BOOL FixtureWrite(NSString *path,NSString *contents) {
    if(![NSFileManager.defaultManager createDirectoryAtPath:path.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil]) return NO;
    return [contents writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
}
static NSString *FixturePath(UninstallFixture *app,NSString *relative) {
    return [app.fixtureHome stringByAppendingPathComponent:relative];
}
static BOOL FixtureExists(NSString *path) { return [NSFileManager.defaultManager fileExistsAtPath:path]; }
static UninstallFixture *NewFixture(void) {
    UninstallFixture *app=[UninstallFixture new];
    app.fixtureRoot=[@"/private/tmp" stringByAppendingPathComponent:[@"keepclam-flow-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    app.fixtureHome=[app.fixtureRoot stringByAppendingPathComponent:@"home"];
    app.fixtureApp=[app.fixtureRoot stringByAppendingPathComponent:@"KeepClam.app"];
    app.fixtureBundleID=@"io.github.keepclam.uninstall-fixture";
    app.fixtureAuthorization=[app.fixtureRoot stringByAppendingPathComponent:@"authorization/keepclam"];
    app.fixtureInstanceFD=-1;
    app.events=[NSMutableArray array];
    app.worker=dispatch_queue_create("io.github.keepclam.uninstall-flow-fixture",DISPATCH_QUEUE_SERIAL);
    app.detailItem=[NSMenuItem new]; app.thermalItem=[NSMenuItem new]; app.recoveryItem=[NSMenuItem new];
    app.active=YES; app.owned=YES;
    if(!FixtureWrite([app.fixtureApp stringByAppendingPathComponent:@"Contents/MacOS/KeepClam"],@"fixture executable\n")) return nil;
    chmod([[app.fixtureApp stringByAppendingPathComponent:@"Contents/MacOS/KeepClam"] fileSystemRepresentation],0700);
    NSDictionary *info=@{@"CFBundleIdentifier":app.fixtureBundleID,@"CFBundleExecutable":@"KeepClam",@"CFBundlePackageType":@"APPL"};
    NSData *plist=[NSPropertyListSerialization dataWithPropertyList:info format:NSPropertyListXMLFormat_v1_0 options:0 error:nil];
    if(![plist writeToFile:[app.fixtureApp stringByAppendingPathComponent:@"Contents/Info.plist"] atomically:YES]) return nil;
    NSArray *files=@[@"Library/Logs/KeepClam/运行日志.log",@"Library/Application Support/KeepClam/guard.lock",
        [NSString stringWithFormat:@"Library/Preferences/%@.plist",app.fixtureBundleID],
        [NSString stringWithFormat:@"Library/Preferences/ByHost/%@.12345678-1234-1234-1234-123456789ABC.plist",app.fixtureBundleID],
        [NSString stringWithFormat:@"Library/Caches/%@/cache",app.fixtureBundleID],
        [NSString stringWithFormat:@"Library/Saved Application State/%@.savedState/state",app.fixtureBundleID],
        @"Library/Preferences/unrelated.app.plist",@"Library/Logs/LidAwake/preserved.log"];
    for(NSString *file in files) if(!FixtureWrite(FixturePath(app,file),@"fixture data\n")) return nil;
    app.fixtureInstanceFD=InstanceLock(FixturePath(app,@"Library/Application Support/KeepClam/app.lock"));
    if(app.fixtureInstanceFD<0) return nil;
    return app;
}
static BOOL WaitForFixture(UninstallFixture *app) {
    NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:5];
    while(!app.done && deadline.timeIntervalSinceNow>0)
        [[NSRunLoop mainRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    return app.done;
}
static BOOL AwaitAuthorizationFixture(UninstallFixture *app,NSError **failure) {
    __block BOOL removed=NO;
    __block NSError *error=nil;
    app.done=NO;
    dispatch_async(app.worker,^{
        removed=[app uninstallRemoveAuthorization:&error];
        dispatch_async(dispatch_get_main_queue(),^{ app.done=YES; });
    });
    WaitForFixture(app);
    if(failure) *failure=error;
    return removed;
}
static void DestroyFixture(UninstallFixture *app) {
    [app.timer invalidate];
    if(app.worker) dispatch_sync(app.worker,^{});
    if(app.logFD>=0) { close(app.logFD); app.logFD=-1; }
    if(app.fixtureInstanceFD>=0) { close(app.fixtureInstanceFD); app.fixtureInstanceFD=-1; }
    [NSFileManager.defaultManager removeItemAtPath:app.fixtureRoot error:nil];
}
static BOOL FixtureUserDataExists(UninstallFixture *app) {
    return FixtureExists(FixturePath(app,@"Library/Logs/KeepClam/运行日志.log")) &&
        FixtureExists(FixturePath(app,@"Library/Application Support/KeepClam/guard.lock")) &&
        FixtureExists(FixturePath(app,[NSString stringWithFormat:@"Library/Preferences/%@.plist",app.fixtureBundleID]));
}

int main(void) {
    @autoreleasepool {
        // Normal and Homebrew routes both preserve ordering. All system actions
        // are mocked, while bundle and user-file cleanup use the actual core.
        for(NSNumber *isBrew in @[@NO,@YES]) {
            UninstallFixture *app=NewFixture(); CHECK(app);
            if(isBrew.boolValue) app.fixtureBrew=@"/private/tmp/fixture-brew-never-executed";
            NSString *log=FixturePath(app,@"Library/Logs/KeepClam/运行日志.log");
            app.logPath=log;
            app.logFD=open(log.fileSystemRepresentation,O_WRONLY|O_CLOEXEC);
            CHECK(app.logFD>=0);
            NSTimer *timer=[NSTimer scheduledTimerWithTimeInterval:60 target:app selector:@selector(fixtureTimerFired:) userInfo:nil repeats:YES];
            app.timer=timer;
            [app log:@"queued before uninstall"];
            NSUInteger generation=app.generation;
            [app startUninstall];
            CHECK(app.uninstalling && app.busy && app.generation==generation+1);
            CHECK(!timer.valid && app.timer==nil);
            CHECK(![app validateMenuItem:[NSMenuItem new]]);
            [app log:@"must not recreate the deleted log"];
            CHECK(WaitForFixture(app)); CHECK(app.succeeded && app.unsafeCalls==0);
            NSArray *expected=@[@"brew-check",@"flush",@"restore-sleep",@"end-session",@"unregister-login",@"remove-authorization",@"clear-preferences",@"remove-data",isBrew.boolValue?@"delete-brew-app":@"delete-app",@"remove-runtime",@"clear-notifications",@"finished"];
            CHECK([app.events isEqual:expected]); CHECK(app.logFD==-1);
            CHECK(!FixtureExists(app.fixtureApp)); CHECK(!FixtureUserDataExists(app));
            CHECK(!FixtureExists(FixturePath(app,@"Library/Logs/KeepClam")));
            CHECK(!FixtureExists(FixturePath(app,@"Library/Application Support/KeepClam")));
            CHECK(!FixtureExists(FixturePath(app,[NSString stringWithFormat:@"Library/Caches/%@",app.fixtureBundleID])));
            CHECK(!FixtureExists(FixturePath(app,[NSString stringWithFormat:@"Library/Saved Application State/%@.savedState",app.fixtureBundleID])));
            CHECK(!FixtureExists(FixturePath(app,[NSString stringWithFormat:@"Library/Preferences/ByHost/%@.12345678-1234-1234-1234-123456789ABC.plist",app.fixtureBundleID])));
            CHECK(FixtureExists(FixturePath(app,@"Library/Preferences/unrelated.app.plist")));
            CHECK(FixtureExists(FixturePath(app,@"Library/Logs/LidAwake/preserved.log")));
            DestroyFixture(app);
        }
        // A restore failure cannot unregister login, remove authorization, or
        // touch any user files. Cover both guard-stuck and sleep-unknown results.
        for(NSNumber *result in @[@2,@3]) {
            UninstallFixture *app=NewFixture(); CHECK(app); app.restoreResult=result.intValue;
            [app startUninstall]; CHECK(WaitForFixture(app));
            CHECK(!app.succeeded && !app.sleepRestored && app.failure.length && app.unsafeCalls==0);
            CHECK([app.events isEqual:@[@"brew-check",@"flush",@"restore-sleep",@"failed"]]);
            CHECK(FixtureExists(app.fixtureApp) && FixtureUserDataExists(app));
            DestroyFixture(app);
        }
        UninstallFixture *app=NewFixture(); CHECK(app); app.loginFails=YES;
        [app startUninstall]; CHECK(WaitForFixture(app));
        CHECK(!app.succeeded && app.sleepRestored && [app.failure containsString:@"fixture login unregister failed"]);
        CHECK([app.events isEqual:@[@"brew-check",@"flush",@"restore-sleep",@"end-session",@"unregister-login",@"failed"]]);
        CHECK(FixtureExists(app.fixtureApp) && FixtureUserDataExists(app) && app.unsafeCalls==0);
        DestroyFixture(app);

        // Cancelling the administrator prompt retains application and user data.
        app=NewFixture(); CHECK(app); app.authorizationFails=YES;
        [app startUninstall]; CHECK(WaitForFixture(app));
        CHECK(!app.succeeded && app.sleepRestored && [app.failure containsString:@"fixture administrator cancelled"]);
        CHECK([app.events isEqual:@[@"brew-check",@"flush",@"restore-sleep",@"end-session",@"unregister-login",@"remove-authorization",@"failed"]]);
        CHECK(FixtureExists(app.fixtureApp) && FixtureUserDataExists(app) && app.unsafeCalls==0);
        DestroyFixture(app);

        // An unsafe user-data target yields a real partial-cleanup error. The
        // app is retained and its symlink target remains completely untouched.
        app=NewFixture(); CHECK(app);
        NSString *logs=FixturePath(app,@"Library/Logs/KeepClam");
        CHECK([NSFileManager.defaultManager removeItemAtPath:logs error:nil]);
        NSString *sentinel=[app.fixtureRoot stringByAppendingPathComponent:@"unrelated/sentinel"];
        CHECK(FixtureWrite(sentinel,@"must survive\n"));
        CHECK([NSFileManager.defaultManager createSymbolicLinkAtPath:logs withDestinationPath:sentinel.stringByDeletingLastPathComponent error:nil]);
        [app startUninstall]; CHECK(WaitForFixture(app));
        CHECK(!app.succeeded && app.sleepRestored && [app.failure containsString:@"symbolic-link"]);
        CHECK([app.events isEqual:@[@"brew-check",@"flush",@"restore-sleep",@"end-session",@"unregister-login",@"remove-authorization",@"clear-preferences",@"remove-data",@"failed"]]);
        CHECK(FixtureExists(app.fixtureApp)); CHECK(FixtureExists(sentinel));
        CHECK(FixtureExists(FixturePath(app,@"Library/Application Support/KeepClam")));
        CHECK([app fixtureLockIsExclusive]);
        CHECK(app.unsafeCalls==0); DestroyFixture(app);

        // Failure of the final application-removal step surfaces its error and
        // retains the app after the completed user-data cleanup.
        app=NewFixture(); CHECK(app); app.deleteFails=YES;
        [app startUninstall]; CHECK(WaitForFixture(app));
        CHECK(!app.succeeded && app.sleepRestored && [app.failure containsString:@"fixture bundle delete failed"]);
        CHECK([app.events isEqual:@[@"brew-check",@"flush",@"restore-sleep",@"end-session",@"unregister-login",@"remove-authorization",@"clear-preferences",@"remove-data",@"delete-app",@"verify-app-usable",@"failed"]]);
        CHECK(FixtureExists(app.fixtureApp) && !FixtureUserDataExists(app) && app.unsafeCalls==0);
        CHECK([app fixtureLockIsExclusive]);
        DestroyFixture(app);

        // If application removal partly succeeds before reporting an error,
        // neither a damaged bundle nor a vanished bundle may resume operation.
        for(NSNumber *damage in @[@1,@2]) {
            app=NewFixture(); CHECK(app); app.damageAppOnDelete=damage.integerValue; app.resumeAfterFailure=YES;
            [app startUninstall]; CHECK(WaitForFixture(app));
            CHECK(!app.succeeded && app.uninstallRecoveryOnly && app.brokenApplication.length);
            CHECK([app.brokenApplication containsString:@"fixture app changed before delete failure"]);
            CHECK([app.brokenApplication containsString:app.fixtureApp]);
            CHECK([app.brokenApplication containsString:FixturePath(app,@"Library/Application Support/KeepClam")]);
            CHECK([app.events isEqual:@[@"brew-check",@"flush",@"restore-sleep",@"end-session",@"unregister-login",@"remove-authorization",@"clear-preferences",@"remove-data",@"delete-app",@"verify-app-usable",@"broken-application",@"clear-notifications",@"finished"]]);
            CHECK(![app.events containsObject:@"restore-runtime"] && ![app.events containsObject:@"initialize-defaults"]);
            CHECK(!FixtureExists(FixturePath(app,@"Library/Logs/KeepClam")) && [app fixtureLockIsExclusive]);
            CHECK(app.timer==nil && app.unsafeCalls==0);
            CHECK(FixtureExists(app.fixtureApp)==(damage.integerValue==1));
            DestroyFixture(app);
        }

        // Returning from a partial uninstall recreates the log directory and
        // resumes ordinary operation without replacing the held instance lock.
        app=NewFixture(); CHECK(app); app.deleteFails=YES; app.resumeAfterFailure=YES;
        app.logPath=FixturePath(app,@"Library/Logs/KeepClam/运行日志.log");
        [app startUninstall]; CHECK(WaitForFixture(app));
        CHECK(!app.succeeded && !app.uninstallRecoveryOnly && !app.uninstalling && !app.busy);
        CHECK(FixtureExists(app.fixtureApp) && [app fixtureLockIsExclusive]);
        CHECK(FixtureExists(FixturePath(app,@"Library/Logs/KeepClam")));
        CHECK(app.timer.valid && [app.events containsObject:@"initialize-defaults"] && [app.events containsObject:@"build-menu"]);
        [app log:@"resumed fixture logging"]; [app flush];
        CHECK([[NSString stringWithContentsOfFile:app.logPath encoding:NSUTF8StringEncoding error:nil] containsString:@"resumed fixture logging"]);
        CHECK(app.unsafeCalls==0); DestroyFixture(app);

        // Recovery refuses redirected log ancestors and leaf directories. Only
        // uninstall, quit, and help remain available until the unsafe path is fixed.
        for(NSString *relative in @[@"Library/Logs",@"Library/Logs/KeepClam"]) {
            app=NewFixture(); CHECK(app);
            NSString *redirected=FixturePath(app,relative);
            CHECK([NSFileManager.defaultManager removeItemAtPath:redirected error:nil]);
            NSString *outside=[app.fixtureRoot stringByAppendingPathComponent:@"outside-logs/sentinel"];
            CHECK(FixtureWrite(outside,@"must survive recovery\n"));
            CHECK([NSFileManager.defaultManager createSymbolicLinkAtPath:redirected withDestinationPath:outside.stringByDeletingLastPathComponent error:nil]);
            app.uninstalling=YES; app.busy=YES;
            [app uninstallResumeAfterFailure];
            CHECK(app.uninstallRecoveryOnly && !app.uninstalling && !app.busy && app.timer==nil);
            CHECK([app.events isEqual:@[@"restore-runtime"]]);
            CHECK(FixtureExists(outside) && [app fixtureLockIsExclusive]);
            CHECK([NSFileManager.defaultManager contentsOfDirectoryAtPath:outside.stringByDeletingLastPathComponent error:nil].count==1);
            NSMenuItem *item=[NSMenuItem new];
            for(NSString *action in @[@"uninstall:",@"quit:",@"help:"]) {
                item.action=NSSelectorFromString(action); CHECK([app validateMenuItem:item]);
            }
            for(NSString *action in @[@"toggle:",@"loginChanged:",@"authAction:",@"interval:",@"language:"]) {
                item.action=NSSelectorFromString(action); CHECK(![app validateMenuItem:item]);
            }
            // Exercise the actual tick and menu delegate while recovery-only is
            // set. No kernel sampling, warning rewrite or logging may restart.
            NSString *detail=app.detailItem.title,*recovery=app.recoveryItem.title;
            app.active=NO; app.owned=NO; app.exerciseProductionRecoveryMethods=YES;
            [app tick:nil]; CHECK(!app.sampling);
            [app fixtureProductionMenuWillOpen:[NSMenu new]]; CHECK(!app.sampling);
            CHECK(app.refreshLoginCalls==1);
            CHECK([app.detailItem.title isEqual:detail] && [app.recoveryItem.title isEqual:recovery]);
            app.logPath=[redirected stringByAppendingPathComponent:@"sentinel"];
            [app log:@"recovery logging must remain stopped"];
            dispatch_sync(app.worker,^{ [app writeLine:@"recovery direct writer must remain stopped\n"]; });
            CHECK([[NSString stringWithContentsOfFile:outside encoding:NSUTF8StringEncoding error:nil] isEqual:@"must survive recovery\n"]);
            CHECK([NSFileManager.defaultManager contentsOfDirectoryAtPath:outside.stringByDeletingLastPathComponent error:nil].count==1);
            CHECK(app.unsafeCalls==0); DestroyFixture(app);
        }

        // A final runtime-cleanup failure is reported after the app disappears;
        // the coordinator still clears notifications and completes the exit.
        app=NewFixture(); CHECK(app); app.runtimeFails=YES;
        [app startUninstall]; CHECK(WaitForFixture(app));
        CHECK(app.succeeded && !FixtureExists(app.fixtureApp) && [app.remaining containsString:@"fixture final runtime cleanup failed"]);
        CHECK([app fixtureLockIsExclusive] && [app.events containsObject:@"remaining"] && app.unsafeCalls==0);
        DestroyFixture(app);

        // Readable 0440 and unreadable 000 rules both reach the privileged
        // comparison. The production path is exercised with our mock admin step.
        for(NSNumber *mode in @[@0440,@0000]) {
            app=NewFixture(); CHECK(app); app.useRealAuthorization=YES;
            CHECK(FixtureWrite(app.fixtureAuthorization,[[app ruleText] stringByAppendingString:@"\n"]));
            CHECK(chmod(app.fixtureAuthorization.fileSystemRepresentation,mode.intValue)==0);
            if(mode.intValue==0 && geteuid()!=0)
                CHECK([NSString stringWithContentsOfFile:app.fixtureAuthorization encoding:NSUTF8StringEncoding error:nil]==nil);
            NSError *failure=nil;
            BOOL removed=AwaitAuthorizationFixture(app,&failure); CHECK(app.done);
            CHECK(removed && !failure && !FixtureExists(app.fixtureAuthorization));
            CHECK([app.events isEqual:@[@"remove-authorization",@"admin-command"]] && app.unsafeCalls==0);
            DestroyFixture(app);
        }
        app=NewFixture(); CHECK(app); app.useRealAuthorization=YES; app.authorizationFails=YES;
        CHECK(FixtureWrite(app.fixtureAuthorization,[[app ruleText] stringByAppendingString:@"\n"]));
        CHECK(chmod(app.fixtureAuthorization.fileSystemRepresentation,0000)==0);
        NSError *failure=nil;
        CHECK(!AwaitAuthorizationFixture(app,&failure)); CHECK(app.done);
        CHECK(failure && FixtureExists(app.fixtureAuthorization));
        CHECK([app.events isEqual:@[@"remove-authorization",@"admin-command"]] && app.unsafeCalls==0);
        DestroyFixture(app);
        // The privileged comparison also protects an unreadable modified rule.
        app=NewFixture(); CHECK(app); app.useRealAuthorization=YES;
        CHECK(FixtureWrite(app.fixtureAuthorization,@"changed fixture authorization\n"));
        CHECK(chmod(app.fixtureAuthorization.fileSystemRepresentation,0000)==0);
        failure=nil;
        CHECK(!AwaitAuthorizationFixture(app,&failure)); CHECK(app.done);
        CHECK(failure && FixtureExists(app.fixtureAuthorization) && app.unsafeCalls==0);
        CHECK([failure.localizedDescription containsString:L(@"uninstall.sudoers.changed")]);
        if(geteuid()!=0) CHECK([app.events isEqual:@[@"remove-authorization",@"admin-command"]]);
        DestroyFixture(app);
        // A rule removed while the prompt was open counts as removed.
        app=NewFixture(); CHECK(app); app.useRealAuthorization=YES;
        CHECK([NSFileManager.defaultManager createDirectoryAtPath:app.fixtureAuthorization.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil]);
        CHECK([app uninstallAdminCommand:[app uninstallAuthorizationCommand:app.fixtureAuthorization] error:&failure]);
        CHECK(app.unsafeCalls==0); DestroyFixture(app);

        // The privileged script itself: run unprivileged against private fixtures,
        // including a path that needs quoting. 3 means changed or not a regular file.
        app=NewFixture(); CHECK(app);
        NSString *rule=[app.fixtureRoot stringByAppendingPathComponent:@"rules/it's keep clam"];
        NSString *ruleTarget=[app.fixtureRoot stringByAppendingPathComponent:@"rules/target"];
        int (^runScript)(void)=^int{ int status=-1; RunLimit(@"/bin/sh",@[@"-c",[app uninstallAuthorizationCommand:rule]],10,&status); return status; };
        CHECK(FixtureWrite(ruleTarget,[[app ruleText] stringByAppendingString:@"\n"]));
        CHECK(runScript()==0); // missing
        CHECK(symlink(ruleTarget.fileSystemRepresentation,rule.fileSystemRepresentation)==0);
        CHECK(runScript()==UninstallAuthorizationChangedStatus && FixtureExists(ruleTarget));
        CHECK(unlink(rule.fileSystemRepresentation)==0);
        CHECK(FixtureWrite(rule,[[app ruleText] stringByAppendingString:@" # extra\n"]));
        CHECK(runScript()==UninstallAuthorizationChangedStatus && FixtureExists(rule));
        CHECK(FixtureWrite(rule,[[app ruleText] stringByAppendingString:@"\n"]));
        CHECK(runScript()==0 && !FixtureExists(rule) && FixtureExists(ruleTarget));
        DestroyFixture(app);

        // AppleScript failures keep their error number and gain a readable prefix.
        app=NewFixture(); CHECK(app);
        NSError *adminError=[app uninstallAdminError:@{NSAppleScriptErrorNumber:@-128,NSAppleScriptErrorMessage:@"User canceled."}];
        CHECK(adminError.code==-128 && [adminError.localizedDescription isEqual:[NSString stringWithFormat:L(@"uninstall.admin.failed"),@"User canceled."]]);
        CHECK([app uninstallAdminError:@{}].localizedDescription.length>0);
        DestroyFixture(app);

        // A FIFO must be rejected by its type before any read or administrator
        // step. A bounded worker wait makes accidental blocking fail the test.
        app=NewFixture(); CHECK(app); app.useRealAuthorization=YES;
        CHECK([NSFileManager.defaultManager createDirectoryAtPath:app.fixtureAuthorization.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil]);
        CHECK(mkfifo(app.fixtureAuthorization.fileSystemRepresentation,0600)==0);
        failure=nil;
        CHECK(!AwaitAuthorizationFixture(app,&failure)); CHECK(app.done);
        CHECK(failure && [app.events isEqual:@[@"remove-authorization"]] && app.unsafeCalls==0);
        DestroyFixture(app);

        // A translocated copy is refused before any state, setting or file changes.
        app=NewFixture(); CHECK(app); app.translocated=YES;
        [app startUninstall];
        CHECK([app.events isEqual:@[@"refused"]] && [app.failure isEqual:L(@"uninstall.translocated")]);
        CHECK(!app.busy && !app.uninstalling && app.generation==0 && app.unsafeCalls==0);
        CHECK(FixtureExists(app.fixtureApp) && FixtureUserDataExists(app));
        CHECK(![app fixtureProductionTranslocated:app.fixtureApp]);
        CHECK([app fixtureProductionTranslocated:@"/private/var/folders/zz/T/AppTranslocation/0000/d/KeepClam.app"]);
        DestroyFixture(app);

        // A busy or already-uninstalling application cannot begin another flow.
        for(NSNumber *uninstalling in @[@NO,@YES]) {
            app=NewFixture(); CHECK(app);
            app.busy=!uninstalling.boolValue; app.uninstalling=uninstalling.boolValue;
            [app startUninstall];
            CHECK(app.events.count==0 && !app.done && app.generation==0);
            CHECK(![app validateMenuItem:[NSMenuItem new]]);
            CHECK(FixtureExists(app.fixtureApp) && FixtureUserDataExists(app));
            app.busy=NO; app.uninstalling=NO;
            CHECK([app validateMenuItem:[NSMenuItem new]]);
            DestroyFixture(app);
        }
        puts("Uninstall coordinator fixture tests passed");
    }
    return 0;
}
