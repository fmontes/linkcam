#import <AppKit/AppKit.h>

FOUNDATION_EXPORT NSNotificationName const CameraPreviewAuthorizationDidChangeNotification;

@interface CameraPreviewView : NSView
- (NSArray *)availablePreviewSources;
- (NSString *)selectedPreviewSourceID;
- (void)selectPreviewSourceWithID:(NSString *)uniqueID;
- (void)startPreview;
- (void)stopPreview;
@end
