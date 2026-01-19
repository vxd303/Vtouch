#include "H264Stream.h"
#include "Screen.h"

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <VideoToolbox/VideoToolbox.h>

#include <sys/socket.h>
#include <netinet/in.h>
#include <unistd.h>
#include <errno.h>
#include <stdatomic.h>

static const int kH264StreamPort = 7001;
static const int kH264TargetWidth = 1280;
static const int kH264TargetHeight = 720;
static const int kH264TargetFPS = 20;
static const int kH264KeyframeIntervalSeconds = 2;
static const int kPCRIntervalFrames = 10;

// TS PIDs
static const uint16_t kTSPatPid = 0x0000;
static const uint16_t kTSPmtPid = 0x0100;
static const uint16_t kTSVideoPid = 0x0101;
static const uint16_t kTSProgramNumber = 1;

// only one viewer
static _Atomic int gActiveClientFd = -1;

@interface ZXTH264EncoderContext : NSObject
@property(nonatomic, strong) NSMutableData *encodedData;
@property(nonatomic) dispatch_semaphore_t semaphore;
@property(nonatomic) BOOL isKeyframe;
@end

@implementation ZXTH264EncoderContext
@end

#pragma mark - Utils

static void appendAnnexBHeader(NSMutableData *data) {
    static const uint8_t header[] = {0x00, 0x00, 0x00, 0x01};
    [data appendBytes:header length:4];
}

static bool sendAll(int fd, const uint8_t *buf, size_t len) {
    size_t sent = 0;
    while (sent < len) {
        ssize_t r = send(fd, buf + sent, len - sent, 0);
        if (r > 0) {
            sent += (size_t)r;
        } else if (r < 0 && errno == EINTR) {
            continue;
        } else {
            return false;
        }
    }
    return true;
}

static uint32_t mpegCrc32(const uint8_t *data, size_t len) {
    uint32_t crc = 0xFFFFFFFF;
    for (size_t i = 0; i < len; i++) {
        crc ^= (uint32_t)data[i] << 24;
        for (int b = 0; b < 8; b++)
            crc = (crc & 0x80000000) ? (crc << 1) ^ 0x04C11DB7 : (crc << 1);
    }
    return crc;
}

#pragma mark - PAT / PMT

static NSData *buildPAT(uint8_t cc) {
    uint8_t sec[16] = {0};
    size_t i = 0;
    sec[i++] = 0x00;
    sec[i++] = 0xB0;
    sec[i++] = 0x00;
    sec[i++] = 0x00;
    sec[i++] = 0x01;
    sec[i++] = 0xC1;
    sec[i++] = 0x00;
    sec[i++] = 0x00;
    sec[i++] = (kTSProgramNumber >> 8) & 0xFF;
    sec[i++] = kTSProgramNumber & 0xFF;
    sec[i++] = 0xE0 | ((kTSPmtPid >> 8) & 0x1F);
    sec[i++] = kTSPmtPid & 0xFF;

    size_t slen = (i - 3) + 4;
    sec[1] = 0xB0 | ((slen >> 8) & 0x0F);
    sec[2] = slen & 0xFF;

    uint32_t crc = mpegCrc32(sec, i);
    sec[i++] = crc >> 24;
    sec[i++] = crc >> 16;
    sec[i++] = crc >> 8;
    sec[i++] = crc;

    uint8_t pkt[188] = {0};
    pkt[0] = 0x47;
    pkt[1] = 0x40;
    pkt[2] = 0x00;
    pkt[3] = 0x10 | (cc & 0x0F);
    pkt[4] = 0x00;
    memcpy(pkt + 5, sec, i);
    memset(pkt + 5 + i, 0xFF, 188 - 5 - i);
    return [NSData dataWithBytes:pkt length:188];
}

static NSData *buildPMT(uint8_t cc) {
    uint8_t sec[32] = {0};
    size_t i = 0;
    sec[i++] = 0x02;
    sec[i++] = 0xB0;
    sec[i++] = 0x00;
    sec[i++] = (kTSProgramNumber >> 8) & 0xFF;
    sec[i++] = kTSProgramNumber & 0xFF;
    sec[i++] = 0xC1;
    sec[i++] = 0x00;
    sec[i++] = 0x00;
    sec[i++] = 0xE0 | ((kTSVideoPid >> 8) & 0x1F);
    sec[i++] = kTSVideoPid & 0xFF;
    sec[i++] = 0xF0;
    sec[i++] = 0x00;
    sec[i++] = 0x1B;
    sec[i++] = 0xE0 | ((kTSVideoPid >> 8) & 0x1F);
    sec[i++] = kTSVideoPid & 0xFF;
    sec[i++] = 0xF0;
    sec[i++] = 0x00;

    size_t slen = (i - 3) + 4;
    sec[1] = 0xB0 | ((slen >> 8) & 0x0F);
    sec[2] = slen & 0xFF;

    uint32_t crc = mpegCrc32(sec, i);
    sec[i++] = crc >> 24;
    sec[i++] = crc >> 16;
    sec[i++] = crc >> 8;
    sec[i++] = crc;

    uint8_t pkt[188] = {0};
    pkt[0] = 0x47;
    pkt[1] = 0x40 | ((kTSPmtPid >> 8) & 0x1F);
    pkt[2] = kTSPmtPid & 0xFF;
    pkt[3] = 0x10 | (cc & 0x0F);
    pkt[4] = 0x00;
    memcpy(pkt + 5, sec, i);
    memset(pkt + 5 + i, 0xFF, 188 - 5 - i);
    return [NSData dataWithBytes:pkt length:188];
}

#pragma mark - TS packet writer

static bool writeTSPackets(int fd,
                           uint16_t pid,
                           const uint8_t *payload,
                           size_t len,
                           bool start,
                           bool addPCR,
                           uint64_t pts90k,
                           uint8_t *cc) {
    size_t off = 0;
    while (off < len) {
        uint8_t pkt[188] = {0};
        bool first = start && (off == 0);
        bool pcrHere = addPCR && first;

        pkt[0] = 0x47;
        pkt[1] = (first ? 0x40 : 0x00) | ((pid >> 8) & 0x1F);
        pkt[2] = pid & 0xFF;
        pkt[3] = (*cc & 0x0F);
        (*cc) = ((*cc) + 1) & 0x0F;

        size_t payloadMax = 184;
        size_t remain = len - off;
        size_t copy = remain < payloadMax ? remain : payloadMax;

        if (pcrHere || copy < payloadMax) {
            pkt[3] |= 0x30;
            uint8_t *ad = pkt + 4;
            size_t ai = 2;
            ad[1] = pcrHere ? 0x10 : 0x00;

            if (pcrHere) {
                uint64_t base = pts90k & ((1ULL << 33) - 1);
                ad[2] = (base >> 25) & 0xFF;
                ad[3] = (base >> 17) & 0xFF;
                ad[4] = (base >> 9) & 0xFF;
                ad[5] = (base >> 1) & 0xFF;
                ad[6] = (uint8_t)(((base & 1) << 7) | 0x7E);
                ad[7] = 0x00;
                ai = 8;
            }

            size_t adaptLen = ai - 1;
            size_t stuff = payloadMax - (ai + copy);
            adaptLen += stuff;
            ad[0] = (uint8_t)adaptLen;
            memset(ad + ai, 0xFF, stuff);
            memcpy(pkt + 4 + 1 + adaptLen, payload + off, copy);
        } else {
            pkt[3] |= 0x10;
            memcpy(pkt + 4, payload + off, copy);
        }

        if (!sendAll(fd, pkt, 188)) return false;
        off += copy;
    }
    return true;
}

#pragma mark - Encoder

static void H264OutputCallback(void *ref,
                              void *src,
                              OSStatus st,
                              VTEncodeInfoFlags flags,
                              CMSampleBufferRef sb) {
    (void)ref; (void)flags;
    if (!src) return;

    ZXTH264EncoderContext *ctx = (ZXTH264EncoderContext *)CFBridgingRelease(src);
    if (st != noErr || !sb || !CMSampleBufferDataIsReady(sb)) {
        dispatch_semaphore_signal(ctx.semaphore);
        return;
    }

    BOOL key = NO;
    CFArrayRef atts = CMSampleBufferGetSampleAttachmentsArray(sb, false);
    if (atts && CFArrayGetCount(atts)) {
        // Sửa lỗi: ép kiểu CFDictionaryRef
        CFDictionaryRef a = (CFDictionaryRef)CFArrayGetValueAtIndex(atts, 0);
        key = !CFDictionaryContainsKey(a, kCMSampleAttachmentKey_NotSync);
    }
    ctx.isKeyframe = key;

    CMFormatDescriptionRef fmt = CMSampleBufferGetFormatDescription(sb);
    if (key && fmt) {
        const uint8_t *sps,*pps; size_t spsSz,ppsSz;
        if (CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt,0,&sps,&spsSz,NULL,NULL)==noErr &&
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt,1,&pps,&ppsSz,NULL,NULL)==noErr) {
            appendAnnexBHeader(ctx.encodedData);
            [ctx.encodedData appendBytes:sps length:spsSz];
            appendAnnexBHeader(ctx.encodedData);
            [ctx.encodedData appendBytes:pps length:ppsSz];
        }
    }

    CMBlockBufferRef bb = CMSampleBufferGetDataBuffer(sb);
    size_t len; char *ptr;
    if (CMBlockBufferGetDataPointer(bb,0,NULL,&len,&ptr)==noErr) {
        size_t off=0;
        while (off+4<len) {
            uint32_t n; memcpy(&n,ptr+off,4);
            n=CFSwapInt32BigToHost(n);
            appendAnnexBHeader(ctx.encodedData);
            [ctx.encodedData appendBytes:ptr+off+4 length:n];
            off+=4+n;
        }
    }
    dispatch_semaphore_signal(ctx.semaphore);
}

static VTCompressionSessionRef createEncoder(void) {
    VTCompressionSessionRef s=NULL;
    if (VTCompressionSessionCreate(kCFAllocatorDefault,
        kH264TargetWidth,kH264TargetHeight,
        kCMVideoCodecType_H264,
        NULL,NULL,NULL,
        H264OutputCallback,NULL,&s)!=noErr) return NULL;

    VTSessionSetProperty(s,kVTCompressionPropertyKey_RealTime,kCFBooleanTrue);
    VTSessionSetProperty(s,kVTCompressionPropertyKey_ProfileLevel,kVTProfileLevel_H264_Baseline_AutoLevel);
    VTSessionSetProperty(s,kVTCompressionPropertyKey_AllowFrameReordering,kCFBooleanFalse);
    VTSessionSetProperty(s,kVTCompressionPropertyKey_MaxKeyFrameInterval,
        (__bridge CFTypeRef)@(kH264TargetFPS*kH264KeyframeIntervalSeconds));
    VTSessionSetProperty(s,kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration,
        (__bridge CFTypeRef)@(kH264KeyframeIntervalSeconds));
    VTSessionSetProperty(s,kVTCompressionPropertyKey_ExpectedFrameRate,
        (__bridge CFTypeRef)@(kH264TargetFPS));
    VTSessionSetProperty(s,kVTCompressionPropertyKey_AverageBitRate,
        (__bridge CFTypeRef)@(2000000));
    VTCompressionSessionPrepareToEncodeFrames(s);
    return s;
}

#pragma mark - Stream loop

static void streamLoop(int fd) {
    VTCompressionSessionRef enc = createEncoder();
    if (!enc) { close(fd); return; }

    uint8_t patCC=0,pmtCC=0,vidCC=0;
    int64_t frame=0;

    while (1) {
        CGImageRef img=[Screen createScreenShotCGImageRef];
        if (!img) break;

        ZXTH264EncoderContext *ctx=[[ZXTH264EncoderContext alloc]init];
        ctx.encodedData=[NSMutableData data];
        ctx.semaphore=dispatch_semaphore_create(0);
        // Sửa lỗi: ép kiểu void * cho CFBridgingRetain
        void *ref=(void *)CFBridgingRetain(ctx);

        CVPixelBufferRef pb=NULL;
        CVPixelBufferCreate(kCFAllocatorDefault,
            kH264TargetWidth,kH264TargetHeight,
            kCVPixelFormatType_32BGRA,NULL,&pb);

        CVPixelBufferLockBaseAddress(pb,0);
        CGContextRef cg=CGBitmapContextCreate(
            CVPixelBufferGetBaseAddress(pb),
            kH264TargetWidth,kH264TargetHeight,8,
            CVPixelBufferGetBytesPerRow(pb),
            CGColorSpaceCreateDeviceRGB(),
            kCGBitmapByteOrder32Little|kCGImageAlphaPremultipliedFirst);
        CGContextDrawImage(cg,CGRectMake(0,0,kH264TargetWidth,kH264TargetHeight),img);
        CGContextRelease(cg);
        CVPixelBufferUnlockBaseAddress(pb,0);

        VTCompressionSessionEncodeFrame(enc,pb,
            CMTimeMake(frame,kH264TargetFPS),
            kCMTimeInvalid,NULL,ref,NULL);
        CVPixelBufferRelease(pb);
        CGImageRelease(img);

        dispatch_semaphore_wait(ctx.semaphore,DISPATCH_TIME_FOREVER);

        NSData *pat=buildPAT(patCC++);
        NSData *pmt=buildPMT(pmtCC++);
        // Sửa lỗi: ép kiểu (const uint8_t *)
        if (!sendAll(fd,(const uint8_t *)pat.bytes,188)) break;
        if (!sendAll(fd,(const uint8_t *)pmt.bytes,188)) break;

        uint64_t pts=(uint64_t)(frame*90000/kH264TargetFPS);
        uint8_t pes[19]={
            0,0,1,0xE0,0,0,0x80,0x80,5,
            (uint8_t)(0x21|((pts>>29)&0x0E)),
            (uint8_t)(pts>>22),
            (uint8_t)(0x01|((pts>>14)&0xFE)),
            (uint8_t)(pts>>7),
            (uint8_t)(0x01|((pts<<1)&0xFE))
        };

        NSMutableData *payload=[NSMutableData dataWithBytes:pes length:14];
        [payload appendData:ctx.encodedData];

        // Sửa lỗi: ép kiểu (const uint8_t *) cho payload.bytes
        if (!writeTSPackets(fd,kTSVideoPid,
            (const uint8_t *)payload.bytes,payload.length,true,
            (frame%kPCRIntervalFrames)==0,
            pts,&vidCC)) break;

        frame++;
        usleep(1000000/kH264TargetFPS);
    }

    VTCompressionSessionInvalidate(enc);
    CFRelease(enc);
    shutdown(fd,SHUT_RDWR);
    close(fd);

    int exp=fd;
    atomic_compare_exchange_strong(&gActiveClientFd,&exp,-1);
}

#pragma mark - Server

void startH264StreamServer(void) {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT,0), ^{
        int s=socket(AF_INET,SOCK_STREAM,0);
        int yes=1;
        setsockopt(s,SOL_SOCKET,SO_REUSEADDR,&yes,sizeof(yes));

        struct sockaddr_in a={0};
        a.sin_family=AF_INET;
        a.sin_addr.s_addr=htonl(INADDR_ANY);
        a.sin_port=htons(kH264StreamPort);
        bind(s,(struct sockaddr*)&a,sizeof(a));
        listen(s,16);

        while (1) {
            int c=accept(s,NULL,NULL);
            if (c<0) continue;

            int exp=-1;
            if (!atomic_compare_exchange_strong(&gActiveClientFd,&exp,c)) {
                close(c);
                continue;
            }

            int nosig=1;
            setsockopt(c,SOL_SOCKET,SO_NOSIGPIPE,&nosig,sizeof(nosig));
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT,0), ^{
                streamLoop(c);
            });
        }
    });
}
