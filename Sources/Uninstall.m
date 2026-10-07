#ifndef KEEPCLAM_UNINSTALL_CORE_INCLUDED
#define KEEPCLAM_UNINSTALL_CORE_INCLUDED
#import <Foundation/Foundation.h>
#import <sys/stat.h>
#import <fcntl.h>
#import <dirent.h>
#import <unistd.h>
#import <errno.h>
#import <string.h>

// Included by App.m and the fixture-only tests. No shell, privilege escalation,
// power changes, defaults-cache mutation or login-item changes happen here.
static NSString *const UninstallErrorDomain=@"io.github.keepclam.uninstall";
static BOOL UninstallFailure(NSError **error,NSString *path,NSString *reason,int code) {
    if(error) {
        NSMutableDictionary *info=[NSMutableDictionary dictionaryWithDictionary:@{
            NSLocalizedDescriptionKey:[NSString stringWithFormat:@"%@: %@",reason,path ?: @""],
            NSFilePathErrorKey:path ?: @""
        }];
        if(code) info[NSUnderlyingErrorKey]=[NSError errorWithDomain:NSPOSIXErrorDomain code:code userInfo:nil];
        *error=[NSError errorWithDomain:UninstallErrorDomain code:code ?: EINVAL userInfo:info];
    }
    return NO;
}
static BOOL UninstallBundleIDIsValid(NSString *bundleID) {
    if(![bundleID isKindOfClass:NSString.class] || bundleID.length>255) return NO;
    NSArray *parts=[bundleID componentsSeparatedByString:@"."];
    if(parts.count<2) return NO;
    NSCharacterSet *allowed=[NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-"];
    for(NSString *part in parts) {
        if(!part.length || [part rangeOfCharacterFromSet:allowed.invertedSet].location!=NSNotFound) return NO;
    }
    return YES;
}
static BOOL UninstallPathIsCanonical(NSString *path) {
    if(![path isKindOfClass:NSString.class] || !path.isAbsolutePath || path.length<=1 ||
       [path hasSuffix:@"/"] || [path containsString:@"//"] ||
       [path rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location!=NSNotFound) return NO;
    // Foundation can shorten existing /private/var paths back to /var. Validate
    // lexical components instead; the descriptor walker checks real ancestors.
    for(NSString *part in [path componentsSeparatedByString:@"/"])
        if([part isEqual:@"."] || [part isEqual:@".."]) return NO;
    return YES;
}
static BOOL UninstallPathIsProtected(NSString *path) {
    for(NSString *root in @[@"/System",@"/Library",@"/bin",@"/sbin",@"/usr",@"/etc",@"/private/etc",@"/private/var/db"])
        if([path isEqual:root] || [path hasPrefix:[root stringByAppendingString:@"/"]]) return YES;
    return NO;
}

// Walk each ancestor with O_NOFOLLOW, so a substituted symlink cannot redirect a
// cleanup outside its declared tree. A missing ancestor is an already-clean path.
static int UninstallOpenDirectory(NSString *path,BOOL *missing,NSError **error) {
    if(missing) *missing=NO;
    if(!UninstallPathIsCanonical(path)) {
        UninstallFailure(error,path,@"Invalid cleanup path",EINVAL); return -1;
    }
    int fd=open("/",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
    if(fd<0) { UninstallFailure(error,path,@"Cannot open filesystem root",errno); return -1; }
    NSArray *parts=path.pathComponents;
    for(NSUInteger i=1;i<parts.count;i++) {
        int next=openat(fd,[parts[i] fileSystemRepresentation],O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
        int saved=errno; close(fd);
        if(next<0) {
            if(saved==ENOENT && missing) *missing=YES;
            else UninstallFailure(error,path,@"Cannot safely open directory (symlinks are refused)",saved);
            return -1;
        }
        fd=next;
    }
    return fd;
}
static NSData *UninstallReadRegularFile(int directory,NSString *name,NSString *path,NSError **error) {
    int fd=openat(directory,name.fileSystemRepresentation,O_RDONLY|O_NOFOLLOW|O_CLOEXEC|O_NONBLOCK);
    if(fd<0) { UninstallFailure(error,path,@"Cannot safely read bundle identity",errno); return nil; }
    struct stat st;
    if(fstat(fd,&st)!=0 || !S_ISREG(st.st_mode) || st.st_size<0 || st.st_size>1024*1024) {
        close(fd); UninstallFailure(error,path,@"Bundle identity must be a small regular file",EINVAL); return nil;
    }
    NSMutableData *data=[NSMutableData data];
    unsigned char bytes[4096];
    for(;;) {
        ssize_t n=read(fd,bytes,sizeof(bytes));
        if(n<0 && errno==EINTR) continue;
        if(n<0) { int saved=errno; close(fd); UninstallFailure(error,path,@"Cannot read bundle identity",saved); return nil; }
        if(!n) break;
        if(data.length+(NSUInteger)n>1024*1024) { close(fd); UninstallFailure(error,path,@"Bundle identity is too large",EFBIG); return nil; }
        [data appendBytes:bytes length:(NSUInteger)n];
    }
    close(fd); return data;
}
static BOOL UninstallAppTargetIsValid(NSString *appPath,NSString *bundleID,NSError **error) {
    if(error) *error=nil;
    if(!UninstallBundleIDIsValid(bundleID) || !UninstallPathIsCanonical(appPath) ||
       ![appPath.pathExtension.lowercaseString isEqual:@"app"] ||
       appPath.pathComponents.count<3 || UninstallPathIsProtected(appPath))
        return UninstallFailure(error,appPath,@"Refused unsafe application target",EINVAL);
    return YES;
}
static BOOL UninstallValidateOpenApp(int app,NSString *appPath,NSString *bundleID,NSError **error) {
    int contents=openat(app,"Contents",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
    if(contents<0) return UninstallFailure(error,appPath,@"Cannot safely open bundle Contents",errno);
    NSString *infoPath=[appPath stringByAppendingPathComponent:@"Contents/Info.plist"];
    NSData *data=UninstallReadRegularFile(contents,@"Info.plist",infoPath,error);
    if(!data) { close(contents); return NO; }
    NSError *parseError=nil;
    id info=[NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:NULL error:&parseError];
    if(![info isKindOfClass:NSDictionary.class] ||
       ![info[@"CFBundleIdentifier"] isKindOfClass:NSString.class] || ![info[@"CFBundleIdentifier"] isEqual:bundleID] ||
       ![info[@"CFBundleExecutable"] isEqual:@"KeepClam"] || ![info[@"CFBundlePackageType"] isEqual:@"APPL"]) {
        close(contents); return UninstallFailure(error,infoPath,@"Application identity does not match KeepClam",EINVAL);
    }
    int macos=openat(contents,"MacOS",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
    int saved=errno; close(contents);
    if(macos<0) return UninstallFailure(error,appPath,@"Cannot safely open bundle executable directory",saved);
    struct stat executable;
    BOOL valid=fstatat(macos,"KeepClam",&executable,AT_SYMLINK_NOFOLLOW)==0 &&
        S_ISREG(executable.st_mode) && (executable.st_mode & 0111)!=0;
    close(macos);
    if(!valid) return UninstallFailure(error,appPath,@"KeepClam executable is missing, non-executable or a symlink",EINVAL);
    return YES;
}

static BOOL UninstallValidateApp(NSString *appPath,NSString *bundleID,NSError **error) {
    if(!UninstallAppTargetIsValid(appPath,bundleID,error)) return NO;
    BOOL missing=NO;
    int app=UninstallOpenDirectory(appPath,&missing,error);
    if(app<0) {
        if(missing) UninstallFailure(error,appPath,@"Application does not exist",ENOENT);
        return NO;
    }
    BOOL valid=UninstallValidateOpenApp(app,appPath,bundleID,error);
    close(app); return valid;
}

// Only direct children of a held directory are removed. Interior symlinks are
// unlinked themselves, never traversed. The inode check detects a replaced folder.
static BOOL UninstallRemoveEntry(int parent,const char *name,NSString *path,BOOL topLevel,const struct stat *expected,NSError **error) {
    struct stat before;
    if(fstatat(parent,name,&before,AT_SYMLINK_NOFOLLOW)!=0) {
        if(errno==ENOENT) return YES;
        return UninstallFailure(error,path,@"Cannot inspect cleanup target",errno);
    }
    if(expected && (before.st_dev!=expected->st_dev || before.st_ino!=expected->st_ino))
        return UninstallFailure(error,path,@"Validated application changed before cleanup",ESTALE);
    if(topLevel && S_ISLNK(before.st_mode)) return UninstallFailure(error,path,@"Refused symbolic-link cleanup target",ELOOP);
    if(!S_ISDIR(before.st_mode)) {
        if(unlinkat(parent,name,0)==0 || errno==ENOENT) return YES;
        return UninstallFailure(error,path,@"Cannot remove file",errno);
    }
    struct stat parentIdentity;
    if(fstat(parent,&parentIdentity)!=0) return UninstallFailure(error,path,@"Cannot inspect cleanup parent",errno);
    if(before.st_dev!=parentIdentity.st_dev)
        return UninstallFailure(error,path,@"Refused mounted-filesystem cleanup target",EBUSY);
    int fd=openat(parent,name,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
    if(fd<0) return UninstallFailure(error,path,@"Cannot safely open cleanup target",errno);
    struct stat opened;
    if(fstat(fd,&opened)!=0 || opened.st_dev!=before.st_dev || opened.st_ino!=before.st_ino) {
        close(fd); return UninstallFailure(error,path,@"Cleanup target changed during inspection",ESTALE);
    }
    DIR *entries=fdopendir(fd);
    if(!entries) { int saved=errno; close(fd); return UninstallFailure(error,path,@"Cannot enumerate cleanup target",saved); }
    BOOL ok=YES;
    for(;;) {
        errno=0;
        struct dirent *entry=readdir(entries);
        if(!entry) {
            if(errno) ok=UninstallFailure(error,path,@"Cannot enumerate cleanup target",errno);
            break;
        }
        if(!strcmp(entry->d_name,".") || !strcmp(entry->d_name,"..")) continue;
        NSString *child=[NSFileManager.defaultManager stringWithFileSystemRepresentation:entry->d_name length:strlen(entry->d_name)];
        if(!UninstallRemoveEntry(dirfd(entries),entry->d_name,[path stringByAppendingPathComponent:child],NO,NULL,error)) { ok=NO; break; }
    }
    closedir(entries);
    if(!ok) return NO;
    struct stat current;
    if(fstatat(parent,name,&current,AT_SYMLINK_NOFOLLOW)!=0) {
        if(errno==ENOENT) return YES;
        return UninstallFailure(error,path,@"Cannot inspect cleaned directory",errno);
    }
    if(!S_ISDIR(current.st_mode) || current.st_dev!=before.st_dev || current.st_ino!=before.st_ino)
        return UninstallFailure(error,path,@"Cleanup target changed before removal",ESTALE);
    if(unlinkat(parent,name,AT_REMOVEDIR)==0 || errno==ENOENT) return YES;
    return UninstallFailure(error,path,@"Cannot remove cleaned directory",errno);
}
static BOOL UninstallRemovePathExpected(NSString *path,const struct stat *expected,NSError **error) {
    if(error) *error=nil;
    BOOL missing=NO;
    int parent=UninstallOpenDirectory(path.stringByDeletingLastPathComponent,&missing,error);
    if(parent<0) return missing;
    BOOL ok=UninstallRemoveEntry(parent,path.lastPathComponent.fileSystemRepresentation,path,YES,expected,error);
    close(parent); return ok;
}
static BOOL UninstallRemovePath(NSString *path,NSError **error) {
    return UninstallRemovePathExpected(path,NULL,error);
}
static BOOL UninstallHomeScopeIsValid(NSString *home,NSError **error) {
    if(error) *error=nil;
    if(!UninstallPathIsCanonical(home) || UninstallPathIsProtected(home) ||
       [@[@"/Users",@"/Applications",@"/private",@"/private/tmp",@"/tmp",@"/Volumes"] containsObject:home])
        return UninstallFailure(error,home,@"Refused unsafe user-data scope",EINVAL);
    return YES;
}
static NSArray<NSString *> *UninstallUserCleanupPaths(NSString *home,NSString *bundleID,NSError **error) {
    if(!UninstallHomeScopeIsValid(home,error)) return nil;
    if(!UninstallBundleIDIsValid(bundleID)) {
        UninstallFailure(error,home,@"Refused unsafe user-data scope",EINVAL); return nil;
    }
    NSArray *relative=@[@"Library/Logs/KeepClam",@"Library/Application Support/KeepClam",
        [NSString stringWithFormat:@"Library/Preferences/%@.plist",bundleID],
        [NSString stringWithFormat:@"Library/Caches/%@",bundleID],
        [NSString stringWithFormat:@"Library/Saved Application State/%@.savedState",bundleID]];
    NSMutableArray *paths=[NSMutableArray array];
    for(NSString *path in relative) [paths addObject:[home stringByAppendingPathComponent:path]];
    return paths;
}
static NSArray<NSString *> *UninstallByHostPreferencePaths(NSString *home,NSString *bundleID,NSError **error) {
    NSString *path=[home stringByAppendingPathComponent:@"Library/Preferences/ByHost"];
    BOOL missing=NO;
    int fd=UninstallOpenDirectory(path,&missing,error);
    if(fd<0) return missing ? @[] : nil;
    DIR *entries=fdopendir(fd);
    if(!entries) { int saved=errno; close(fd); UninstallFailure(error,path,@"Cannot enumerate host preferences",saved); return nil; }
    NSMutableArray *paths=[NSMutableArray array];
    NSString *prefix=[bundleID stringByAppendingString:@"."];
    for(;;) {
        errno=0;
        struct dirent *entry=readdir(entries);
        if(!entry) {
            int saved=errno; closedir(entries);
            if(saved) { UninstallFailure(error,path,@"Cannot enumerate host preferences",saved); return nil; }
            return paths;
        }
        NSString *name=[NSFileManager.defaultManager stringWithFileSystemRepresentation:entry->d_name length:strlen(entry->d_name)];
        if(![name hasPrefix:prefix] || ![name hasSuffix:@".plist"] || name.length<=prefix.length+6) continue;
        NSString *host=[name substringWithRange:NSMakeRange(prefix.length,name.length-prefix.length-6)];
        if([[NSUUID alloc] initWithUUIDString:host]) [paths addObject:[path stringByAppendingPathComponent:name]];
    }
}
static BOOL UninstallValidatePreservedRuntime(NSString *path,NSError **error) {
    BOOL missing=NO;
    int parent=UninstallOpenDirectory(path.stringByDeletingLastPathComponent,&missing,error);
    if(parent<0) return missing;
    int runtime=openat(parent,path.lastPathComponent.fileSystemRepresentation,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
    if(runtime<0) {
        int saved=errno; close(parent);
        if(saved==ENOENT) return YES;
        return UninstallFailure(error,path,@"Cannot safely preserve runtime directory",saved);
    }
    struct stat parentIdentity,runtimeIdentity;
    BOOL ok=fstat(parent,&parentIdentity)==0 && fstat(runtime,&runtimeIdentity)==0;
    int saved=errno; close(runtime); close(parent);
    if(!ok) return UninstallFailure(error,path,@"Cannot inspect runtime directory",saved);
    if(parentIdentity.st_dev!=runtimeIdentity.st_dev)
        return UninstallFailure(error,path,@"Refused mounted-filesystem runtime directory",EBUSY);
    return YES;
}
// Every failure is returned, including partial cleanup; absent items are success.
// Preserve the app.lock directory while approval prompts or Homebrew can still
// delay termination, so a second copy cannot acquire a newly recreated lock.
static NSArray<NSError *> *UninstallRemoveUserDataWithRuntimePolicy(NSString *home,NSString *bundleID,BOOL preserveRuntime) {
    NSError *error=nil;
    NSArray *fixed=UninstallUserCleanupPaths(home,bundleID,&error);
    if(!fixed) return @[error];
    NSMutableArray<NSError *> *failures=[NSMutableArray array];
    NSString *runtime=[home stringByAppendingPathComponent:@"Library/Application Support/KeepClam"];
    if(preserveRuntime && !UninstallValidatePreservedRuntime(runtime,&error)) [failures addObject:error];
    error=nil;
    NSArray *host=UninstallByHostPreferencePaths(home,bundleID,&error);
    if(!host && error) [failures addObject:error];
    for(NSString *path in [fixed arrayByAddingObjectsFromArray:host ?: @[]]) {
        if(preserveRuntime && [path isEqual:runtime]) continue;
        error=nil;
        if(!UninstallRemovePath(path,&error)) [failures addObject:error];
    }
    return failures;
}
static NSArray<NSError *> *UninstallRemoveUserData(NSString *home,NSString *bundleID) {
    return UninstallRemoveUserDataWithRuntimePolicy(home,bundleID,NO);
}
static NSArray<NSError *> *UninstallRemoveUserDataPreservingRuntime(NSString *home,NSString *bundleID) {
    return UninstallRemoveUserDataWithRuntimePolicy(home,bundleID,YES);
}
static BOOL UninstallRemoveRuntimeData(NSString *home,NSError **error) {
    return UninstallHomeScopeIsValid(home,error) &&
        UninstallRemovePath([home stringByAppendingPathComponent:@"Library/Application Support/KeepClam"],error);
}
static BOOL UninstallPreparePrivateDirectory(int homeFD,NSString *home,NSArray<NSString *> *parts,NSError **error) {
    int parent=dup(homeFD);
    if(parent<0) return UninstallFailure(error,home,@"Cannot open runtime home",errno);
    NSString *path=home;
    for(NSUInteger i=0;i<parts.count;i++) {
        NSString *name=parts[i]; path=[path stringByAppendingPathComponent:name];
        if(mkdirat(parent,name.fileSystemRepresentation,0700)!=0 && errno!=EEXIST) {
            int saved=errno; close(parent); return UninstallFailure(error,path,@"Cannot create runtime directory",saved);
        }
        int child=openat(parent,name.fileSystemRepresentation,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
        int saved=errno;
        if(child<0) { close(parent); return UninstallFailure(error,path,@"Cannot safely open runtime directory",saved); }
        if(i==parts.count-1) {
            struct stat parentIdentity,childIdentity;
            BOOL safe=fstat(parent,&parentIdentity)==0 && fstat(child,&childIdentity)==0;
            saved=errno;
            if(!safe || parentIdentity.st_dev!=childIdentity.st_dev) {
                close(parent); close(child);
                return UninstallFailure(error,path,@"Cannot safely prepare runtime directory",safe ? EBUSY : saved);
            }
            if(fchmod(child,0700)!=0) {
                saved=errno; close(parent); close(child);
                return UninstallFailure(error,path,@"Cannot set private runtime-directory permissions",saved);
            }
        }
        close(parent); parent=child;
    }
    close(parent); return YES;
}
// Used only when returning to normal operation after an incomplete uninstall.
// Existing shared ancestors keep their permissions; both app-owned leaves are 0700.
static BOOL UninstallPrepareRuntimeDirectories(NSString *home,NSError **error) {
    if(!UninstallHomeScopeIsValid(home,error)) return NO;
    BOOL missing=NO;
    int fd=UninstallOpenDirectory(home,&missing,error);
    if(fd<0) {
        if(missing) UninstallFailure(error,home,@"Runtime home does not exist",ENOENT);
        return NO;
    }
    BOOL ok=UninstallPreparePrivateDirectory(fd,home,@[@"Library",@"Logs",@"KeepClam"],error) &&
        UninstallPreparePrivateDirectory(fd,home,@[@"Library",@"Application Support",@"KeepClam"],error);
    close(fd); return ok;
}
static BOOL UninstallRemoveAppExpected(NSString *appPath,NSString *bundleID,uint64_t expectedDevice,uint64_t expectedInode,NSError **error) {
    if(!UninstallAppTargetIsValid(appPath,bundleID,error)) return NO;
    BOOL missing=NO;
    int app=UninstallOpenDirectory(appPath,&missing,error);
    if(app<0) {
        if(missing) UninstallFailure(error,appPath,@"Application does not exist",ENOENT);
        return NO;
    }
    struct stat identity;
    BOOL ok=fstat(app,&identity)==0;
    if(!ok) UninstallFailure(error,appPath,@"Cannot inspect application identity",errno);
    if(ok && (expectedDevice || expectedInode) &&
       ((uint64_t)identity.st_dev!=expectedDevice || (uint64_t)identity.st_ino!=expectedInode))
        ok=UninstallFailure(error,appPath,@"Application identity changed before privileged cleanup",ESTALE);
    if(ok) ok=UninstallValidateOpenApp(app,appPath,bundleID,error);
    if(ok) ok=UninstallRemovePathExpected(appPath,&identity,error);
    close(app); return ok;
}
static BOOL UninstallRemoveApp(NSString *appPath,NSString *bundleID,NSError **error) {
    return UninstallRemoveAppExpected(appPath,bundleID,0,0,error);
}

static NSString *UninstallResolvedPath(NSString *path) {
    char resolved[PATH_MAX];
    return path && realpath(path.fileSystemRepresentation,resolved) ? [NSString stringWithUTF8String:resolved] : nil;
}
// Same precedence as Homebrew's Cask::Config: explicit, then env, then default.
static NSString *UninstallHomebrewAppDirectory(NSString *caskroom) {
    NSData *data=[NSData dataWithContentsOfFile:[caskroom stringByAppendingPathComponent:@".metadata/config.json"]];
    id config=data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if([config isKindOfClass:NSDictionary.class]) {
        for(NSString *scope in @[@"explicit",@"env",@"default"]) {
            id directories=config[scope];
            id appdir=[directories isKindOfClass:NSDictionary.class] ? directories[@"appdir"] : nil;
            if([appdir isKindOfClass:NSString.class] && [appdir length]) return [appdir stringByExpandingTildeInPath];
        }
    }
    return @"/Applications";
}
// Homebrew moves a cask's app into its appdir, leaving only metadata in the
// Caskroom; older releases linked it from the staged version directory instead.
static NSString *UninstallHomebrewForApp(NSString *appPath,NSArray<NSString *> *prefixes) {
    NSString *app=UninstallResolvedPath(appPath);
    if(!app) return nil;
    NSFileManager *fm=NSFileManager.defaultManager;
    for(NSString *prefix in prefixes) {
        NSString *brew=[prefix stringByAppendingPathComponent:@"bin/brew"];
        NSString *caskroom=[prefix stringByAppendingPathComponent:@"Caskroom/keepclam"];
        BOOL directory=NO;
        if(![fm isExecutableFileAtPath:brew] || ![fm fileExistsAtPath:caskroom isDirectory:&directory] || !directory) continue;
        NSMutableArray *candidates=[NSMutableArray arrayWithObject:[UninstallHomebrewAppDirectory(caskroom) stringByAppendingPathComponent:@"KeepClam.app"]];
        for(NSString *version in [fm contentsOfDirectoryAtPath:caskroom error:nil])
            if(![version hasPrefix:@"."]) [candidates addObject:[[caskroom stringByAppendingPathComponent:version] stringByAppendingPathComponent:@"KeepClam.app"]];
        for(NSString *candidate in candidates)
            if([UninstallResolvedPath(candidate) isEqualToString:app]) return brew;
    }
    return nil;
}
#endif
