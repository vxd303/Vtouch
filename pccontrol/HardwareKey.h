#ifndef HARDWARE_KEY_H
#define HARDWARE_KEY_H

#import <Foundation/Foundation.h>

#define HARDWARE_KEY_ACTION_UP 0
#define HARDWARE_KEY_ACTION_DOWN 1

#define HARDWARE_KEY_HOME 1
#define HARDWARE_KEY_VOLUME_UP 2
#define HARDWARE_KEY_VOLUME_DOWN 3
#define HARDWARE_KEY_LOCK 4

int sendHardwareKeyEventFromRawData(UInt8 *eventData, NSError **error);

#endif
