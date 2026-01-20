// TODO: multiple client write back support


#include "SocketServer.h"
#include "IPCConfig.h"
#include "Task.h"
#include <sys/un.h>


CFSocketRef socketRef;
CFWriteStreamRef writeStreamRef = NULL;
CFReadStreamRef readStreamRef = NULL;
static NSMutableDictionary *socketClients = NULL;
void report_memory(void);

// Reference: https://www.jianshu.com/p/9353105a9129

void socketServer()
{
    @autoreleasepool {
        unlink(IPC_SOCKET_PATH); // Remove existing file

        CFSocketRef _socket = CFSocketCreate(kCFAllocatorDefault, PF_LOCAL, SOCK_STREAM, 0, kCFSocketAcceptCallBack, TCPServerAcceptCallBack, NULL);
        
        if (_socket == NULL) {
            NSLog(@"### com.zjx.springboard: failed to create socket.");
            return;
        }
        
        int nativeSocket = CFSocketGetNative(_socket);
        struct sockaddr_un addr;
        memset(&addr, 0, sizeof(addr));
        addr.sun_family = AF_LOCAL;
        strcpy(addr.sun_path, IPC_SOCKET_PATH);
        
        // Use CFDataRef to wrap the address
        CFDataRef address = CFDataCreate(kCFAllocatorDefault, (const UInt8 *)&addr, sizeof(addr));
        
        if (CFSocketSetAddress(_socket, address) != kCFSocketSuccess) {
            NSLog(@"### com.zjx.springboard: failed to bind socket.");
            if (_socket) {
                CFRelease(_socket);
            }
            _socket = NULL;
        } else {
            // Set permissions
            chmod(IPC_SOCKET_PATH, 0777); // Allow zxtouchd to access
        }
        
        CFRelease(address);

        socketClients = [[NSMutableDictionary alloc] init];

        NSLog(@"### com.zjx.springboard: IPC connection waiting");
        CFRunLoopRef cfrunLoop = CFRunLoopGetCurrent();
        CFRunLoopSourceRef source = CFSocketCreateRunLoopSource(kCFAllocatorDefault, _socket, 0);

        CFRunLoopAddSource(cfrunLoop, source, kCFRunLoopCommonModes);

        CFRelease(source);
        CFRunLoopRun();
    }

}

static void readStream(CFReadStreamRef readStream, CFStreamEventType eventype, void * clientCallBackInfo) 
{
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        @autoreleasepool{
            UInt8 readDataBuff[2048];
            memset(readDataBuff, 0, sizeof(readDataBuff));
            
            CFIndex hasRead = CFReadStreamRead(readStream, readDataBuff, sizeof(readDataBuff));

            if (hasRead > 0) {
                //don't know how it works, copied from https://www.educative.io/edpresso/splitting-a-string-using-strtok-in-c
                for(char * charSep = strtok((char*)readDataBuff, "\r\n"); charSep != NULL; charSep = strtok(NULL, "\r\n")) {
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
        socketWriteQueue = dispatch_queue_create("com.zjx.springboard.socketWriteQueue", NULL);
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
        
        CFSocketNativeHandle  nativeSocketHandle = *(CFSocketNativeHandle *)data;
        
        // No need for getpeername on UDS
        
        readStreamRef = NULL;
        writeStreamRef = NULL;

        CFStreamCreatePairWithSocket(kCFAllocatorDefault, nativeSocketHandle, &readStreamRef, &writeStreamRef);
       
        if (readStreamRef && writeStreamRef) {
            CFReadStreamOpen(readStreamRef);
            CFWriteStreamOpen(writeStreamRef);
            
            CFStreamClientContext context = {0, NULL, NULL, NULL };

            if (!CFReadStreamSetClient(readStreamRef, kCFStreamEventHasBytesAvailable, readStream, &context)) {
                NSLog(@"### com.zjx.springboard: error 1");
                return;
            }
            
            CFReadStreamScheduleWithRunLoop(readStreamRef, CFRunLoopGetCurrent(), kCFRunLoopCommonModes);

			[socketClients setObject:@((long)writeStreamRef) forKey:@((long)readStreamRef)];
        }
        else
        {
            close(nativeSocketHandle);
        }
		
    }
    
}
