#ifndef SERVER_H
#define SERVER_H

#import <Foundation/Foundation.h>

#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>

// Internal IPC Port for SpringBoard Tweak
#define PORT 6001
#define ADDR "127.0.0.1"

void socketServer();
static void readStream(CFReadStreamRef readStream, CFStreamEventType eventype, void * clientCallBackInfo);
static void TCPServerAcceptCallBack(CFSocketRef socket, CFSocketCallBackType type, CFDataRef address, const void *data, void *info);
int notifyClient(UInt8* msg, CFWriteStreamRef client);

#endif
