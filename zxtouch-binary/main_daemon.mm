#import <Foundation/Foundation.h>
#include <stdio.h>
#include <sys/socket.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <string.h>
#include <signal.h>
#include "NSTask.h"

// Task 1.2: Daemon with Socket Server

#define PORT 6000

// Forward declaration
void daemonSocketServer();

// Keep the daemon running
BOOL isRunning = YES;

void handle_signal(int signal) {
    NSLog(@"com.zjx.zxtouchd: Received signal %d, stopping...", signal);
    isRunning = NO;
    CFRunLoopStop(CFRunLoopGetMain());
}

int main(int argc, char *argv[], char *envp[]) {
    @autoreleasepool {
        NSLog(@"com.zjx.zxtouchd: Daemon started (Version 1.2 - Proxy Mode).");

        signal(SIGTERM, handle_signal);
        signal(SIGINT, handle_signal);

        // Start the Socket Server
        // This sets up the CFSocket sources in the runloop
        daemonSocketServer();

        // Prevent exit and keep the runloop alive
        NSRunLoop *runLoop = [NSRunLoop currentRunLoop];
        while (isRunning && [runLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate distantFuture]]);

        NSLog(@"com.zjx.zxtouchd: Daemon exiting.");
    }
    return 0;
}
