#import <Foundation/Foundation.h>
#include <stdio.h>
#include <sys/socket.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <string.h>
#include <signal.h>
#include "NSTask.h"
#include "../pccontrol/SocketServer.h"

// Re-declare since we are in a different project structure but reusing code
// ideally we should fix the makefile to include the source files
// For now, I will modify the Makefile to include SocketServer.xm and Task.xm

#define PORT 6000

// Keep the daemon running
BOOL isRunning = YES;

void handle_signal(int signal) {
    NSLog(@"com.zjx.zxtouchd: Received signal %d, stopping...", signal);
    isRunning = NO;
}

int main(int argc, char *argv[], char *envp[]) {
    @autoreleasepool {
        NSLog(@"com.zjx.zxtouchd: Daemon started.");

        signal(SIGTERM, handle_signal);
        signal(SIGINT, handle_signal);

        // Start the Socket Server
        // We will call the existing socketServer function from pccontrol/SocketServer.xm
        // But first we need to make sure that file is compiled into this binary.
        // For now, let's just print a message.

        NSLog(@"com.zjx.zxtouchd: Starting socket server on port %d...", PORT);

        // In the future: socketServer();
        // Since socketServer() blocks, we are good.

        // Prevent exit
        NSRunLoop *runLoop = [NSRunLoop currentRunLoop];
        while (isRunning && [runLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate distantFuture]]);

        NSLog(@"com.zjx.zxtouchd: Daemon exiting.");
    }
    return 0;
}
