//
//  IDFV.m
//  LiveContainer
//
//  Created by s s on 2026/4/25.
//
@import Foundation;
@import ObjectiveC;

NSUUID* idForVendorUUID = nil;

NSUUID* getIDFV_hook(NSObject* cur) {
    (void)cur;
    return idForVendorUUID;
}

NSUUID* getAdvertisingIdentifier_hook(NSObject* cur) {
    (void)cur;
    static NSUUID* zeroUUID = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        zeroUUID = [[NSUUID alloc] initWithUUIDString:@"00000000-0000-0000-0000-000000000000"];
    });
    return zeroUUID;
}

static void hookInstanceMethod(Class cls, SEL selector, IMP implementation) {
    if (!cls) {
        return;
    }
    Method method = class_getInstanceMethod(cls, selector);
    if (method) {
        method_setImplementation(method, implementation);
    }
}

void IDFVHookInit(NSUUID* uuid) {
    if (!uuid) {
        return;
    }
    idForVendorUUID = uuid;

    hookInstanceMethod(objc_getClass("LSApplicationWorkspace"), NSSelectorFromString(@"deviceIdentifierForVendor"), (IMP)getIDFV_hook);
    hookInstanceMethod(objc_getClass("UIDevice"), NSSelectorFromString(@"identifierForVendor"), (IMP)getIDFV_hook);
    hookInstanceMethod(objc_getClass("ASIdentifierManager"), NSSelectorFromString(@"advertisingIdentifier"), (IMP)getAdvertisingIdentifier_hook);
}
