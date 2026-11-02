// Build-time only. Brand the installer volume without changing its signed app.
#import <AppKit/AppKit.h>
#import <CoreServices/CoreServices.h>
#import <sys/attr.h>
#import <sys/mount.h>
#import <sys/stat.h>

static void Fail(NSString *message) {
    fprintf(stderr, "Installer volume icon: %s\n", message.UTF8String);
    exit(1);
}

static NSData *AppIcon(NSString *mount) {
    NSString *contents = [mount stringByAppendingPathComponent:@"Echo.app/Contents"];
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[contents stringByAppendingPathComponent:@"Info.plist"]];
    NSString *name = info[@"CFBundleIconFile"];
    if (![name isKindOfClass:NSString.class] || name.length == 0 ||
        ![name isEqualToString:name.lastPathComponent] || [name hasPrefix:@"."]) {
        Fail(@"Echo's bundle must declare a local icon filename");
    }
    if (name.pathExtension.length == 0) name = [name stringByAppendingPathExtension:@"icns"];
    if (![name.pathExtension isEqualToString:@"icns"]) Fail(@"Echo's declared icon must be an ICNS file");
    NSString *resources = [[contents stringByAppendingPathComponent:@"Resources"] stringByResolvingSymlinksInPath];
    NSString *path = [[resources stringByAppendingPathComponent:name] stringByResolvingSymlinksInPath];
    if (![path.stringByDeletingLastPathComponent isEqualToString:resources]) Fail(@"App icon must stay inside its Resources directory");
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (data.length < 8 || data.length > 16 * 1024 * 1024 || memcmp(data.bytes, "icns", 4) != 0) Fail(@"Echo's app icon is missing or invalid");
    UInt32 length;
    memcpy(&length, (const uint8_t *)data.bytes + 4, sizeof(length));
    if (CFSwapInt32BigToHost(length) != data.length || ![[[NSImage alloc] initWithData:data] isValid]) Fail(@"Echo's app icon is incomplete");
    return data;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 3) Fail(@"Usage: InstallerVolumeIcon {apply|verify} MOUNT");
        NSString *mode = @(argv[1]);
        BOOL apply = [mode isEqualToString:@"apply"];
        if (!apply && ![mode isEqualToString:@"verify"]) Fail(@"Unknown command");
        NSString *mount = [@(argv[2]) stringByStandardizingPath];
        const char *path = mount.fileSystemRepresentation;
        struct statfs filesystem;
        struct stat folder;
        if (lstat(path, &folder) != 0 || !S_ISDIR(folder.st_mode) || folder.st_ino != 2 ||
            statfs(path, &filesystem) != 0 || strcmp(filesystem.f_fstypename, "hfs") != 0) {
            Fail(@"Expected the root of the scratch HFS+ installer image");
        }
        NSData *icon = AppIcon(mount);
        struct attrlist attributes = {0};
        attributes.bitmapcount = ATTR_BIT_MAP_COUNT;
        attributes.commonattr = ATTR_CMN_FNDRINFO;
        // Folder attributes, deliberately not ATTR_VOL_INFO. The volume header
        // holds separate auto-open metadata which must remain unchanged.
        struct { uint32_t length; uint8_t finder[32]; } info = {0};
        if (getattrlist(path, &attributes, &info, sizeof(info), 0) != 0 || info.length != sizeof(info)) Fail(@"Cannot read installer root Finder information");
        UInt16 flags;
        memcpy(&flags, info.finder + 8, sizeof(flags));
        flags = CFSwapInt16BigToHost(flags);
        NSString *destination = [mount stringByAppendingPathComponent:@".VolumeIcon.icns"];
        struct stat existing;
        if (lstat(destination.fileSystemRepresentation, &existing) == 0 && !S_ISREG(existing.st_mode)) Fail(@"Volume icon must be a regular file");
        if (apply) {
            NSError *error;
            if (![icon writeToFile:destination options:NSDataWritingAtomic error:&error]) Fail([@"Cannot copy Echo's icon: " stringByAppendingString:error.localizedDescription]);
            flags = CFSwapInt16HostToBig(flags | kHasCustomIcon);
            memcpy(info.finder + 8, &flags, sizeof(flags));
            if (setattrlist(path, &attributes, info.finder, sizeof(info.finder), 0) != 0) Fail(@"Cannot enable the installer's custom volume icon");
        } else {
            if (!(flags & kHasCustomIcon)) Fail(@"Installer custom-icon flag was lost after conversion");
            if (![icon isEqualToData:[NSData dataWithContentsOfFile:destination]]) Fail(@"Installer volume icon differs from Echo's app icon");
        }
    }
    return 0;
}
