#include "H264Stream.h"
#include "Screen.h"

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <VideoToolbox/VideoToolbox.h>

#include <sys/socket.h>
#include <netinet/in.h>
#include <unistd.h>

static const int kH264StreamPort = 7001;
static const int kH264TargetWidth = 1280;
static const int kH264TargetHeight = 720;
static const int kH264TargetFPS = 20;
static const int kH264KeyframeIntervalSeconds = 2;
static const int kPCRIntervalFrames = 10;
static const uint16_t kTSVideoPid = 0x0100;
static const uint16_t kTSPatPid = 0x0000;
static const uint16_t kTSPmtPid = 0x1000;
static const uint16_t kTSProgramNumber = 1;

@interface ZXTH264EncoderContext : NSObject
@property(nonatomic, strong) NSMutableData *encodedData;
@property(nonatomic) dispatch_semaphore_t semaphore;
@property(nonatomic) BOOL isKeyframe;
@end

@implementation ZXTH264EncoderContext
@end

static void appendAnnexBHeader(NSMutableData *data) {
    static const uint8_t header[] = {0x00, 0x00, 0x00, 0x01};
    [data appendBytes:header length:sizeof(header)];
}

static void H264OutputCallback(void *outputCallbackRefCon,
                               void *sourceFrameRefCon,
                               OSStatus status,
                               VTEncodeInfoFlags infoFlags,
                               CMSampleBufferRef sampleBuffer) {
    (void)outputCallbackRefCon;
    (void)infoFlags;
    if (!sourceFrameRefCon) {
        return;
    }
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

    CMFormatDescriptionRef formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer);
    if (isKeyframe && formatDesc) {
        const uint8_t *sps = NULL;
        const uint8_t *pps = NULL;
        size_t spsSize = 0;
        size_t ppsSize = 0;
        size_t spsCount = 0;
        size_t ppsCount = 0;
        if (CMVideoFormatDescriptionGetH264ParameterSetAtIndex(formatDesc, 0, &sps, &spsSize, &spsCount, NULL) == noErr &&
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(formatDesc, 1, &pps, &ppsSize, &ppsCount, NULL) == noErr) {
            appendAnnexBHeader(context.encodedData);
            [context.encodedData appendBytes:sps length:spsSize];
            appendAnnexBHeader(context.encodedData);
            [context.encodedData appendBytes:pps length:ppsSize];
        }
    }

    CMBlockBufferRef dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer);
    size_t length = 0;
    char *dataPointer = NULL;
    if (CMBlockBufferGetDataPointer(dataBuffer, 0, NULL, &length, &dataPointer) == noErr) {
        size_t offset = 0;
        const size_t headerLength = 4;
        while (offset + headerLength < length) {
            uint32_t nalLength = 0;
            memcpy(&nalLength, dataPointer + offset, headerLength);
            nalLength = CFSwapInt32BigToHost(nalLength);
            appendAnnexBHeader(context.encodedData);
            [context.encodedData appendBytes:(dataPointer + offset + headerLength) length:nalLength];
            offset += headerLength + nalLength;
        }
    }

    dispatch_semaphore_signal(context.semaphore);
}

static bool sendAll(int socketFd, const uint8_t *buffer, size_t length) {
    size_t sent = 0;
    while (sent < length) {
        ssize_t result = send(socketFd, buffer + sent, length - sent, MSG_NOSIGNAL);
        if (result <= 0) {
            return false;
        }
        sent += (size_t)result;
    }
    return true;
}

static uint32_t mpegCrc32(const uint8_t *data, size_t length) {
    uint32_t crc = 0xFFFFFFFF;
    for (size_t i = 0; i < length; i++) {
        crc ^= (uint32_t)data[i] << 24;
        for (int bit = 0; bit < 8; bit++) {
            if (crc & 0x80000000) {
                crc = (crc << 1) ^ 0x04C11DB7;
            } else {
                crc <<= 1;
            }
        }
    }
    return crc;
}

static NSData *buildPATPacket(uint8_t continuityCounter) {
    uint8_t section[16] = {0};
    size_t index = 0;
    section[index++] = 0x00; // table_id
    section[index++] = 0xB0; // section_syntax_indicator + reserved + section_length high
    section[index++] = 0x00; // section_length low (filled later)
    section[index++] = 0x00; // transport_stream_id high
    section[index++] = 0x01; // transport_stream_id low
    section[index++] = 0xC1; // version_number + current_next_indicator
    section[index++] = 0x00; // section_number
    section[index++] = 0x00; // last_section_number
    section[index++] = (kTSProgramNumber >> 8) & 0xFF;
    section[index++] = kTSProgramNumber & 0xFF;
    section[index++] = 0xE0 | ((kTSPmtPid >> 8) & 0x1F);
    section[index++] = kTSPmtPid & 0xFF;

    size_t sectionLength = (index - 3) + 4;
    section[1] = 0xB0 | ((sectionLength >> 8) & 0x0F);
    section[2] = sectionLength & 0xFF;

    uint32_t crc = mpegCrc32(section, index);
    section[index++] = (crc >> 24) & 0xFF;
    section[index++] = (crc >> 16) & 0xFF;
    section[index++] = (crc >> 8) & 0xFF;
    section[index++] = crc & 0xFF;

    uint8_t packet[188] = {0};
    packet[0] = 0x47;
    packet[1] = 0x40 | ((kTSPatPid >> 8) & 0x1F);
    packet[2] = kTSPatPid & 0xFF;
    packet[3] = 0x10 | (continuityCounter & 0x0F);
    packet[4] = 0x00; // pointer_field
    memcpy(packet + 5, section, index);
    memset(packet + 5 + index, 0xFF, 188 - 5 - index);
    return [NSData dataWithBytes:packet length:sizeof(packet)];
}

static NSData *buildPMTPacket(uint8_t continuityCounter) {
    uint8_t section[32] = {0};
    size_t index = 0;
    section[index++] = 0x02; // table_id
    section[index++] = 0xB0; // section_syntax_indicator + reserved + section_length high
    section[index++] = 0x00; // section_length low (filled later)
    section[index++] = (kTSProgramNumber >> 8) & 0xFF;
    section[index++] = kTSProgramNumber & 0xFF;
    section[index++] = 0xC1; // version_number + current_next_indicator
    section[index++] = 0x00; // section_number
    section[index++] = 0x00; // last_section_number
    section[index++] = 0xE0 | ((kTSVideoPid >> 8) & 0x1F); // PCR PID
    section[index++] = kTSVideoPid & 0xFF;
    section[index++] = 0xF0; // program_info_length high
    section[index++] = 0x00; // program_info_length low
    section[index++] = 0x1B; // stream_type H.264
    section[index++] = 0xE0 | ((kTSVideoPid >> 8) & 0x1F);
    section[index++] = kTSVideoPid & 0xFF;
    section[index++] = 0xF0; // ES_info_length high
    section[index++] = 0x00; // ES_info_length low

    size_t sectionLength = (index - 3) + 4;
    section[1] = 0xB0 | ((sectionLength >> 8) & 0x0F);
    section[2] = sectionLength & 0xFF;

    uint32_t crc = mpegCrc32(section, index);
    section[index++] = (crc >> 24) & 0xFF;
    section[index++] = (crc >> 16) & 0xFF;
    section[index++] = (crc >> 8) & 0xFF;
    section[index++] = crc & 0xFF;

    uint8_t packet[188] = {0};
    packet[0] = 0x47;
    packet[1] = 0x40 | ((kTSPmtPid >> 8) & 0x1F);
    packet[2] = kTSPmtPid & 0xFF;
    packet[3] = 0x10 | (continuityCounter & 0x0F);
    packet[4] = 0x00; // pointer_field
    memcpy(packet + 5, section, index);
    memset(packet + 5 + index, 0xFF, 188 - 5 - index);
    return [NSData dataWithBytes:packet length:sizeof(packet)];
}

static void writeTSPackets(int socketFd, uint16_t pid, const uint8_t *payload, size_t payloadLength, bool payloadStart, bool addPCR, uint64_t pcrBase, uint8_t *continuityCounter) {
    size_t offset = 0;
    while (offset < payloadLength) {
        uint8_t packet[188] = {0};
        bool isFirst = payloadStart && (offset == 0);
        bool includePCR = addPCR && isFirst;
        size_t adaptationLength = 0;
        packet[0] = 0x47;
        packet[1] = ((isFirst ? 0x40 : 0x00) | ((pid >> 8) & 0x1F));
        packet[2] = pid & 0xFF;
        packet[3] = (*continuityCounter & 0x0F);
        (*continuityCounter) = ((*continuityCounter) + 1) & 0x0F;

        size_t payloadCapacity = 184;
        size_t remaining = payloadLength - offset;
        size_t toCopy = remaining < payloadCapacity ? remaining : payloadCapacity;

        if (includePCR || toCopy < payloadCapacity) {
            packet[3] |= 0x30; // adaptation + payload
            uint8_t *adapt = packet + 4;
            size_t adaptIndex = 2;
            adapt[1] = includePCR ? 0x10 : 0x00;
            if (includePCR) {
                uint64_t pcr = pcrBase * 300;
                adapt[2] = (pcr >> 25) & 0xFF;
                adapt[3] = (pcr >> 17) & 0xFF;
                adapt[4] = (pcr >> 9) & 0xFF;
                adapt[5] = (pcr >> 1) & 0xFF;
                adapt[6] = ((pcr & 0x1) << 7) | 0x7E;
                adapt[7] = 0x00;
                adaptIndex = 8;
            }

            size_t payloadRoom = payloadCapacity - (1 + adaptIndex);
            if (toCopy > payloadRoom) {
                toCopy = payloadRoom;
            }
            adaptationLength = (size_t)(adaptIndex - 1);
            size_t stuffing = payloadCapacity - (adaptIndex + toCopy);
            adaptationLength += stuffing;
            adapt[0] = (uint8_t)adaptationLength;
            memset(adapt + adaptIndex, 0xFF, stuffing);
            memcpy(packet + 4 + 1 + adaptationLength, payload + offset, toCopy);
        } else {
            packet[3] |= 0x10; // payload only
            memcpy(packet + 4, payload + offset, toCopy);
        }

        sendAll(socketFd, packet, sizeof(packet));
        offset += toCopy;
    }
}

static CVPixelBufferRef createPixelBufferFromCGImage(CGImageRef image, size_t width, size_t height) {
    NSDictionary *attributes = @{
        (id)kCVPixelBufferCGImageCompatibilityKey : @YES,
        (id)kCVPixelBufferCGBitmapContextCompatibilityKey : @YES
    };

    CVPixelBufferRef pixelBuffer = NULL;
    CVReturn status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, (__bridge CFDictionaryRef)attributes, &pixelBuffer);
    if (status != kCVReturnSuccess || !pixelBuffer) {
        return NULL;
    }

    CVPixelBufferLockBaseAddress(pixelBuffer, 0);
    void *baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer);
    size_t bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer);
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(baseAddress, width, height, 8, bytesPerRow, colorSpace, kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst);
    if (context) {
        CGContextDrawImage(context, CGRectMake(0, 0, width, height), image);
        CGContextRelease(context);
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

    size_t width = kH264TargetWidth;
    size_t height = kH264TargetHeight;
    CVPixelBufferRef pixelBuffer = createPixelBufferFromCGImage(image, width, height);
    if (!pixelBuffer) {
        CFRelease((CFTypeRef)contextRef);
        return nil;
    }

    VTEncodeInfoFlags flags = 0;
    OSStatus status = VTCompressionSessionEncodeFrame(session, pixelBuffer, frameTime, kCMTimeInvalid, NULL, contextRef, &flags);
    CVPixelBufferRelease(pixelBuffer);
    if (status != noErr) {
        CFRelease((CFTypeRef)contextRef);
        return nil;
    }

    dispatch_semaphore_wait(context.semaphore, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)));
    return context;
}

static VTCompressionSessionRef createEncoder(void) {
    VTCompressionSessionRef session = NULL;
    OSStatus status = VTCompressionSessionCreate(kCFAllocatorDefault,
                                                 kH264TargetWidth,
                                                 kH264TargetHeight,
                                                 kCMVideoCodecType_H264,
                                                 NULL,
                                                 NULL,
                                                 NULL,
                                                 H264OutputCallback,
                                                 NULL,
                                                 &session);
    if (status != noErr || !session) {
        return NULL;
    }

    VTSessionSetProperty(session, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue);
    VTSessionSetProperty(session, kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_Baseline_AutoLevel);
    VTSessionSetProperty(session, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse);
    VTSessionSetProperty(session, kVTCompressionPropertyKey_MaxKeyFrameInterval, (__bridge CFTypeRef)@(kH264TargetFPS * kH264KeyframeIntervalSeconds));
    VTSessionSetProperty(session, kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, (__bridge CFTypeRef)@(kH264KeyframeIntervalSeconds));
    VTSessionSetProperty(session, kVTCompressionPropertyKey_ExpectedFrameRate, (__bridge CFTypeRef)@(kH264TargetFPS));
    VTSessionSetProperty(session, kVTCompressionPropertyKey_AverageBitRate, (__bridge CFTypeRef)@(2000000));
    VTCompressionSessionPrepareToEncodeFrames(session);
    return session;
}

static void streamLoop(int clientSocket) {
    VTCompressionSessionRef encoder = createEncoder();
    if (!encoder) {
        close(clientSocket);
        return;
    }

    int64_t frameIndex = 0;
    uint8_t patContinuity = 0;
    uint8_t pmtContinuity = 0;
    uint8_t videoContinuity = 0;
    bool sentTables = false;
    while (clientSocket >= 0) {
        CGImageRef image = [Screen createScreenShotCGImageRef];
        if (!image) {
            break;
        }

        CMTime frameTime = CMTimeMake(frameIndex, kH264TargetFPS);
        ZXTH264EncoderContext *context = encodeFrame(encoder, image, frameTime);
        CGImageRelease(image);

        if (!context || context.encodedData.length == 0) {
            break;
        }

        if (!sentTables || context.isKeyframe) {
            NSData *pat = buildPATPacket(patContinuity++);
            NSData *pmt = buildPMTPacket(pmtContinuity++);
            sendAll(clientSocket, (const uint8_t *)pat.bytes, pat.length);
            sendAll(clientSocket, (const uint8_t *)pmt.bytes, pmt.length);
            sentTables = true;
        }

        uint64_t pts = (uint64_t)((frameIndex * 90000) / kH264TargetFPS);
        uint8_t pesHeader[19] = {0};
        size_t pesIndex = 0;
        pesHeader[pesIndex++] = 0x00;
        pesHeader[pesIndex++] = 0x00;
        pesHeader[pesIndex++] = 0x01;
        pesHeader[pesIndex++] = 0xE0; // stream_id
        pesHeader[pesIndex++] = 0x00;
        pesHeader[pesIndex++] = 0x00; // PES length 0 for video
        pesHeader[pesIndex++] = 0x80; // '10' + no scrambling
        pesHeader[pesIndex++] = 0x80; // PTS only
        pesHeader[pesIndex++] = 0x05; // header length
        pesHeader[pesIndex++] = 0x21 | ((pts >> 29) & 0x0E);
        pesHeader[pesIndex++] = (pts >> 22) & 0xFF;
        pesHeader[pesIndex++] = 0x01 | ((pts >> 14) & 0xFE);
        pesHeader[pesIndex++] = (pts >> 7) & 0xFF;
        pesHeader[pesIndex++] = 0x01 | ((pts << 1) & 0xFE);

        NSMutableData *pesPayload = [NSMutableData dataWithBytes:pesHeader length:pesIndex];
        [pesPayload appendData:context.encodedData];
        bool addPCR = (frameIndex % kPCRIntervalFrames) == 0;
        writeTSPackets(clientSocket, kTSVideoPid, (const uint8_t *)pesPayload.bytes, pesPayload.length, true, addPCR, pts, &videoContinuity);

        if (clientSocket < 0) {
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

void startH264StreamServer(void) {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        int serverSocket = socket(AF_INET, SOCK_STREAM, 0);
        if (serverSocket < 0) {
            return;
        }

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

        if (listen(serverSocket, 5) != 0) {
            close(serverSocket);
            return;
        }

        while (1) {
            int clientSocket = accept(serverSocket, NULL, NULL);
            if (clientSocket < 0) {
                continue;
            }
            int noSigPipe = 1;
            setsockopt(clientSocket, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, sizeof(noSigPipe));
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                streamLoop(clientSocket);
            });
        }
    });
}
