#import <Foundation/Foundation.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>

#define PORT 6000
#define ADDR "0.0.0.0"

// Forward declaration
void processTask(UInt8 *buff, CFWriteStreamRef writeStreamRef);

CFSocketRef socketRef;
CFWriteStreamRef writeStreamRef = NULL;
CFReadStreamRef readStreamRef = NULL;
static NSMutableDictionary *socketClients = NULL;

static void readStream(CFReadStreamRef readStream, CFStreamEventType eventype, void * clientCallBackInfo);
static void TCPServerAcceptCallBack(CFSocketRef socket, CFSocketCallBackType type, CFDataRef address, const void *data, void *info);

int notifyClient(UInt8* msg, CFWriteStreamRef client);

void daemonSocketServer()
{
    @autoreleasepool {
        CFSocketRef _socket = CFSocketCreate(kCFAllocatorDefault, PF_INET, SOCK_STREAM, IPPROTO_TCP, kCFSocketAcceptCallBack, TCPServerAcceptCallBack, NULL);

        if (_socket == NULL) {
            NSLog(@"### com.zjx.zxtouchd: failed to create socket.");
            return;
        }

        UInt32 reused = 1;
        setsockopt(CFSocketGetNative(_socket), SOL_SOCKET, SO_REUSEADDR, (const void *)&reused, sizeof(reused));

        struct sockaddr_in Socketaddr;
        memset(&Socketaddr, 0, sizeof(Socketaddr));
        Socketaddr.sin_len = sizeof(Socketaddr);
        Socketaddr.sin_family = AF_INET;
        Socketaddr.sin_addr.s_addr = inet_addr(ADDR);
        Socketaddr.sin_port = htons(PORT);

        CFDataRef address = CFDataCreate(kCFAllocatorDefault,  (UInt8 *)&Socketaddr, sizeof(Socketaddr));

        if (CFSocketSetAddress(_socket, address) != kCFSocketSuccess) {
            if (_socket) {
                CFRelease(_socket);
            }
            _socket = NULL;
        }

        socketClients = [[NSMutableDictionary alloc] init];

        NSLog(@"### com.zjx.zxtouchd: connection waiting on port %d", PORT);
        CFRunLoopRef cfrunLoop = CFRunLoopGetCurrent();
        CFRunLoopSourceRef source = CFSocketCreateRunLoopSource(kCFAllocatorDefault, _socket, 0);
        CFRunLoopAddSource(cfrunLoop, source, kCFRunLoopCommonModes);
        CFRelease(source);
    }
}

static void readStream(CFReadStreamRef readStream, CFStreamEventType eventype, void * clientCallBackInfo)
{
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        @autoreleasepool{
            UInt8 readDataBuff[2049]; // +1 for safety
            memset(readDataBuff, 0, sizeof(readDataBuff));

            CFIndex hasRead = CFReadStreamRead(readStream, readDataBuff, 2048); // Read max 2048 to leave space for null terminator

            if (hasRead > 0) {
                readDataBuff[hasRead] = '\0'; // Ensure null termination

                char *saveptr;
                // strtok_r is thread-safe
                for(char * charSep = strtok_r((char*)readDataBuff, "\r\n", &saveptr); charSep != NULL; charSep = strtok_r(NULL, "\r\n", &saveptr)) {
                    UInt8 *buff = (UInt8*)charSep;
                    id temp = [socketClients objectForKey:@((long)readStream)];
                    if (temp != nil)
                        processTask(buff, (CFWriteStreamRef)[temp longValue]);
                    else
                        processTask(buff, NULL);
                }
            }
        }
    });
}

static dispatch_queue_t socketWriteQueue;
static dispatch_once_t onceToken;

int notifyClient(UInt8* msg, CFWriteStreamRef client)
{
    if (client == NULL || msg == NULL) return -1;

    dispatch_once(&onceToken, ^{
        socketWriteQueue = dispatch_queue_create("com.zjx.zxtouchd.socketWriteQueue", NULL);
    });

    size_t len = strlen((char*)msg);
    NSData *data = [NSData dataWithBytes:msg length:len];

    CFRetain(client);
    dispatch_async(socketWriteQueue, ^{
        if (CFWriteStreamGetStatus(client) == kCFStreamStatusOpen || CFWriteStreamGetStatus(client) == kCFStreamStatusWriting) {
            CFWriteStreamWrite(client, (const UInt8*)[data bytes], [data length]);
        }
        CFRelease(client);
    });
    return 0;
}

static void TCPServerAcceptCallBack(CFSocketRef socket, CFSocketCallBackType type, CFDataRef address, const void *data, void *info)
{
    if (kCFSocketAcceptCallBack == type) {
        CFSocketNativeHandle nativeSocketHandle = *(CFSocketNativeHandle *)data;
        readStreamRef = NULL;
        writeStreamRef = NULL;

        CFStreamCreatePairWithSocket(kCFAllocatorDefault, nativeSocketHandle, &readStreamRef, &writeStreamRef);

        if (readStreamRef && writeStreamRef) {
            CFReadStreamOpen(readStreamRef);
            CFWriteStreamOpen(writeStreamRef);

            CFStreamClientContext context = {0, NULL, NULL, NULL };

            if (!CFReadStreamSetClient(readStreamRef, kCFStreamEventHasBytesAvailable, readStream, &context)) {
                return;
            }

            CFReadStreamScheduleWithRunLoop(readStreamRef, CFRunLoopGetCurrent(), kCFRunLoopCommonModes);
			[socketClients setObject:@((long)writeStreamRef) forKey:@((long)readStreamRef)];
        }
        else {
            close(nativeSocketHandle);
        }
    }
}
