#include "Screen.h"
#include "Common.h"

#include "headers/IOSurface/IOSurfaceAccelerator.h"
#include "headers/IOSurface/IOMobileFramebuffer.h"
#import "headers/IOSurface/IOSurface.h"
#include "headers/IOSurface/CoreSurface.h"
#import <Photos/Photos.h>

OBJC_EXTERN void CARenderServerRenderDisplay(kern_return_t a, CFStringRef b, IOSurfaceRef surface, int x, int y);
OBJC_EXTERN kern_return_t IOSurfaceLock(IOSurfaceRef buffer, IOSurfaceLockOptions options, uint32_t *seed);
OBJC_EXTERN kern_return_t IOSurfaceUnLock(IOSurfaceRef buffer, IOSurfaceLockOptions options, uint32_t *seed);
OBJC_EXTERN IOSurfaceRef IOSurfaceCreate(CFDictionaryRef dictionary);
OBJC_EXTERN CGImageRef UICreateCGImageFromIOSurface(IOSurfaceRef surface);

static CGFloat device_screen_width = 0;
static CGFloat device_screen_height = 0;
static NSString *const kZXTouchAlbumName = @"ZXTouch";

@implementation Screen
{
    // device screen size
}


/*
Get the size of the screen and set them.
*/
+ (void)setScreenSize:(CGFloat)x height:(CGFloat) y
{
	device_screen_width = x;
	device_screen_height = y;

	if (device_screen_width == 0 || device_screen_height == 0 || device_screen_width > 10000 || device_screen_height > 10000)
	{
		NSLog(@"com.zjx.springboard: Unable to initialze the screen size. screen width: %f, screen height: %f", device_screen_width, device_screen_height);
	}
	else
	{
		NSLog(@"com.zjx.springboard: successfully initialize the screen size. screen width: %f, screen height: %f", device_screen_width, device_screen_height);
	}
}

+ (int)getScreenOrientation
{
    __block int screenOrientation = -1;

    dispatch_sync(dispatch_get_main_queue(), ^{
        @try{
            SpringBoard *springboard = (SpringBoard*)[%c(SpringBoard) sharedApplication];
            screenOrientation = [springboard _frontMostAppOrientation];
            //NSLog(@"com.zjx.springboard: orientation %d", screenOrientation);
        }
        @catch (NSException *exception) {
            NSLog(@"com.zjx.springboard: Debug: %@", exception.reason);
        }
    }   
    );

    return screenOrientation;
}

+ (CGFloat)getScreenWidth
{
    if (device_screen_width == 0)
    {
        NSLog(@"com.zjx.springboard: Cannot get screen width. Maybe you call [Screen getScreenWidth] before springboard getting the screen size.");
    }
    return device_screen_width;
}

+ (CGFloat)getScreenHeight
{
    if (device_screen_height == 0)
    {
        NSLog(@"com.zjx.springboard: Cannot get screen height. Maybe you call [Screen getScreenHeight] before springboard getting the screen size.");
    }
    return device_screen_height;
}

+ (CGFloat)getScale
{    
    return [[UIScreen mainScreen] scale];
}

+ (CGRect)getBounds
{
    return [UIScreen mainScreen].bounds;
}


OBJC_EXTERN UIImage *_UICreateScreenUIImage(void);
+ (NSString*)screenShot
{
    UIImage *screenImage = _UICreateScreenUIImage();
    // Create path.
    NSString *filePath = [getDocumentRoot() stringByAppendingPathComponent:@"screenshot.png"];

    // Save image.
    [UIImagePNGRepresentation(screenImage) writeToFile:filePath atomically:NO];
    return filePath;
}

+ (UIImage*)screenShotUIImage // memory leak, need to be fixed
{
    return _UICreateScreenUIImage();
}

+ (CGImageRef)createScreenShotCGImageRef
{
    Boolean isiPad8orUp = false;

    CGFloat scale = [UIScreen mainScreen].scale;
    CGSize screenSize = [UIScreen mainScreen].bounds.size;

    int height = (int)(screenSize.height * scale);
    int width = (int)(screenSize.width * scale);

    // check whether it is ipad8 or later
    NSString *searchText = getDeviceName();

    NSRange range = [searchText rangeOfString:@"^iPad[8-9]|iPad[1-9][0-9]+" options:NSRegularExpressionSearch];
    if (range.location != NSNotFound) { // ipad pro (3rd) or later
        isiPad8orUp = true;
    }

    if (isiPad8orUp)
    {
        if (width < height)
        {
            int temp = width;
            width = height;
            height = temp;
        }
    }
    else
    {
        if (width > height)
        {
            int temp = width;
            width = height;
            height = temp;
        }
    }

    int bytesPerElement = 4;
    int bytesPerRow = roundUp(bytesPerElement * width, 32);

    NSNumber *IOSurfaceBytesPerElement = [NSNumber numberWithInteger:bytesPerElement]; 
    NSNumber *IOSurfaceBytesPerRow = [NSNumber numberWithInteger:bytesPerRow]; // don't know why but it should be a multiple of 32
    NSNumber *IOSurfaceAllocSize = [NSNumber numberWithInteger:bytesPerRow * height]; 
    NSNumber *nheight = [NSNumber numberWithInteger:height]; 
    NSNumber *nwidth = [NSNumber numberWithInteger:width]; 
    NSNumber *IOSurfacePixelFormat = [NSNumber numberWithInteger:1111970369]; 
    NSNumber *IOSurfaceIsGlobal = [NSNumber numberWithInteger:1]; 

    NSDictionary *properties = [[NSDictionary alloc] initWithObjectsAndKeys:IOSurfaceAllocSize, @"IOSurfaceAllocSize"
                                , IOSurfaceBytesPerElement, @"IOSurfaceBytesPerElement", IOSurfaceBytesPerRow, @"IOSurfaceBytesPerRow", nheight, @"IOSurfaceHeight", 
                                IOSurfaceIsGlobal, @"IOSurfaceIsGlobal", IOSurfacePixelFormat, @"IOSurfacePixelFormat", nwidth, @"IOSurfaceWidth", nil];    

    IOSurfaceRef screenSurface = IOSurfaceCreate((__bridge CFDictionaryRef)(properties));

    properties = nil;
    
    IOSurfaceLock(screenSurface, 0, NULL);
    CARenderServerRenderDisplay(0, CFSTR("LCD"), screenSurface, 0, 0);
        
    CGImageRef cgImageRef = nil;
    if (screenSurface) {
        cgImageRef = UICreateCGImageFromIOSurface(screenSurface);
        int targetWidth = CGImageGetWidth(cgImageRef);
        int targetHeight = CGImageGetHeight(cgImageRef);

        if (isiPad8orUp) // rotate 90 degrees counterclockwise
        {
            CGColorSpaceRef colorSpaceInfo = CGImageGetColorSpace(cgImageRef);
            CGContextRef bitmap;

            //if (sourceImage.imageOrientation == UIImageOrientationUp || sourceImage.imageOrientation == UIImageOrientationDown) {
                bitmap = CGBitmapContextCreate(NULL, targetHeight, targetWidth, CGImageGetBitsPerComponent(cgImageRef), CGImageGetBytesPerRow(cgImageRef), colorSpaceInfo, kCGImageAlphaPremultipliedFirst);
            //} else {
                //bitmap = CGBitmapContextCreate(NULL, targetHeight, targetWidth, CGImageGetBitsPerComponent(cgImageRef), CGImageGetBytesPerRow(imageRef), colorSpaceInfo, bitmapInfo);

            //}   

            CGFloat degrees = -90.f;
            CGFloat radians = degrees * (M_PI / 180.f);

            CGContextTranslateCTM (bitmap, 0.5*targetHeight, 0.5*targetWidth);
            CGContextRotateCTM (bitmap, radians);
            CGContextTranslateCTM (bitmap, -0.5*targetWidth, -0.5*targetHeight);

            CGContextDrawImage(bitmap, CGRectMake(0, 0, targetWidth, targetHeight), cgImageRef);
            
            CGImageRelease(cgImageRef);
            cgImageRef = CGBitmapContextCreateImage(bitmap);

            CGColorSpaceRelease(colorSpaceInfo);
            CGContextRelease(bitmap);
        }
    }
    IOSurfaceUnlock(screenSurface, 0, NULL);
    CFRelease(screenSurface);
    screenSurface = nil;

    return cgImageRef;
}


+ (NSString*)screenShotAlwaysUp
{
     UIImage *screenImage = _UICreateScreenUIImage();
    int orientation = [self getScreenOrientation];

    UIImageOrientation after = UIImageOrientationUp;
    if (orientation == 4)
    {
        after = UIImageOrientationRight;
    }
    else if (orientation == 3)
    {
        after = UIImageOrientationLeft;
    }
    else if (orientation == 2)
    {
        after = UIImageOrientationDown;
    }

    UIImage *result = [UIImage imageWithCGImage:[screenImage CGImage]
              scale:[screenImage scale]
              orientation: after];

    // Create path.
    NSString *filePath = [getDocumentRoot() stringByAppendingPathComponent:@"screenshot.png"];

    // Save image.
    [UIImagePNGRepresentation(result) writeToFile:filePath atomically:NO];
    return filePath;
}

+ (NSString*)screenShotToPath:(NSString*)filePath region:(CGRect)region error:(NSError**)error
{
    CGImageRef screenshotRef = [Screen createScreenShotCGImageRef];
    if (!screenshotRef)
    {
        if (error)
        {
            *error = [NSError errorWithDomain:@"com.zjx.zxtouchsp"
                                         code:999
                                     userInfo:@{NSLocalizedDescriptionKey:@"-1;;Unable to capture screenshot.\r\n"}];
        }
        return nil;
    }

    CGSize imageSize = CGSizeMake(CGImageGetWidth(screenshotRef), CGImageGetHeight(screenshotRef));
    CGRect bounds = CGRectMake(0, 0, imageSize.width, imageSize.height);
    CGRect targetRegion = CGRectIsEmpty(region) ? bounds : CGRectIntersection(bounds, region);

    if (CGRectIsEmpty(targetRegion))
    {
        CGImageRelease(screenshotRef);
        if (error)
        {
            *error = [NSError errorWithDomain:@"com.zjx.zxtouchsp"
                                         code:999
                                     userInfo:@{NSLocalizedDescriptionKey:@"-1;;Invalid screenshot region.\r\n"}];
        }
        return nil;
    }

    CGImageRef croppedRef = CGImageCreateWithImageInRect(screenshotRef, targetRegion);
    CGImageRelease(screenshotRef);
    if (!croppedRef)
    {
        if (error)
        {
            *error = [NSError errorWithDomain:@"com.zjx.zxtouchsp"
                                         code:999
                                     userInfo:@{NSLocalizedDescriptionKey:@"-1;;Failed to crop screenshot.\r\n"}];
        }
        return nil;
    }

    UIImage *image = [UIImage imageWithCGImage:croppedRef];
    CGImageRelease(croppedRef);

    NSString *targetPath = filePath;
    if (!targetPath || [targetPath length] == 0)
    {
        targetPath = [getDocumentRoot() stringByAppendingPathComponent:@"screenshot.png"];
    }

    if (![UIImagePNGRepresentation(image) writeToFile:targetPath atomically:NO])
    {
        if (error)
        {
            *error = [NSError errorWithDomain:@"com.zjx.zxtouchsp"
                                         code:999
                                     userInfo:@{NSLocalizedDescriptionKey:@"-1;;Failed to save screenshot.\r\n"}];
        }
        return nil;
    }

    return targetPath;
}

+ (PHAssetCollection*)fetchZXTouchAlbum
{
    PHFetchOptions *fetchOptions = [[PHFetchOptions alloc] init];
    fetchOptions.predicate = [NSPredicate predicateWithFormat:@"title = %@", kZXTouchAlbumName];
    PHFetchResult<PHAssetCollection*> *result = [PHAssetCollection fetchAssetCollectionsWithType:PHAssetCollectionTypeAlbum
                                                                                         subtype:PHAssetCollectionSubtypeAlbumRegular
                                                                                         options:fetchOptions];
    return result.firstObject;
}

+ (PHAssetCollection*)ensureZXTouchAlbumWithError:(NSError**)error
{
    if (!NSClassFromString(@"PHPhotoLibrary"))
    {
        if (error)
        {
            *error = [NSError errorWithDomain:@"com.zjx.zxtouchsp"
                                         code:999
                                     userInfo:@{NSLocalizedDescriptionKey:@"-1;;Photos framework is unavailable.\r\n"}];
        }
        return nil;
    }

    PHAssetCollection *album = [self fetchZXTouchAlbum];
    if (album)
    {
        return album;
    }

    NSError *creationError = nil;
    [[PHPhotoLibrary sharedPhotoLibrary] performChangesAndWait:^{
        [PHAssetCollectionChangeRequest creationRequestForAssetCollectionWithTitle:kZXTouchAlbumName];
    } error:&creationError];

    if (creationError)
    {
        if (error)
        {
            *error = [NSError errorWithDomain:@"com.zjx.zxtouchsp"
                                         code:999
                                     userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:@"-1;;Failed to create album: %@\r\n", creationError.localizedDescription]}];
        }
        return nil;
    }

    album = [self fetchZXTouchAlbum];
    if (!album && error)
    {
        *error = [NSError errorWithDomain:@"com.zjx.zxtouchsp"
                                     code:999
                                 userInfo:@{NSLocalizedDescriptionKey:@"-1;;Unable to fetch created album.\r\n"}];
    }
    return album;
}

+ (void)saveToSystemAlbum:(NSString*)filePath error:(NSError**)error
{
    UIImage *image = [UIImage imageWithContentsOfFile:filePath];
    if (!image)
    {
        if (error)
        {
            *error = [NSError errorWithDomain:@"com.zjx.zxtouchsp"
                                         code:999
                                     userInfo:@{NSLocalizedDescriptionKey:@"-1;;Image not found at path.\r\n"}];
        }
        return;
    }

    PHAssetCollection *album = [self ensureZXTouchAlbumWithError:error];
    if (!album)
    {
        return;
    }

    NSError *saveError = nil;
    [[PHPhotoLibrary sharedPhotoLibrary] performChangesAndWait:^{
        PHAssetChangeRequest *assetRequest = [PHAssetChangeRequest creationRequestForAssetFromImage:image];
        PHAssetCollectionChangeRequest *albumRequest = [PHAssetCollectionChangeRequest changeRequestForAssetCollection:album];
        [albumRequest addAssets:@[[assetRequest placeholderForCreatedAsset]]];
    } error:&saveError];

    if (saveError && error)
    {
        *error = [NSError errorWithDomain:@"com.zjx.zxtouchsp"
                                     code:999
                                 userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:@"-1;;Failed to save to album: %@\r\n", saveError.localizedDescription]}];
    }
}

+ (void)clearSystemAlbum:(NSError**)error
{
    PHAssetCollection *album = [self fetchZXTouchAlbum];
    if (!album)
    {
        return;
    }

    PHFetchResult<PHAsset*> *assets = [PHAsset fetchAssetsInAssetCollection:album options:nil];
    if (assets.count == 0)
    {
        return;
    }

    NSError *deleteError = nil;
    [[PHPhotoLibrary sharedPhotoLibrary] performChangesAndWait:^{
        [PHAssetChangeRequest deleteAssets:assets];
    } error:&deleteError];

    if (deleteError && error)
    {
        *error = [NSError errorWithDomain:@"com.zjx.zxtouchsp"
                                     code:999
                                 userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:@"-1;;Failed to clear album: %@\r\n", deleteError.localizedDescription]}];
    }
}
@end

NSString* handleScreenshotTaskFromRawData(UInt8 *eventData, NSError **error)
{
    NSArray *data = [[NSString stringWithUTF8String:(char*)eventData] componentsSeparatedByString:@";;"];
    if ([data count] < 1)
    {
        if (error)
        {
            *error = [NSError errorWithDomain:@"com.zjx.zxtouchsp"
                                         code:999
                                     userInfo:@{NSLocalizedDescriptionKey:@"-1;;Screenshot task missing action.\r\n"}];
        }
        return nil;
    }

    int action = [data[0] intValue];
    if (action == SCREENSHOT_TASK_CAPTURE)
    {
        if ([data count] < 2)
        {
            if (error)
            {
                *error = [NSError errorWithDomain:@"com.zjx.zxtouchsp"
                                             code:999
                                         userInfo:@{NSLocalizedDescriptionKey:@"-1;;Screenshot task missing output path.\r\n"}];
            }
            return nil;
        }

        NSString *filePath = data[1];
        CGRect region = CGRectZero;
        if ([data count] >= 6)
        {
            CGFloat x = [data[2] floatValue];
            CGFloat y = [data[3] floatValue];
            CGFloat width = [data[4] floatValue];
            CGFloat height = [data[5] floatValue];
            region = CGRectMake(x, y, width, height);
        }

        return [Screen screenShotToPath:filePath region:region error:error];
    }
    else if (action == SCREENSHOT_TASK_SAVE_TO_ALBUM)
    {
        if ([data count] < 2)
        {
            if (error)
            {
                *error = [NSError errorWithDomain:@"com.zjx.zxtouchsp"
                                             code:999
                                         userInfo:@{NSLocalizedDescriptionKey:@"-1;;Save to album missing file path.\r\n"}];
            }
            return nil;
        }

        [Screen saveToSystemAlbum:data[1] error:error];
        return nil;
    }
    else if (action == SCREENSHOT_TASK_CLEAR_ALBUM)
    {
        [Screen clearSystemAlbum:error];
        return nil;
    }

    if (error)
    {
        *error = [NSError errorWithDomain:@"com.zjx.zxtouchsp"
                                     code:999
                                 userInfo:@{NSLocalizedDescriptionKey:@"-1;;Unknown screenshot action.\r\n"}];
    }
    return nil;
}
