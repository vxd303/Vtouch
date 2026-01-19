#import <Foundation/Foundation.h>
#include <stdio.h>
#include <sys/socket.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <string.h>
#include <signal.h>
#include "NSTask.h"

// Task 1.1: Daemon Skeleton
// This daemon currently just stays alive.
// In Task 1.2, we will move the SocketServer logic here.

#define PORT 6000

// Keep the daemon running
BOOL isRunning = YES;

void handle_signal(int signal) {
    NSLog(@"com.zjx.zxtouchd: Received signal %d, stopping...", signal);
    isRunning = NO;
    CFRunLoopStop(CFRunLoopGetMain());
}

int main(int argc, char *argv[], char *envp[]) {
    @autoreleasepool {
        NSLog(@"com.zjx.zxtouchd: Daemon started. Waiting for instructions...");

        signal(SIGTERM, handle_signal);
        signal(SIGINT, handle_signal);

        // Prevent exit and keep the runloop alive
        NSRunLoop *runLoop = [NSRunLoop currentRunLoop];
        while (isRunning && [runLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate distantFuture]]);

        NSLog(@"com.zjx.zxtouchd: Daemon exiting.");
    }
    return 0;
}
