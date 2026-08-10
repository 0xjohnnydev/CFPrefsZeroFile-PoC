# cfprefsd zero-file create PoC

This PoC makes system `cfprefsd` create one selected missing file. The result
is a root-owned, mode-`0644`, zero-byte regular file.

The caller does not control the file contents. This is not arbitrary file
write, file read, directory listing, truncation, or replacement of an existing
file.

## Path scope

The app controls the raced container tree below its own temporary directory:

```text
/private/var/mobile/Containers/Data/Application/<app-UUID>/tmp/CFPrefsContainer-<nonce>/
```

The final preference leaf is:

```text
Library/Preferences/local.research.cfprefs.zero.<nonce>.plist
```

That leaf is a symlink to one selected missing target. The safe runtime test
used:

```text
/private/var/mobile/Containers/Data/Application/<app-UUID>/tmp/CFPrefsTarget-<nonce>/locked/created.plist
```

The target must not already exist. System `cfprefsd` must also have permission
to reach its parent directory. A hit creates only a root-owned, mode-`0644`,
zero-byte regular file.

This primitive cannot overwrite the existing MobileGestalt cache plist. It
does not provide chosen plist contents.

## 1. Raw path acceptance

The request uses a container string with the expected system-group prefix. Its
canonical path points into the caller's own application container:

```objc
NSString *rawContainer = [NSString stringWithFormat:
    @"/private/var/containers/Shared/SystemGroup/../../../mobile/"
     "Containers/Data/Application/%@/tmp/%@", appUUID, leaf];
```

The PoC renames the last directory while Core Foundation fixes up the path:

```objc
while (atomic_load(&running)) {
    rename(hidden.fileSystemRepresentation, actual.fileSystemRepresentation);
    usleep(35);
    rename(actual.fileSystemRepresentation, hidden.fileSystemRepresentation);
    usleep(35);
}
```

If canonicalization fails at the right point, the daemon keeps the raw path.
Exact-build decompilation indicates that a later authorization check accepts
its textual `/private/var/containers/Shared/SystemGroup/` prefix. The preserved
assessment disassembly does not include that exact string comparison, so the
published mechanism relies on the decompilation plus the runtime path effect.

## 2. Create before validation

The raced-in preference leaf is a symlink to a missing target:

```objc
NSString *preference = [hidden stringByAppendingPathComponent:
    [@"Library/Preferences" stringByAppendingPathComponent:
        [domain stringByAppendingPathExtension:@"plist"]]];

symlink(target.fileSystemRepresentation,
        preference.fileSystemRepresentation);
```

`cfprefsd` reaches `openat(..., O_CREAT, 0644)` before access-token validation.
The open lacks `O_NOFOLLOW`, so it creates the symlink target. Rejection cleanup
checks the original leaf with `AT_SYMLINK_NOFOLLOW`, sees a symlink, and leaves
the created target in place.

The request uses the private container variants of CFPreferences:

```objc
setValue(CFSTR("marker"), CFSTR("not_expected_to_write"),
         (__bridge CFStringRef)domain, kCFPreferencesAnyUser,
         kCFPreferencesAnyHost, (__bridge CFStringRef)rawContainer);

synchronize((__bridge CFStringRef)domain,
            kCFPreferencesAnyUser, kCFPreferencesAnyHost,
            (__bridge CFStringRef)rawContainer);
```

The marker does not become file contents. It only enters the preference write
path.

## Proof check

[`poc.m`](poc.m) first creates a mode-`0500` parent and confirms that the app
cannot create the target. A hit requires all of these conditions:

```objc
BOOL hit = sent && IsSymlinkTo(actualPreference, target) &&
    lstat(target.fileSystemRepresentation, &targetStatus) == 0 &&
    S_ISREG(targetStatus.st_mode) && targetStatus.st_uid == 0 &&
    (targetStatus.st_mode & 0777) == 0644 && targetStatus.st_size == 0;
```

The test uses random paths below its own `tmp` directory and removes them after
verification.

## Use

1. Add `poc.m` to an Objective-C iOS application target.
2. Build with the `iphoneos` SDK for `arm64e`.
3. Call `run_cfprefsd_zero_file_poc()` from an explicit test action.

The race can miss. A return value of `2` means no hit or incomplete evidence.

## Evidence and patch status

Two of three app-owned trials hit with a 35-microsecond delay on `iPhone18,2`,
build `24A5390f`.

A separate two-app test on the same device and build proved cross-container
creation. The attacker app could not create or inspect the foreign target. The
owner app independently found a root-owned, mode-`0644`, zero-byte file at the
chosen missing path and then removed it. Foreign-target confirmation therefore
requires an independent reader with authority to that container.

Exact-build static analysis found both behaviors in `iPhone18,2` build
`24A5408d`. Runtime testing has not confirmed the primitive on that build.
Relevant `24A5408d` function addresses are listed at the top of `poc.m`.

The tests establish only the named iOS 27.0 beta build. The earliest affected
version is unknown.
