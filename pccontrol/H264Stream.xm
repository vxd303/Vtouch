#include "H264Stream.h"
#include "Screen.h"

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <VideoToolbox/VideoToolbox.h>

#include <sys/socket.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <unistd.h>
#include <errno.h>
#include <string.h>

// -------------------- Config --------------------
static const int kH264StreamPort = 7001;
static const int kH264TargetWidth = 1280;
static const int kH264TargetHeight = 720;
static const int kH264TargetFPS = 20;

// Giảm nếu muốn join lên hình nhanh hơn
static const int kH264KeyframeIntervalSeconds = 2;

// Gửi PCR thường xuyên giúp player lock nhanh (mỗi 2–5 frame là ổn)
static const int kPCRIntervalFrames = 5;

// PAT/PMT định kỳ để client join giữa stream vẫn bắt nhanh
static const int kPsiRepeatIntervalFrames = 10; // 10 frames ~ 0.5s @20fps

static const uint16_t kTSVideoPid = 0x0100;
static const uint16_t kTSPatPid   = 0x0000;
static const uint16_t kTSPmtPid   = 0x1000;
static const uint16_t kTSProgramNumber = 1;

// -------------------- Encoder context --------------------
@interface ZXTH264EncoderContext : NSObject
@property(nonatomic, strong) NSMutableData *encodedData; // Annex-B output
@property(nonatomic) dispatch_semaphore_t semaphore;
@property(nonatomic) BOOL isKeyframe;
@end
@implementation ZXTH264EncoderContext @end

static inline void appendAnnexBHeader(NSMutableData *data) {
    static const uint8_t header[] = {0x00, 0x00, 0x00, 0x01};
    [data appendBytes:header length:sizeof(header)];
}

// -------------------- H264 callback --------------------
static void H264OutputCallback(void *outputCallbackRefCon,
                               void *sourceFrameRefCon,
                               OSStatus status,
                               VTEncodeInfoFlags infoFlags,
                               CMSampleBufferRef sampleBuffer) {
    (void)outputCallbackRefCon;
    (void)infoFlags;

    if (!sourceFrameRefCon) return;

    ZXTH264EncoderContext *context = CFBridgingRelease(sourceFrameRefCon);
    if (status != noErr || !sampleBuffer || !CMSampleBufferDataIsReady(sampleBuffer)) {
        dispatch_semaphore_signal(context.semaphore);
        return;
    }

    BOOL isKeyframe = NO;
    CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, false);
    if (attachments && CFArrayGetCount(attachments) > 0) {
        CFDictionaryRef attachment = (CFDictionaryRef)CFArrayGetValueAtIndex(attachments, 0);
        BOOL notSync = CFDictionaryContainsKey(attachment, kCMSampleAttachmentKey_NotSync);
        isKeyframe = !notSync;
    }
    context.isKeyframe = isKeyframe;

    // SPS/PPS at keyframe
    CMFormatDescriptionRef formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer);
    if (isKeyframe && formatDesc) {
        const uint8_t *sps = NULL, *pps = NULL;
        size_t spsSize = 0, ppsSize = 0;
        size_t spsCount = 0, ppsCount = 0;

        if (CMVideoFormatDescriptionGetH264ParameterSetAtIndex(formatDesc, 0, &sps, &spsSize, &spsCount, NULL) == noErr &&
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(formatDesc, 1, &pps, &ppsSize, &ppsCount, NULL) == noErr) {
            appendAnnexBHeader(context.encodedData);
            [context.encodedData appendBytes:sps length:spsSize];
            appendAnnexBHeader(context.encodedData);
            [context.encodedData appendBytes:pps length:ppsSize];
        }
    }

    // Convert AVCC (len + NAL) -> AnnexB
    CMBlockBufferRef dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer);
    size_t length = 0;
    char *dataPointer = NULL;
    if (dataBuffer && CMBlockBufferGetDataPointer(dataBuffer, 0, NULL, &length, &dataPointer) == noErr) {
        size_t offset = 0;
        const size_t headerLength = 4;
        while (offset + headerLength <= length) {
            uint32_t nalLength = 0;
            memcpy(&nalLength, dataPointer + offset, headerLength);
            nalLength = CFSwapInt32BigToHost(nalLength);
            offset += headerLength;
            if (offset + nalLength > length) break;

            appendAnnexBHeader(context.encodedData);
            [context.encodedData appendBytes:(dataPointer + offset) length:nalLength];
            offset += nalLength;
        }
    }

    dispatch_semaphore_signal(context.semaphore);
}

// -------------------- Socket helpers --------------------
static bool sendAll(int fd, const uint8_t *buf, size_t len) {
    size_t sent = 0;
    while (sent < len) {
        ssize_t r = send(fd, buf + sent, len - sent, MSG_NOSIGNAL);
        if (r <= 0) {
            return false;
        }
        sent += (size_t)r;
    }
    return true;
}

static void setClientSocketOptions(int fd) {
    int noSigPipe = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, sizeof(noSigPipe));

    int one = 1;
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));

    // Optional keepalive (giúp mạng "đứt ngầm" phát hiện nhanh hơn)
    setsockopt(fd, SOL_SOCKET, SO_KEEPALIVE, &one, sizeof(one));
}

// -------------------- MPEG-TS helpers --------------------
static uint32_t mpegCrc32(const uint8_t *data, size_t length) {
    uint32_t crc = 0xFFFFFFFF;
    for (size_t i = 0; i < length; i++) {
        crc ^= (uint32_t)data[i] << 24;
        for (int bit = 0; bit < 8; bit++) {
            crc = (crc & 0x80000000) ? ((crc << 1) ^ 0x04C11DB7) : (crc << 1);
        }
    }
    return crc;
}

static NSData *buildPATPacket(uint8_t cc) {
    // PAT section: table_id(1) + section_length... + CRC(4)
    uint8_t section[1024] = {0};
    size_t i = 0;

    section[i++] = 0x00;        // table_id
    section[i++] = 0xB0;        // section_syntax_indicator=1, reserved, section_length high (fill later)
    section[i++] = 0x00;        // section_length low (fill later)
    section[i++] = 0x00;        // transport_stream_id high
    section[i++] = 0x01;        // transport_stream_id low
    section[i++] = 0xC1;        // version=0, current_next=1
    section[i++] = 0x00;        // section_number
    section[i++] = 0x00;        // last_section_number

    // program_number -> PMT PID
    section[i++] = (kTSProgramNumber >> 8) & 0xFF;
    section[i++] = kTSProgramNumber & 0xFF;
    section[i++] = 0xE0 | ((kTSPmtPid >> 8) & 0x1F);
    section[i++] = kTSPmtPid & 0xFF;

    size_t sectionLength = (i - 3) + 4; // bytes from transport_stream_id to CRC inclusive
    section[1] = 0xB0 | ((sectionLength >> 8) & 0x0F);
    section[2] = sectionLength & 0xFF;

    uint32_t crc = mpegCrc32(section, i);
    section[i++] = (crc >> 24) & 0xFF;
    section[i++] = (crc >> 16) & 0xFF;
    section[i++] = (crc >> 8) & 0xFF;
    section[i++] = crc & 0xFF;

    uint8_t pkt[188];
    memset(pkt, 0xFF, sizeof(pkt));

    pkt[0] = 0x47;
    pkt[1] = 0x40 | ((kTSPatPid >> 8) & 0x1F); // PUSI=1
    pkt[2] = kTSPatPid & 0xFF;
    pkt[3] = 0x10 | (cc & 0x0F);              // payload only
    pkt[4] = 0x00;                            // pointer_field = 0
    memcpy(pkt + 5, section, i);

    return [NSData dataWithBytes:pkt length:sizeof(pkt)];
}

static NSData *buildPMTPacket(uint8_t cc) {
    uint8_t section[1024] = {0};
    size_t i = 0;

    section[i++] = 0x02;        // table_id = PMT
    section[i++] = 0xB0;        // section_length high (fill later)
    section[i++] = 0x00;        // section_length low (fill later)
    section[i++] = (kTSProgramNumber >> 8) & 0xFF;
    section[i++] = kTSProgramNumber & 0xFF;
    section[i++] = 0xC1;        // version=0, current_next=1
    section[i++] = 0x00;        // section_number
    section[i++] = 0x00;        // last_section_number

    // PCR PID
    section[i++] = 0xE0 | ((kTSVideoPid >> 8) & 0x1F);
    section[i++] = kTSVideoPid & 0xFF;

    // program_info_length = 0
    section[i++] = 0xF0;
    section[i++] = 0x00;

    // One ES: H.264
    section[i++] = 0x1B; // stream_type H.264
    section[i++] = 0xE0 | ((kTSVideoPid >> 8) & 0x1F);
    section[i++] = kTSVideoPid & 0xFF;

    // ES_info_length = 0
    section[i++] = 0xF0;
    section[i++] = 0x00;

    size_t sectionLength = (i - 3) + 4;
    section[1] = 0xB0 | ((sectionLength >> 8) & 0x0F);
    section[2] = sectionLength & 0xFF;

    uint32_t crc = mpegCrc32(section, i);
    section[i++] = (crc >> 24) & 0xFF;
    section[i++] = (crc >> 16) & 0xFF;
    section[i++] = (crc >> 8) & 0xFF;
    section[i++] = crc & 0xFF;

    uint8_t pkt[188];
    memset(pkt, 0xFF, sizeof(pkt));

    pkt[0] = 0x47;
    pkt[1] = 0x40 | ((kTSPmtPid >> 8) & 0x1F); // PUSI=1
    pkt[2] = kTSPmtPid & 0xFF;
    pkt[3] = 0x10 | (cc & 0x0F);               // payload only
    pkt[4] = 0x00;                             // pointer_field
    memcpy(pkt + 5, section, i);

    return [NSData dataWithBytes:pkt length:sizeof(pkt)];
}

// PCR encoding: pcr_base is 90kHz ticks (33-bit), pcr_ext 9-bit (0..299)
// Here we use ext=0
static inline void writePCR(uint8_t *dst6, uint64_t pcrBase90k) {
    uint64_t base = (pcrBase90k & 0x1FFFFFFFFULL); // 33-bit
    uint16_t ext = 0;

    dst6[0] = (base >> 25) & 0xFF;
    dst6[1] = (base >> 17) & 0xFF;
    dst6[2] = (base >> 9)  & 0xFF;
    dst6[3] = (base >> 1)  & 0xFF;
    dst6[4] = ((base & 0x1) << 7) | 0x7E | ((ext >> 8) & 0x01);
    dst6[5] = ext & 0xFF;
}

// Build ONE TS packet for video PES chunk.
// Never pads PES payload with 0xFF; uses adaptation stuffing instead.
static bool sendVideoTSPacket(int fd,
                              uint16_t pid,
                              bool payloadUnitStart,
                              const uint8_t *payload,
                              size_t payloadLen,
                              bool includePCR,
                              uint64_t pcrBase90k,
                              bool randomAccess,
                              uint8_t *cc) {
    if (payloadLen > 184) payloadLen = 184;

    uint8_t pkt[188];
    memset(pkt, 0xFF, sizeof(pkt));

    pkt[0] = 0x47;
    pkt[1] = (payloadUnitStart ? 0x40 : 0x00) | ((pid >> 8) & 0x1F);
    pkt[2] = pid & 0xFF;

    // Decide if we need adaptation field:
    // - if includePCR
    // - or if payloadLen < 184 (need stuffing but not into payload)
    bool needAdapt = includePCR || (payloadLen < 184);

    if (!needAdapt) {
        pkt[3] = 0x10 | (*cc & 0x0F); // payload only
        memcpy(pkt + 4, payload, payloadLen);
    } else {
        pkt[3] = 0x30 | (*cc & 0x0F); // adaptation + payload

        // adaptation_field_length L such that: 4(header) + 1(L) + L + payloadLen = 188
        // => L = 183 - payloadLen
        size_t L = 183 - payloadLen;

        // Must have at least 1 byte flags in adaptation field (L>=1 always here)
        // If includePCR, need flags + 6 bytes PCR => total >= 7
        size_t minL = includePCR ? 7 : 1;
        if (L < minL) {
            // reduce payloadLen to make room
            size_t need = minL - L;
            if (payloadLen >= need) {
                payloadLen -= need;
                L += need;
            } else {
                // can't happen realistically with sane sizes
                payloadLen = 0;
                L = minL;
            }
        }

        pkt[4] = (uint8_t)L; // adaptation_field_length
        uint8_t *adapt = pkt + 5;

        uint8_t flags = 0x00;
        if (includePCR) flags |= 0x10;
        if (randomAccess) flags |= 0x40; // random_access_indicator for keyframe
        adapt[0] = flags;

        size_t pos = 1;
        if (includePCR) {
            writePCR(adapt + pos, pcrBase90k);
            pos += 6;
        }

        // Stuffing to fill remaining adaptation bytes
        while (pos < L) {
            adapt[pos++] = 0xFF;
        }

        // payload starts after adaptation field
        memcpy(pkt + 4 + 1 + L, payload, payloadLen);
    }

    *cc = (uint8_t)((*cc + 1) & 0x0F);
    return sendAll(fd, pkt, sizeof(pkt));
}

// Build PES header (video) with PTS only. Return NSData = header + ES data.
static NSMutableData *buildVideoPES(uint64_t pts90k, NSData *annexbH264) {
    // PES header 14 bytes + 5 bytes PTS = 19 bytes (like you did)
    uint8_t pes[19] = {0};
    size_t i = 0;

    pes[i++] = 0x00; pes[i++] = 0x00; pes[i++] = 0x01;
    pes[i++] = 0xE0; // stream_id video

    // PES_packet_length: 0 for video in TS (allowed for unbounded)
    pes[i++] = 0x00;
    pes[i++] = 0x00;

    pes[i++] = 0x80; // '10' + no scrambling
    pes[i++] = 0x80; // PTS only
    pes[i++] = 0x05; // header_data_length

    uint64_t pts = pts90k & 0x1FFFFFFFFULL; // 33-bit

    pes[i++] = (uint8_t)(0x21 | ((pts >> 29) & 0x0E));
    pes[i++] = (uint8_t)((pts >> 22) & 0xFF);
    pes[i++] = (uint8_t)(0x01 | ((pts >> 14) & 0xFE));
    pes[i++] = (uint8_t)((pts >> 7) & 0xFF);
    pes[i++] = (uint8_t)(0x01 | ((pts << 1) & 0xFE));

    NSMutableData *out = [NSMutableData dataWithBytes:pes length:i];
    [out appendData:annexbH264];
    return out;
}

// Packetize PES -> multiple TS packets
static bool sendPESAsTS(int fd,
                        uint16_t pid,
                        const uint8_t *pes,
                        size_t pesLen,
                        bool addPCR,
                        uint64_t pcrBase90k,
                        bool randomAccess,
                        uint8_t *videoCC) {
    size_t off = 0;
    bool first = true;

    while (off < pesLen) {
        size_t remaining = pesLen - off;

        // We prefer payloadLen=184 if possible; if remaining < 184, we send remaining and stuff via adaptation.
        size_t payloadLen = remaining >= 184 ? 184 : remaining;

        bool includePCR = addPCR && first; // PCR only on first packet of this PES/frame (you can tune)
        if (!sendVideoTSPacket(fd, pid, first, pes + off, payloadLen, includePCR, pcrBase90k, randomAccess, videoCC)) {
            return false;
        }

        off += payloadLen;
        first = false;
        randomAccess = false;
        addPCR = false;
    }
    return true;
}

// -------------------- PixelBuffer from CGImage --------------------
static CVPixelBufferRef createPixelBufferFromCGImage(CGImageRef image, size_t width, size_t height) {
    NSDictionary *attributes = @{
        (id)kCVPixelBufferCGImageCompatibilityKey : @YES,
        (id)kCVPixelBufferCGBitmapContextCompatibilityKey : @YES
    };

    CVPixelBufferRef pixelBuffer = NULL;
    CVReturn status = CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                         kCVPixelFormatType_32BGRA,
                                         (__bridge CFDictionaryRef)attributes,
                                         &pixelBuffer);
    if (status != kCVReturnSuccess || !pixelBuffer) return NULL;

    CVPixelBufferLockBaseAddress(pixelBuffer, 0);
    void *baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer);
    size_t bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer);

    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(baseAddress, width, height, 8, bytesPerRow,
                                             colorSpace,
                                             kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst);
    if (ctx) {
        CGContextDrawImage(ctx, CGRectMake(0, 0, width, height), image);
        CGContextRelease(ctx);
    }
    CGColorSpaceRelease(colorSpace);

    CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
    return pixelBuffer;
}

static ZXTH264EncoderContext *encodeFrame(VTCompressionSessionRef session, CGImageRef image, CMTime frameTime) {
    ZXTH264EncoderContext *context = [[ZXTH264EncoderContext alloc] init];
    context.encodedData = [NSMutableData data];
    context.semaphore = dispatch_semaphore_create(0);

    void *contextRef = (void *)CFBridgingRetain(context);

    CVPixelBufferRef pb = createPixelBufferFromCGImage(image, kH264TargetWidth, kH264TargetHeight);
    if (!pb) {
        CFRelease((CFTypeRef)contextRef);
        return nil;
    }

    VTEncodeInfoFlags flags = 0;
    OSStatus st = VTCompressionSessionEncodeFrame(session, pb, frameTime, kCMTimeInvalid, NULL, contextRef, &flags);
    CVPixelBufferRelease(pb);

    if (st != noErr) {
        CFRelease((CFTypeRef)contextRef);
        return nil;
    }

    // Wait callback (1s)
    dispatch_semaphore_wait(context.semaphore, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)));
    return context;
}

static VTCompressionSessionRef createEncoder(void) {
    VTCompressionSessionRef session = NULL;
    OSStatus st = VTCompressionSessionCreate(kCFAllocatorDefault,
                                            kH264TargetWidth,
                                            kH264TargetHeight,
                                            kCMVideoCodecType_H264,
                                            NULL, NULL, NULL,
                                            H264OutputCallback,
                                            NULL,
                                            &session);
    if (st != noErr || !session) return NULL;

    VTSessionSetProperty(session, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue);
    VTSessionSetProperty(session, kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_Baseline_AutoLevel);
    VTSessionSetProperty(session, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse);

    // GOP / Keyframe
    VTSessionSetProperty(session, kVTCompressionPropertyKey_MaxKeyFrameInterval,
                         (__bridge CFTypeRef)@(kH264TargetFPS * kH264KeyframeIntervalSeconds));
    VTSessionSetProperty(session, kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration,
                         (__bridge CFTypeRef)@(kH264KeyframeIntervalSeconds));

    // FPS + bitrate
    VTSessionSetProperty(session, kVTCompressionPropertyKey_ExpectedFrameRate,
                         (__bridge CFTypeRef)@(kH264TargetFPS));
    VTSessionSetProperty(session, kVTCompressionPropertyKey_AverageBitRate,
                         (__bridge CFTypeRef)@(2000000));

    // Emit SPS/PPS at keyframes (giúp decoder join nhanh hơn)
    VTSessionSetProperty(session, kVTCompressionPropertyKey_EmitH264SPSPPSAtKeyFrames, kCFBooleanTrue);

    VTCompressionSessionPrepareToEncodeFrames(session);
    return session;
}

// -------------------- Streaming loop --------------------
static void streamLoop(int clientSocket) {
    setClientSocketOptions(clientSocket);

    VTCompressionSessionRef encoder = createEncoder();
    if (!encoder) {
        shutdown(clientSocket, SHUT_RDWR);
        close(clientSocket);
        return;
    }

    int64_t frameIndex = 0;

    uint8_t patCC = 0;
    uint8_t pmtCC = 0;
    uint8_t videoCC = 0;

    // Send PAT/PMT immediately on connect (fast probe)
    {
        NSData *pat = buildPATPacket(patCC++);
        NSData *pmt = buildPMTPacket(pmtCC++);
        if (!sendAll(clientSocket, (const uint8_t *)pat.bytes, pat.length) ||
            !sendAll(clientSocket, (const uint8_t *)pmt.bytes, pmt.length)) {
            VTCompressionSessionInvalidate(encoder);
            CFRelease(encoder);
            shutdown(clientSocket, SHUT_RDWR);
            close(clientSocket);
            return;
        }
    }

    while (true) {
        CGImageRef img = [Screen createScreenShotCGImageRef];
        if (!img) break;

        CMTime frameTime = CMTimeMake(frameIndex, kH264TargetFPS);
        ZXTH264EncoderContext *ctx = encodeFrame(encoder, img, frameTime);
        CGImageRelease(img);

        if (!ctx || ctx.encodedData.length == 0) break;

        // Repeat PAT/PMT periodically + at keyframes (helps reconnect/join)
        if ((frameIndex % kPsiRepeatIntervalFrames) == 0 || ctx.isKeyframe) {
            NSData *pat = buildPATPacket(patCC++);
            NSData *pmt = buildPMTPacket(pmtCC++);
            if (!sendAll(clientSocket, (const uint8_t *)pat.bytes, pat.length) ||
                !sendAll(clientSocket, (const uint8_t *)pmt.bytes, pmt.length)) {
                break;
            }
        }

        // PTS in 90kHz
        uint64_t pts90k = (uint64_t)((frameIndex * 90000) / kH264TargetFPS);

        // PES = header + AnnexB H264
        NSMutableData *pes = buildVideoPES(pts90k, ctx.encodedData);

        // Add PCR periodically (on first TS packet of PES)
        bool addPCR = ((frameIndex % kPCRIntervalFrames) == 0);

        // random_access on keyframe helps some players
        bool randomAccess = ctx.isKeyframe;

        if (!sendPESAsTS(clientSocket,
                         kTSVideoPid,
                         (const uint8_t *)pes.bytes,
                         pes.length,
                         addPCR,
                         pts90k,        // PCR base = use same timeline
                         randomAccess,
                         &videoCC)) {
            break;
        }

        frameIndex++;
        usleep((useconds_t)(1000000 / kH264TargetFPS));
    }

    VTCompressionSessionInvalidate(encoder);
    CFRelease(encoder);

    shutdown(clientSocket, SHUT_RDWR);
    close(clientSocket);
}

// -------------------- Server --------------------
void startH264StreamServer(void) {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        int serverSocket = socket(AF_INET, SOCK_STREAM, 0);
        if (serverSocket < 0) return;

        int reuse = 1;
        setsockopt(serverSocket, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));

        int reusePort = 1;
        setsockopt(serverSocket, SOL_SOCKET, SO_REUSEPORT, &reusePort, sizeof(reusePort));

        struct sockaddr_in addr;
        memset(&addr, 0, sizeof(addr));
        addr.sin_family = AF_INET;
        addr.sin_addr.s_addr = htonl(INADDR_ANY);
        addr.sin_port = htons(kH264StreamPort);

        if (bind(serverSocket, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
            close(serverSocket);
            return;
        }

        if (listen(serverSocket, 16) != 0) {
            close(serverSocket);
            return;
        }

        while (1) {
            int clientSocket = accept(serverSocket, NULL, NULL);
            if (clientSocket < 0) continue;

            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                streamLoop(clientSocket);
            });
        }
    });
}
