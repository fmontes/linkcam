#import "LinkCamPopoverViewController.h"

#import "CameraPreviewView.h"
#import "LinkCamCore.h"
#import "LinkCamMath.h"

#include <math.h>
#include <stdlib.h>

enum {
    DirectionUp = 1,
    DirectionDown,
    DirectionLeft,
    DirectionRight,
    DirectionCenter
};

@interface LinkCamPopoverViewController ()
{
    CameraPreviewView *_previewView;
    NSTextField *_connectionDot;
    NSTextField *_connectionLabel;
    NSTextField *_connectionStatus;
    NSTextField *_panValue;
    NSTextField *_tiltValue;
    NSTextField *_zoomValue;
    NSTextField *_previewZoomValue;
    NSTextField *_messageLabel;
    NSProgressIndicator *_activityIndicator;
    NSButton *_refreshButton;
    NSPopUpButton *_previewSourcePicker;
    NSPopUpButton *_stepPicker;
    NSSlider *_zoomSlider;
    NSSwitch *_trackingSwitch;
    NSTextField *_trackingStatus;
    NSSegmentedControl *_modeControl;
    NSMutableArray *_controlButtons;
    dispatch_queue_t _deviceQueue;
    LinkCamDevice *_device;
    NSTimer *_stateTimer;
    id _keyMonitor;
    NSInteger _nudgeDegrees;
    BOOL _trackingAvailable;
    BOOL _trackingRequested;
    BOOL _trackingActive;
    BOOL _connected;
    BOOL _operationInFlight;
    BOOL _pollInFlight;
    BOOL _popoverOpen;
    BOOL _previewSourcesAvailable;
}
@end

@implementation LinkCamPopoverViewController

static NSTextField *label(NSString *text, CGFloat size, NSFontWeight weight, NSColor *color) {
    NSTextField *field = [NSTextField labelWithString:text];
    field.font = [NSFont systemFontOfSize:size weight:weight];
    field.textColor = color;
    return field;
}

static NSView *panel(CGFloat radius, NSColor *color) {
    NSView *view = [[[NSView alloc] initWithFrame:NSZeroRect] autorelease];
    view.wantsLayer = YES;
    view.layer.backgroundColor = color.CGColor;
    view.layer.cornerRadius = radius;
    view.layer.borderWidth = 1.0;
    view.layer.borderColor = [NSColor colorWithWhite:1.0 alpha:0.08].CGColor;
    return view;
}

static NSBox *separator(void) {
    NSBox *line = [[[NSBox alloc] initWithFrame:NSZeroRect] autorelease];
    line.boxType = NSBoxSeparator;
    return line;
}

- (instancetype)init {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _deviceQueue = dispatch_queue_create("com.fmontes.linkcam.device", DISPATCH_QUEUE_SERIAL);
        _controlButtons = [[NSMutableArray alloc] init];
        _nudgeDegrees = 2;
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(previewAuthorizationChanged:)
                                                     name:CameraPreviewAuthorizationDidChangeNotification
                                                   object:nil];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_stateTimer invalidate];
    [_stateTimer release];
    if (_device) LinkCamDeviceClose(_device);
    [_previewView release];
    [_connectionDot release];
    [_connectionLabel release];
    [_connectionStatus release];
    [_panValue release];
    [_tiltValue release];
    [_zoomValue release];
    [_previewZoomValue release];
    [_messageLabel release];
    [_activityIndicator release];
    [_refreshButton release];
    [_previewSourcePicker release];
    [_stepPicker release];
    [_zoomSlider release];
    [_trackingSwitch release];
    [_trackingStatus release];
    [_modeControl release];
    [_controlButtons release];
    if (_keyMonitor) [NSEvent removeMonitor:_keyMonitor];
    dispatch_release(_deviceQueue);
    [super dealloc];
}

- (NSButton *)symbolButton:(NSString *)symbol label:(NSString *)accessibility tag:(NSInteger)tag {
    NSButton *button = [NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:symbol accessibilityDescription:accessibility]
                                         target:self
                                         action:@selector(directionPressed:)];
    button.tag = tag;
    button.bordered = NO;
    button.imagePosition = NSImageOnly;
    button.contentTintColor = NSColor.labelColor;
    button.toolTip = accessibility;
    button.translatesAutoresizingMaskIntoConstraints = NO;
    [button.widthAnchor constraintEqualToConstant:34].active = YES;
    [button.heightAnchor constraintEqualToConstant:34].active = YES;
    [button setAccessibilityLabel:accessibility];
    [_controlButtons addObject:button];
    return button;
}

- (void)loadView {
    NSView *root = [[[NSView alloc] initWithFrame:NSMakeRect(0, 0, 430, 650)] autorelease];
    root.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    root.wantsLayer = YES;
    root.layer.backgroundColor = [NSColor colorWithWhite:0.085 alpha:1.0].CGColor;
    self.view = root;

    _connectionDot = [label(@"●", 10, NSFontWeightRegular, NSColor.systemRedColor) retain];
    _connectionLabel = [label(@"Insta360 Link 2", 17, NSFontWeightSemibold, NSColor.labelColor) retain];
    _connectionStatus = [label(@"Disconnected", 13, NSFontWeightRegular, NSColor.secondaryLabelColor) retain];

    _refreshButton = [[NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:@"ellipsis" accessibilityDescription:@"More options"]
                                          target:self
                                          action:@selector(morePressed:)] retain];
    _refreshButton.bordered = NO;
    _refreshButton.toolTip = @"More options";

    NSView *header = [[[NSView alloc] initWithFrame:NSZeroRect] autorelease];
    NSView *cameraTile = panel(9, [NSColor colorWithWhite:1.0 alpha:0.11]);
    NSImageView *cameraIcon = [[[NSImageView alloc] initWithFrame:NSZeroRect] autorelease];
    cameraIcon.image = [NSImage imageWithSystemSymbolName:@"web.camera.fill" accessibilityDescription:@"Insta360 Link 2"];
    cameraIcon.contentTintColor = NSColor.labelColor;
    cameraIcon.translatesAutoresizingMaskIntoConstraints = NO;
    [cameraTile addSubview:cameraIcon];

    NSStackView *statusLine = [NSStackView stackViewWithViews:@[_connectionDot, _connectionStatus]];
    statusLine.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    statusLine.alignment = NSLayoutAttributeCenterY;
    statusLine.spacing = 6;
    NSStackView *headerText = [NSStackView stackViewWithViews:@[_connectionLabel, statusLine]];
    headerText.orientation = NSUserInterfaceLayoutOrientationVertical;
    headerText.alignment = NSLayoutAttributeLeading;
    headerText.spacing = 1;

    for (NSView *view in @[cameraTile, headerText, _refreshButton]) {
        view.translatesAutoresizingMaskIntoConstraints = NO;
        [header addSubview:view];
    }
    [NSLayoutConstraint activateConstraints:@[
        [cameraTile.leadingAnchor constraintEqualToAnchor:header.leadingAnchor],
        [cameraTile.centerYAnchor constraintEqualToAnchor:header.centerYAnchor],
        [cameraTile.widthAnchor constraintEqualToConstant:38],
        [cameraTile.heightAnchor constraintEqualToConstant:38],
        [cameraIcon.centerXAnchor constraintEqualToAnchor:cameraTile.centerXAnchor],
        [cameraIcon.centerYAnchor constraintEqualToAnchor:cameraTile.centerYAnchor],
        [cameraIcon.widthAnchor constraintEqualToConstant:22],
        [cameraIcon.heightAnchor constraintEqualToConstant:22],
        [headerText.leadingAnchor constraintEqualToAnchor:cameraTile.trailingAnchor constant:12],
        [headerText.centerYAnchor constraintEqualToAnchor:header.centerYAnchor],
        [_refreshButton.trailingAnchor constraintEqualToAnchor:header.trailingAnchor],
        [_refreshButton.centerYAnchor constraintEqualToAnchor:header.centerYAnchor],
        [_refreshButton.widthAnchor constraintEqualToConstant:30],
        [_refreshButton.heightAnchor constraintEqualToConstant:30],
        [header.heightAnchor constraintEqualToConstant:46]
    ]];

    _previewView = [[CameraPreviewView alloc] initWithFrame:NSZeroRect];
    _previewView.translatesAutoresizingMaskIntoConstraints = NO;
    NSView *previewContainer = [[[NSView alloc] initWithFrame:NSZeroRect] autorelease];
    [previewContainer addSubview:_previewView];
    [_previewView.leadingAnchor constraintEqualToAnchor:previewContainer.leadingAnchor].active = YES;
    [_previewView.trailingAnchor constraintEqualToAnchor:previewContainer.trailingAnchor].active = YES;
    [_previewView.topAnchor constraintEqualToAnchor:previewContainer.topAnchor].active = YES;
    [_previewView.bottomAnchor constraintEqualToAnchor:previewContainer.bottomAnchor].active = YES;
    [previewContainer.heightAnchor constraintEqualToConstant:224].active = YES;

    _panValue = [label(@"Pan —", 12, NSFontWeightMedium, NSColor.labelColor) retain];
    _tiltValue = [label(@"Tilt —", 12, NSFontWeightMedium, NSColor.labelColor) retain];
    _previewZoomValue = [label(@"Zoom —", 12, NSFontWeightMedium, NSColor.labelColor) retain];
    NSStackView *telemetryStack = [NSStackView stackViewWithViews:@[_panValue, _tiltValue, _previewZoomValue]];
    telemetryStack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    telemetryStack.spacing = 13;
    telemetryStack.translatesAutoresizingMaskIntoConstraints = NO;
    NSView *telemetryPill = panel(14, [NSColor colorWithWhite:0.02 alpha:0.69]);
    telemetryPill.translatesAutoresizingMaskIntoConstraints = NO;
    [telemetryPill addSubview:telemetryStack];
    [previewContainer addSubview:telemetryPill];
    [NSLayoutConstraint activateConstraints:@[
        [telemetryPill.leadingAnchor constraintEqualToAnchor:previewContainer.leadingAnchor constant:10],
        [telemetryPill.bottomAnchor constraintEqualToAnchor:previewContainer.bottomAnchor constant:-9],
        [telemetryPill.heightAnchor constraintEqualToConstant:28],
        [telemetryStack.leadingAnchor constraintEqualToAnchor:telemetryPill.leadingAnchor constant:10],
        [telemetryStack.trailingAnchor constraintEqualToAnchor:telemetryPill.trailingAnchor constant:-10],
        [telemetryStack.centerYAnchor constraintEqualToAnchor:telemetryPill.centerYAnchor]
    ]];

    NSView *settingsCard = panel(12, [NSColor colorWithWhite:1.0 alpha:0.065]);
    [settingsCard.heightAnchor constraintEqualToConstant:136].active = YES;

    NSTextField *previewSourceLabel = label(@"Source", 14, NSFontWeightRegular, NSColor.labelColor);
    _previewSourcePicker = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    _previewSourcePicker.controlSize = NSControlSizeRegular;
    _previewSourcePicker.font = [NSFont systemFontOfSize:13];
    _previewSourcePicker.target = self;
    _previewSourcePicker.action = @selector(previewSourceChanged:);
    [_previewSourcePicker setAccessibilityLabel:@"Preview source"];
    _previewSourcePicker.translatesAutoresizingMaskIntoConstraints = NO;

    NSTextField *trackingTitle = label(@"AI Tracking", 14, NSFontWeightRegular, NSColor.labelColor);
    _trackingStatus = [label(@"", 11, NSFontWeightRegular, NSColor.secondaryLabelColor) retain];
    _trackingStatus.alignment = NSTextAlignmentRight;
    _trackingSwitch = [[NSSwitch alloc] initWithFrame:NSZeroRect];
    _trackingSwitch.target = self;
    _trackingSwitch.action = @selector(trackingChanged:);
    [_trackingSwitch setAccessibilityLabel:@"AI subject tracking"];
    _trackingSwitch.translatesAutoresizingMaskIntoConstraints = NO;

    NSTextField *modeTitle = label(@"Mode", 14, NSFontWeightRegular, NSColor.labelColor);
    _modeControl = [[NSSegmentedControl alloc] initWithFrame:NSZeroRect];
    _modeControl.segmentCount = 3;
    [_modeControl setLabel:@"Normal" forSegment:0];
    [_modeControl setLabel:@"DeskView" forSegment:1];
    [_modeControl setLabel:@"Whiteboard" forSegment:2];
    [_modeControl setWidth:72 forSegment:0];
    [_modeControl setWidth:78 forSegment:1];
    [_modeControl setWidth:91 forSegment:2];
    _modeControl.trackingMode = NSSegmentSwitchTrackingSelectOne;
    _modeControl.selectedSegment = 0;
    _modeControl.target = self;
    _modeControl.action = @selector(modeChanged:);
    [_modeControl setAccessibilityLabel:@"Camera mode"];
    _modeControl.translatesAutoresizingMaskIntoConstraints = NO;

    NSBox *settingsLineOne = separator();
    NSBox *settingsLineTwo = separator();
    for (NSView *view in @[previewSourceLabel, _previewSourcePicker, trackingTitle, _trackingStatus,
                           _trackingSwitch, modeTitle, _modeControl, settingsLineOne, settingsLineTwo]) {
        view.translatesAutoresizingMaskIntoConstraints = NO;
        [settingsCard addSubview:view];
    }
    [NSLayoutConstraint activateConstraints:@[
        [previewSourceLabel.leadingAnchor constraintEqualToAnchor:settingsCard.leadingAnchor constant:12],
        [previewSourceLabel.centerYAnchor constraintEqualToAnchor:settingsCard.topAnchor constant:23],
        [_previewSourcePicker.trailingAnchor constraintEqualToAnchor:settingsCard.trailingAnchor constant:-10],
        [_previewSourcePicker.centerYAnchor constraintEqualToAnchor:previewSourceLabel.centerYAnchor],
        [_previewSourcePicker.widthAnchor constraintEqualToConstant:221],
        [settingsLineOne.leadingAnchor constraintEqualToAnchor:settingsCard.leadingAnchor constant:12],
        [settingsLineOne.trailingAnchor constraintEqualToAnchor:settingsCard.trailingAnchor constant:-12],
        [settingsLineOne.topAnchor constraintEqualToAnchor:settingsCard.topAnchor constant:45],
        [trackingTitle.leadingAnchor constraintEqualToAnchor:settingsCard.leadingAnchor constant:12],
        [trackingTitle.centerYAnchor constraintEqualToAnchor:settingsCard.topAnchor constant:68],
        [_trackingSwitch.trailingAnchor constraintEqualToAnchor:settingsCard.trailingAnchor constant:-12],
        [_trackingSwitch.centerYAnchor constraintEqualToAnchor:trackingTitle.centerYAnchor],
        [_trackingStatus.trailingAnchor constraintEqualToAnchor:_trackingSwitch.leadingAnchor constant:-8],
        [_trackingStatus.centerYAnchor constraintEqualToAnchor:trackingTitle.centerYAnchor],
        [settingsLineTwo.leadingAnchor constraintEqualToAnchor:settingsCard.leadingAnchor constant:12],
        [settingsLineTwo.trailingAnchor constraintEqualToAnchor:settingsCard.trailingAnchor constant:-12],
        [settingsLineTwo.topAnchor constraintEqualToAnchor:settingsCard.topAnchor constant:91],
        [modeTitle.leadingAnchor constraintEqualToAnchor:settingsCard.leadingAnchor constant:12],
        [modeTitle.centerYAnchor constraintEqualToAnchor:settingsCard.topAnchor constant:114],
        [_modeControl.trailingAnchor constraintEqualToAnchor:settingsCard.trailingAnchor constant:-10],
        [_modeControl.centerYAnchor constraintEqualToAnchor:modeTitle.centerYAnchor],
        [_modeControl.widthAnchor constraintEqualToConstant:250]
    ]];

    NSView *controlsCard = panel(12, [NSColor colorWithWhite:1.0 alpha:0.065]);
    [controlsCard.heightAnchor constraintEqualToConstant:160].active = YES;
    NSView *pad = panel(68, [NSColor colorWithWhite:1.0 alpha:0.045]);
    pad.translatesAutoresizingMaskIntoConstraints = NO;
    NSButton *up = [self symbolButton:@"chevron.up" label:@"Pan up" tag:DirectionUp];
    NSButton *down = [self symbolButton:@"chevron.down" label:@"Pan down" tag:DirectionDown];
    NSButton *left = [self symbolButton:@"chevron.left" label:@"Tilt left" tag:DirectionLeft];
    NSButton *right = [self symbolButton:@"chevron.right" label:@"Tilt right" tag:DirectionRight];
    NSButton *center = [self symbolButton:@"scope" label:@"Recenter camera" tag:DirectionCenter];
    center.bordered = YES;
    center.bezelStyle = NSBezelStyleCircular;
    for (NSButton *button in @[up, down, left, right, center]) [pad addSubview:button];
    [controlsCard addSubview:pad];
    [NSLayoutConstraint activateConstraints:@[
        [pad.leadingAnchor constraintEqualToAnchor:controlsCard.leadingAnchor constant:12],
        [pad.centerYAnchor constraintEqualToAnchor:controlsCard.centerYAnchor],
        [pad.widthAnchor constraintEqualToConstant:136],
        [pad.heightAnchor constraintEqualToConstant:136],
        [up.centerXAnchor constraintEqualToAnchor:pad.centerXAnchor],
        [up.topAnchor constraintEqualToAnchor:pad.topAnchor constant:10],
        [down.centerXAnchor constraintEqualToAnchor:pad.centerXAnchor],
        [down.bottomAnchor constraintEqualToAnchor:pad.bottomAnchor constant:-10],
        [left.centerYAnchor constraintEqualToAnchor:pad.centerYAnchor],
        [left.leadingAnchor constraintEqualToAnchor:pad.leadingAnchor constant:10],
        [right.centerYAnchor constraintEqualToAnchor:pad.centerYAnchor],
        [right.trailingAnchor constraintEqualToAnchor:pad.trailingAnchor constant:-10],
        [center.centerXAnchor constraintEqualToAnchor:pad.centerXAnchor],
        [center.centerYAnchor constraintEqualToAnchor:pad.centerYAnchor],
        [center.widthAnchor constraintEqualToConstant:46],
        [center.heightAnchor constraintEqualToConstant:46]
    ]];

    NSTextField *zoomTitle = label(@"Zoom", 14, NSFontWeightMedium, NSColor.labelColor);
    _zoomValue = [label(@"—", 14, NSFontWeightRegular, NSColor.secondaryLabelColor) retain];
    _zoomValue.alignment = NSTextAlignmentRight;
    NSStackView *zoomHeader = [NSStackView stackViewWithViews:@[zoomTitle, _zoomValue]];
    zoomHeader.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    zoomHeader.distribution = NSStackViewDistributionFillEqually;

    _zoomSlider = [[NSSlider alloc] initWithFrame:NSZeroRect];
    _zoomSlider.minValue = 1.0;
    _zoomSlider.maxValue = 4.0;
    _zoomSlider.numberOfTickMarks = 4;
    _zoomSlider.allowsTickMarkValuesOnly = NO;
    _zoomSlider.continuous = NO;
    _zoomSlider.target = self;
    _zoomSlider.action = @selector(zoomChanged:);
    [_zoomSlider setAccessibilityLabel:@"Zoom"];
    NSStackView *tickLabels = [NSStackView stackViewWithViews:@[
        label(@"1×", 11, NSFontWeightRegular, NSColor.tertiaryLabelColor),
        label(@"2×", 11, NSFontWeightRegular, NSColor.tertiaryLabelColor),
        label(@"3×", 11, NSFontWeightRegular, NSColor.tertiaryLabelColor),
        label(@"4×", 11, NSFontWeightRegular, NSColor.tertiaryLabelColor)
    ]];
    tickLabels.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    tickLabels.distribution = NSStackViewDistributionEqualSpacing;

    NSTextField *keyboardHint = label(@"Arrow keys work", 11, NSFontWeightRegular, NSColor.secondaryLabelColor);
    _stepPicker = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    for (NSNumber *degrees in @[@1, @2, @5]) {
        [_stepPicker addItemWithTitle:[NSString stringWithFormat:@"%@° step", degrees]];
        _stepPicker.lastItem.representedObject = degrees;
    }
    [_stepPicker selectItemAtIndex:1];
    _stepPicker.controlSize = NSControlSizeSmall;
    _stepPicker.font = [NSFont systemFontOfSize:11];
    _stepPicker.target = self;
    _stepPicker.action = @selector(stepChanged:);
    [_stepPicker setAccessibilityLabel:@"Movement step"];
    NSStackView *stepRow = [NSStackView stackViewWithViews:@[keyboardHint, _stepPicker]];
    stepRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    stepRow.distribution = NSStackViewDistributionEqualSpacing;
    stepRow.alignment = NSLayoutAttributeCenterY;

    NSStackView *zoomStack = [NSStackView stackViewWithViews:@[zoomHeader, _zoomSlider, tickLabels, stepRow]];
    zoomStack.translatesAutoresizingMaskIntoConstraints = NO;
    zoomStack.orientation = NSUserInterfaceLayoutOrientationVertical;
    zoomStack.spacing = 4;
    [zoomStack setCustomSpacing:1 afterView:_zoomSlider];
    [zoomStack setCustomSpacing:13 afterView:tickLabels];
    [controlsCard addSubview:zoomStack];
    [NSLayoutConstraint activateConstraints:@[
        [zoomStack.leadingAnchor constraintEqualToAnchor:pad.trailingAnchor constant:18],
        [zoomStack.trailingAnchor constraintEqualToAnchor:controlsCard.trailingAnchor constant:-12],
        [zoomStack.centerYAnchor constraintEqualToAnchor:controlsCard.centerYAnchor],
        [zoomHeader.widthAnchor constraintEqualToAnchor:zoomStack.widthAnchor],
        [_zoomSlider.widthAnchor constraintEqualToAnchor:zoomStack.widthAnchor],
        [tickLabels.widthAnchor constraintEqualToAnchor:zoomStack.widthAnchor],
        [stepRow.widthAnchor constraintEqualToAnchor:zoomStack.widthAnchor]
    ]];

    _activityIndicator = [[NSProgressIndicator alloc] initWithFrame:NSZeroRect];
    _activityIndicator.style = NSProgressIndicatorStyleSpinning;
    _activityIndicator.controlSize = NSControlSizeSmall;
    _activityIndicator.displayedWhenStopped = NO;
    _activityIndicator.translatesAutoresizingMaskIntoConstraints = NO;
    [_activityIndicator.widthAnchor constraintEqualToConstant:14].active = YES;
    [_activityIndicator.heightAnchor constraintEqualToConstant:14].active = YES;
    [_activityIndicator setAccessibilityLabel:@"Camera action in progress"];

    _messageLabel = [label(@"Connect the camera to begin", 11, NSFontWeightRegular, NSColor.secondaryLabelColor) retain];
    _messageLabel.lineBreakMode = NSLineBreakByTruncatingTail;

    NSStackView *statusBar = [NSStackView stackViewWithViews:@[_activityIndicator, _messageLabel]];
    statusBar.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    statusBar.alignment = NSLayoutAttributeCenterY;
    statusBar.spacing = 7;
    [statusBar.heightAnchor constraintEqualToConstant:18].active = YES;
    [_messageLabel setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];

    NSStackView *stack = [NSStackView stackViewWithViews:@[header, previewContainer, settingsCard, controlsCard, statusBar]];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.spacing = 10;
    [root addSubview:stack];

    [header.widthAnchor constraintEqualToAnchor:stack.widthAnchor].active = YES;
    [previewContainer.widthAnchor constraintEqualToAnchor:stack.widthAnchor].active = YES;
    [settingsCard.widthAnchor constraintEqualToAnchor:stack.widthAnchor].active = YES;
    [controlsCard.widthAnchor constraintEqualToAnchor:stack.widthAnchor].active = YES;
    [statusBar.widthAnchor constraintEqualToAnchor:stack.widthAnchor].active = YES;

    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:16],
        [stack.trailingAnchor constraintEqualToAnchor:root.trailingAnchor constant:-16],
        [stack.topAnchor constraintEqualToAnchor:root.topAnchor constant:14],
        [stack.bottomAnchor constraintEqualToAnchor:root.bottomAnchor constant:-12]
    ]];

    [self setControlsEnabled:NO];
}

- (void)refreshPreviewSources {
    NSArray *sources = [_previewView availablePreviewSources];
    NSString *selectedID = [_previewView selectedPreviewSourceID];
    [_previewSourcePicker removeAllItems];

    if (sources.count == 0) {
        _previewSourcesAvailable = NO;
        [_previewSourcePicker addItemWithTitle:@"Camera access required"];
        _previewSourcePicker.enabled = NO;
        return;
    }

    _previewSourcesAvailable = YES;
    _previewSourcePicker.enabled = !_operationInFlight;
    for (NSDictionary *source in sources) {
        [_previewSourcePicker addItemWithTitle:source[@"name"]];
        _previewSourcePicker.lastItem.representedObject = source[@"id"];
    }
    for (NSMenuItem *item in _previewSourcePicker.itemArray) {
        if ([item.representedObject isEqualToString:selectedID]) {
            [_previewSourcePicker selectItem:item];
            break;
        }
    }
}

- (void)previewSourceChanged:(NSPopUpButton *)sender {
    NSString *uniqueID = sender.selectedItem.representedObject;
    if (uniqueID) [_previewView selectPreviewSourceWithID:uniqueID];
}

- (void)previewAuthorizationChanged:(NSNotification *)notification {
    (void)notification;
    [self refreshPreviewSources];
    [self refreshDevice];
}

- (void)setControlsEnabled:(BOOL)enabled {
    for (NSButton *button in _controlButtons) button.enabled = enabled;
    _zoomSlider.enabled = enabled;
    _trackingSwitch.enabled = enabled && _trackingAvailable;
    _modeControl.enabled = enabled;
    _stepPicker.enabled = !_operationInFlight;
    _refreshButton.enabled = !_operationInFlight;
    _previewSourcePicker.enabled = _previewSourcesAvailable && !_operationInFlight;
}

- (void)beginOperationWithMessage:(NSString *)message {
    _operationInFlight = YES;
    [_activityIndicator startAnimation:nil];
    if (message.length > 0) _messageLabel.stringValue = message;
    [self setControlsEnabled:NO];
}

- (void)finishOperation {
    _operationInFlight = NO;
    [_activityIndicator stopAnimation:nil];
    [self setControlsEnabled:_connected];
}

- (void)updateDisplayedState:(LinkCamState)state {
    _connected = YES;
    _connectionDot.textColor = NSColor.systemGreenColor;
    _connectionLabel.stringValue = @"Insta360 Link 2";
    _connectionStatus.stringValue = @"Connected · USB-C";
    _panValue.stringValue = [NSString stringWithFormat:@"Pan %.1f°", LinkCamDegreesFromUnits(state.panUnits)];
    _tiltValue.stringValue = [NSString stringWithFormat:@"Tilt %.1f°", LinkCamDegreesFromUnits(state.tiltUnits)];
    double zoom = LinkCamZoomMultiplierFromUnits(state.zoomUnits);
    _zoomValue.stringValue = [NSString stringWithFormat:@"%.2f×", zoom];
    _previewZoomValue.stringValue = [NSString stringWithFormat:@"Zoom %.2f×", zoom];
    _zoomSlider.doubleValue = zoom;
    _trackingAvailable = state.tracking >= 0;
    _trackingRequested = state.tracking == 1;
    _trackingActive = state.trackingActive == 1;
    _trackingSwitch.state = state.tracking == 1 ? NSControlStateValueOn : NSControlStateValueOff;
    _trackingStatus.stringValue = state.tracking < 0
        ? @"Unavailable"
        : (state.tracking ? (_trackingActive ? @"Tracking" : @"Looking…") : @"");
    if (state.videoMode == 6) _modeControl.selectedSegment = 1;
    else if (state.videoMode == 4) _modeControl.selectedSegment = 2;
    else _modeControl.selectedSegment = 0;
}

- (void)applyState:(LinkCamState)state {
    [self updateDisplayedState:state];
    if (state.tracking == 1) {
        _messageLabel.stringValue = _trackingActive
            ? @"Tracking subject · Manual controls turn it off"
            : @"Looking for a subject in the camera preview…";
    } else {
        _messageLabel.stringValue = [NSString stringWithFormat:@"Ready · %ld° steps", (long)_nudgeDegrees];
    }
    [self finishOperation];
}

- (void)applyError:(LinkCamResult)result {
    _connected = NO;
    _connectionDot.textColor = NSColor.systemRedColor;
    _connectionLabel.stringValue = @"Insta360 Link 2";
    _connectionStatus.stringValue = @"Disconnected";
    _panValue.stringValue = @"Pan —";
    _tiltValue.stringValue = @"Tilt —";
    _zoomValue.stringValue = @"—";
    _previewZoomValue.stringValue = @"Zoom —";
    _trackingAvailable = NO;
    _trackingRequested = NO;
    _trackingActive = NO;
    _trackingSwitch.state = NSControlStateValueOff;
    _trackingStatus.stringValue = @"Unavailable";
    _modeControl.selectedSegment = 0;
    switch (result) {
        case LinkCamResultDeviceNotFound:
            _messageLabel.stringValue = @"Connect the camera to begin";
            break;
        case LinkCamResultReadFailed:
            _messageLabel.stringValue = @"Camera is busy or unavailable";
            break;
        case LinkCamResultWriteFailed:
            _messageLabel.stringValue = @"Could not update the camera";
            break;
        case LinkCamResultTrackingDisableFailed:
            _messageLabel.stringValue = @"Could not turn off AI tracking";
            break;
        default:
            _messageLabel.stringValue = @"Camera control unavailable";
            break;
    }
    [self finishOperation];
}

- (void)beginStateRefresh {
    [self beginOperationWithMessage:@"Refreshing camera position…"];
    _connectionDot.textColor = NSColor.systemOrangeColor;
    _connectionLabel.stringValue = @"Insta360 Link 2";
    _connectionStatus.stringValue = @"Reading camera state…";
    _panValue.stringValue = @"Pan —";
    _tiltValue.stringValue = @"Tilt —";
    _zoomValue.stringValue = @"—";
    _previewZoomValue.stringValue = @"Zoom —";
    _trackingAvailable = NO;
    _trackingRequested = NO;
    _trackingActive = NO;
    _trackingSwitch.state = NSControlStateValueOff;
    _trackingStatus.stringValue = @"Reading…";
}

- (void)applyActionError:(LinkCamResult)result {
    switch (result) {
        case LinkCamResultTrackingDisableFailed:
            _messageLabel.stringValue = @"Could not turn off AI tracking";
            break;
        case LinkCamResultWriteFailed:
            _messageLabel.stringValue = @"Camera rejected the change";
            break;
        case LinkCamResultReadFailed:
            _messageLabel.stringValue = @"Could not read the camera state";
            break;
        default:
            _messageLabel.stringValue = @"Camera control unavailable";
            break;
    }
    [self finishOperation];
}

- (void)pollPosition:(NSTimer *)timer {
    (void)timer;
    if (!_popoverOpen || !_connected || _operationInFlight || _pollInFlight) return;
    _pollInFlight = YES;
    BOOL shouldAcquireSubject = _trackingRequested && !_trackingActive;

    dispatch_async(_deviceQueue, ^{
        int8_t trackingActive = 0;
        if (shouldAcquireSubject && self->_device) {
            (void)LinkCamEnsureTrackingSubject(self->_device, &trackingActive);
        }

        LinkCamState state = {0};
        LinkCamResult result = self->_device
            ? LinkCamReadState(self->_device, &state)
            : LinkCamResultDeviceNotFound;
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_pollInFlight = NO;
            if (result != LinkCamResultOK || !self->_popoverOpen || self->_operationInFlight) return;

            [self updateDisplayedState:state];
            if (self->_trackingRequested) {
                self->_messageLabel.stringValue = self->_trackingActive
                    ? @"Tracking subject · Manual controls turn it off"
                    : @"Looking for a subject in the camera preview…";
            } else {
                self->_messageLabel.stringValue = [NSString stringWithFormat:@"Ready · %ld° steps", (long)self->_nudgeDegrees];
            }
        });
    });
}

- (void)startStatePolling {
    [_stateTimer invalidate];
    [_stateTimer release];
    _stateTimer = [[NSTimer scheduledTimerWithTimeInterval:0.4
                                                   target:self
                                                 selector:@selector(pollPosition:)
                                                 userInfo:nil
                                                  repeats:YES] retain];
}

- (void)stopStatePolling {
    [_stateTimer invalidate];
    [_stateTimer release];
    _stateTimer = nil;
}

- (void)refreshDeviceReconnecting:(BOOL)reconnect {
    dispatch_async(_deviceQueue, ^{
        if (reconnect && self->_device) {
            LinkCamDeviceClose(self->_device);
            self->_device = NULL;
        }
        if (!self->_device) {
            LinkCamResult openResult = LinkCamDeviceOpen(&self->_device);
            if (openResult != LinkCamResultOK) {
                dispatch_async(dispatch_get_main_queue(), ^{ [self applyError:openResult]; });
                return;
            }
        }

        LinkCamState state = {0};
        LinkCamResult result = LinkCamReadState(self->_device, &state);
        if (result != LinkCamResultOK) {
            LinkCamDeviceClose(self->_device);
            self->_device = NULL;
            dispatch_async(dispatch_get_main_queue(), ^{ [self applyError:result]; });
            return;
        }
        dispatch_async(dispatch_get_main_queue(), ^{ [self applyState:state]; });
    });
}

- (void)refreshDevice {
    [self refreshDeviceReconnecting:NO];
}

- (void)refreshPressed:(id)sender {
    (void)sender;
    [self beginStateRefresh];
    [self refreshDeviceReconnecting:YES];
    [self refreshPreviewSources];
    [_previewView stopPreview];
    [_previewView startPreview];
}

- (void)morePressed:(NSButton *)sender {
    NSMenu *menu = [[[NSMenu alloc] initWithTitle:@""] autorelease];
    NSMenuItem *refresh = [[[NSMenuItem alloc] initWithTitle:@"Refresh Camera"
                                                     action:@selector(refreshPressed:)
                                              keyEquivalent:@"r"] autorelease];
    refresh.target = self;
    [menu addItem:refresh];
    [menu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *controller = [[[NSMenuItem alloc] initWithTitle:@"Open Insta360 Link Controller…"
                                                        action:@selector(openOfficialController:)
                                                 keyEquivalent:@""] autorelease];
    controller.target = self;
    [menu addItem:controller];

    NSMenuItem *settings = [[[NSMenuItem alloc] initWithTitle:@"Camera Privacy Settings…"
                                                      action:@selector(openSettings:)
                                               keyEquivalent:@","] autorelease];
    settings.target = self;
    [menu addItem:settings];
    [menu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *quit = [[[NSMenuItem alloc] initWithTitle:@"Quit LinkCam"
                                                  action:@selector(terminate:)
                                           keyEquivalent:@"q"] autorelease];
    quit.target = NSApp;
    [menu addItem:quit];
    [menu popUpMenuPositioningItem:nil
                        atLocation:NSMakePoint(0, NSHeight(sender.bounds) + 4)
                            inView:sender];
}

- (void)openOfficialController:(id)sender {
    (void)sender;
    NSURL *url = [NSURL fileURLWithPath:@"/Applications/Insta360 Link Controller.app"];
    if (![[NSWorkspace sharedWorkspace] openURL:url]) {
        _messageLabel.stringValue = @"Insta360 Link Controller is not installed";
    }
}

- (void)openSettings:(id)sender {
    (void)sender;
    NSURL *url = [NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_Camera"];
    if (![[NSWorkspace sharedWorkspace] openURL:url]) {
        [[NSWorkspace sharedWorkspace] openApplicationAtURL:
            [NSURL fileURLWithPath:@"/System/Applications/System Settings.app"]
                                              configuration:[NSWorkspaceOpenConfiguration configuration]
                                          completionHandler:nil];
    }
}

- (void)stepChanged:(NSPopUpButton *)sender {
    NSNumber *degrees = sender.selectedItem.representedObject;
    if (degrees) _nudgeDegrees = degrees.integerValue;
    _messageLabel.stringValue = [NSString stringWithFormat:@"Ready · %ld° steps", (long)_nudgeDegrees];
}

- (void)modeChanged:(NSSegmentedControl *)sender {
    static const int8_t modes[] = {0, 6, 4};
    NSInteger segment = sender.selectedSegment;
    if (segment < 0 || segment > 2) return;
    int8_t requestedMode = modes[segment];
    NSString *modeName = segment == 1 ? @"DeskView" : (segment == 2 ? @"Whiteboard" : @"Normal");
    [self beginOperationWithMessage:[NSString stringWithFormat:@"Switching to %@…", modeName]];

    dispatch_async(_deviceQueue, ^{
        if (!self->_device) {
            dispatch_async(dispatch_get_main_queue(), ^{ [self applyError:LinkCamResultDeviceNotFound]; });
            return;
        }
        LinkCamState state = {0};
        LinkCamResult result = LinkCamSetVideoMode(self->_device, requestedMode, &state);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (result == LinkCamResultOK) [self applyState:state];
            else [self applyActionError:result];
        });
    });
}

- (void)performTrackingChange:(int8_t)requested {
    dispatch_async(_deviceQueue, ^{
        if (!self->_device) {
            dispatch_async(dispatch_get_main_queue(), ^{ [self applyError:LinkCamResultDeviceNotFound]; });
            return;
        }

        LinkCamState state = {0};
        LinkCamResult result = LinkCamSetTracking(self->_device, requested, &state);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (result == LinkCamResultOK) [self applyState:state];
            else [self applyActionError:result];
        });
    });
}

- (void)trackingChanged:(NSSwitch *)sender {
    int8_t requested = sender.state == NSControlStateValueOn ? 1 : 0;
    [self beginOperationWithMessage:requested
        ? @"Starting subject tracking…"
        : @"Returning to manual control…"];
    _trackingStatus.stringValue = requested ? @"Turning on…" : @"Turning off…";
    [self performTrackingChange:requested];
}

- (void)performDirection:(NSInteger)direction {
    if (_operationInFlight || !_connected) return;
    [self beginOperationWithMessage:direction == DirectionCenter ? @"Recentering…" : @"Moving camera…"];

    dispatch_async(_deviceQueue, ^{
        if (!self->_device) {
            dispatch_async(dispatch_get_main_queue(), ^{ [self applyError:LinkCamResultDeviceNotFound]; });
            return;
        }

        LinkCamState current = {0};
        LinkCamResult result = LinkCamReadState(self->_device, &current);
        if (result == LinkCamResultOK) {
            const int32_t step = (int32_t)_nudgeDegrees * LINKCAM_ANGLE_STEP_UNITS;
            switch (direction) {
                case DirectionUp: current.panUnits += step; break;
                case DirectionDown: current.panUnits -= step; break;
                case DirectionLeft: current.tiltUnits -= step; break;
                case DirectionRight: current.tiltUnits += step; break;
                case DirectionCenter: current.panUnits = 0; current.tiltUnits = 0; break;
            }
            result = LinkCamSetPanTilt(self->_device, current.panUnits, current.tiltUnits, &current);
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            if (result == LinkCamResultOK) [self applyState:current];
            else [self applyActionError:result];
        });
    });
}

- (void)directionPressed:(NSButton *)sender {
    [self performDirection:sender.tag];
}

- (void)zoomChanged:(NSSlider *)sender {
    uint16_t zoomUnits = (uint16_t)lround(sender.doubleValue * 100.0);
    [self beginOperationWithMessage:@"Adjusting zoom…"];

    dispatch_async(_deviceQueue, ^{
        if (!self->_device) {
            dispatch_async(dispatch_get_main_queue(), ^{ [self applyError:LinkCamResultDeviceNotFound]; });
            return;
        }
        LinkCamState state = {0};
        LinkCamResult result = LinkCamSetZoom(self->_device, zoomUnits, &state);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (result == LinkCamResultOK) [self applyState:state];
            else [self applyActionError:result];
        });
    });
}

- (void)popoverWillOpen {
    _popoverOpen = YES;
    if (!_keyMonitor) {
        __block LinkCamPopoverViewController *controller = self;
        _keyMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown
                                                            handler:^NSEvent *(NSEvent *event) {
            NSInteger direction = 0;
            switch (event.keyCode) {
                case 126: direction = DirectionUp; break;
                case 125: direction = DirectionDown; break;
                case 123: direction = DirectionLeft; break;
                case 124: direction = DirectionRight; break;
                default: return event;
            }
            [controller performDirection:direction];
            return nil;
        }];
    }
    [self beginStateRefresh];
    [self refreshPreviewSources];
    if (!getenv("LINKCAM_DISABLE_PREVIEW")) [_previewView startPreview];
    [self refreshDeviceReconnecting:YES];
    [self startStatePolling];
}

- (void)popoverDidClose {
    _popoverOpen = NO;
    if (_keyMonitor) {
        [NSEvent removeMonitor:_keyMonitor];
        _keyMonitor = nil;
    }
    [self stopStatePolling];
    [_previewView stopPreview];
}

@end
