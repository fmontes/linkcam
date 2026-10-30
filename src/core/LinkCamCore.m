#import "LinkCamCore.h"
#import "LinkCamMath.h"
#import "UVCController.h"

#import <CoreMediaIO/CoreMediaIO.h>
#import <Foundation/Foundation.h>

#include <math.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

enum {
    LinkCamVendorID = 0x2e1a,
    LinkCamProductID = 0x4c04,
    LinkCamPro2ProductID = 0x4c06,
    LinkCamVideoModeSelector = 0x02,
    LinkCamVideoModePayloadLength = 56,
    LinkCamVideoModeNormal = 0,
    LinkCamVideoModeSubjectTracking = 1,
    LinkCamVideoModeWhiteboard = 4,
    LinkCamVideoModeDeskView = 6,
    LinkCamTrackingTargetSelector = 0x15,
    LinkCamTrackingCandidatesSelector = 0x18,
    LinkCamPanTiltAbsoluteSelector = 0x1a,
    LinkCamTrackingSelector = 0x1b,
    LinkCamTrackingBit = 8,
    UVCGetCurrent = 0x81,
    UVCGetLength = 0x85
};

@interface UVCController (LinkCamRawExtensionUnit)
- (BOOL)setData:(void *)value withLength:(int)length forSelector:(int)selector atUnitId:(int)unitId;
- (BOOL)getData:(void *)value ofType:(int)type withLength:(int)length fromSelector:(int)selector atUnitId:(int)unitId;
@end

struct LinkCamDevice {
    UVCController *controller;
    NSLock *lock;
    CMIODeviceID cmioDevice;
    CMIOControlID panTiltControl;
    CMIOControlID zoomControl;
    BOOL manualModePrepared;
    BOOL trackingModeActive;
    BOOL trackingAcquisitionPrepared;
};

static CMIOObjectPropertyAddress propertyAddress(CMIOObjectPropertySelector selector) {
    return (CMIOObjectPropertyAddress){
        selector,
        kCMIOObjectPropertyScopeGlobal,
        kCMIOObjectPropertyElementMain
    };
}

static BOOL readCMIOProperty(CMIOObjectID object,
                             CMIOObjectPropertySelector selector,
                             void *buffer,
                             UInt32 bufferSize,
                             UInt32 *bytesRead) {
    CMIOObjectPropertyAddress address = propertyAddress(selector);
    if (!CMIOObjectHasProperty(object, &address)) return NO;
    UInt32 used = 0;
    OSStatus status = CMIOObjectGetPropertyData(object, &address, 0, NULL, bufferSize, &used, buffer);
    if (bytesRead) *bytesRead = used;
    return status == noErr;
}

static BOOL writeCMIOProperty(CMIOObjectID object,
                              CMIOObjectPropertySelector selector,
                              const void *buffer,
                              UInt32 bufferSize) {
    CMIOObjectPropertyAddress address = propertyAddress(selector);
    if (!CMIOObjectHasProperty(object, &address)) return NO;
    Boolean settable = false;
    if (CMIOObjectIsPropertySettable(object, &address, &settable) != noErr || !settable) return NO;
    return CMIOObjectSetPropertyData(object, &address, 0, NULL, bufferSize, buffer) == noErr;
}

static CFStringRef copyCMIOString(CMIOObjectID object, CMIOObjectPropertySelector selector) {
    CFStringRef value = NULL;
    UInt32 used = 0;
    if (!readCMIOProperty(object, selector, &value, sizeof(value), &used) || used != sizeof(value)) {
        if (value) CFRelease(value);
        return NULL;
    }
    return value;
}

static void findControlsOwnedBy(CMIOObjectID owner,
                                CMIOControlID *panTiltControl,
                                CMIOControlID *zoomControl,
                                NSUInteger depth) {
    if (depth > 3 || (*panTiltControl && *zoomControl)) return;

    CMIOObjectPropertyAddress address = propertyAddress(kCMIOObjectPropertyOwnedObjects);
    UInt32 size = 0;
    if (CMIOObjectGetPropertyDataSize(owner, &address, 0, NULL, &size) != noErr || size == 0) return;

    CMIOObjectID *objects = calloc(1, size);
    if (!objects) return;
    UInt32 used = 0;
    if (CMIOObjectGetPropertyData(owner, &address, 0, NULL, size, &used, objects) != noErr) {
        free(objects);
        return;
    }

    UInt32 count = used / (UInt32)sizeof(CMIOObjectID);
    for (UInt32 index = 0; index < count; index++) {
        CMIOClassID classID = 0;
        UInt32 classBytes = 0;
        if (readCMIOProperty(objects[index], kCMIOObjectPropertyClass,
                             &classID, sizeof(classID), &classBytes) &&
            classBytes == sizeof(classID)) {
            if (classID == kCMIOPanTiltAbsoluteControlClassID && !*panTiltControl) {
                *panTiltControl = objects[index];
            } else if (classID == kCMIOZoomControlClassID && !*zoomControl) {
                *zoomControl = objects[index];
            }
        }
        findControlsOwnedBy(objects[index], panTiltControl, zoomControl, depth + 1);
    }
    free(objects);
}

static BOOL findCMIOLinkCamera(CMIODeviceID *deviceID,
                               CMIOControlID *panTiltControl,
                               CMIOControlID *zoomControl) {
    CMIOObjectPropertyAddress address = propertyAddress(kCMIOHardwarePropertyDevices);
    UInt32 size = 0;
    if (CMIOObjectGetPropertyDataSize(kCMIOObjectSystemObject, &address, 0, NULL, &size) != noErr || size == 0) {
        return NO;
    }

    CMIODeviceID *devices = calloc(1, size);
    if (!devices) return NO;
    UInt32 used = 0;
    if (CMIOObjectGetPropertyData(kCMIOObjectSystemObject, &address, 0, NULL, size, &used, devices) != noErr) {
        free(devices);
        return NO;
    }

    BOOL found = NO;
    UInt32 count = used / (UInt32)sizeof(CMIODeviceID);
    for (UInt32 index = 0; index < count; index++) {
        CFStringRef nameRef = copyCMIOString(devices[index], kCMIOObjectPropertyName);
        NSString *name = (NSString *)nameRef;
        BOOL isLink = name &&
            [name rangeOfString:@"Insta360 Link 2" options:NSCaseInsensitiveSearch].location != NSNotFound;
        if (isLink) {
            CMIOControlID panTilt = kCMIOObjectUnknown;
            CMIOControlID zoom = kCMIOObjectUnknown;
            findControlsOwnedBy(devices[index], &panTilt, &zoom, 0);
            if (panTilt && zoom) {
                *deviceID = devices[index];
                *panTiltControl = panTilt;
                *zoomControl = zoom;
                found = YES;
            }
        }
        if (nameRef) CFRelease(nameRef);
        if (found) break;
    }
    free(devices);
    return found;
}

static LinkCamResult readUVCpanTilt(LinkCamDevice *device, int32_t *panUnits, int32_t *tiltUnits) {
    UVCControl *control = [device->controller controlWithName:UVCTerminalControlPanTiltAbsolute];
    if (!control) return LinkCamResultControlUnavailable;

    UVCValue *value = [control currentValue];
    if (!value) return LinkCamResultReadFailed;

    int32_t *pan = (int32_t *)[value pointerToFieldWithName:@"pan"];
    int32_t *tilt = (int32_t *)[value pointerToFieldWithName:@"tilt"];
    if (!pan || !tilt) return LinkCamResultReadFailed;

    *panUnits = *pan;
    *tiltUnits = *tilt;
    return LinkCamResultOK;
}

static LinkCamResult readCMIOPanTilt(LinkCamDevice *device, int32_t *panUnits, int32_t *tiltUnits) {
    int32_t values[2] = {0, 0};
    UInt32 used = 0;
    if (!readCMIOProperty(device->panTiltControl, kCMIOFeatureControlPropertyNativeData,
                          values, sizeof(values), &used) || used != sizeof(values)) {
        return LinkCamResultReadFailed;
    }
    *panUnits = values[0];
    *tiltUnits = values[1];
    return LinkCamResultOK;
}

static int32_t readInt32LittleEndian(const uint8_t *source) {
    uint32_t bits = (uint32_t)source[0] |
                    ((uint32_t)source[1] << 8) |
                    ((uint32_t)source[2] << 16) |
                    ((uint32_t)source[3] << 24);
    return (int32_t)bits;
}

/*
 * Link 2's standard macOS PTZ property is the host's last requested value.
 * Firmware-driven motion such as subject tracking does not update it. The
 * camera's selector 0x1a is its live gimbal position: two little-endian int32
 * values in the same 1/3600-degree units as UVC pan/tilt absolute controls.
 */
static LinkCamResult readExtensionPanTilt(LinkCamDevice *device,
                                          int32_t *panUnits,
                                          int32_t *tiltUnits) {
    if (!device->controller) return LinkCamResultControlUnavailable;

    int unitID = [device->controller extensionUnitId];
    if (unitID == 0) return LinkCamResultControlUnavailable;

    uint8_t value[8] = {0};
    if (![device->controller getData:value
                              ofType:UVCGetCurrent
                          withLength:(int)sizeof(value)
                        fromSelector:LinkCamPanTiltAbsoluteSelector
                             atUnitId:unitID]) {
        return LinkCamResultReadFailed;
    }

    *panUnits = readInt32LittleEndian(value);
    *tiltUnits = readInt32LittleEndian(value + sizeof(int32_t));
    return LinkCamResultOK;
}

static LinkCamResult readPanTiltUnlocked(LinkCamDevice *device, int32_t *panUnits, int32_t *tiltUnits) {
    if (device->controller) {
        LinkCamResult result = readExtensionPanTilt(device, panUnits, tiltUnits);
        if (result == LinkCamResultOK) return result;
    }
    if (device->panTiltControl) return readCMIOPanTilt(device, panUnits, tiltUnits);
    if (device->controller) return readUVCpanTilt(device, panUnits, tiltUnits);
    return LinkCamResultControlUnavailable;
}

static BOOL readCMIOFloat(CMIOObjectID control, CMIOObjectPropertySelector selector, Float32 *value) {
    UInt32 used = 0;
    return readCMIOProperty(control, selector, value, sizeof(*value), &used) && used == sizeof(*value);
}

static BOOL readCMIORange(CMIOObjectID control, CMIOObjectPropertySelector selector, AudioValueRange *range) {
    UInt32 used = 0;
    return readCMIOProperty(control, selector, range, sizeof(*range), &used) && used == sizeof(*range);
}

static double zoomUnitsFromNativeValue(Float32 value, const AudioValueRange *range) {
    if (range && range->mMinimum >= 0.0 && range->mMaximum <= 1.01 && range->mMaximum > range->mMinimum) {
        double fraction = (value - range->mMinimum) / (range->mMaximum - range->mMinimum);
        return LINKCAM_ZOOM_MIN_UNITS + fraction * (LINKCAM_ZOOM_MAX_UNITS - LINKCAM_ZOOM_MIN_UNITS);
    }
    if (range && range->mMaximum <= 10.0) return value * 100.0;
    return value;
}

static Float32 nativeValueFromZoomUnits(uint16_t units, const AudioValueRange *range) {
    if (range && range->mMinimum >= 0.0 && range->mMaximum <= 1.01 && range->mMaximum > range->mMinimum) {
        double fraction = (double)(units - LINKCAM_ZOOM_MIN_UNITS) /
                          (LINKCAM_ZOOM_MAX_UNITS - LINKCAM_ZOOM_MIN_UNITS);
        return (Float32)(range->mMinimum + fraction * (range->mMaximum - range->mMinimum));
    }
    if (range && range->mMaximum <= 10.0) return (Float32)LinkCamZoomMultiplierFromUnits(units);
    return (Float32)units;
}

static LinkCamResult readCMIOZoom(LinkCamDevice *device, uint16_t *zoomUnits) {
    Float32 value = 0;
    if (readCMIOFloat(device->zoomControl, kCMIOFeatureControlPropertyNativeValue, &value)) {
        AudioValueRange range = {0};
        AudioValueRange *rangePtr = readCMIORange(device->zoomControl,
                                                  kCMIOFeatureControlPropertyNativeRange,
                                                  &range) ? &range : NULL;
        *zoomUnits = LinkCamClampZoomUnits((int64_t)llround(zoomUnitsFromNativeValue(value, rangePtr)));
        return LinkCamResultOK;
    }
    if (readCMIOFloat(device->zoomControl, kCMIOFeatureControlPropertyAbsoluteValue, &value)) {
        *zoomUnits = LinkCamClampZoomUnits((int64_t)llround(value * 100.0));
        return LinkCamResultOK;
    }
    return LinkCamResultReadFailed;
}

static LinkCamResult readUVCZoom(LinkCamDevice *device, uint16_t *zoomUnits) {
    UVCControl *control = [device->controller controlWithName:UVCTerminalControlZoomAbsolute];
    if (!control) return LinkCamResultControlUnavailable;

    UVCValue *value = [control currentValue];
    if (!value || [value byteSize] < sizeof(uint16_t)) return LinkCamResultReadFailed;
    uint16_t units = *(uint16_t *)[value valuePtr];
    if (units < LINKCAM_ZOOM_MIN_UNITS || units > LINKCAM_ZOOM_MAX_UNITS) return LinkCamResultReadFailed;
    *zoomUnits = units;
    return LinkCamResultOK;
}

static LinkCamResult readZoomUnlocked(LinkCamDevice *device, uint16_t *zoomUnits) {
    // Prefer the camera's GET_CUR so a cached host value cannot hide external zoom changes.
    LinkCamResult result = LinkCamResultControlUnavailable;
    if (device->controller) {
        result = readUVCZoom(device, zoomUnits);
        if (result == LinkCamResultOK) return result;
    }
    if (device->zoomControl) return readCMIOZoom(device, zoomUnits);
    return result;
}

static LinkCamResult readTrackingFeatureUnlocked(LinkCamDevice *device, int8_t *tracking) {
    if (!device->controller) return LinkCamResultControlUnavailable;

    int unitID = [device->controller extensionUnitId];
    if (unitID == 0) return LinkCamResultControlUnavailable;

    uint16_t length = 0;
    if (![device->controller getData:&length
                              ofType:UVCGetLength
                          withLength:(int)sizeof(length)
                        fromSelector:LinkCamTrackingSelector
                             atUnitId:unitID] || length < sizeof(uint16_t) || length > 256) {
        return LinkCamResultReadFailed;
    }

    uint8_t value[256] = {0};
    if (![device->controller getData:value
                              ofType:UVCGetCurrent
                          withLength:length
                        fromSelector:LinkCamTrackingSelector
                             atUnitId:unitID]) {
        return LinkCamResultReadFailed;
    }

    uint16_t featureMask = (uint16_t)value[0] | ((uint16_t)value[1] << 8);
    *tracking = (featureMask & (1u << LinkCamTrackingBit)) ? 1 : 0;
    return LinkCamResultOK;
}

static LinkCamResult readVideoModeUnlocked(LinkCamDevice *device, uint8_t *mode) {
    if (!device->controller) return LinkCamResultControlUnavailable;

    int unitID = [device->controller extensionUnitId];
    if (unitID == 0) return LinkCamResultControlUnavailable;

    uint16_t length = 0;
    if (![device->controller getData:&length
                              ofType:UVCGetLength
                          withLength:(int)sizeof(length)
                        fromSelector:LinkCamVideoModeSelector
                             atUnitId:unitID] || length == 0 || length > 256) {
        return LinkCamResultReadFailed;
    }

    uint8_t value[256] = {0};
    if (![device->controller getData:value
                              ofType:UVCGetCurrent
                          withLength:length
                        fromSelector:LinkCamVideoModeSelector
                             atUnitId:unitID]) {
        return LinkCamResultReadFailed;
    }

    *mode = value[0];
    return LinkCamResultOK;
}

/*
 * The feature bit records a tracking request, while video mode 1 is the
 * camera's authoritative indication that its gimbal is actively tracking.
 * Keep both: the request keeps the switch on while subject acquisition is in
 * progress, and the mode catches tracking started asynchronously or elsewhere.
 */
static LinkCamResult readTrackingStateUnlocked(LinkCamDevice *device,
                                               int8_t *tracking,
                                               int8_t *active,
                                               int8_t *currentVideoMode) {
    int8_t featureEnabled = 0;
    uint8_t videoMode = LinkCamVideoModeNormal;
    LinkCamResult featureResult = readTrackingFeatureUnlocked(device, &featureEnabled);
    LinkCamResult modeResult = readVideoModeUnlocked(device, &videoMode);

    if (featureResult != LinkCamResultOK && modeResult != LinkCamResultOK) {
        *tracking = -1;
        *active = -1;
        if (currentVideoMode) *currentVideoMode = -1;
        return featureResult != LinkCamResultControlUnavailable ? featureResult : modeResult;
    }

    if (currentVideoMode) *currentVideoMode = modeResult == LinkCamResultOK ? (int8_t)videoMode : -1;
    *active = modeResult == LinkCamResultOK && videoMode == LinkCamVideoModeSubjectTracking ? 1 : 0;
    *tracking = *active || (featureResult == LinkCamResultOK && featureEnabled) ? 1 : 0;
    device->trackingModeActive = *active == 1;
    return LinkCamResultOK;
}

static LinkCamResult writeTrackingUnlocked(LinkCamDevice *device, int8_t tracking) {
    if (!device->controller) return LinkCamResultControlUnavailable;

    int unitID = [device->controller extensionUnitId];
    if (unitID == 0) return LinkCamResultControlUnavailable;

    uint16_t length = 0;
    if (![device->controller getData:&length
                              ofType:UVCGetLength
                          withLength:(int)sizeof(length)
                        fromSelector:LinkCamTrackingSelector
                             atUnitId:unitID] || length < sizeof(uint16_t) || length > 256) {
        return LinkCamResultReadFailed;
    }

    uint8_t value[256] = {0};
    if (![device->controller getData:value
                              ofType:UVCGetCurrent
                          withLength:length
                        fromSelector:LinkCamTrackingSelector
                             atUnitId:unitID]) {
        return LinkCamResultReadFailed;
    }

    uint16_t featureMask = (uint16_t)value[0] | ((uint16_t)value[1] << 8);
    if (tracking) featureMask |= (1u << LinkCamTrackingBit);
    else featureMask &= (uint16_t)~(1u << LinkCamTrackingBit);
    value[0] = (uint8_t)(featureMask & 0xff);
    value[1] = (uint8_t)(featureMask >> 8);

    return [device->controller setData:value
                            withLength:length
                           forSelector:LinkCamTrackingSelector
                              atUnitId:unitID]
        ? LinkCamResultOK : LinkCamResultWriteFailed;
}

/*
 * Link 2 video modes use a 56-byte selector-2 payload. These non-zero defaults
 * mirror the payload built by the official controller for this camera model;
 * sending a zero-filled normal-mode payload can reset the gimbal position.
 */
static void writeInt32LittleEndian(uint8_t *destination, int32_t value) {
    uint32_t bits = (uint32_t)value;
    destination[0] = (uint8_t)(bits & 0xff);
    destination[1] = (uint8_t)((bits >> 8) & 0xff);
    destination[2] = (uint8_t)((bits >> 16) & 0xff);
    destination[3] = (uint8_t)((bits >> 24) & 0xff);
}

static LinkCamResult writeExtensionPanTilt(LinkCamDevice *device,
                                           int32_t panUnits,
                                           int32_t tiltUnits) {
    if (!device->controller) return LinkCamResultControlUnavailable;

    int unitID = [device->controller extensionUnitId];
    if (unitID == 0) return LinkCamResultControlUnavailable;

    uint8_t payload[8] = {0};
    writeInt32LittleEndian(payload, panUnits);
    writeInt32LittleEndian(payload + sizeof(int32_t), tiltUnits);
    return [device->controller setData:payload
                            withLength:(int)sizeof(payload)
                           forSelector:LinkCamPanTiltAbsoluteSelector
                              atUnitId:unitID]
        ? LinkCamResultOK : LinkCamResultWriteFailed;
}

static void buildVideoModePayload(uint8_t payload[LinkCamVideoModePayloadLength], uint8_t mode) {
    for (size_t index = 0; index < LinkCamVideoModePayloadLength; index++) payload[index] = 0;
    payload[0] = mode;
    writeInt32LittleEndian(payload + 0x26, 3610);
    writeInt32LittleEndian(payload + 0x2a, 3610);
    writeInt32LittleEndian(payload + 0x2e, 3610);
    if (mode != LinkCamVideoModeWhiteboard) {
        writeInt32LittleEndian(payload + 0x32, -29491200);
    }
}

static LinkCamResult setVideoModeUnlocked(LinkCamDevice *device, uint8_t mode) {
    if (!device->controller) return LinkCamResultControlUnavailable;

    int unitID = [device->controller extensionUnitId];
    if (unitID == 0) return LinkCamResultControlUnavailable;

    uint8_t payload[LinkCamVideoModePayloadLength] = {0};
    buildVideoModePayload(payload, mode);
    return [device->controller setData:payload
                            withLength:(int)sizeof(payload)
                           forSelector:LinkCamVideoModeSelector
                              atUnitId:unitID]
        ? LinkCamResultOK : LinkCamResultWriteFailed;
}

static uint16_t readUInt16LittleEndian(const uint8_t *source) {
    return (uint16_t)source[0] | ((uint16_t)source[1] << 8);
}

static void writeFloatLittleEndian(uint8_t *destination, float value) {
    uint32_t bits = 0;
    memcpy(&bits, &value, sizeof(bits));
    destination[0] = (uint8_t)(bits & 0xff);
    destination[1] = (uint8_t)((bits >> 8) & 0xff);
    destination[2] = (uint8_t)((bits >> 16) & 0xff);
    destination[3] = (uint8_t)((bits >> 24) & 0xff);
}

/*
 * Link 2 exposes firmware-detected subject boxes on selector 0x18 of its
 * second extension unit. Each entry is four uint16 values normalized to
 * 10,000. The official controller selects one of these boxes before entering
 * video mode 1; entering the mode without a target leaves tracking idle.
 */
static LinkCamResult readBestTrackingCandidateUnlocked(LinkCamDevice *device,
                                                        float output[4],
                                                        BOOL *found) {
    *found = NO;
    if (!device->controller) return LinkCamResultControlUnavailable;

    int primaryUnitID = [device->controller extensionUnitId];
    if (primaryUnitID == 0) return LinkCamResultControlUnavailable;
    int candidatesUnitID = primaryUnitID + 1;

    uint16_t length = 0;
    if (![device->controller getData:&length
                              ofType:UVCGetLength
                          withLength:(int)sizeof(length)
                        fromSelector:LinkCamTrackingCandidatesSelector
                             atUnitId:candidatesUnitID] || length == 0 || length > 256) {
        return LinkCamResultReadFailed;
    }

    uint8_t value[256] = {0};
    if (![device->controller getData:value
                              ofType:UVCGetCurrent
                          withLength:length
                        fromSelector:LinkCamTrackingCandidatesSelector
                             atUnitId:candidatesUnitID]) {
        return LinkCamResultReadFailed;
    }

    NSUInteger count = MIN((NSUInteger)value[0], (NSUInteger)6);
    double bestScore = HUGE_VAL;
    for (NSUInteger index = 0; index < count; index++) {
        NSUInteger offset = 1 + index * 8;
        if (offset + 8 > length) break;

        float x = readUInt16LittleEndian(value + offset) / 10000.0f;
        float y = readUInt16LittleEndian(value + offset + 2) / 10000.0f;
        float width = readUInt16LittleEndian(value + offset + 4) / 10000.0f;
        float height = readUInt16LittleEndian(value + offset + 6) / 10000.0f;
        if (width <= 0.0f || height <= 0.0f || width > 1.0f || height > 1.0f) continue;

        double centerX = x + width * 0.5;
        double centerY = y + height * 0.5;
        double dx = centerX - 0.5;
        double dy = centerY - 0.5;
        double score = dx * dx + dy * dy - (width * height * 0.05);
        if (score < bestScore) {
            bestScore = score;
            output[0] = x;
            output[1] = y;
            output[2] = width;
            output[3] = height;
            *found = YES;
        }
    }
    return LinkCamResultOK;
}

static LinkCamResult acquireTrackingSubjectUnlocked(LinkCamDevice *device, BOOL *acquired) {
    *acquired = device->trackingModeActive;
    if (*acquired) return LinkCamResultOK;

    float target[4] = {0};
    BOOL found = NO;
    LinkCamResult result = readBestTrackingCandidateUnlocked(device, target, &found);
    if (result != LinkCamResultOK || !found) return result;

    int unitID = [device->controller extensionUnitId];
    uint8_t payload[16] = {0};
    for (NSUInteger index = 0; index < 4; index++) {
        writeFloatLittleEndian(payload + index * 4, target[index]);
    }
    if (![device->controller setData:payload
                          withLength:(int)sizeof(payload)
                         forSelector:LinkCamTrackingTargetSelector
                            atUnitId:unitID]) {
        return LinkCamResultWriteFailed;
    }

    /* The official controller waits roughly 500 ms after selecting a target. */
    usleep(550000);
    result = setVideoModeUnlocked(device, LinkCamVideoModeSubjectTracking);
    if (result == LinkCamResultOK) {
        device->trackingModeActive = YES;
        *acquired = YES;
    }
    return result;
}

static LinkCamResult disableTrackingForManualControlUnlocked(LinkCamDevice *device) {
    int8_t tracking = -1;
    int8_t trackingActive = -1;
    LinkCamResult result = readTrackingStateUnlocked(device, &tracking, &trackingActive, NULL);

    /* Keep standard UVC movement usable on systems that do not expose the XU. */
    if (result == LinkCamResultControlUnavailable) return LinkCamResultOK;
    if (result != LinkCamResultOK) return LinkCamResultTrackingDisableFailed;

    /*
     * The mode change completes asynchronously. Sending it before every nudge
     * can race the PTZ write and restore the mode payload's centered position.
     * Prepare manual mode once per connection (and again after tracking is
     * enabled), wait for that transition to settle, then leave subsequent PTZ
     * updates alone.
     */
    if (!tracking && device->manualModePrepared) return LinkCamResultOK;
    if (tracking && writeTrackingUnlocked(device, 0) != LinkCamResultOK) {
        return LinkCamResultTrackingDisableFailed;
    }
    if (setVideoModeUnlocked(device, LinkCamVideoModeNormal) != LinkCamResultOK) {
        return LinkCamResultTrackingDisableFailed;
    }

    usleep(350000);
    device->manualModePrepared = YES;
    device->trackingModeActive = NO;
    device->trackingAcquisitionPrepared = NO;
    return LinkCamResultOK;
}

static LinkCamResult readStateUnlocked(LinkCamDevice *device, LinkCamState *output) {
    output->tracking = -1;
    output->trackingActive = -1;
    output->videoMode = -1;

    LinkCamResult result = readPanTiltUnlocked(device, &output->panUnits, &output->tiltUnits);
    if (result != LinkCamResultOK) return result;

    result = readZoomUnlocked(device, &output->zoomUnits);
    if (result != LinkCamResultOK) return result;

    (void)readTrackingStateUnlocked(device, &output->tracking, &output->trackingActive, &output->videoMode);
    return LinkCamResultOK;
}

LinkCamResult LinkCamDeviceOpen(LinkCamDevice **output) {
    if (!output) return LinkCamResultInvalidArgument;
    *output = NULL;

    @autoreleasepool {
        LinkCamDevice *device = calloc(1, sizeof(LinkCamDevice));
        if (!device) return LinkCamResultReadFailed;
        device->lock = [[NSLock alloc] init];

        (void)findCMIOLinkCamera(&device->cmioDevice, &device->panTiltControl, &device->zoomControl);

        for (UVCController *candidate in [UVCController uvcControllers]) {
            if ([candidate vendorId] == LinkCamVendorID &&
                ([candidate productId] == LinkCamProductID || [candidate productId] == LinkCamPro2ProductID)) {
                device->controller = [candidate retain];
                break;
            }
        }

        if ((!device->panTiltControl || !device->zoomControl) && !device->controller) {
            [device->lock release];
            free(device);
            return LinkCamResultDeviceNotFound;
        }
        *output = device;
    }
    return LinkCamResultOK;
}

void LinkCamDeviceClose(LinkCamDevice *device) {
    if (!device) return;
    [device->lock lock];
    [device->controller release];
    device->controller = nil;
    [device->lock unlock];
    [device->lock release];
    free(device);
}

LinkCamResult LinkCamReadState(LinkCamDevice *device, LinkCamState *output) {
    if (!device || !output) return LinkCamResultInvalidArgument;
    [device->lock lock];
    LinkCamResult result = readStateUnlocked(device, output);
    [device->lock unlock];
    return result;
}

LinkCamResult LinkCamReadPanTilt(LinkCamDevice *device, int32_t *panUnits, int32_t *tiltUnits) {
    if (!device || !panUnits || !tiltUnits) return LinkCamResultInvalidArgument;
    [device->lock lock];
    LinkCamResult result = readPanTiltUnlocked(device, panUnits, tiltUnits);
    [device->lock unlock];
    return result;
}

LinkCamResult LinkCamReadZoom(LinkCamDevice *device, uint16_t *zoomUnits) {
    if (!device || !zoomUnits) return LinkCamResultInvalidArgument;
    [device->lock lock];
    LinkCamResult result = readZoomUnlocked(device, zoomUnits);
    [device->lock unlock];
    return result;
}

LinkCamResult LinkCamReadTracking(LinkCamDevice *device, int8_t *tracking) {
    if (!device || !tracking) return LinkCamResultInvalidArgument;
    [device->lock lock];
    int8_t active = -1;
    LinkCamResult result = readTrackingStateUnlocked(device, tracking, &active, NULL);
    [device->lock unlock];
    return result;
}

LinkCamResult LinkCamEnsureTrackingSubject(LinkCamDevice *device, int8_t *active) {
    if (!device || !active) return LinkCamResultInvalidArgument;

    [device->lock lock];
    int8_t tracking = -1;
    int8_t trackingActive = -1;
    LinkCamResult result = readTrackingStateUnlocked(device, &tracking, &trackingActive, NULL);
    if (result == LinkCamResultOK && !tracking) {
        device->trackingModeActive = NO;
        device->trackingAcquisitionPrepared = NO;
        *active = 0;
    } else if (result == LinkCamResultOK && trackingActive == 1) {
        device->trackingModeActive = YES;
        *active = 1;
    } else if (result == LinkCamResultOK) {
        if (!device->trackingModeActive && !device->trackingAcquisitionPrepared) {
            result = setVideoModeUnlocked(device, LinkCamVideoModeNormal);
            if (result == LinkCamResultOK) {
                usleep(200000);
                device->trackingAcquisitionPrepared = YES;
            }
        }
        BOOL acquired = NO;
        if (result == LinkCamResultOK) result = acquireTrackingSubjectUnlocked(device, &acquired);
        *active = acquired ? 1 : 0;
    }
    [device->lock unlock];
    return result;
}

static LinkCamResult writePanTiltUnlocked(LinkCamDevice *device, int32_t panUnits, int32_t tiltUnits) {
    if (device->controller) {
        LinkCamResult result = writeExtensionPanTilt(device, panUnits, tiltUnits);
        if (result != LinkCamResultControlUnavailable) return result;
    }

    if (device->panTiltControl) {
        int32_t values[2] = {panUnits, tiltUnits};
        return writeCMIOProperty(device->panTiltControl, kCMIOFeatureControlPropertyNativeData,
                                 values, sizeof(values)) ? LinkCamResultOK : LinkCamResultWriteFailed;
    }

    if (!device->controller) return LinkCamResultControlUnavailable;
    UVCControl *control = [device->controller controlWithName:UVCTerminalControlPanTiltAbsolute];
    if (!control) return LinkCamResultControlUnavailable;

    UVCValue *value = [control currentValue];
    int32_t *pan = value ? (int32_t *)[value pointerToFieldWithName:@"pan"] : NULL;
    int32_t *tilt = value ? (int32_t *)[value pointerToFieldWithName:@"tilt"] : NULL;
    if (!pan || !tilt) return LinkCamResultReadFailed;

    *pan = panUnits;
    *tilt = tiltUnits;
    return [control writeFromCurrentValue] ? LinkCamResultOK : LinkCamResultWriteFailed;
}

LinkCamResult LinkCamSetPanTilt(LinkCamDevice *device,
                                int32_t panUnits,
                                int32_t tiltUnits,
                                LinkCamState *readback) {
    if (!device) return LinkCamResultInvalidArgument;
    panUnits = LinkCamClampAngleUnits(panUnits, LINKCAM_PAN_MIN_UNITS, LINKCAM_PAN_MAX_UNITS);
    tiltUnits = LinkCamClampAngleUnits(tiltUnits, LINKCAM_TILT_MIN_UNITS, LINKCAM_TILT_MAX_UNITS);

    [device->lock lock];
    LinkCamResult result = disableTrackingForManualControlUnlocked(device);
    if (result == LinkCamResultOK) result = writePanTiltUnlocked(device, panUnits, tiltUnits);
    if (result == LinkCamResultOK && readback) result = readStateUnlocked(device, readback);
    [device->lock unlock];
    return result;
}

static LinkCamResult writeZoomUnlocked(LinkCamDevice *device, uint16_t zoomUnits) {
    if (device->zoomControl) {
        AudioValueRange range = {0};
        AudioValueRange *rangePtr = readCMIORange(device->zoomControl,
                                                  kCMIOFeatureControlPropertyNativeRange,
                                                  &range) ? &range : NULL;
        Float32 nativeValue = nativeValueFromZoomUnits(zoomUnits, rangePtr);
        if (writeCMIOProperty(device->zoomControl, kCMIOFeatureControlPropertyNativeValue,
                              &nativeValue, sizeof(nativeValue))) {
            return LinkCamResultOK;
        }

        Float32 absoluteValue = (Float32)LinkCamZoomMultiplierFromUnits(zoomUnits);
        return writeCMIOProperty(device->zoomControl, kCMIOFeatureControlPropertyAbsoluteValue,
                                 &absoluteValue, sizeof(absoluteValue))
            ? LinkCamResultOK : LinkCamResultWriteFailed;
    }

    if (!device->controller) return LinkCamResultControlUnavailable;
    UVCControl *control = [device->controller controlWithName:UVCTerminalControlZoomAbsolute];
    if (!control) return LinkCamResultControlUnavailable;

    UVCValue *value = [control currentValue];
    if (!value || [value byteSize] < sizeof(uint16_t)) return LinkCamResultReadFailed;
    *(uint16_t *)[value valuePtr] = zoomUnits;
    return [control writeFromCurrentValue] ? LinkCamResultOK : LinkCamResultWriteFailed;
}

LinkCamResult LinkCamSetZoom(LinkCamDevice *device, uint16_t zoomUnits, LinkCamState *readback) {
    if (!device) return LinkCamResultInvalidArgument;
    zoomUnits = LinkCamClampZoomUnits(zoomUnits);

    [device->lock lock];
    LinkCamResult result = writeZoomUnlocked(device, zoomUnits);
    if (result == LinkCamResultOK && readback) result = readStateUnlocked(device, readback);
    [device->lock unlock];
    return result;
}

LinkCamResult LinkCamSetTracking(LinkCamDevice *device, int8_t tracking, LinkCamState *readback) {
    if (!device || (tracking != 0 && tracking != 1)) return LinkCamResultInvalidArgument;

    [device->lock lock];
    LinkCamResult result = writeTrackingUnlocked(device, tracking);
    if (result == LinkCamResultOK && tracking) {
        /*
         * Keep the camera in normal mode while its firmware publishes subject
         * candidates, select the best candidate, then enter tracking mode.
         */
        result = setVideoModeUnlocked(device, LinkCamVideoModeNormal);
        if (result == LinkCamResultOK) {
            usleep(200000);
            device->manualModePrepared = NO;
            device->trackingModeActive = NO;
            device->trackingAcquisitionPrepared = YES;
            BOOL acquired = NO;
            result = acquireTrackingSubjectUnlocked(device, &acquired);
        }
        if (result != LinkCamResultOK) {
            /* Do not report tracking as enabled when acquisition setup failed. */
            (void)writeTrackingUnlocked(device, 0);
            (void)setVideoModeUnlocked(device, LinkCamVideoModeNormal);
            device->trackingModeActive = NO;
            device->trackingAcquisitionPrepared = NO;
        }
    } else if (result == LinkCamResultOK) {
        result = setVideoModeUnlocked(device, LinkCamVideoModeNormal);
        if (result == LinkCamResultOK) {
            usleep(350000);
            device->manualModePrepared = YES;
            device->trackingModeActive = NO;
            device->trackingAcquisitionPrepared = NO;
        } else {
            result = LinkCamResultTrackingDisableFailed;
        }
    }
    if (result == LinkCamResultOK && readback) result = readStateUnlocked(device, readback);
    [device->lock unlock];
    return result;
}

LinkCamResult LinkCamSetVideoMode(LinkCamDevice *device, int8_t videoMode, LinkCamState *readback) {
    if (!device || (videoMode != LinkCamVideoModeNormal &&
                    videoMode != LinkCamVideoModeWhiteboard &&
                    videoMode != LinkCamVideoModeDeskView)) {
        return LinkCamResultInvalidArgument;
    }

    [device->lock lock];
    /* The three explicit modes and AI subject tracking are mutually exclusive. */
    LinkCamResult result = writeTrackingUnlocked(device, 0);
    if (result == LinkCamResultOK) result = setVideoModeUnlocked(device, (uint8_t)videoMode);
    if (result == LinkCamResultOK) {
        usleep(350000);
        device->manualModePrepared = videoMode == LinkCamVideoModeNormal;
        device->trackingModeActive = NO;
        device->trackingAcquisitionPrepared = NO;
        if (readback) result = readStateUnlocked(device, readback);
    }
    [device->lock unlock];
    return result;
}

const char *LinkCamResultCode(LinkCamResult result) {
    switch (result) {
        case LinkCamResultOK: return "ok";
        case LinkCamResultInvalidArgument: return "invalid_argument";
        case LinkCamResultDeviceNotFound: return "device_not_found";
        case LinkCamResultControlUnavailable: return "control_unavailable";
        case LinkCamResultReadFailed: return "read_failed";
        case LinkCamResultWriteFailed: return "write_failed";
        case LinkCamResultTrackingDisableFailed: return "tracking_disable_failed";
    }
    return "unknown_error";
}

const char *LinkCamResultDescription(LinkCamResult result) {
    switch (result) {
        case LinkCamResultOK: return "success";
        case LinkCamResultInvalidArgument: return "invalid argument";
        case LinkCamResultDeviceNotFound: return "Insta360 Link 2 not found; check that it is plugged in and awake";
        case LinkCamResultControlUnavailable: return "the camera does not expose the requested control";
        case LinkCamResultReadFailed: return "the camera did not return a valid control value";
        case LinkCamResultWriteFailed: return "the camera rejected the control update";
        case LinkCamResultTrackingDisableFailed: return "AI tracking could not be disabled before manual movement";
    }
    return "unknown error";
}
