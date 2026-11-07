//
//  DeviceSpoof.m
//  LiveContainer
//
//  Makes the guest app see a different device (name and model identifier).
//
@import Foundation;
@import ObjectiveC;
@import UIKit;
#include <sys/utsname.h>
#include <sys/sysctl.h>
#include <string.h>
#import "../../litehook/src/litehook.h"

static NSString* spoofedName = nil;
static NSString* spoofedMachine = nil;

static int (*orig_uname)(struct utsname *) = uname;
static int (*orig_sysctlbyname)(const char *, void *, size_t *, void *, size_t) = sysctlbyname;

static int hook_uname(struct utsname *buf) {
    int ret = orig_uname(buf);
    if(ret == 0 && buf) {
        if(spoofedMachine) {
            strlcpy(buf->machine, spoofedMachine.UTF8String, sizeof(buf->machine));
        }
        if(spoofedName) {
            strlcpy(buf->nodename, spoofedName.UTF8String, sizeof(buf->nodename));
        }
    }
    return ret;
}

static int hook_sysctlbyname(const char *name, void *oldp, size_t *oldlenp, void *newp, size_t newlen) {
    NSString *value = nil;
    if(name && !newp) {
        if(spoofedMachine && !strcmp(name, "hw.machine")) {
            value = spoofedMachine;
        } else if(spoofedName && !strcmp(name, "kern.hostname")) {
            value = spoofedName;
        }
    }
    if(!value) {
        return orig_sysctlbyname(name, oldp, oldlenp, newp, newlen);
    }
    const char *s = value.UTF8String;
    size_t need = strlen(s) + 1;
    if(!oldp) {
        if(oldlenp) *oldlenp = need;
        return 0;
    }
    if(!oldlenp || *oldlenp < need) {
        if(oldlenp) *oldlenp = need;
        errno = ENOMEM;
        return -1;
    }
    memcpy(oldp, s, need);
    *oldlenp = need;
    return 0;
}

static NSString* hook_UIDevice_name(id self, SEL _cmd) {
    return spoofedName;
}

void DeviceSpoofHookInit(NSString* name, NSString* machine) {
    spoofedName = name.length ? [name copy] : nil;
    spoofedMachine = machine.length ? [machine copy] : nil;
    if(spoofedMachine || spoofedName) {
        litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, uname, hook_uname, nil);
        litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, sysctlbyname, hook_sysctlbyname, nil);
    }
    if(spoofedName) {
        Method m = class_getInstanceMethod(UIDevice.class, @selector(name));
        if(m) method_setImplementation(m, (IMP)hook_UIDevice_name);
    }
}
