#include "HardwareKey.h"
#include "headers/IOHIDEvent.h"
#include "headers/IOHIDEventSystemClient.h"
#include <mach/mach_time.h>

static IOHIDEventSystemClientRef hardwareKeyClient = NULL;

static Boolean getUsageForKeyType(int keyType, uint16_t *usagePage, uint16_t *usage)
{
    // Consumer usage page (0x0C) values from HID Usage Tables.
    switch (keyType)
    {
        case HARDWARE_KEY_HOME:
            *usagePage = 0x0C;
            *usage = 0x0223; // AC Home
            return true;
        case HARDWARE_KEY_VOLUME_UP:
            *usagePage = 0x0C;
            *usage = 0x00E9; // Volume Increment
            return true;
        case HARDWARE_KEY_VOLUME_DOWN:
            *usagePage = 0x0C;
            *usage = 0x00EA; // Volume Decrement
            return true;
        case HARDWARE_KEY_LOCK:
            *usagePage = 0x0C;
            *usage = 0x0030; // Power
            return true;
        default:
            return false;
    }
}

int sendHardwareKeyEventFromRawData(UInt8 *eventData, NSError **error)
{
    NSArray *data = [[NSString stringWithUTF8String:(char*)eventData] componentsSeparatedByString:@";;"];
    if ([data count] < 2)
    {
        if (error)
        {
            *error = [NSError errorWithDomain:@"com.zjx.zxtouchsp"
                                         code:999
                                     userInfo:@{NSLocalizedDescriptionKey:@"-1;;Hardware key task missing action or key type.\r\n"}];
        }
        return -1;
    }

    int action = [data[0] intValue];
    int keyType = [data[1] intValue];
    Boolean isDown = action == HARDWARE_KEY_ACTION_DOWN;

    uint16_t usagePage = 0;
    uint16_t usage = 0;
    if (!getUsageForKeyType(keyType, &usagePage, &usage))
    {
        if (error)
        {
            *error = [NSError errorWithDomain:@"com.zjx.zxtouchsp"
                                         code:999
                                     userInfo:@{NSLocalizedDescriptionKey:@"-1;;Unknown hardware key type.\r\n"}];
        }
        return -1;
    }

    if (!hardwareKeyClient)
    {
        hardwareKeyClient = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
    }

    if (!hardwareKeyClient)
    {
        if (error)
        {
            *error = [NSError errorWithDomain:@"com.zjx.zxtouchsp"
                                         code:999
                                     userInfo:@{NSLocalizedDescriptionKey:@"-1;;Unable to create HID event client.\r\n"}];
        }
        return -1;
    }

    IOHIDEventRef event = IOHIDEventCreateKeyboardEvent(kCFAllocatorDefault,
                                                       mach_absolute_time(),
                                                       usagePage,
                                                       usage,
                                                       isDown,
                                                       0);
    if (!event)
    {
        if (error)
        {
            *error = [NSError errorWithDomain:@"com.zjx.zxtouchsp"
                                         code:999
                                     userInfo:@{NSLocalizedDescriptionKey:@"-1;;Unable to create hardware key event.\r\n"}];
        }
        return -1;
    }

    IOHIDEventSystemClientDispatchEvent(hardwareKeyClient, event);
    CFRelease(event);
    return 0;
}
