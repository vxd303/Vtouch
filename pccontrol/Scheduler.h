#ifndef SCHEDULER_H
#define SCHEDULER_H

#import <Foundation/Foundation.h>

NSString* setAutoLaunchFromRawData(UInt8 *eventData, NSError **error);
NSString* listAutoLaunch(NSError **error);
NSString* setTimerFromRawData(UInt8 *eventData, NSError **error);
NSString* removeTimerFromRawData(UInt8 *eventData, NSError **error);
NSString* keepAwakeFromRawData(UInt8 *eventData, NSError **error);
NSString* stopScriptFromRawData(NSError **error);

#endif
