#ifndef PROCESS_H
#define PROCESS_H

#import <Foundation/Foundation.h>

#include <dlfcn.h>

int switchProcessForegroundFromRawData(UInt8 *eventData);
int bringAppForeground(NSString *appIdentifier);
id getFrontMostApplication();
NSString* killAppFromRawData(UInt8 *eventData, NSError **error);
NSString* appStateFromRawData(UInt8 *eventData, NSError **error);
NSString* appInfoFromRawData(UInt8 *eventData, NSError **error);
NSString* frontMostAppId(void);
NSString* frontMostAppOrientation(void);

#endif
