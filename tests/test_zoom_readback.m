#import <CoreMediaIO/CoreMediaIO.h>
#import <Foundation/Foundation.h>

#include <assert.h>
#include <string.h>

static BOOL cmioAvailable = YES;
static NSUInteger cmioReads = 0;

static Boolean testHasProperty(CMIOObjectID object, const CMIOObjectPropertyAddress *address) {
    return cmioAvailable && object == 7 &&
        (address->mSelector == kCMIOFeatureControlPropertyNativeValue ||
         address->mSelector == kCMIOFeatureControlPropertyNativeRange);
}

static OSStatus testGetPropertyData(CMIOObjectID object,
                                    const CMIOObjectPropertyAddress *address,
                                    UInt32 qualifierSize, const void *qualifier,
                                    UInt32 size, UInt32 *used, void *output) {
    (void)qualifierSize;
    (void)qualifier;
    assert(testHasProperty(object, address));
    cmioReads++;
    if (address->mSelector == kCMIOFeatureControlPropertyNativeValue) {
        Float32 cachedZoom = 100.0f;
        assert(size == sizeof(cachedZoom));
        memcpy(output, &cachedZoom, size);
    } else {
        AudioValueRange range = {100, 400};
        assert(size == sizeof(range));
        memcpy(output, &range, size);
    }
    *used = size;
    return noErr;
}

// Exercise the real core with simulated USB and CMIO reads, without a camera.
#define CMIOObjectHasProperty testHasProperty
#define CMIOObjectGetPropertyData testGetPropertyData
#import "../src/core/LinkCamCore.m"
#undef CMIOObjectHasProperty
#undef CMIOObjectGetPropertyData

@interface TestZoomControl : UVCControl
@property uint16_t units;
@property BOOL readFails;
@end

@implementation TestZoomControl
- (instancetype)init {
    if ((self = [super init])) {
        _currentValue = [[UVCValue uvcValueWithType:[UVCType uvcTypeWithCString:"{U2}"]] retain];
    }
    return self;
}
- (UVCValue *)currentValue {
    if (self.readFails) return nil;
    *(uint16_t *)[_currentValue valuePtr] = self.units;
    return _currentValue;
}
@end

@interface TestZoomController : UVCController
@property (retain) TestZoomControl *zoom;
@end

@implementation TestZoomController
- (UVCControl *)controlWithName:(NSString *)name {
    return [name isEqualToString:UVCTerminalControlZoomAbsolute] ? self.zoom : nil;
}
- (UInt8)extensionUnitId { return 9; }
- (BOOL)getData:(void *)value ofType:(int)type withLength:(int)length
    fromSelector:(int)selector atUnitId:(int)unitID {
    if (unitID != 9 || selector != LinkCamPanTiltAbsoluteSelector || type != UVCGetCurrent || length != 8) return NO;
    memset(value, 0, length);
    return YES;
}
- (void)dealloc {
    [_zoom release];
    [super dealloc];
}
@end

int main(void) {
    @autoreleasepool {
        TestZoomController *controller = [[[TestZoomController alloc] init] autorelease];
        controller.zoom = [[[TestZoomControl alloc] init] autorelease];
        LinkCamDevice device = {0};
        device.controller = controller;
        device.lock = [[[NSLock alloc] init] autorelease];
        device.zoomControl = 7;
        uint16_t units = 0;

        // Opening the UI reads full state: live 1.75x must beat cached 1x.
        controller.zoom.units = 175;
        LinkCamState state = {0};
        assert(LinkCamReadState(&device, &state) == LinkCamResultOK);
        assert(state.zoomUnits == 175);
        assert(cmioReads == 0);

        // Subsequent polls must pick up external zoom changes, including 1x.
        for (uint16_t zoom = 100; zoom <= 400; zoom += 25) {
            controller.zoom.units = zoom;
            assert(LinkCamReadZoom(&device, &units) == LinkCamResultOK);
            assert(units == zoom);
        }

        controller.zoom.readFails = YES;
        assert(LinkCamReadZoom(&device, &units) == LinkCamResultOK && units == 100);
        controller.zoom.readFails = NO;
        controller.zoom.units = 0;
        assert(LinkCamReadZoom(&device, &units) == LinkCamResultOK && units == 100);
        controller.zoom.units = 401;
        assert(LinkCamReadZoom(&device, &units) == LinkCamResultOK && units == 100);
        controller.zoom = nil;
        assert(LinkCamReadZoom(&device, &units) == LinkCamResultOK && units == 100);

        cmioAvailable = NO;
        assert(LinkCamReadZoom(&device, &units) != LinkCamResultOK);
        device.controller = nil;
        cmioAvailable = YES;
        assert(LinkCamReadZoom(&device, &units) == LinkCamResultOK && units == 100);
        device.zoomControl = 0;
        assert(LinkCamReadZoom(&device, &units) == LinkCamResultControlUnavailable);
    }
    puts("Zoom readback tests passed");
    return 0;
}
