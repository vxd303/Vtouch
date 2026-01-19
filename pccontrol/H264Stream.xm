// H264Stream.xm
#include "H264Stream.h"
#include "Screen.h"

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <VideoToolbox/VideoToolbox.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreMedia/CoreMedia.h>

#include <sys/socket.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <unistd.h>
#include <errno.h>
#include <stdatomic.h>
#include <string.h>
#include <stdlib.h>

static const int kH264StreamPort = 7001;
static const int kH264TargetWidth = 667;
static const int kH264TargetHeight = 375;
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

#pragma mark - Utils

static inline void appendAnnexBHeaderToCF(CFMutableDataRef data) {
    static const uint8_t header[] = {0x00, 0x00, 0x00, 0x01};
    CFDataAppendBytes(data, header, 4);
}

static bool sendAll(int fd, const uint8_t *buf, size_t len) {
    size_t sent = 0;
    while (sent < len) {
#ifdef MSG_NOSIGNAL
        ssize_t r = send(fd, buf + sent, len - sent, MSG_NOSIGNAL);
#else
        ssize_t r = send(fd, buf + sent, len - sent, 0);
#endif
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
        for (int b = 0; b < 8; b++) {
            crc = (crc & 0x80000000) ? ((crc << 1) ^ 0x04C11DB7) : (crc << 1);
        }
    }
    return crc;
}

static void setClientSocketOptions(int fd) {
    int one = 1;
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
#ifdef SO_NOSIGPIPE
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
#endif
}

#pragma mark - PAT / PMT

static NSData *buildPAT(uint8_t cc) {
    uint8_t sec[16] = {0};
    size_t i = 0;

    sec[i++] = 0x00; // table_id
    sec[i++] = 0xB0; // section_syntax + reserved + section_length hi (fill later)
    sec[i++] = 0x00; // section_length lo (fill later)

    sec[i++] = 0x00; // tsid hi
    sec[i++] = 0x01; // tsid lo
    sec[i++] = 0xC1; // version + current_next
    sec[i++] = 0x00; // section_number
    sec[i++] = 0x00; // last_section_number

    sec[i++] = (kTSProgramNumber >> 8) & 0xFF;
    sec[i++] = kTSProgramNumber & 0xFF;
    sec[i++] = 0xE0 | ((kTSPmtPid >> 8) & 0x1F);
    sec[i++] = (uint8_t)(kTSPmtPid & 0xFF);

    size_t slen = (i - 3) + 4;
    sec[1] = 0xB0 | ((slen >> 8) & 0x0F);
    sec[2] = (uint8_t)(slen & 0xFF);

    uint32_t crc = mpegCrc32(sec, i);
    sec[i++] = (uint8_t)(crc >> 24);
    sec[i++] = (uint8_t)(crc >> 16);
    sec[i++] = (uint8_t)(crc >> 8);
    sec[i++] = (uint8_t)(crc);

    uint8_t pkt[188] = {0};
    pkt[0] = 0x47;
    pkt[1] = 0x40 | ((kTSPatPid >> 8) & 0x1F);
    pkt[2] = (uint8_t)(kTSPatPid & 0xFF);
    pkt[3] = 0x10 | (cc & 0x0F);
    pkt[4] = 0x00; // pointer_field
    memcpy(pkt + 5, sec, i);
    memset(pkt + 5 + i, 0xFF, 188 - 5 - i);

    return [NSData dataWithBytes:pkt length:188];
}

static NSData *buildPMT(uint8_t cc) {
    uint8_t sec[32] = {0};
    size_t i = 0;

    sec[i++] = 0x02; // table_id
    sec[i++] = 0xB0; // section_syntax + reserved + section_length hi (fill later)
    sec[i++] = 0x00; // section_length lo (fill later)

    sec[i++] = (kTSProgramNumber >> 8) & 0xFF;
    sec[i++] = (uint8_t)(kTSProgramNumber & 0xFF);
    sec[i++] = 0xC1;
    sec[i++] = 0x00;
    sec[i++] = 0x00;

    // PCR PID = video PID
    sec[i++] = 0xE0 | ((kTSVideoPid >> 8) & 0x1F);
    sec[i++] = (uint8_t)(kTSVideoPid & 0xFF);

    // program_info_length
    sec[i++] = 0xF0; sec[i++] = 0x00;

    // stream: H.264
    sec[i++] = 0x1B;
    sec[i++] = 0xE0 | ((kTSVideoPid >> 8) & 0x1F);
    sec[i++] = (uint8_t)(kTSVideoPid & 0xFF);
    sec[i++] = 0xF0; sec[i++] = 0x00;

    size_t slen = (i - 3) + 4;
    sec[1] = 0xB0 | ((slen >> 8) & 0x0F);
    sec[2] = (uint8_t)(slen & 0xFF);

    uint32_t crc = mpegCrc32(sec, i);
    sec[i++] = (uint8_t)(crc >> 24);
    sec[i++] = (uint8_t)(crc >> 16);
    sec[i++] = (uint8_t)(crc >> 8);
    sec[i++] = (uint8_t)(crc);

    uint8_t pkt[188] = {0};
    pkt[0] = 0x47;
    pkt[1] = 0x40 | ((kTSPmtPid >> 8) & 0x1F);
    pkt[2] = (uint8_t)(kTSPmtPid & 0xFF);
    pkt[3] = 0x10 | (cc & 0x0F);
    pkt[4] = 0x00; // pointer_field
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
        pkt[1] = (uint8_t)(((first ? 0x40 : 0x00) | ((pid >> 8) & 0x1F)));
        pkt[2] = (uint8_t)(pid & 0xFF);
        pkt[3] = (uint8_t)(*cc & 0x0F);
        *cc = (uint8_t)((*cc + 1) & 0x0F);

        const size_t payloadMax = 184;
        size_t remain = len - off;
        size_t copy = (remain < payloadMax) ? remain : payloadMax;

        if (pcrHere || copy < payloadMax) {
            pkt[3] |= 0x30; // adaptation + payload
            uint8_t *ad = pkt + 4;
            size_t ai = 2;

            ad[1] = pcrHere ? 0x10 : 0x00; // PCR flag

            if (pcrHere) {
                // PCR_base = pts90k (90kHz). PCR_ext = 0.
                uint64_t base = pts90k & ((1ULL << 33) - 1);
                ad[2] = (uint8_t)((base >> 25) & 0xFF);
                ad[3] = (uint8_t)((base >> 17) & 0xFF);
                ad[4] = (uint8_t)((base >> 9) & 0xFF);
                ad[5] = (uint8_t)((base >> 1) & 0xFF);
                ad[6] = (uint8_t)(((base & 1) << 7) | 0x7E);
                ad[7] = 0x00;
                ai = 8;
            }

            size_t payloadRoom = payloadMax - ai;
            if (copy > payloadRoom) {
                copy = payloadRoom;
            }
            size_t adaptLen = ai - 1;
            size_t stuff = payloadMax - (ai + copy);
            adaptLen += stuff;

            ad[0] = (uint8_t)adaptLen;
            memset(ad + ai, 0xFF, stuff);

            memcpy(pkt + 4 + 1 + adaptLen, payload + off, copy);
        } else {
            pkt[3] |= 0x10; // payload only
            memcpy(pkt + 4, payload + off, copy);
        }

        if (!sendAll(fd, pkt, 188)) return false;
        off += copy;
    }

    return true;
}

#pragma mark - Per-frame C context (NO ObjC bridging)

typedef struct {
    dispatch_semaphore_t sem;
    CFMutableDataRef data;   // Annex-B H264 (CF-only)
    bool key;
} FrameCtx;

static void FrameCtxFree(FrameCtx *f) {
    if (!f) return;
    if (f->data) CFRelease(f->data);
    free(f);
}

#pragma mark - Encoder callback

static void H264OutputCallback(void *outputCallbackRefCon,
                              void *sourceFrameRefCon,
                              OSStatus status,
                              VTEncodeInfoFlags infoFlags,
                              CMSampleBufferRef sb) {
    (void)outputCallbackRefCon;
    (void)infoFlags;

    FrameCtx *f = (FrameCtx *)sourceFrameRefCon;
    if (!f) return;

    if (status != noErr || !sb || !CMSampleBufferDataIsReady(sb)) {
        dispatch_semaphore_signal(f->sem);
        return;
    }

    bool key = false;
    CFArrayRef atts = CMSampleBufferGetSampleAttachmentsArray(sb, false);
    if (atts && CFArrayGetCount(atts) > 0) {
        CFDictionaryRef a = (CFDictionaryRef)CFArrayGetValueAtIndex(atts, 0);
        key = !CFDictionaryContainsKey(a, kCMSampleAttachmentKey_NotSync);
    }
    f->key = key;

    CMFormatDescriptionRef fmt = CMSampleBufferGetFormatDescription(sb);
    if (key && fmt) {
        const uint8_t *sps = NULL, *pps = NULL;
        size_t spsSz = 0, ppsSz = 0;
        if (CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, 0, &sps, &spsSz, NULL, NULL) == noErr &&
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, 1, &pps, &ppsSz, NULL, NULL) == noErr) {
            appendAnnexBHeaderToCF(f->data);
            CFDataAppendBytes(f->data, sps, (CFIndex)spsSz);
            appendAnnexBHeaderToCF(f->data);
            CFDataAppendBytes(f->data, pps, (CFIndex)ppsSz);
        }
    }

    CMBlockBufferRef bb = CMSampleBufferGetDataBuffer(sb);
    size_t totalLen = 0;
    char *ptr = NULL;

    if (bb && CMBlockBufferGetDataPointer(bb, 0, NULL, &totalLen, &ptr) == noErr) {
        size_t off = 0;
        while (off + 4 <= totalLen) {
            uint32_t nalLen = 0;
            memcpy(&nalLen, ptr + off, 4);
            nalLen = CFSwapInt32BigToHost(nalLen);
            off += 4;
            if (off + nalLen > totalLen) break;

            appendAnnexBHeaderToCF(f->data);
            CFDataAppendBytes(f->data, (const UInt8 *)(ptr + off), (CFIndex)nalLen);
            off += nalLen;
        }
    }

    dispatch_semaphore_signal(f->sem);
}

static VTCompressionSessionRef createEncoder(void) {
    VTCompressionSessionRef s = NULL;
    OSStatus st = VTCompressionSessionCreate(kCFAllocatorDefault,
                                             kH264TargetWidth,
                                             kH264TargetHeight,
                                             kCMVideoCodecType_H264,
                                             NULL,
                                             NULL,
                                             NULL,
                                             H264OutputCallback,
                                             NULL,
                                             &s);
    if (st != noErr || !s) return NULL;

    VTSessionSetProperty(s, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue);
    VTSessionSetProperty(s, kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_Baseline_AutoLevel);
    VTSessionSetProperty(s, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse);

    VTSessionSetProperty(s, kVTCompressionPropertyKey_MaxKeyFrameInterval,
                         (__bridge CFTypeRef)@(kH264TargetFPS * kH264KeyframeIntervalSeconds));
    VTSessionSetProperty(s, kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration,
                         (__bridge CFTypeRef)@(kH264KeyframeIntervalSeconds));
    VTSessionSetProperty(s, kVTCompressionPropertyKey_ExpectedFrameRate,
                         (__bridge CFTypeRef)@(kH264TargetFPS));
    VTSessionSetProperty(s, kVTCompressionPropertyKey_AverageBitRate,
                         (__bridge CFTypeRef)@(2000000));

    VTCompressionSessionPrepareToEncodeFrames(s);
    return s;
}

#pragma mark - Stream loop

static void sendTables(int fd, uint8_t *patCC, uint8_t *pmtCC) {
    NSData *pat = buildPAT((*patCC)++);
    NSData *pmt = buildPMT((*pmtCC)++);
    (void)sendAll(fd, (const uint8_t *)pat.bytes, 188);
    (void)sendAll(fd, (const uint8_t *)pmt.bytes, 188);
}

static void streamLoop(int fd) {
    @autoreleasepool {
        setClientSocketOptions(fd);

        // Declare everything early to avoid goto / jump init problems
        VTCompressionSessionRef enc = NULL;
        CVPixelBufferRef pb = NULL;
        CGColorSpaceRef cs = NULL;
        CGContextRef cg = NULL;

        uint8_t patCC = 0, pmtCC = 0, vidCC = 0;
        int64_t frame = 0;

        bool running = true;

        enc = createEncoder();
        if (!enc) running = false;

        if (running) {
            CVReturn cr = CVPixelBufferCreate(kCFAllocatorDefault,
                                              kH264TargetWidth,
                                              kH264TargetHeight,
                                              kCVPixelFormatType_32BGRA,
                                              NULL,
                                              &pb);
            if (cr != kCVReturnSuccess || !pb) running = false;
        }

        if (running) {
            cs = CGColorSpaceCreateDeviceRGB();
            if (!cs) running = false;
        }

        if (running) {
            // Send PAT/PMT immediately to help ffmpeg detect TS packet size
            sendTables(fd, &patCC, &pmtCC);
        }

        while (running) {
            @autoreleasepool {
                CGImageRef img = [Screen createScreenShotCGImageRef];
                if (!img) { running = false; break; }

                CVPixelBufferLockBaseAddress(pb, 0);

                if (!cg) {
                    cg = CGBitmapContextCreate(CVPixelBufferGetBaseAddress(pb),
                                               kH264TargetWidth,
                                               kH264TargetHeight,
                                               8,
                                               CVPixelBufferGetBytesPerRow(pb),
                                               cs,
                                               kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst);
                }

                if (cg) {
                    CGContextDrawImage(cg, CGRectMake(0, 0, kH264TargetWidth, kH264TargetHeight), img);
                }

                CVPixelBufferUnlockBaseAddress(pb, 0);
                CGImageRelease(img);

                FrameCtx *f = (FrameCtx *)calloc(1, sizeof(FrameCtx));
                if (!f) { running = false; break; }

                f->sem = dispatch_semaphore_create(0);
                f->data = CFDataCreateMutable(kCFAllocatorDefault, 0);
                f->key = false;

                // Force keyframe on first frame
                CFMutableDictionaryRef opts = NULL;
                if (frame == 0) {
                    opts = CFDictionaryCreateMutable(kCFAllocatorDefault, 1,
                                                     &kCFTypeDictionaryKeyCallBacks,
                                                     &kCFTypeDictionaryValueCallBacks);
                    if (opts) CFDictionarySetValue(opts, kVTEncodeFrameOptionKey_ForceKeyFrame, kCFBooleanTrue);
                }

                OSStatus st = VTCompressionSessionEncodeFrame(enc,
                                                             pb,
                                                             CMTimeMake(frame, kH264TargetFPS),
                                                             kCMTimeInvalid,
                                                             opts,
                                                             f,
                                                             NULL);

                if (opts) CFRelease(opts);

                if (st != noErr) {
                    FrameCtxFree(f);
                    running = false;
                    break;
                }

                dispatch_semaphore_wait(f->sem, DISPATCH_TIME_FOREVER);

                CFIndex hlen = CFDataGetLength(f->data);
                if (hlen <= 0) {
                    FrameCtxFree(f);
                    running = false;
                    break;
                }

                // Resend PAT/PMT on keyframes
                if (f->key) {
                    sendTables(fd, &patCC, &pmtCC);
                }

                uint64_t pts = (uint64_t)(frame * 90000 / kH264TargetFPS);
                uint8_t pes[14] = {
                    0x00, 0x00, 0x01, 0xE0,
                    0x00, 0x00,
                    0x80,
                    0x80,
                    0x05,
                    (uint8_t)(0x21 | ((pts >> 29) & 0x0E)),
                    (uint8_t)(pts >> 22),
                    (uint8_t)(0x01 | ((pts >> 14) & 0xFE)),
                    (uint8_t)(pts >> 7),
                    (uint8_t)(0x01 | ((pts << 1) & 0xFE))
                };

                size_t total = sizeof(pes) + (size_t)hlen;
                uint8_t *buf = (uint8_t *)malloc(total);
                if (!buf) {
                    FrameCtxFree(f);
                    running = false;
                    break;
                }

                memcpy(buf, pes, sizeof(pes));
                memcpy(buf + sizeof(pes), CFDataGetBytePtr(f->data), (size_t)hlen);

                bool addPCR = ((frame % kPCRIntervalFrames) == 0);
                bool ok = writeTSPackets(fd,
                                         kTSVideoPid,
                                         buf,
                                         total,
                                         true,
                                         addPCR,
                                         pts,
                                         &vidCC);

                free(buf);
                FrameCtxFree(f);

                if (!ok) {
                    running = false;
                    break;
                }

                frame++;
                usleep((useconds_t)(1000000 / kH264TargetFPS));
            }
        }

        if (cg) CGContextRelease(cg);
        if (cs) CGColorSpaceRelease(cs);
        if (pb) CVPixelBufferRelease(pb);

        if (enc) {
            VTCompressionSessionInvalidate(enc);
            CFRelease(enc);
        }

        shutdown(fd, SHUT_RDWR);
        close(fd);

        int exp = fd;
        atomic_compare_exchange_strong(&gActiveClientFd, &exp, -1);
    }
}

#pragma mark - Server

void startH264StreamServer(void) {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        int s = socket(AF_INET, SOCK_STREAM, 0);
        if (s < 0) return;

        int yes = 1;
        setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));

        struct sockaddr_in a;
        memset(&a, 0, sizeof(a));
        a.sin_family = AF_INET;
        a.sin_addr.s_addr = htonl(INADDR_ANY);
        a.sin_port = htons(kH264StreamPort);

        if (bind(s, (struct sockaddr *)&a, sizeof(a)) != 0) {
            close(s);
            return;
        }
        if (listen(s, 16) != 0) {
            close(s);
            return;
        }

        while (1) {
            int c = accept(s, NULL, NULL);
            if (c < 0) continue;

            int exp = -1;
            if (!atomic_compare_exchange_strong(&gActiveClientFd, &exp, c)) {
                shutdown(c, SHUT_RDWR);
                close(c);
                continue;
            }

            setClientSocketOptions(c);

            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                streamLoop(c);
            });
        }
    });
}
