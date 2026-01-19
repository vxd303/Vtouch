#ifndef SCREEN_H
#define SCREEN_H

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#ifdef __cplusplus
#ifdef NO
#undef NO
#import <opencv2/opencv.hpp>
#define NO __objc_no
#else
#import <opencv2/opencv.hpp>
#endif
#endif

@interface Screen :NSObject
{
    
}

#define SCREENSHOT_TASK_CAPTURE 1
#define SCREENSHOT_TASK_SAVE_TO_ALBUM 2
#define SCREENSHOT_TASK_CLEAR_ALBUM 3

+ (void)setScreenSize:(CGFloat)x height:(CGFloat) y;
+ (int)getScreenOrientation;
+ (CGFloat)getScreenWidth;
+ (CGFloat)getScreenHeight;
+ (CGFloat)getScale;
+ (NSString*)screenShot;
+ (CGRect)getBounds;
+ (NSString*)screenShotAlwaysUp;
+ (UIImage*)screenShotUIImage;
+ (void)releaseUIImage:(UIImage**)img;
+ (CGImageRef)createScreenShotCGImageRef;
+ (NSString*)screenShotToPath:(NSString*)filePath region:(CGRect)region error:(NSError**)error;
+ (void)saveToSystemAlbum:(NSString*)filePath error:(NSError**)error;
+ (void)clearSystemAlbum:(NSError**)error;

#ifdef __cplusplus
+ (cv::Mat)createScreenShotCvMat;
#endif

@end

NSString* handleScreenshotTaskFromRawData(UInt8 *eventData, NSError **error);

#endif
