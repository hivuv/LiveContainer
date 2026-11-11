@import Foundation;
#import "utils.h"
#import "LCSharedUtils.h"
#import "Tweaks.h"
#include "../../litehook/src/litehook.h"
#include "../LCMachOUtils.h"
#include <dlfcn.h>

BOOL isolateAppGroup = NO;
void* webKitHeader = 0;
void NSFMGuestHooksInit(void) {
    NSDictionary* infoDict = [NSUserDefaults guestContainerInfo];
    isolateAppGroup = [infoDict[@"isolateAppGroup"] boolValue];
    swizzle(NSFileManager.class, @selector(containerURLForSecurityApplicationGroupIdentifier:), @selector(hook_containerURLForSecurityApplicationGroupIdentifier:));
    
    /// To fix https://github.com/LiveContainer/LiveContainer/issues/888 i.e. WebKit being unable to save cookie issue, we have to hook -[NSFileManager createDirectoryAtPath:withIntermediateDirectories:attributes:error:] so that WebKit still creates bookmark for the symlinked lc's cookies folder, which is resolved by the kernel to the app's cookies folder
    /// see https://github.com/apple-oss-distributions/WebKit/blob/0c8cf3581e5c01d970ea411128007c9325ba2d48/Source/WebKit/Shared/Cocoa/SandboxExtensionCocoa.mm#L159 and https://github.com/apple-oss-distributions/WebKit/blob/0c8cf3581e5c01d970ea411128007c9325ba2d48/Source/WebKit/UIProcess/WebsiteData/WebsiteDataStore.cpp#L2225
    /// WebKit::WebsiteDataStore::createHandleFromResolvedPathIfPossible requires WebKit::WebsiteDataStore::resolvedCookieStorageDirectory to return a non-empty path to create a bookmark, which is possible when WebKit::resolveAndCreateReadWriteDirectoryForSandboxExtension is non-empty. However if -[NSFileManager createDirectoryAtPath:withIntermediateDirectories:attributes:error:] returns false for cookies folder since it's a symlink, resolveAndCreateReadWriteDirectoryForSandboxExtension will return empty value. So that com.apple.WebKit.Networking process does not receive the bookmark and is unable to access the cookies folder.
    /// So the hook is simple, we just check if the path is lc's cookies folder and return YES. For performance, we check if caller's address falls in WebKit+0 to WebKit+32M
    /// If you have a better solution, please let us know.
    void* dscPtr = getDSCAddr();
    webKitHeader = getCachedSymbol(@"webKitHeader", dscPtr);
    
    if(!webKitHeader) {
        dlopen("/System/Library/Frameworks/WebKit.framework/WebKit", RTLD_GLOBAL);
        webKitHeader = LCGetLoadedImageHeader(0, "/System/Library/Frameworks/WebKit.framework/WebKit");
        saveCachedSymbol(@"webKitHeader", dscPtr, webKitHeader-dscPtr);
    }
    
    swizzle(NSFileManager.class, @selector(createDirectoryAtPath:withIntermediateDirectories:attributes:error:), @selector(hook_createDirectoryAtPath:withIntermediateDirectories:attributes:error:));
    
}

static NSURL* legacyAppGroupURL(NSString* groupIdentifier) {
    if (NSUserDefaults.lcAppGroupPath) {
        return [NSURL fileURLWithPath:[NSString stringWithFormat:@"%@/LiveContainer/Data/AppGroup/%@", NSUserDefaults.lcAppGroupPath, groupIdentifier]];
    }
    const char* lcHomePath = LCHomePath();
    if (lcHomePath) {
        return [NSURL fileURLWithPath:[NSString stringWithFormat:@"%s/Documents/Data/AppGroup/%@", lcHomePath, groupIdentifier]];
    }
    return nil;
}

static NSString* appGroupMigrationMarkerDirectory(void) {
    const char* home = getenv("HOME");
    if (!home) {
        return nil;
    }
    return [NSString stringWithFormat:@"%s/LCAppGroupMigrationPending", home];
}

static BOOL appGroupDirectoryIsEffectivelyEmpty(NSString* path, NSFileManager* fm) {
    NSArray* contents = [fm contentsOfDirectoryAtPath:path error:nil];
    if (!contents) {
        return NO;
    }
    if (contents.count == 0) {
        return YES;
    }
    if (contents.count != 1 || ![contents.firstObject isEqualToString:@"Library"]) {
        return NO;
    }
    NSString* libraryPath = [path stringByAppendingPathComponent:@"Library"];
    NSArray* libraryContents = [fm contentsOfDirectoryAtPath:libraryPath error:nil];
    if (!libraryContents) {
        return NO;
    }
    if (libraryContents.count == 0) {
        return YES;
    }
    if (libraryContents.count != 1 || ![libraryContents.firstObject isEqualToString:@"Caches"]) {
        return NO;
    }
    NSString* cachesPath = [libraryPath stringByAppendingPathComponent:@"Caches"];
    NSArray* cachesContents = [fm contentsOfDirectoryAtPath:cachesPath error:nil];
    return cachesContents != nil && cachesContents.count == 0;
}

// NSFileManager simulate app group
@implementation NSFileManager(LiveContainerHooks)

- (nullable NSURL *)hook_containerURLForSecurityApplicationGroupIdentifier:(NSString *)groupIdentifier {
    if([groupIdentifier isEqualToString:[NSClassFromString(@"LCSharedUtils") appGroupID]]) {
        return [NSURL fileURLWithPath: NSUserDefaults.lcAppGroupPath];
    }
    NSURL *result;
    if(isolateAppGroup) {
        result = [NSURL fileURLWithPath:[NSString stringWithFormat:@"%s/LCAppGroup/%@", getenv("HOME"), groupIdentifier]];

        // One-time migration for containers that previously used a shared app
        // group. The marker directory is only created when isolation is enabled
        // on an existing container, so brand-new containers always start empty.
        NSString* markerDirectory = appGroupMigrationMarkerDirectory();
        BOOL markerDirectoryIsDir = NO;
        if (markerDirectory && [NSFileManager.defaultManager fileExistsAtPath:markerDirectory isDirectory:&markerDirectoryIsDir] && markerDirectoryIsDir) {
            NSString* groupMarker = [markerDirectory stringByAppendingPathComponent:groupIdentifier];
            NSFileManager* fm = NSFileManager.defaultManager;
            if (![fm fileExistsAtPath:groupMarker]) {
                BOOL isDir = NO;
                BOOL destinationExists = [fm fileExistsAtPath:result.path isDirectory:&isDir];
                BOOL destinationEmpty = destinationExists && isDir && appGroupDirectoryIsEffectivelyEmpty(result.path, fm);

                if (destinationExists && !destinationEmpty) {
                    [fm createFileAtPath:groupMarker contents:nil attributes:nil];
                } else {
                    NSURL* legacyURL = legacyAppGroupURL(groupIdentifier);
                    BOOL legacyIsDir = NO;
                    BOOL legacyExists = legacyURL && [fm fileExistsAtPath:legacyURL.path isDirectory:&legacyIsDir] && legacyIsDir;
                    if (legacyExists) {
                        if (destinationExists) {
                            [fm removeItemAtURL:result error:nil];
                        }
                        NSError* error = nil;
                        [fm createDirectoryAtPath:result.path.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:&error];
                        if ([fm copyItemAtPath:legacyURL.path toPath:result.path error:&error]) {
                            [fm createFileAtPath:groupMarker contents:nil attributes:nil];
                        } else {
                            [fm removeItemAtURL:result error:nil];
                            NSLog(@"[LC] Failed to migrate app group %@: %@", groupIdentifier, error);
                        }
                    } else {
                        [fm createFileAtPath:groupMarker contents:nil attributes:nil];
                    }
                }
            }
        }
    } else if (NSUserDefaults.lcAppGroupPath){
        result = [NSURL fileURLWithPath:[NSString stringWithFormat:@"%@/LiveContainer/Data/AppGroup/%@", NSUserDefaults.lcAppGroupPath, groupIdentifier]];
    } else {
        result = [NSURL fileURLWithPath:[NSString stringWithFormat:@"%s/Documents/Data/AppGroup/%@", LCHomePath(), groupIdentifier]];
    }
    [NSFileManager.defaultManager createDirectoryAtURL:[result URLByAppendingPathComponent:@"Library/Caches"] withIntermediateDirectories:YES attributes:nil error:nil];
    return result;
}

- (bool)hook_createDirectoryAtPath:(NSString *)path withIntermediateDirectories:(BOOL)createIntermediates attributes:(NSDictionary<NSFileAttributeKey,id> *)attributes error:(NSError *__autoreleasing  _Nullable *)error {
    bool ans = [self hook_createDirectoryAtPath:path withIntermediateDirectories:createIntermediates attributes:attributes error:error];
    void* callerAddr = __builtin_return_address(0);
    if(callerAddr > webKitHeader && callerAddr < (webKitHeader + (32 << 20) )) {
        if([path hasSuffix:@"Library/Cookies"]) {
            // symlink Cookies folder
            // https://github.com/apple-oss-distributions/WebKit/blob/0c8cf3581e5c01d970ea411128007c9325ba2d48/Source/WebKit/Shared/Cocoa/SandboxUtilities.mm#L56
            // unfortunately we cannot hook sandbox_container_path_for_pid, so we symlink Cookies folder in normal mode
            // see NSFileManager+GuestHooks.m for more info
            NSFileManager *fm = NSFileManager.defaultManager;
            const char *lcHomePath = NSUserDefaults.isLiveProcess ? LPHomePath() : LCHomePath();
            NSString *libraryPath = [@(lcHomePath) stringByAppendingPathComponent:@"Library"];
            NSString *cookies2Path = [libraryPath stringByAppendingPathComponent:@"Cookies2"];
            NSString *cookiesPath = [libraryPath stringByAppendingPathComponent:@"Cookies"];
            NSString* appCookiesPath = [@(getenv("HOME")) stringByAppendingPathComponent:@"Library/Cookies"];
            BOOL isDir = NO;
            if (![fm fileExistsAtPath:cookies2Path isDirectory:&isDir]) {
                if([fm fileExistsAtPath:cookiesPath isDirectory:&isDir]) {
                    [fm moveItemAtPath:cookiesPath toPath:cookies2Path error:nil];
                } else {
                    [fm createDirectoryAtPath:cookies2Path withIntermediateDirectories:YES attributes:nil error:nil];
                }
            }
            remove(cookiesPath.UTF8String);
            symlink(appCookiesPath.UTF8String, cookiesPath.UTF8String);
            return YES;
        }
    }
    return ans;
}

@end
