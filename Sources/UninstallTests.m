#import "Uninstall.m"
#import <sys/file.h>
#define CHECK(x) do { if(!(x)) { fprintf(stderr,"FAILED line %d: %s\n",__LINE__,#x); return 1; } } while(0)
static NSString *const TestBundleID=@"io.github.LCROSSY.keepclam.fixture";
static BOOL FixtureDirectory(NSString *path) {
    return [NSFileManager.defaultManager createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:nil];
}
static BOOL FixtureFile(NSString *path,NSString *content) {
    return FixtureDirectory(path.stringByDeletingLastPathComponent) &&
        [content writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
}
static BOOL FixtureApp(NSString *path,NSString *bundleID,NSString *executable) {
    NSString *infoPath=[path stringByAppendingPathComponent:@"Contents/Info.plist"];
    NSString *execPath=[path stringByAppendingPathComponent:@"Contents/MacOS/KeepClam"];
    if(!FixtureFile(execPath,@"fixture executable\n") || chmod(execPath.fileSystemRepresentation,0700)!=0) return NO;
    NSDictionary *info=@{@"CFBundleIdentifier":bundleID,@"CFBundleExecutable":executable,@"CFBundlePackageType":@"APPL"};
    return [info writeToFile:infoPath atomically:YES];
}
static BOOL FixtureExists(NSString *path) { return [NSFileManager.defaultManager fileExistsAtPath:path]; }
static BOOL FixtureSymlink(NSString *path,NSString *destination) {
    return FixtureDirectory(path.stringByDeletingLastPathComponent) && symlink(destination.fileSystemRepresentation,path.fileSystemRepresentation)==0;
}
int main(void) {
    @autoreleasepool {
        // Every mutation remains below this private temporary fixture directory.
        NSString *root=[@"/private/tmp" stringByAppendingPathComponent:[@"keepclam-uninstall-" stringByAppendingString:NSUUID.UUID.UUIDString]];
        CHECK(FixtureDirectory(root));
        NSString *outside=[root stringByAppendingPathComponent:@"unrelated"];
        NSString *sentinel=[outside stringByAppendingPathComponent:@"preserve me.txt"];
        CHECK(FixtureFile(sentinel,@"untouched"));
        NSError *error=nil;
        CHECK(UninstallBundleIDIsValid(TestBundleID));
        CHECK(UninstallBundleIDIsValid(@"io.github.KeepClam-tests"));
        for(NSString *bad in @[@"",@"io",@".keepclam",@"io..keepclam",@"io.keepclam.",@"io/keepclam",@"io.keepclam/../../escape",@"io.keep clam",@"io.keepclam\n"]) {
            CHECK(!UninstallBundleIDIsValid(bad));
            CHECK(UninstallUserCleanupPaths(root,bad,&error)==nil && error!=nil);
        }
        CHECK(UninstallUserCleanupPaths(@"/",TestBundleID,&error)==nil && error);
        CHECK(UninstallUserCleanupPaths(@"/Users",TestBundleID,&error)==nil && error);
        CHECK(UninstallUserCleanupPaths([root stringByAppendingString:@"/../escape"],TestBundleID,&error)==nil && error);
        CHECK(!UninstallValidateApp(@"/",TestBundleID,&error) && error);
        CHECK(!UninstallValidateApp(@"/KeepClam.app",TestBundleID,&error) && error);
        CHECK(!UninstallValidateApp(@"/System/KeepClam.app",TestBundleID,&error) && error);
        CHECK(!UninstallValidateApp(outside,TestBundleID,&error) && error);

        // A renamed bundle and spaces in the path are safe; unrelated files survive.
        NSString *app=[root stringByAppendingPathComponent:@"My KeepClam Copy.app"];
        CHECK(FixtureApp(app,TestBundleID,@"KeepClam"));
        CHECK(UninstallValidateApp(app,TestBundleID,&error) && error==nil);
        CHECK(FixtureSymlink([app stringByAppendingPathComponent:@"Contents/external logs"],outside));
        CHECK(UninstallRemoveApp(app,TestBundleID,&error) && error==nil);
        CHECK(!FixtureExists(app) && FixtureExists(sentinel));
        CHECK(!UninstallRemoveApp(app,TestBundleID,&error) && error); // missing package is not a validated app

        NSString *wrong=[root stringByAppendingPathComponent:@"Wrong.app"];
        CHECK(FixtureApp(wrong,@"org.example.other",@"KeepClam"));
        CHECK(!UninstallRemoveApp(wrong,TestBundleID,&error) && error && FixtureExists(wrong));
        CHECK(FixtureApp(wrong,TestBundleID,@"OtherProgram"));
        CHECK(!UninstallRemoveApp(wrong,TestBundleID,&error) && error && FixtureExists(wrong));
        CHECK(FixtureApp(wrong,TestBundleID,@"KeepClam"));
        NSString *wrongExec=[wrong stringByAppendingPathComponent:@"Contents/MacOS/KeepClam"];
        CHECK(chmod(wrongExec.fileSystemRepresentation,0600)==0);
        CHECK(!UninstallValidateApp(wrong,TestBundleID,&error) && error);
        CHECK(chmod(wrongExec.fileSystemRepresentation,0700)==0);
        CHECK(unlink(wrongExec.fileSystemRepresentation)==0 && FixtureSymlink(wrongExec,sentinel));
        CHECK(!UninstallValidateApp(wrong,TestBundleID,&error) && error && FixtureExists(sentinel));
        CHECK(unlink(wrongExec.fileSystemRepresentation)==0 && FixtureApp(wrong,TestBundleID,@"KeepClam"));

        // Identity files and bundle ancestors may never redirect to another tree.
        NSString *alias=[root stringByAppendingPathComponent:@"Alias.app"];
        CHECK(FixtureSymlink(alias,wrong));
        CHECK(!UninstallValidateApp(alias,TestBundleID,&error) && error);
        CHECK(!UninstallRemoveApp(alias,TestBundleID,&error) && error && FixtureExists(wrong));
        NSString *parentAlias=[root stringByAppendingPathComponent:@"linked parent"];
        CHECK(FixtureSymlink(parentAlias,root));
        CHECK(!UninstallValidateApp([parentAlias stringByAppendingPathComponent:@"Wrong.app"],TestBundleID,&error) && error);
        NSString *infoPath=[wrong stringByAppendingPathComponent:@"Contents/Info.plist"];
        NSString *foreignInfo=[outside stringByAppendingPathComponent:@"Info.plist"];
        CHECK([NSFileManager.defaultManager copyItemAtPath:infoPath toPath:foreignInfo error:nil]);
        CHECK(unlink(infoPath.fileSystemRepresentation)==0 && FixtureSymlink(infoPath,foreignInfo));
        CHECK(!UninstallValidateApp(wrong,TestBundleID,&error) && error && FixtureExists(foreignInfo));
        CHECK(unlink(infoPath.fileSystemRepresentation)==0 && FixtureApp(wrong,TestBundleID,@"KeepClam"));
        CHECK(unlink(infoPath.fileSystemRepresentation)==0 && mkfifo(infoPath.fileSystemRepresentation,0600)==0);
        CHECK(!UninstallValidateApp(wrong,TestBundleID,&error) && error); // a FIFO cannot block validation
        CHECK(unlink(infoPath.fileSystemRepresentation)==0 && FixtureApp(wrong,TestBundleID,@"KeepClam"));

        // A package replacement after identity verification is refused by inode.
        BOOL missing=NO;
        int held=UninstallOpenDirectory(wrong,&missing,&error);
        CHECK(held>=0);
        struct stat identity; CHECK(fstat(held,&identity)==0);
        NSString *moved=[root stringByAppendingPathComponent:@"original moved.app"];
        CHECK([NSFileManager.defaultManager moveItemAtPath:wrong toPath:moved error:nil]);
        CHECK(FixtureApp(wrong,@"org.example.replacement",@"KeepClam"));
        CHECK(!UninstallRemovePathExpected(wrong,&identity,&error) && error);
        CHECK(FixtureExists(wrong) && FixtureExists(moved));
        CHECK(FixtureApp(wrong,TestBundleID,@"KeepClam"));
        CHECK(UninstallValidateApp(wrong,TestBundleID,&error)); // same claimed bundle identity, different package inode
        CHECK(!UninstallRemoveAppExpected(wrong,TestBundleID,(uint64_t)identity.st_dev,(uint64_t)identity.st_ino,&error) && error.code==ESTALE);
        CHECK(FixtureExists(wrong) && FixtureExists(moved)); close(held);
        struct stat replacement; CHECK(lstat(wrong.fileSystemRepresentation,&replacement)==0);
        CHECK(!UninstallRemoveAppExpected(wrong,TestBundleID,(uint64_t)replacement.st_dev+1,(uint64_t)replacement.st_ino,&error));
        CHECK(UninstallRemoveAppExpected(wrong,TestBundleID,(uint64_t)replacement.st_dev,(uint64_t)replacement.st_ino,&error));
        CHECK(!FixtureExists(wrong));

        // Only explicitly owned folders and this exact preferences domain disappear.
        NSString *home=[root stringByAppendingPathComponent:@"user home with spaces"];
        CHECK(FixtureDirectory(home));
        NSArray *paths=UninstallUserCleanupPaths(home,TestBundleID,&error);
        CHECK(paths.count==5 && error==nil);
        for(NSString *path in paths) {
            if([path.pathExtension isEqual:@"plist"]) CHECK(FixtureFile(path,@"fixture preference"));
            else CHECK(FixtureFile([path stringByAppendingPathComponent:@"owned.txt"],@"owned"));
        }
        NSString *logs=[home stringByAppendingPathComponent:@"Library/Logs/KeepClam"];
        CHECK(FixtureSymlink([logs stringByAppendingPathComponent:@"external directory"],outside));
        NSString *otherLog=[home stringByAppendingPathComponent:@"Library/Logs/OtherApp/keep.txt"];
        NSString *otherPreferences=[home stringByAppendingPathComponent:@"Library/Preferences/org.example.other.plist"];
        NSString *legacyLogs=[home stringByAppendingPathComponent:@"Library/Logs/LidAwake/keep.txt"];
        CHECK(FixtureFile(otherLog,@"other") && FixtureFile(otherPreferences,@"other") && FixtureFile(legacyLogs,@"legacy"));
        NSString *hostID=NSUUID.UUID.UUIDString;
        NSString *hostPreference=[home stringByAppendingPathComponent:[NSString stringWithFormat:@"Library/Preferences/ByHost/%@.%@.plist",TestBundleID,hostID]];
        NSString *otherHost=[home stringByAppendingPathComponent:[NSString stringWithFormat:@"Library/Preferences/ByHost/%@.other.%@.plist",TestBundleID,hostID]];
        NSString *malformedHost=[home stringByAppendingPathComponent:[NSString stringWithFormat:@"Library/Preferences/ByHost/%@.not-a-host-id.plist",TestBundleID]];
        CHECK(FixtureFile(hostPreference,@"owned") && FixtureFile(otherHost,@"other domain") && FixtureFile(malformedHost,@"not recognized"));
        CHECK(UninstallRemoveUserData(home,TestBundleID).count==0);
        for(NSString *path in paths) CHECK(!FixtureExists(path));
        CHECK(!FixtureExists(hostPreference) && FixtureExists(otherHost) && FixtureExists(malformedHost));
        CHECK(FixtureExists(otherLog) && FixtureExists(otherPreferences) && FixtureExists(legacyLogs) && FixtureExists(sentinel));
        CHECK(UninstallRemoveUserData(home,TestBundleID).count==0); // idempotent absent files

        // Initial cleanup preserves the same locked inode until the final exit phase.
        NSString *lockedHome=[root stringByAppendingPathComponent:@"locked home"];
        NSString *lockedRuntime=[lockedHome stringByAppendingPathComponent:@"Library/Application Support/KeepClam"];
        NSString *lockPath=[lockedRuntime stringByAppendingPathComponent:@"app.lock"];
        NSString *lockedLog=[lockedHome stringByAppendingPathComponent:@"Library/Logs/KeepClam/owned.txt"];
        CHECK(FixtureFile(lockPath,@"") && FixtureFile(lockedLog,@"owned"));
        int lock=open(lockPath.fileSystemRepresentation,O_RDWR|O_NOFOLLOW|O_CLOEXEC);
        CHECK(lock>=0 && flock(lock,LOCK_EX|LOCK_NB)==0);
        struct stat lockedIdentity; CHECK(fstat(lock,&lockedIdentity)==0);
        CHECK(UninstallRemoveUserDataPreservingRuntime(lockedHome,TestBundleID).count==0);
        CHECK(FixtureExists(lockPath) && !FixtureExists(lockedLog));
        int contender=open(lockPath.fileSystemRepresentation,O_CREAT|O_RDWR|O_NOFOLLOW|O_CLOEXEC,0600);
        CHECK(contender>=0 && flock(contender,LOCK_EX|LOCK_NB)!=0);
        struct stat contenderIdentity; CHECK(fstat(contender,&contenderIdentity)==0);
        CHECK(contenderIdentity.st_dev==lockedIdentity.st_dev && contenderIdentity.st_ino==lockedIdentity.st_ino);
        close(contender);
        CHECK(UninstallRemoveRuntimeData(lockedHome,&error) && !FixtureExists(lockedRuntime)); close(lock);
        CHECK(UninstallRemoveRuntimeData(lockedHome,&error)); // absent runtime is already clean
        CHECK(!UninstallRemoveRuntimeData(@"/",&error) && error);

        // Recover missing runtime leaves without changing shared ancestor permissions.
        NSString *libraryParent=[lockedHome stringByAppendingPathComponent:@"Library"];
        NSString *logsParent=[lockedHome stringByAppendingPathComponent:@"Library/Logs"];
        NSString *supportParent=[lockedHome stringByAppendingPathComponent:@"Library/Application Support"];
        CHECK(chmod(libraryParent.fileSystemRepresentation,0751)==0 && chmod(logsParent.fileSystemRepresentation,0755)==0 && chmod(supportParent.fileSystemRepresentation,0750)==0);
        CHECK(UninstallPrepareRuntimeDirectories(lockedHome,&error) && error==nil);
        struct stat permissions;
        CHECK(stat(libraryParent.fileSystemRepresentation,&permissions)==0 && (permissions.st_mode & 0777)==0751);
        CHECK(stat(logsParent.fileSystemRepresentation,&permissions)==0 && (permissions.st_mode & 0777)==0755);
        CHECK(stat(supportParent.fileSystemRepresentation,&permissions)==0 && (permissions.st_mode & 0777)==0750);
        NSString *ownedLogs=[logsParent stringByAppendingPathComponent:@"KeepClam"];
        CHECK(stat(ownedLogs.fileSystemRepresentation,&permissions)==0 && (permissions.st_mode & 0777)==0700);
        CHECK(stat(lockedRuntime.fileSystemRepresentation,&permissions)==0 && (permissions.st_mode & 0777)==0700);
        CHECK(chmod(ownedLogs.fileSystemRepresentation,0777)==0 && UninstallPrepareRuntimeDirectories(lockedHome,&error));
        CHECK(stat(ownedLogs.fileSystemRepresentation,&permissions)==0 && (permissions.st_mode & 0777)==0700);
        CHECK([NSFileManager.defaultManager removeItemAtPath:ownedLogs error:nil]);
        CHECK(FixtureSymlink(ownedLogs,outside));
        CHECK(!UninstallPrepareRuntimeDirectories(lockedHome,&error) && error && FixtureExists(sentinel));
        CHECK(!FixtureExists([outside stringByAppendingPathComponent:@"KeepClam"]));
        CHECK(unlink(ownedLogs.fileSystemRepresentation)==0);
        CHECK([NSFileManager.defaultManager removeItemAtPath:logsParent error:nil]);
        CHECK(FixtureSymlink(logsParent,outside));
        CHECK(!UninstallPrepareRuntimeDirectories(lockedHome,&error) && error && FixtureExists(sentinel));
        CHECK(!FixtureExists([outside stringByAppendingPathComponent:@"KeepClam"]));
        CHECK(!UninstallPrepareRuntimeDirectories(parentAlias,&error) && error && FixtureExists(sentinel));
        CHECK(!UninstallPrepareRuntimeDirectories(@"/",&error) && error);

        // Top-level and ancestor symlinks are reported; independent paths still clean.
        CHECK(FixtureFile([logs stringByAppendingPathComponent:@"remove.txt"],@"owned"));
        NSString *support=[home stringByAppendingPathComponent:@"Library/Application Support/KeepClam"];
        CHECK(FixtureSymlink(support,outside));
        NSString *cache=[home stringByAppendingPathComponent:@"Library/Caches"];
        CHECK([NSFileManager.defaultManager removeItemAtPath:cache error:nil]);
        CHECK(FixtureSymlink(cache,outside));
        NSArray<NSError *> *failures=UninstallRemoveUserData(home,TestBundleID);
        CHECK(failures.count==2);
        CHECK(!FixtureExists(logs) && FixtureExists(sentinel));
        CHECK([failures[0].userInfo[NSFilePathErrorKey] isEqual:support]);
        CHECK([failures[1].userInfo[NSFilePathErrorKey] containsString:@"Library/Caches"]);
        CHECK([failures[0].domain isEqual:UninstallErrorDomain] && failures[0].localizedDescription.length>0);
        failures=UninstallRemoveUserDataPreservingRuntime(home,TestBundleID);
        CHECK(failures.count==2 && [failures[0].userInfo[NSFilePathErrorKey] isEqual:support]);
        CHECK(!UninstallRemoveRuntimeData(home,&error) && [error.userInfo[NSFilePathErrorKey] isEqual:support]);
        CHECK(UninstallRemoveUserDataPreservingRuntime(parentAlias,TestBundleID).count>0);
        CHECK(UninstallRemoveUserData(parentAlias,TestBundleID).count>0);
        CHECK(FixtureExists(sentinel));
        CHECK(UninstallRemoveUserData(home,@"io/../../escape").count==1);

        // Homebrew moves the app into its appdir and keeps only metadata in the
        // Caskroom. Detection follows that layout, the configured appdir, and the
        // legacy staged link; any other copy is uninstalled directly.
        NSString *prefix=[root stringByAppendingPathComponent:@"homebrew"];
        NSString *brew=[prefix stringByAppendingPathComponent:@"bin/brew"];
        NSString *caskroom=[prefix stringByAppendingPathComponent:@"Caskroom/keepclam"];
        NSString *config=[caskroom stringByAppendingPathComponent:@".metadata/config.json"];
        NSString *appdir=[root stringByAppendingPathComponent:@"Applications"];
        NSString *brewApp=[appdir stringByAppendingPathComponent:@"KeepClam.app"];
        CHECK(FixtureApp(brewApp,TestBundleID,@"KeepClam"));
        CHECK(FixtureFile(brew,@"#!/bin/sh\nexit 1\n") && chmod(brew.fileSystemRepresentation,0755)==0);
        CHECK(UninstallHomebrewForApp(brewApp,@[prefix])==nil); // no Caskroom record
        CHECK(FixtureDirectory([caskroom stringByAppendingPathComponent:@"1.0.0"]));
        NSString *(^configJSON)(NSString *,NSString *)=^(NSString *defaultDir,NSString *explicitDir) {
            NSDictionary *json=@{@"default":@{@"appdir":defaultDir},@"env":@{},@"explicit":explicitDir?@{@"appdir":explicitDir}:@{}};
            return [[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:json options:0 error:nil] encoding:NSUTF8StringEncoding];
        };
        CHECK(FixtureFile(config,configJSON(appdir,nil)));
        CHECK([UninstallHomebrewForApp(brewApp,@[[root stringByAppendingPathComponent:@"missing"],prefix]) isEqual:brew]);
        NSString *aliasedApp=[[root stringByAppendingPathComponent:@"Applications/../Applications"] stringByAppendingPathComponent:@"KeepClam.app"];
        CHECK([UninstallHomebrewForApp(aliasedApp,@[prefix]) isEqual:brew]); // compared after resolving
        NSString *copy=[appdir stringByAppendingPathComponent:@"KeepClam Copy.app"];
        CHECK(FixtureApp(copy,TestBundleID,@"KeepClam"));
        CHECK(UninstallHomebrewForApp(copy,@[prefix])==nil);
        NSString *otherDir=[root stringByAppendingPathComponent:@"Explicit Apps"];
        NSString *explicitApp=[otherDir stringByAppendingPathComponent:@"KeepClam.app"];
        CHECK(FixtureApp(explicitApp,TestBundleID,@"KeepClam"));
        CHECK(FixtureFile(config,configJSON(appdir,otherDir)));
        CHECK([UninstallHomebrewForApp(explicitApp,@[prefix]) isEqual:brew]);
        CHECK(UninstallHomebrewForApp(brewApp,@[prefix])==nil); // explicit appdir wins over default
        CHECK(FixtureFile(config,@"{not json"));
        CHECK(UninstallHomebrewForApp(brewApp,@[prefix])==nil); // falls back to /Applications
        CHECK(FixtureSymlink([caskroom stringByAppendingPathComponent:@"1.0.0/KeepClam.app"],brewApp));
        CHECK([UninstallHomebrewForApp(brewApp,@[prefix]) isEqual:brew]); // legacy staged link
        CHECK(chmod(brew.fileSystemRepresentation,0644)==0);
        CHECK(UninstallHomebrewForApp(brewApp,@[prefix])==nil); // brew must be executable
        CHECK(UninstallHomebrewForApp([root stringByAppendingPathComponent:@"Missing.app"],@[prefix])==nil);

        CHECK([NSFileManager.defaultManager removeItemAtPath:root error:nil]);
        puts("PASS: scoped uninstall, bundle identity, symlink refusal, no-follow cleanup, expected inode, runtime lock retention and recovery, partial errors, unrelated-file preservation, Homebrew detection");
    }
    return 0;
}
