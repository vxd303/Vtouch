#ifndef SCREEN_H
#define SCREEN_H

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

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

@end

NSString* handleScreenshotTaskFromRawData(UInt8 *eventData, NSError **error);

#endif
