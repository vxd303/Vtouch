#include "Scheduler.h"
#include "Common.h"
#include "Play.h"

#import <UIKit/UIKit.h>

static NSString *const kAutoLaunchFileName = @"autolaunch.plist";
static NSMutableDictionary<NSString*, NSTimer*> *timerRegistry = nil;

@interface ZXTimerTarget : NSObject
+ (void)timerFired:(NSTimer *)timer;
@end

static NSString* autoLaunchFilePath(void)
{
    return [getDocumentRoot() stringByAppendingPathComponent:kAutoLaunchFileName];
}

static NSMutableDictionary* loadAutoLaunchConfig(void)
{
    NSString *path = autoLaunchFilePath();
    NSMutableDictionary *config = [NSMutableDictionary dictionaryWithContentsOfFile:path];
    if (!config)
    {
        config = [NSMutableDictionary dictionary];
    }
    return config;
}

static BOOL saveAutoLaunchConfig(NSMutableDictionary *config, NSError **error)
{
    NSString *path = autoLaunchFilePath();
    BOOL ok = [config writeToFile:path atomically:YES];
    if (!ok && error)
    {
        *error = [NSError errorWithDomain:@"com.zjx.zxtouchsp"
                                     code:999
                                 userInfo:@{NSLocalizedDescriptionKey:@"-1;;Failed to save auto launch config.\r\n"}];
    }
    return ok;
}

NSString* setAutoLaunchFromRawData(UInt8 *eventData, NSError **error)
{
    NSArray *data = [[NSString stringWithUTF8String:(char*)eventData] componentsSeparatedByString:@";;"];
    if ([data count] < 3)
    {
        if (error)
        {
            *error = [NSError errorWithDomain:@"com.zjx.zxtouchsp"
                                         code:999
                                     userInfo:@{NSLocalizedDescriptionKey:@"-1;;Auto launch requires name, script, enabled.\r\n"}];
        }
        return nil;
    }

    NSString *name = data[0];
    NSString *script = data[1];
    BOOL enabled = [data[2] intValue] != 0;

    NSMutableDictionary *config = loadAutoLaunchConfig();
    config[name] = @{@"script": script, @"enabled": @(enabled)};
    saveAutoLaunchConfig(config, error);
    return @"";
}

NSString* listAutoLaunch(NSError **error)
{
    NSMutableDictionary *config = loadAutoLaunchConfig();
    NSMutableArray<NSString*> *entries = [NSMutableArray array];
    [config enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSDictionary *obj, BOOL *stop) {
        NSString *script = obj[@"script"] ?: @"";
        NSString *enabled = [obj[@"enabled"] boolValue] ? @"1" : @"0";
        [entries addObject:[NSString stringWithFormat:@"%@,,%@,,%@", key, script, enabled]];
    }];
    return [entries componentsJoinedByString:@";;"];
}

static void ensureTimerRegistry(void)
{
    if (!timerRegistry)
    {
        timerRegistry = [[NSMutableDictionary alloc] init];
    }
}

static void timerFired(NSTimer *timer)
{
    NSDictionary *info = timer.userInfo;
    NSString *script = info[@"script"];
    NSError *err = nil;
    if (script)
    {
        playScript((UInt8*)[script UTF8String], &err);
    }

    if (![info[@"repeat"] boolValue])
    {
        NSString *name = info[@"name"];
        if (name)
        {
            [timerRegistry removeObjectForKey:name];
        }
        [timer invalidate];
    }
}

@implementation ZXTimerTarget
+ (void)timerFired:(NSTimer *)timer
{
    timerFired(timer);
}
@end

NSString* setTimerFromRawData(UInt8 *eventData, NSError **error)
{
    NSArray *data = [[NSString stringWithUTF8String:(char*)eventData] componentsSeparatedByString:@";;"];
    if ([data count] < 4)
    {
        if (error)
        {
            *error = [NSError errorWithDomain:@"com.zjx.zxtouchsp"
                                         code:999
                                     userInfo:@{NSLocalizedDescriptionKey:@"-1;;Timer requires name, interval, repeat, script.\r\n"}];
        }
        return nil;
    }

    NSString *name = data[0];
    NSTimeInterval interval = [data[1] doubleValue];
    BOOL repeat = [data[2] intValue] != 0;
    NSString *script = data[3];

    if (interval <= 0)
    {
        if (error)
        {
            *error = [NSError errorWithDomain:@"com.zjx.zxtouchsp"
                                         code:999
                                     userInfo:@{NSLocalizedDescriptionKey:@"-1;;Timer interval must be > 0.\r\n"}];
        }
        return nil;
    }

    ensureTimerRegistry();

    NSTimer *existing = timerRegistry[name];
    if (existing)
    {
        [existing invalidate];
    }

    NSDictionary *userInfo = @{@"name": name, @"script": script, @"repeat": @(repeat)};
    dispatch_async(dispatch_get_main_queue(), ^{
        NSTimer *timer = [NSTimer scheduledTimerWithTimeInterval:interval
                                                          target:[ZXTimerTarget class]
                                                        selector:@selector(timerFired:)
                                                        userInfo:userInfo
                                                         repeats:repeat];
        timerRegistry[name] = timer;
    });

    return @"";
}

NSString* removeTimerFromRawData(UInt8 *eventData, NSError **error)
{
    NSString *name = [NSString stringWithFormat:@"%s", eventData];
    if ([name length] == 0)
    {
        if (error)
        {
            *error = [NSError errorWithDomain:@"com.zjx.zxtouchsp"
                                         code:999
                                     userInfo:@{NSLocalizedDescriptionKey:@"-1;;Timer name is required.\r\n"}];
        }
        return nil;
    }

    ensureTimerRegistry();
    NSTimer *timer = timerRegistry[name];
    if (timer)
    {
        [timer invalidate];
        [timerRegistry removeObjectForKey:name];
    }
    return @"";
}

NSString* keepAwakeFromRawData(UInt8 *eventData, NSError **error)
{
    NSString *value = [NSString stringWithFormat:@"%s", eventData];
    BOOL enabled = [value intValue] != 0;
    dispatch_async(dispatch_get_main_queue(), ^{
        [UIApplication sharedApplication].idleTimerDisabled = enabled;
    });
    return @"";
}

NSString* stopScriptFromRawData(NSError **error)
{
    stopScriptPlaying(error);
    return @"";
}
