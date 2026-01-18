#include "RuntimeUtils.h"
#include "Common.h"
#include <CoreFoundation/CoreFoundation.h>
#include "headers/CFUserNotification.h"

static NSString *lastDialogValue = @"";

NSString* dialogFromRawData(UInt8 *eventData, NSError **error)
{
    NSArray *data = [[NSString stringWithUTF8String:(char*)eventData] componentsSeparatedByString:@";;"];
    NSString *title = data.count > 0 ? data[0] : @"ZXTouch";
    NSString *message = data.count > 1 ? data[1] : @"";
    NSString *ok = data.count > 2 ? data[2] : @"OK";
    NSString *cancel = data.count > 3 ? data[3] : @"Cancel";

    CFOptionFlags response = 0;
    CFUserNotificationDisplayAlert(0,
                                   kCFUserNotificationNoteAlertLevel,
                                   NULL,
                                   NULL,
                                   NULL,
                                   (__bridge CFStringRef)title,
                                   (__bridge CFStringRef)message,
                                   (__bridge CFStringRef)ok,
                                   (__bridge CFStringRef)cancel,
                                   NULL,
                                   &response);

    lastDialogValue = [NSString stringWithFormat:@"%ld", (long)response];
    return lastDialogValue;
}

NSString* clearDialogValues(NSError **error)
{
    lastDialogValue = @"";
    return @"";
}

NSString* rootDirValue(void)
{
    return getDocumentRoot();
}

NSString* currentDirValue(void)
{
    return getDocumentRoot();
}

NSString* botPathValue(void)
{
    return getScriptsFolder();
}
