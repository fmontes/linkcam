#import "AppDelegate.h"
#import "LinkCamPopoverViewController.h"

#include <stdlib.h>

@interface AppDelegate ()
{
    NSStatusItem *_statusItem;
    NSPopover *_popover;
    LinkCamPopoverViewController *_controller;
}
@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];

    _statusItem = [[[NSStatusBar systemStatusBar] statusItemWithLength:NSSquareStatusItemLength] retain];
    NSStatusBarButton *button = _statusItem.button;
    button.image = [NSImage imageWithSystemSymbolName:@"video.fill" accessibilityDescription:@"LinkCam"];
    button.image.template = YES;
    button.toolTip = @"LinkCam";
    button.target = self;
    button.action = @selector(togglePopover:);

    _controller = [[LinkCamPopoverViewController alloc] init];
    _popover = [[NSPopover alloc] init];
    _popover.behavior = NSPopoverBehaviorTransient;
    _popover.animates = YES;
    _popover.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    _popover.contentSize = NSMakeSize(430, 650);
    _popover.contentViewController = _controller;
    _popover.delegate = self;

    // UI-test hook: production launches remain quiet in the menu bar, while
    // local verification can open the popover without synthesizing a click.
    if (getenv("LINKCAM_SHOW_ON_LAUNCH")) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self togglePopover:nil]; });
    }

    const char *screenshotPath = getenv("LINKCAM_SCREENSHOT_PATH");
    if (screenshotPath) {
        NSString *path = [[NSString alloc] initWithUTF8String:screenshotPath];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            NSView *view = self->_controller.view;
            [view layoutSubtreeIfNeeded];
            NSBitmapImageRep *bitmap = [view bitmapImageRepForCachingDisplayInRect:view.bounds];
            [view cacheDisplayInRect:view.bounds toBitmapImageRep:bitmap];
            NSData *png = [bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
            [png writeToFile:path atomically:YES];
            [path release];
            [NSApp terminate:nil];
        });
    }
}

- (void)dealloc {
    [[NSStatusBar systemStatusBar] removeStatusItem:_statusItem];
    [_statusItem release];
    [_popover release];
    [_controller release];
    [super dealloc];
}

- (void)togglePopover:(id)sender {
    (void)sender;
    if (_popover.shown) {
        [_popover performClose:nil];
        return;
    }

    NSStatusBarButton *button = _statusItem.button;
    if (button) {
        [_popover showRelativeToRect:button.bounds ofView:button preferredEdge:NSRectEdgeMinY];
        [_controller popoverWillOpen];
    }
}

- (void)popoverDidClose:(NSNotification *)notification {
    (void)notification;
    [_controller popoverDidClose];
}

@end
