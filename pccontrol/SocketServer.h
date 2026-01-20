#ifndef SERVER_H
#define SERVER_H

#import <Foundation/Foundation.h>

#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>

// IPC is now handled via Unix Domain Socket defined in IPCConfig.h
// These definitions are kept for reference or legacy support if needed
// #define PORT 6001
// #define ADDR "127.0.0.1"

void socketServer();
static void readStream(CFReadStreamRef readStream, CFStreamEventType eventype, void * clientCallBackInfo);
static void TCPServerAcceptCallBack(CFSocketRef socket, CFSocketCallBackType type, CFDataRef address, const void *data, void *info);
int notifyClient(UInt8* msg, CFWriteStreamRef client);

#endif
