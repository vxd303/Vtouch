#include "Process.h"
#include "Common.h"
#include "Screen.h"
#include <objc/message.h>
int (*openApp)(CFStringRef, Boolean);

static void* sbServices = dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices", RTLD_LAZY);

@interface SBApplicationController : NSObject
+ (instancetype)sharedInstance;
- (id)applicationWithBundleIdentifier:(NSString*)bundleIdentifier;
@end

@interface LSApplicationProxy : NSObject
+ (instancetype)applicationProxyForIdentifier:(NSString*)identifier;
@property (nonatomic, readonly) NSString *localizedName;
@property (nonatomic, readonly) NSString *shortVersionString;
@property (nonatomic, readonly) NSString *bundleVersion;
@end

int switchProcessForegroundFromRawData(UInt8 *eventData)
{
    return bringAppForeground([NSString stringWithFormat:@"%s", eventData]);
}

int bringAppForeground(NSString *appIdentifier)
{
    CFStringRef appBundleName = CFStringCreateWithFormat(NULL, NULL, CFSTR("%@"), appIdentifier);
    //[NSString stringWithFormat:@"%s", eventData];
    NSLog(@"### com.zjx.springboard: Switch to application: %@", appBundleName);
    if (!openApp)
        openApp = (int(*)(CFStringRef, Boolean))dlsym(sbServices,"SBSLaunchApplicationWithIdentifier");

    return openApp(appBundleName, false);
}

id getFrontMostApplication()
{
    //TODO: might cause problem here. Both _accessibilityFrontMostApplication failed or front most application springboard will cause app be nil.
    __block id app = nil;
    dispatch_sync(dispatch_get_main_queue(), ^{
        @try{
            SpringBoard *springboard = (SpringBoard*)[%c(SpringBoard) sharedApplication];
            app = [springboard _accessibilityFrontMostApplication];
            //NSLog(@"com.zjx.springboard: app: %@, id: %@", app, [app displayIdentifier]);
        }
        @catch (NSException *exception) {
            NSLog(@"com.zjx.springboard: Debug: %@", exception.reason);
        }
        });
    return app;
}

static SBApplication *getApplicationForBundleId(NSString *bundleId)
{
    SBApplicationController *controller = [NSClassFromString(@"SBApplicationController") sharedInstance];
    if (!controller)
    {
        return nil;
    }
    if ([controller respondsToSelector:@selector(applicationWithBundleIdentifier:)])
    {
        return [controller applicationWithBundleIdentifier:bundleId];
    }
    return nil;
}

NSString* frontMostAppId(void)
{
    SBApplication *app = getFrontMostApplication();
    if (!app)
    {
        return @"com.apple.springboard";
    }
    return app.bundleIdentifier ?: @"com.apple.springboard";
}

NSString* frontMostAppOrientation(void)
{
    return [NSString stringWithFormat:@"%d", [Screen getScreenOrientation]];
}

static BOOL sendTerminationToApp(SBApplication *app)
{
    if (!app)
    {
        return false;
    }

    SEL killSelector = NSSelectorFromString(@"kill");
    if ([app respondsToSelector:killSelector])
    {
        ((void (*)(id, SEL))objc_msgSend)(app, killSelector);
        return true;
    }

    SEL terminateSelector = NSSelectorFromString(@"terminate");
    if ([app respondsToSelector:terminateSelector])
    {
        ((void (*)(id, SEL))objc_msgSend)(app, terminateSelector);
        return true;
    }

    return false;
}

NSString* killAppFromRawData(UInt8 *eventData, NSError **error)
{
    NSString *bundleId = [NSString stringWithFormat:@"%s", eventData];
    if ([bundleId length] == 0)
    {
        if (error)
        {
            *error = [NSError errorWithDomain:@"com.zjx.zxtouchsp"
                                         code:999
                                     userInfo:@{NSLocalizedDescriptionKey:@"-1;;Missing bundle identifier.\r\n"}];
        }
        return nil;
    }

    SBApplication *app = getApplicationForBundleId(bundleId);
    if (!sendTerminationToApp(app))
    {
        if (error)
        {
            *error = [NSError errorWithDomain:@"com.zjx.zxtouchsp"
                                         code:999
                                     userInfo:@{NSLocalizedDescriptionKey:@"-1;;Unable to terminate app.\r\n"}];
        }
        return nil;
    }

    return @"";
}

NSString* appStateFromRawData(UInt8 *eventData, NSError **error)
{
    NSString *bundleId = [NSString stringWithFormat:@"%s", eventData];
    if ([bundleId length] == 0)
    {
        if (error)
        {
            *error = [NSError errorWithDomain:@"com.zjx.zxtouchsp"
                                         code:999
                                     userInfo:@{NSLocalizedDescriptionKey:@"-1;;Missing bundle identifier.\r\n"}];
        }
        return nil;
    }

    SBApplication *app = getApplicationForBundleId(bundleId);
    if (!app)
    {
        return @"0";
    }

    SEL processStateSelector = NSSelectorFromString(@"processState");
    if ([app respondsToSelector:processStateSelector])
    {
        NSInteger state = ((NSInteger (*)(id, SEL))objc_msgSend)(app, processStateSelector);
        return [NSString stringWithFormat:@"%ld", (long)state];
    }

    SEL isRunningSelector = NSSelectorFromString(@"isRunning");
    if ([app respondsToSelector:isRunningSelector])
    {
        BOOL isRunning = ((BOOL (*)(id, SEL))objc_msgSend)(app, isRunningSelector);
        return isRunning ? @"1" : @"0";
    }

    return @"-1";
}

NSString* appInfoFromRawData(UInt8 *eventData, NSError **error)
{
    NSString *bundleId = [NSString stringWithFormat:@"%s", eventData];
    if ([bundleId length] == 0)
    {
        if (error)
        {
            *error = [NSError errorWithDomain:@"com.zjx.zxtouchsp"
                                         code:999
                                     userInfo:@{NSLocalizedDescriptionKey:@"-1;;Missing bundle identifier.\r\n"}];
        }
        return nil;
    }

    LSApplicationProxy *proxy = [LSApplicationProxy applicationProxyForIdentifier:bundleId];
    NSString *name = proxy.localizedName ?: @"";
    NSString *shortVersion = proxy.shortVersionString ?: @"";
    NSString *bundleVersion = proxy.bundleVersion ?: @"";
    NSString *state = appStateFromRawData(eventData, nil) ?: @"-1";

    return [NSString stringWithFormat:@"%@;;%@;;%@;;%@;;%@", bundleId, name, shortVersion, bundleVersion, state];
}
