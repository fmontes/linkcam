#import "CameraPreviewView.h"

#import <AVFoundation/AVFoundation.h>
#import <QuartzCore/QuartzCore.h>

NSNotificationName const CameraPreviewAuthorizationDidChangeNotification = @"CameraPreviewAuthorizationDidChangeNotification";
static NSString * const CameraPreviewSourceDefaultsKey = @"LinkCamPreviewSourceUniqueID";

typedef NS_ENUM(NSInteger, CameraPreviewAction) {
    CameraPreviewActionNone = 0,
    CameraPreviewActionRequestAccess,
    CameraPreviewActionOpenSettings,
    CameraPreviewActionRetry
};

@interface CameraPreviewView ()
{
    AVCaptureSession *_session;
    AVCaptureVideoPreviewLayer *_previewLayer;
    NSView *_overlayView;
    NSImageView *_overlayIcon;
    NSTextField *_overlayTitle;
    NSTextField *_overlayDetail;
    NSButton *_overlayButton;
    dispatch_queue_t _sessionQueue;
    NSString *_selectedDeviceID;
    CameraPreviewAction _previewAction;
    BOOL _configured;
    BOOL _wantsPreview;
}
@end

@implementation CameraPreviewView

static NSTextField *previewLabel(NSString *text, CGFloat size, NSFontWeight weight, NSColor *color) {
    NSTextField *field = [NSTextField labelWithString:text];
    field.font = [NSFont systemFontOfSize:size weight:weight];
    field.textColor = color;
    field.alignment = NSTextAlignmentCenter;
    return field;
}

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (!self) return nil;

    self.wantsLayer = YES;
    self.layer.backgroundColor = [NSColor colorWithWhite:0.055 alpha:1.0].CGColor;
    self.layer.cornerRadius = 12.0;
    self.layer.masksToBounds = YES;

    _sessionQueue = dispatch_queue_create("com.fmontes.linkcam.preview", DISPATCH_QUEUE_SERIAL);
    _session = [[AVCaptureSession alloc] init];
    _selectedDeviceID = [[[NSUserDefaults standardUserDefaults] stringForKey:CameraPreviewSourceDefaultsKey] copy];

    _previewLayer = [[AVCaptureVideoPreviewLayer alloc] initWithSession:_session];
    _previewLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
    _previewLayer.zPosition = 0;
    [self.layer addSublayer:_previewLayer];

    _overlayView = [[NSView alloc] initWithFrame:NSZeroRect];
    _overlayView.translatesAutoresizingMaskIntoConstraints = NO;
    _overlayView.wantsLayer = YES;
    _overlayView.layer.backgroundColor = [NSColor colorWithWhite:0.055 alpha:0.94].CGColor;
    _overlayView.layer.zPosition = 10;
    [self addSubview:_overlayView];

    _overlayIcon = [[NSImageView alloc] initWithFrame:NSZeroRect];
    _overlayIcon.translatesAutoresizingMaskIntoConstraints = NO;
    _overlayIcon.imageScaling = NSImageScaleProportionallyUpOrDown;
    _overlayIcon.contentTintColor = NSColor.systemBlueColor;

    _overlayTitle = [previewLabel(@"Live camera preview", 13, NSFontWeightSemibold, NSColor.labelColor) retain];

    _overlayDetail = [previewLabel(@"Open LinkCam to start the preview.", 11, NSFontWeightRegular, NSColor.secondaryLabelColor) retain];
    _overlayDetail.lineBreakMode = NSLineBreakByWordWrapping;
    _overlayDetail.maximumNumberOfLines = 2;
    _overlayDetail.preferredMaxLayoutWidth = 292;

    _overlayButton = [[NSButton buttonWithTitle:@"" target:self action:@selector(previewActionPressed:)] retain];
    _overlayButton.bezelStyle = NSBezelStyleRounded;
    _overlayButton.controlSize = NSControlSizeRegular;
    _overlayButton.hidden = YES;

    NSStackView *overlayStack = [NSStackView stackViewWithViews:@[
        _overlayIcon, _overlayTitle, _overlayDetail, _overlayButton
    ]];
    overlayStack.translatesAutoresizingMaskIntoConstraints = NO;
    overlayStack.orientation = NSUserInterfaceLayoutOrientationVertical;
    overlayStack.alignment = NSLayoutAttributeCenterX;
    overlayStack.spacing = 6;
    [overlayStack setCustomSpacing:10 afterView:_overlayDetail];
    [_overlayView addSubview:overlayStack];

    [NSLayoutConstraint activateConstraints:@[
        [_overlayView.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [_overlayView.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [_overlayView.topAnchor constraintEqualToAnchor:self.topAnchor],
        [_overlayView.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
        [_overlayIcon.widthAnchor constraintEqualToConstant:25],
        [_overlayIcon.heightAnchor constraintEqualToConstant:25],
        [_overlayDetail.widthAnchor constraintLessThanOrEqualToConstant:292],
        [overlayStack.centerXAnchor constraintEqualToAnchor:_overlayView.centerXAnchor],
        [overlayStack.centerYAnchor constraintEqualToAnchor:_overlayView.centerYAnchor],
        [overlayStack.leadingAnchor constraintGreaterThanOrEqualToAnchor:_overlayView.leadingAnchor constant:18],
        [overlayStack.trailingAnchor constraintLessThanOrEqualToAnchor:_overlayView.trailingAnchor constant:-18]
    ]];

    [self showOverlayWithSymbol:@"video.fill"
                          title:@"Live camera preview"
                         detail:@"Open LinkCam to start the preview."
                    buttonTitle:nil
                         action:CameraPreviewActionNone];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(applicationDidBecomeActive:)
                                                 name:NSApplicationDidBecomeActiveNotification
                                               object:nil];
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_session stopRunning];
    [_previewLayer release];
    [_session release];
    [_overlayView release];
    [_overlayIcon release];
    [_overlayTitle release];
    [_overlayDetail release];
    [_overlayButton release];
    [_selectedDeviceID release];
    dispatch_release(_sessionQueue);
    [super dealloc];
}

- (void)layout {
    [super layout];
    _previewLayer.frame = self.bounds;
}

- (void)showOverlayWithSymbol:(NSString *)symbol
                        title:(NSString *)title
                       detail:(NSString *)detail
                  buttonTitle:(NSString *)buttonTitle
                       action:(CameraPreviewAction)action {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self showOverlayWithSymbol:symbol title:title detail:detail buttonTitle:buttonTitle action:action];
        });
        return;
    }

    NSImage *image = [NSImage imageWithSystemSymbolName:symbol accessibilityDescription:title];
    image.template = YES;
    _overlayIcon.image = image;
    _overlayTitle.stringValue = title;
    _overlayDetail.stringValue = detail;
    _previewAction = action;
    _overlayButton.hidden = buttonTitle.length == 0;
    if (buttonTitle.length > 0) {
        _overlayButton.title = buttonTitle;
        [_overlayButton setAccessibilityLabel:buttonTitle];
    }
    _overlayView.hidden = NO;
}

- (void)hideOverlay {
    dispatch_async(dispatch_get_main_queue(), ^{
        self->_overlayView.hidden = YES;
        self->_previewAction = CameraPreviewActionNone;
    });
}

- (void)pauseCaptureSession {
    dispatch_async(_sessionQueue, ^{
        if (self->_session.running) [self->_session stopRunning];
    });
}

- (NSArray *)availablePreviewSources {
    NSArray *allDevices = [[AVCaptureDevice devicesWithMediaType:AVMediaTypeVideo]
        sortedArrayUsingComparator:^NSComparisonResult(AVCaptureDevice *left, AVCaptureDevice *right) {
            return [left.localizedName localizedCaseInsensitiveCompare:right.localizedName];
        }];

    BOOL selectedDeviceExists = NO;
    AVCaptureDevice *preferredDevice = nil;
    AVCaptureDevice *firstInsta360Device = nil;
    NSMutableArray *sources = [NSMutableArray array];
    for (AVCaptureDevice *device in allDevices) {
        if ([device.localizedName rangeOfString:@"Insta360" options:NSCaseInsensitiveSearch].location == NSNotFound) {
            continue;
        }
        if (!firstInsta360Device) firstInsta360Device = device;
        if ([_selectedDeviceID isEqualToString:device.uniqueID]) selectedDeviceExists = YES;
        if (!preferredDevice &&
            [device.localizedName rangeOfString:@"Insta360 Link 2" options:NSCaseInsensitiveSearch].location != NSNotFound) {
            preferredDevice = device;
        }
        [sources addObject:@{@"id": device.uniqueID, @"name": device.localizedName}];
    }

    // An empty list commonly means camera access has not been granted yet.
    // Keep the saved source so a temporary authorization state does not erase
    // the user's virtual-camera preference.
    if (sources.count == 0) return sources;

    if (!selectedDeviceExists) {
        AVCaptureDevice *fallback = preferredDevice ?: firstInsta360Device;
        [_selectedDeviceID release];
        _selectedDeviceID = [fallback.uniqueID copy];
        if (_selectedDeviceID) {
            [[NSUserDefaults standardUserDefaults] setObject:_selectedDeviceID forKey:CameraPreviewSourceDefaultsKey];
        }
    }
    return sources;
}

- (NSString *)selectedPreviewSourceID {
    return _selectedDeviceID;
}

- (AVCaptureDevice *)selectedCamera {
    AVCaptureDevice *selected = _selectedDeviceID ? [AVCaptureDevice deviceWithUniqueID:_selectedDeviceID] : nil;
    if (selected &&
        [selected.localizedName rangeOfString:@"Insta360" options:NSCaseInsensitiveSearch].location != NSNotFound) {
        return selected;
    }

    NSArray *devices = [AVCaptureDevice devicesWithMediaType:AVMediaTypeVideo];
    for (AVCaptureDevice *device in devices) {
        if ([device.localizedName rangeOfString:@"Insta360" options:NSCaseInsensitiveSearch].location != NSNotFound) {
            return device;
        }
    }
    return nil;
}

- (void)selectPreviewSourceWithID:(NSString *)uniqueID {
    if (!uniqueID.length || [_selectedDeviceID isEqualToString:uniqueID]) return;

    [_selectedDeviceID release];
    _selectedDeviceID = [uniqueID copy];
    [[NSUserDefaults standardUserDefaults] setObject:_selectedDeviceID forKey:CameraPreviewSourceDefaultsKey];

    [self showOverlayWithSymbol:@"video.fill"
                          title:@"Switching preview"
                         detail:@"Connecting to the selected camera…"
                    buttonTitle:nil
                         action:CameraPreviewActionNone];
    dispatch_async(_sessionQueue, ^{
        @autoreleasepool {
            if (self->_session.running) [self->_session stopRunning];
            [self->_session beginConfiguration];
            for (AVCaptureInput *input in [[self->_session.inputs copy] autorelease]) {
                [self->_session removeInput:input];
            }
            [self->_session commitConfiguration];
            self->_configured = NO;
            if (self->_wantsPreview) [self configureAndStart];
        }
    });
}

- (void)configureAndStart {
    [self showOverlayWithSymbol:@"video.fill"
                          title:@"Starting preview"
                         detail:@"Connecting to your Insta360 Link 2…"
                    buttonTitle:nil
                         action:CameraPreviewActionNone];

    dispatch_async(_sessionQueue, ^{
        @autoreleasepool {
            if (!self->_wantsPreview) return;

            if (!self->_configured) {
                AVCaptureDevice *camera = [self selectedCamera];
                if (!camera) {
                    [self showOverlayWithSymbol:@"video.slash.fill"
                                          title:@"Preview source unavailable"
                                         detail:@"Connect or select a camera, then try again."
                                    buttonTitle:@"Try Again"
                                         action:CameraPreviewActionRetry];
                    return;
                }

                NSError *error = nil;
                AVCaptureDeviceInput *input = [AVCaptureDeviceInput deviceInputWithDevice:camera error:&error];
                if (!input) {
                    [self showOverlayWithSymbol:@"exclamationmark.triangle.fill"
                                          title:@"Preview unavailable"
                                         detail:@"Another app may be using the camera. Close it and try again."
                                    buttonTitle:@"Try Again"
                                         action:CameraPreviewActionRetry];
                    return;
                }

                [self->_session beginConfiguration];
                self->_session.sessionPreset = AVCaptureSessionPresetHigh;
                if (![self->_session canAddInput:input]) {
                    [self->_session commitConfiguration];
                    [self showOverlayWithSymbol:@"exclamationmark.triangle.fill"
                                          title:@"Preview unavailable"
                                         detail:@"LinkCam couldn’t start a preview from this camera."
                                    buttonTitle:@"Try Again"
                                         action:CameraPreviewActionRetry];
                    return;
                }
                [self->_session addInput:input];
                [self->_session commitConfiguration];
                self->_configured = YES;
            }

            if (!self->_session.running) [self->_session startRunning];
            if (!self->_wantsPreview) {
                if (self->_session.running) [self->_session stopRunning];
                return;
            }

            if (self->_session.running) {
                [self hideOverlay];
            } else {
                [self showOverlayWithSymbol:@"exclamationmark.triangle.fill"
                                      title:@"Preview unavailable"
                                     detail:@"Another app may be using the camera. Close it and try again."
                                buttonTitle:@"Try Again"
                                     action:CameraPreviewActionRetry];
            }
        }
    });
}

- (void)refreshAuthorizationState {
    AVAuthorizationStatus status = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo];
    switch (status) {
        case AVAuthorizationStatusAuthorized:
            [self configureAndStart];
            break;
        case AVAuthorizationStatusNotDetermined:
            [self pauseCaptureSession];
            [self showOverlayWithSymbol:@"video.badge.plus"
                                  title:@"Allow camera preview"
                                 detail:@"Access is used only for the live preview. Camera controls work without it."
                            buttonTitle:@"Allow Camera Access"
                                 action:CameraPreviewActionRequestAccess];
            break;
        case AVAuthorizationStatusDenied:
            [self pauseCaptureSession];
            [self showOverlayWithSymbol:@"lock.fill"
                                  title:@"Camera access is off"
                                 detail:@"Enable LinkCam in Privacy & Security › Camera, then return here."
                            buttonTitle:@"Open System Settings"
                                 action:CameraPreviewActionOpenSettings];
            break;
        case AVAuthorizationStatusRestricted:
            [self pauseCaptureSession];
            [self showOverlayWithSymbol:@"lock.fill"
                                  title:@"Camera access is restricted"
                                 detail:@"This Mac’s privacy settings currently prevent camera access."
                            buttonTitle:@"Open System Settings"
                                 action:CameraPreviewActionOpenSettings];
            break;
    }
}

- (void)requestCameraAccess {
    if ([AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo] != AVAuthorizationStatusNotDetermined) {
        [self refreshAuthorizationState];
        return;
    }

    [self showOverlayWithSymbol:@"video.badge.plus"
                          title:@"Waiting for permission"
                         detail:@"Choose Allow in the macOS permission dialog."
                    buttonTitle:nil
                         action:CameraPreviewActionNone];
    [AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo completionHandler:^(BOOL granted) {
        (void)granted;
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter]
                postNotificationName:CameraPreviewAuthorizationDidChangeNotification object:self];
            if (self->_wantsPreview) [self refreshAuthorizationState];
        });
    }];
}

- (void)openCameraSettings {
    // Apple does not expose a dedicated camera-settings API. This fixed system
    // URL opens Privacy & Security > Camera; opening System Settings itself is
    // the safe fallback if a macOS version does not recognize the pane URL.
    NSURL *cameraSettings = [NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_Camera"];
    if ([[NSWorkspace sharedWorkspace] openURL:cameraSettings]) return;

    NSURL *settingsApp = [[NSWorkspace sharedWorkspace] URLForApplicationWithBundleIdentifier:@"com.apple.systempreferences"];
    if (settingsApp) [[NSWorkspace sharedWorkspace] openURL:settingsApp];
}

- (void)previewActionPressed:(id)sender {
    (void)sender;
    switch (_previewAction) {
        case CameraPreviewActionRequestAccess:
            [self requestCameraAccess];
            break;
        case CameraPreviewActionOpenSettings:
            [self openCameraSettings];
            break;
        case CameraPreviewActionRetry:
            [self refreshAuthorizationState];
            break;
        case CameraPreviewActionNone:
            break;
    }
}

- (void)applicationDidBecomeActive:(NSNotification *)notification {
    (void)notification;
    if (_wantsPreview) [self refreshAuthorizationState];
}

- (void)startPreview {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self startPreview]; });
        return;
    }
    _wantsPreview = YES;
    [self refreshAuthorizationState];
}

- (void)stopPreview {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self stopPreview]; });
        return;
    }
    _wantsPreview = NO;
    [self pauseCaptureSession];
    [self showOverlayWithSymbol:@"video.fill"
                          title:@"Live camera preview"
                         detail:@"Open LinkCam to start the preview."
                    buttonTitle:nil
                         action:CameraPreviewActionNone];
}

@end
