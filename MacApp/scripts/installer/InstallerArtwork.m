// Build-time only: AppKit artwork and the native Carbon alias Finder requires.
// The deprecated alias API is deliberately isolated here; it is never shipped
// inside Echo and is available to both Apple Silicon and Intel release hosts.
#import <AppKit/AppKit.h>
#import <CoreText/CoreText.h>
#import <CoreServices/CoreServices.h>
#import <sys/attr.h>
#import <sys/mount.h>
#import <sys/stat.h>

static void Fail(NSString *message) {
    fprintf(stderr, "Installer artwork: %s\n", message.UTF8String);
    exit(1);
}

static NSFont *Font(NSString *directory, NSString *file, NSString *name, CGFloat size) {
    NSURL *url = [NSURL fileURLWithPath:[directory stringByAppendingPathComponent:file]];
    CFErrorRef error = NULL;
    if (!CTFontManagerRegisterFontsForURL((__bridge CFURLRef)url, kCTFontManagerScopeProcess, &error)) {
        if (error) CFRelease(error);
        Fail([@"Cannot register bundled font " stringByAppendingString:file]);
    }
    NSFont *font = [NSFont fontWithName:name size:size];
    if (!font) Fail([@"Cannot load bundled font " stringByAppendingString:name]);
    return font;
}

static void Text(NSString *text, CGFloat y, NSFont *font, NSColor *color) {
    NSMutableParagraphStyle *paragraph = [NSMutableParagraphStyle new];
    paragraph.alignment = NSTextAlignmentCenter;
    [text drawInRect:NSMakeRect(30, y, 580, 48)
      withAttributes:@{NSFontAttributeName: font, NSForegroundColorAttributeName: color,
                       NSParagraphStyleAttributeName: paragraph}];
}

static void Sprite(NSImage *image, NSPoint center, CGFloat size, CGFloat angle) {
    [NSGraphicsContext saveGraphicsState];
    NSAffineTransform *transform = [NSAffineTransform transform];
    [transform translateXBy:center.x yBy:center.y];
    [transform rotateByDegrees:angle];
    [transform concat];
    [image drawInRect:NSMakeRect(-size / 2, -size / 2, size, size)
        fromRect:NSZeroRect operation:NSCompositingOperationSourceOver
        fraction:1 respectFlipped:YES hints:nil];
    [NSGraphicsContext restoreGraphicsState];
}

static void MakerMark(NSImage *logo, NSFont *font) {
    NSDictionary *attributes = @{NSFontAttributeName: font,
        NSForegroundColorAttributeName: [NSColor colorWithSRGBRed:0.45 green:0.44 blue:0.49 alpha:1]};
    NSSize bySize = [@"by" sizeWithAttributes:attributes];
    CGFloat logoWidth = 78;
    CGFloat gap = 8;
    CGFloat x = (640 - bySize.width - gap - logoWidth) / 2;
    [@"by" drawAtPoint:NSMakePoint(x, 381) withAttributes:attributes];
    // Use the supplied vector wordmark unchanged. Crop its built-in whitespace;
    // darken compositing lets the pale SVG canvas blend into the installer.
    [logo drawInRect:NSMakeRect(x + bySize.width + gap, 383, logoWidth, 11.4)
        fromRect:NSMakeRect(49, 47, 697, 102) operation:NSCompositingOperationDarken
        fraction:0.78 respectFlipped:YES hints:nil];
}

static NSBitmapImageRep *Artwork(NSInteger scale, NSArray<NSImage *> *characters,
        NSImage *logo, NSFont *instruction, NSFont *credit) {
    NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc]
        initWithBitmapDataPlanes:NULL pixelsWide:640 * scale pixelsHigh:420 * scale
        bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO
        colorSpaceName:NSCalibratedRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
    bitmap.size = NSMakeSize(640, 420);
    NSGraphicsContext *context = [NSGraphicsContext graphicsContextWithBitmapImageRep:bitmap];
    [NSGraphicsContext saveGraphicsState];
    NSGraphicsContext.currentContext = context;
    CGContextRef cg = context.CGContext;
    // The bitmap context already maps logical points to Retina pixels.
    CGContextTranslateCTM(cg, 0, 420);
    CGContextScaleCTM(cg, 1, -1);
    NSGraphicsContext.currentContext = [NSGraphicsContext graphicsContextWithCGContext:cg flipped:YES];
    NSGraphicsContext.currentContext.imageInterpolation = NSImageInterpolationHigh;
    [[NSColor colorWithSRGBRed:0.988 green:0.984 blue:0.977 alpha:1] setFill];
    NSRectFill(NSMakeRect(0, 0, 640, 420));

    // Separate transparent artwork keeps the native icon locations independent.
    // Flying above the route, winking beside the instruction, and two friends
    // peeking behind the native Applications icon. Each pose is a separate asset.
    Sprite(characters[1], NSMakePoint(346, 76), 86, -8);
    Sprite(characters[2], NSMakePoint(77, 308), 78, -17);
    Sprite(characters[3], NSMakePoint(446, 124), 82, -11);
    Sprite(characters[0], NSMakePoint(486, 117), 66, 15);

    // A dotted sound wave points from Echo to the actual Applications shortcut.
    NSColor *routeColor = [NSColor colorWithSRGBRed:0.56 green:0.54 blue:0.64 alpha:0.8];
    [routeColor setFill];
    for (NSInteger index = 0; index <= 21; index++) {
        CGFloat progress = index / 21.0;
        CGFloat x = 253 + progress * 126;
        CGFloat y = 180 - sin(progress * M_PI * 3) * 15;
        [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(x - 2, y - 2, 4, 4)] fill];
    }
    NSBezierPath *arrow = [NSBezierPath bezierPath];
    [arrow moveToPoint:NSMakePoint(376, 171)];
    [arrow lineToPoint:NSMakePoint(384, 180)];
    [arrow lineToPoint:NSMakePoint(373, 182)];
    arrow.lineWidth = 1.8;
    arrow.lineCapStyle = NSLineCapStyleRound;
    arrow.lineJoinStyle = NSLineJoinStyleRound;
    [routeColor setStroke];
    [arrow stroke];

    Text(@"Drag Echo to Applications", 328, instruction,
        [NSColor colorWithSRGBRed:0.12 green:0.12 blue:0.14 alpha:1]);
    [[NSColor colorWithSRGBRed:0.78 green:0.77 blue:0.80 alpha:1] setFill];
    [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(306, 367, 28, 1)
        xRadius:0.5 yRadius:0.5] fill];
    MakerMark(logo, credit);
    [NSGraphicsContext restoreGraphicsState];
    return bitmap;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 3 || argc > 5) Fail(@"Usage: InstallerArtwork {background FONT_DIRECTORY OUTPUT.tiff CHARACTER.png | alias TARGET OUTPUT.alias}");
        NSString *mode = @(argv[1]);
        NSString *input = @(argv[2]);
        NSString *output = argc >= 4 ? @(argv[3]) : nil;
        if (![mode isEqualToString:@"autoopen"] && ![mode isEqualToString:@"verify-autoopen"] && !output) Fail(@"Output path is required");
        if ([mode isEqualToString:@"background"]) {
            if (argc != 5) Fail(@"Installer character asset is required");
            NSString *characterPath = @(argv[4]);
            NSString *assetDirectory = characterPath.stringByDeletingLastPathComponent;
            NSMutableArray<NSImage *> *characters = [NSMutableArray new];
            for (NSString *filename in @[characterPath.lastPathComponent,
                    @"echo-flying.png", @"echo-wink.png", @"echo-peek.png"]) {
                NSImage *character = [[NSImage alloc] initWithContentsOfFile:
                    [assetDirectory stringByAppendingPathComponent:filename]];
                if (!character.isValid) Fail([@"Cannot load installer character asset: " stringByAppendingString:filename]);
                [characters addObject:character];
            }
            NSImage *logo = [[NSImage alloc] initWithContentsOfFile:
                [assetDirectory stringByAppendingPathComponent:@"voicelab.svg"]];
            if (!logo.isValid) Fail(@"Cannot load VoiceLab logo");
            NSFont *instruction = Font(input, @"manrope-semibold.ttf", @"Manrope-SemiBold", 22);
            NSFont *credit = Font(input, @"manrope-regular.ttf", @"Manrope-Regular", 10);
            NSArray *representations = @[Artwork(1, characters, logo, instruction, credit),
                Artwork(2, characters, logo, instruction, credit)];
            NSData *tiff = [NSBitmapImageRep TIFFRepresentationOfImageRepsInArray:representations];
            if (![tiff writeToFile:output atomically:YES]) Fail(@"Cannot write background TIFF");
        } else if ([mode isEqualToString:@"alias"]) {
            FSRef target;
            AliasHandle alias = NULL;
            if (FSPathMakeRef((const UInt8 *)input.fileSystemRepresentation, &target, NULL) != noErr ||
                FSNewAlias(NULL, &target, &alias) != noErr || alias == NULL) {
                Fail(@"Cannot make the background alias on the mounted installer");
            }
            NSData *bytes = [NSData dataWithBytes:*alias length:GetAliasSize(alias)];
            DisposeHandle((Handle)alias);
            if (![bytes writeToFile:output atomically:YES]) Fail(@"Cannot write background alias");
        } else if ([mode isEqualToString:@"autoopen"] || [mode isEqualToString:@"verify-autoopen"]) {
            struct statfs filesystem;
            struct stat folder;
            const char *path = input.fileSystemRepresentation;
            if (statfs(path, &filesystem) != 0 || stat(path, &folder) != 0 ||
                strcmp(filesystem.f_fstypename, "hfs") != 0 || folder.st_ino != 2) {
                Fail(@"Auto-open requires the root of the scratch HFS+ image");
            }
            struct attrlist attributes = {0};
            attributes.bitmapcount = ATTR_BIT_MAP_COUNT;
            attributes.commonattr = ATTR_CMN_FNDRINFO;
            attributes.volattr = ATTR_VOL_INFO;
            struct { uint32_t length; uint8_t finder[32]; } info = {0};
            if (getattrlist(path, &attributes, &info, sizeof(info), 0) != 0 || info.length != sizeof(info)) {
                Fail(@"Cannot read installer Finder information");
            }
            // Volume FinderInfo[2] contains the auto-open folder's catalog ID.
            // ATTR_VOL_INFO selects the volume header, not folder attributes.
            UInt32 folderID = CFSwapInt32HostToBig(2);
            if ([mode isEqualToString:@"verify-autoopen"]) {
                if (memcmp(info.finder + 8, &folderID, sizeof(folderID)) != 0) Fail(@"Installer auto-open metadata was lost");
                return 0;
            }
            memcpy(info.finder + 8, &folderID, sizeof(folderID));
            if (setattrlist(path, &attributes, info.finder, sizeof(info.finder), 0) != 0) {
                Fail([NSString stringWithFormat:@"Cannot set installer auto-open metadata (%d)", errno]);
            }
        } else if ([mode isEqualToString:@"verify-alias"]) {
            NSData *data = [NSData dataWithContentsOfFile:input];
            CFDataRef bookmark = CFURLCreateBookmarkDataFromAliasRecord(NULL, (__bridge CFDataRef)data);
            if (!bookmark) Fail(@"Background alias is invalid");
            CFURLRef resolved = CFURLCreateByResolvingBookmarkData(NULL, bookmark,
                kCFURLBookmarkResolutionWithoutUIMask | kCFURLBookmarkResolutionWithoutMountingMask,
                NULL, NULL, NULL, NULL);
            CFRelease(bookmark);
            if (!resolved) Fail(@"Background alias does not resolve after remount");
            NSString *path = [(__bridge NSURL *)resolved path];
            BOOL matches = [path.stringByResolvingSymlinksInPath isEqualToString:output.stringByResolvingSymlinksInPath];
            CFRelease(resolved);
            if (!matches) Fail(@"Background alias resolved outside the installer");
        } else {
            Fail(@"Unknown command");
        }
    }
    return 0;
}
