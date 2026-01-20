#import <Foundation/Foundation.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <string.h>
#include "NSTask.h"
#include "../pccontrol/IPCConfig.h"

// Defines for Task Types (Copied from Task.h)
#define TASK_USLEEP 18
#define TASK_RUN_SHELL 17

// Forward declaration
int notifyClient(UInt8* msg, CFWriteStreamRef client);

static int getTaskType(UInt8* dataArray)
{
	int taskType = 0;
	for (int i = 0; i <= 1; i++)
	{
		taskType += (dataArray[i] - '0')*pow(10, 1-i);
	}
	return taskType;
}

// Function to forward data to SpringBoard Tweak
static void forwardToSpringBoard(UInt8 *buff, CFWriteStreamRef originalClient)
{
    int sock = 0;
    struct sockaddr_un serv_addr;

    // Create socket
    if ((sock = socket(AF_LOCAL, SOCK_STREAM, 0)) < 0) {
        NSLog(@"com.zjx.zxtouchd: IPC Socket creation error");
        notifyClient((UInt8*)"-1;;IPC Error\r\n", originalClient);
        return;
    }

    memset(&serv_addr, 0, sizeof(serv_addr));
    serv_addr.sun_family = AF_LOCAL;
    strcpy(serv_addr.sun_path, IPC_SOCKET_PATH);

    // Connect
    if (connect(sock, (struct sockaddr *)&serv_addr, sizeof(serv_addr)) < 0) {
        NSLog(@"com.zjx.zxtouchd: IPC Connection Failed. Is SpringBoard running? Path: %s", IPC_SOCKET_PATH);
        notifyClient((UInt8*)"-1;;IPC Connection Failed\r\n", originalClient);
        close(sock);
        return;
    }

    // Send Request
    send(sock, buff, strlen((char*)buff), 0);
    send(sock, "\r\n", 2, 0);

    // Read Response Loop
    NSMutableData *responseData = [NSMutableData data];
    char chunk[4096];
    long valread;

    // Set a timeout for read
    struct timeval tv;
    tv.tv_sec = 5;  // 5 seconds timeout
    tv.tv_usec = 0;
    setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, (const char*)&tv, sizeof tv);

    while ((valread = read(sock, chunk, sizeof(chunk) - 1)) > 0) {
        chunk[valread] = '\0';
        [responseData appendBytes:chunk length:valread];

        if (valread < (sizeof(chunk) - 1)) {
            if (chunk[valread-1] == '\n') {
                break;
            }
        }
    }

    close(sock);

    if ([responseData length] > 0) {
        NSMutableData *safeBuffer = [NSMutableData dataWithData:responseData];
        char nullByte = 0;
        [safeBuffer appendBytes:&nullByte length:1];

        notifyClient((UInt8*)[safeBuffer bytes], originalClient);
    } else {
        notifyClient((UInt8*)"0;;No Response from SB\r\n", originalClient);
    }
}

void processTask(UInt8 *buff, CFWriteStreamRef writeStreamRef)
{
    // Basic validation
    if (strlen((char*)buff) < 2) return;

    int taskType = getTaskType(buff);
    UInt8 *eventData = buff + 0x2;

    if (taskType == TASK_USLEEP)
    {
        int usleepTime = atoi((char*)eventData);
        usleep(usleepTime);
        if (writeStreamRef) {
             notifyClient((UInt8*)"0;;Sleep ends\r\n", writeStreamRef);
        }
    }
    else if (taskType == TASK_RUN_SHELL)
    {
        NSString *cmd = [NSString stringWithUTF8String:(char*)eventData];
        NSLog(@"com.zjx.zxtouchd: Executing shell: %@", cmd);

        @autoreleasepool {
            NSTask *task = [[NSTask alloc] init];
            [task setLaunchPath:@"/bin/sh"];
            [task setArguments:@[@"-c", cmd]];
            [task launch];
            [task waitUntilExit];
        }

        if (writeStreamRef) {
            notifyClient((UInt8*)"0\r\n", writeStreamRef);
        }
    }
    else
    {
        forwardToSpringBoard(buff, writeStreamRef);
    }
}
