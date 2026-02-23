#include <CoreAudio/AudioHardware.h>
#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreAudio/HostTime.h>
#include <CoreFoundation/CoreFoundation.h>
#include <os/log.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <cmath>
#include <cstring>
#include <mutex>

namespace {

#ifndef MICBRIDGE_DEVICE_NAME
#define MICBRIDGE_DEVICE_NAME "MicBridge Virtual Mic"
#endif

#ifndef MICBRIDGE_INPUT_STREAM_NAME
#define MICBRIDGE_INPUT_STREAM_NAME "MicBridge Input Stream"
#endif

#ifndef MICBRIDGE_OUTPUT_STREAM_NAME
#define MICBRIDGE_OUTPUT_STREAM_NAME "MicBridge Output Stream"
#endif

constexpr AudioObjectID kObjectID_Device = 2;
constexpr AudioObjectID kObjectID_Stream_Input = 3;
constexpr AudioObjectID kObjectID_Stream_Output = 4;

constexpr UInt32 kChannelCount = 1;
constexpr UInt32 kDefaultBufferFrameSize = 256;
constexpr UInt32 kMinBufferFrameSize = 64;
constexpr UInt32 kMaxBufferFrameSize = 2048;
constexpr Float64 kDefaultSampleRate = 48000.0;
constexpr UInt32 kMinZeroTimestampPeriodFrames = 10923;
constexpr UInt32 kRingCapacityFrames = 96000;
constexpr bool kEnableDriverDebugLogs = false;

const CFStringRef kPlugInName = CFSTR("MicBridge HAL Driver");
const CFStringRef kPlugInManufacturer = CFSTR("MicBridge");
const CFStringRef kPlugInBundleID = CFSTR("ch.hefti.micbridge.driver");

const CFStringRef kDeviceName = CFSTR(MICBRIDGE_DEVICE_NAME);
const CFStringRef kDeviceManufacturer = CFSTR("MicBridge");
const CFStringRef kDeviceUID = CFSTR("ch.hefti.micbridge.virtualmic.device");
const CFStringRef kDeviceModelUID = CFSTR("ch.hefti.micbridge.virtualmic.model");

const CFStringRef kInputStreamName = CFSTR(MICBRIDGE_INPUT_STREAM_NAME);
const CFStringRef kOutputStreamName = CFSTR(MICBRIDGE_OUTPUT_STREAM_NAME);

struct DriverState {
    std::atomic<UInt32> refCount{1};
    std::mutex configMutex;

    AudioServerPlugInHostRef host = nullptr;

    Float64 sampleRate = kDefaultSampleRate;
    UInt32 bufferFrameSize = kDefaultBufferFrameSize;

    std::atomic<UInt32> ioClients{0};
    std::atomic<UInt64> zeroTimestampSeed{1};
    std::atomic<UInt64> anchorHostTime{0};

    std::array<Float32, kRingCapacityFrames * kChannelCount> ring{};
    std::atomic<UInt64> ringReadFrame{0};
    std::atomic<UInt64> ringWriteFrame{0};
    std::atomic<UInt64> ringUnderruns{0};
    std::atomic<UInt64> ringOverruns{0};
};

DriverState gState;

bool IsPlugInObject(AudioObjectID objectID) {
    return objectID == kAudioObjectPlugInObject;
}

bool IsDeviceObject(AudioObjectID objectID) {
    return objectID == kObjectID_Device;
}

bool IsInputStreamObject(AudioObjectID objectID) {
    return objectID == kObjectID_Stream_Input;
}

bool IsOutputStreamObject(AudioObjectID objectID) {
    return objectID == kObjectID_Stream_Output;
}

bool IsStreamObject(AudioObjectID objectID) {
    return IsInputStreamObject(objectID) || IsOutputStreamObject(objectID);
}

bool IsOutputScope(AudioObjectPropertyScope scope) {
    return scope == kAudioObjectPropertyScopeOutput;
}

bool IsInputScope(AudioObjectPropertyScope scope) {
    return scope == kAudioObjectPropertyScopeInput;
}

bool IsGlobalOrWildcardScope(AudioObjectPropertyScope scope) {
    return scope == kAudioObjectPropertyScopeGlobal || scope == kAudioObjectPropertyScopeWildcard;
}

AudioClassID ClassIDForObject(AudioObjectID objectID) {
    if (IsPlugInObject(objectID)) {
        return kAudioPlugInClassID;
    }
    if (IsDeviceObject(objectID)) {
        return kAudioDeviceClassID;
    }
    if (IsStreamObject(objectID)) {
        return kAudioStreamClassID;
    }
    return kAudioObjectClassID;
}

bool ObjectMatchesClass(AudioObjectID objectID, AudioClassID classID) {
    if (classID == kAudioObjectClassID) {
        return IsPlugInObject(objectID) || IsDeviceObject(objectID) || IsStreamObject(objectID);
    }
    if (classID == kAudioPlugInClassID) {
        return IsPlugInObject(objectID);
    }
    if (classID == kAudioDeviceClassID) {
        return IsDeviceObject(objectID);
    }
    if (classID == kAudioStreamClassID) {
        return IsStreamObject(objectID);
    }
    // We do not expose any controls today.
    if (classID == kAudioControlClassID || classID == kAudioBooleanControlClassID || classID == kAudioLevelControlClassID) {
        return false;
    }
    return ClassIDForObject(objectID) == classID;
}

bool ObjectMatchesQualifierClasses(AudioObjectID objectID, UInt32 qualifierDataSize, const void* qualifierData) {
    if (qualifierDataSize == 0 || qualifierData == nullptr) {
        return true;
    }
    if ((qualifierDataSize % sizeof(AudioClassID)) != 0) {
        return false;
    }
    UInt32 classCount = qualifierDataSize / sizeof(AudioClassID);
    const auto* classes = reinterpret_cast<const AudioClassID*>(qualifierData);
    for (UInt32 i = 0; i < classCount; ++i) {
        if (ObjectMatchesClass(objectID, classes[i])) {
            return true;
        }
    }
    return false;
}

OSStatus BuildFilteredObjectList(const AudioObjectID* candidates, UInt32 candidateCount, UInt32 qualifierDataSize, const void* qualifierData, AudioObjectID* outObjects, UInt32* outObjectCount) {
    if (outObjectCount == nullptr) {
        return kAudioHardwareIllegalOperationError;
    }
    if (qualifierDataSize > 0 && qualifierData == nullptr) {
        return kAudioHardwareIllegalOperationError;
    }
    if ((qualifierDataSize % sizeof(AudioClassID)) != 0) {
        return kAudioHardwareBadPropertySizeError;
    }

    UInt32 count = 0;
    for (UInt32 i = 0; i < candidateCount; ++i) {
        if (ObjectMatchesQualifierClasses(candidates[i], qualifierDataSize, qualifierData)) {
            if (outObjects != nullptr) {
                outObjects[count] = candidates[i];
            }
            ++count;
        }
    }
    *outObjectCount = count;
    return noErr;
}

OSStatus CopyObjectIDArrayToOutData(const AudioObjectID* values, UInt32 valueCount, UInt32 inDataSize, UInt32* outDataSize, void* outData) {
    UInt32 requiredSize = valueCount * static_cast<UInt32>(sizeof(AudioObjectID));
    if (requiredSize == 0) {
        *outDataSize = 0;
        return noErr;
    }
    if (outData == nullptr || inDataSize < requiredSize) {
        return kAudioHardwareBadPropertySizeError;
    }
    std::memcpy(outData, values, requiredSize);
    *outDataSize = requiredSize;
    return noErr;
}

void DebugLogProperty(const char* phase, AudioObjectID objectID, const AudioObjectPropertyAddress* address, UInt32 qualifierDataSize, UInt32 outCount, OSStatus status) {
    if (!kEnableDriverDebugLogs || address == nullptr) {
        return;
    }
    os_log_error(OS_LOG_DEFAULT,
                 "MicBridge %{public}s obj=%u sel=%u scope=%u elem=%u qsize=%u count=%u status=%d",
                 phase, objectID, address->mSelector, address->mScope, address->mElement, qualifierDataSize, outCount, status);
}

AudioStreamBasicDescription MakeFormat(Float64 sampleRate) {
    AudioStreamBasicDescription format{};
    format.mSampleRate = sampleRate;
    format.mFormatID = kAudioFormatLinearPCM;
    format.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
    format.mBytesPerPacket = kChannelCount * sizeof(Float32);
    format.mFramesPerPacket = 1;
    format.mBytesPerFrame = kChannelCount * sizeof(Float32);
    format.mChannelsPerFrame = kChannelCount;
    format.mBitsPerChannel = 8 * sizeof(Float32);
    return format;
}

UInt32 ZeroTimestampPeriodFramesForSampleRate(Float64 sampleRate) {
    UInt32 quarterSecondFrames = static_cast<UInt32>(sampleRate / 4.0);
    return std::max(kMinZeroTimestampPeriodFrames, quarterSecondFrames);
}

AudioStreamRangedDescription MakeRangedFormat(Float64 sampleRate) {
    AudioStreamRangedDescription description{};
    description.mFormat = MakeFormat(sampleRate);
    description.mSampleRateRange.mMinimum = sampleRate;
    description.mSampleRateRange.mMaximum = sampleRate;
    return description;
}

void NotifyPropertiesChanged(AudioObjectID objectID, UInt32 addressCount, const AudioObjectPropertyAddress* addresses) {
    if (gState.host == nullptr || gState.host->PropertiesChanged == nullptr) {
        return;
    }
    gState.host->PropertiesChanged(gState.host, objectID, addressCount, addresses);
}

OSStatus CopyCFStringToOutData(CFStringRef value, UInt32 inDataSize, UInt32* outDataSize, void* outData) {
    if (inDataSize < sizeof(CFStringRef) || outData == nullptr || outDataSize == nullptr) {
        return kAudioHardwareBadPropertySizeError;
    }
    auto* outValue = reinterpret_cast<CFStringRef*>(outData);
    *outValue = value;
    if (value != nullptr) {
        CFRetain(value);
    }
    *outDataSize = sizeof(CFStringRef);
    return noErr;
}

OSStatus CopyUInt32ToOutData(UInt32 value, UInt32 inDataSize, UInt32* outDataSize, void* outData) {
    if (inDataSize < sizeof(UInt32) || outData == nullptr || outDataSize == nullptr) {
        return kAudioHardwareBadPropertySizeError;
    }
    *reinterpret_cast<UInt32*>(outData) = value;
    *outDataSize = sizeof(UInt32);
    return noErr;
}

OSStatus CopyFloat64ToOutData(Float64 value, UInt32 inDataSize, UInt32* outDataSize, void* outData) {
    if (inDataSize < sizeof(Float64) || outData == nullptr || outDataSize == nullptr) {
        return kAudioHardwareBadPropertySizeError;
    }
    *reinterpret_cast<Float64*>(outData) = value;
    *outDataSize = sizeof(Float64);
    return noErr;
}

void WriteRing(const Float32* source, UInt32 frameCount) {
    UInt64 writeFrame = gState.ringWriteFrame.load(std::memory_order_relaxed);
    UInt64 readFrame = gState.ringReadFrame.load(std::memory_order_acquire);
    UInt64 available = writeFrame - readFrame;

    if (available >= kRingCapacityFrames) {
        gState.ringOverruns.fetch_add(frameCount, std::memory_order_relaxed);
        gState.ringReadFrame.store(writeFrame - kRingCapacityFrames + 1, std::memory_order_release);
        readFrame = gState.ringReadFrame.load(std::memory_order_acquire);
        available = writeFrame - readFrame;
    }

    UInt64 capacityLeft = kRingCapacityFrames - available;
    if (frameCount > capacityLeft) {
        UInt64 drop = frameCount - capacityLeft;
        gState.ringReadFrame.store(readFrame + drop, std::memory_order_release);
        gState.ringOverruns.fetch_add(drop, std::memory_order_relaxed);
    }

    for (UInt32 frame = 0; frame < frameCount; ++frame) {
        UInt64 index = (writeFrame + frame) % kRingCapacityFrames;
        gState.ring[index] = source[frame];
    }

    gState.ringWriteFrame.store(writeFrame + frameCount, std::memory_order_release);
}

UInt32 ReadRing(Float32* destination, UInt32 frameCount) {
    UInt64 readFrame = gState.ringReadFrame.load(std::memory_order_relaxed);
    UInt64 writeFrame = gState.ringWriteFrame.load(std::memory_order_acquire);

    UInt64 available = writeFrame - readFrame;
    UInt32 framesToRead = static_cast<UInt32>(std::min<UInt64>(frameCount, available));

    for (UInt32 frame = 0; frame < framesToRead; ++frame) {
        UInt64 index = (readFrame + frame) % kRingCapacityFrames;
        destination[frame] = gState.ring[index];
    }

    if (framesToRead < frameCount) {
        std::memset(destination + framesToRead, 0, static_cast<size_t>(frameCount - framesToRead) * sizeof(Float32));
        gState.ringUnderruns.fetch_add(frameCount - framesToRead, std::memory_order_relaxed);
    }

    gState.ringReadFrame.store(readFrame + framesToRead, std::memory_order_release);
    return framesToRead;
}

HRESULT MicBridge_QueryInterface(void* inDriver, REFIID inUUID, LPVOID* outInterface);
ULONG MicBridge_AddRef(void* inDriver);
ULONG MicBridge_Release(void* inDriver);
OSStatus MicBridge_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost);
OSStatus MicBridge_CreateDevice(AudioServerPlugInDriverRef inDriver, CFDictionaryRef inDescription, const AudioServerPlugInClientInfo* inClientInfo, AudioObjectID* outDeviceObjectID);
OSStatus MicBridge_DestroyDevice(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID);
OSStatus MicBridge_AddDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo* inClientInfo);
OSStatus MicBridge_RemoveDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo* inClientInfo);
OSStatus MicBridge_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void* inChangeInfo);
OSStatus MicBridge_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void* inChangeInfo);
Boolean MicBridge_HasProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress);
OSStatus MicBridge_IsPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, Boolean* outIsSettable);
OSStatus MicBridge_GetPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32* outDataSize);
OSStatus MicBridge_GetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, UInt32* outDataSize, void* outData);
OSStatus MicBridge_SetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, const void* inData);
OSStatus MicBridge_StartIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID);
OSStatus MicBridge_StopIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID);
OSStatus MicBridge_GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, Float64* outSampleTime, UInt64* outHostTime, UInt64* outSeed);
OSStatus MicBridge_WillDoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, Boolean* outWillDo, Boolean* outWillDoInPlace);
OSStatus MicBridge_BeginIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo);
OSStatus MicBridge_DoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, AudioObjectID inStreamObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo, void* ioMainBuffer, void* ioSecondaryBuffer);
OSStatus MicBridge_EndIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo);

AudioServerPlugInDriverInterface gDriverInterface = {
    nullptr,
    MicBridge_QueryInterface,
    MicBridge_AddRef,
    MicBridge_Release,
    MicBridge_Initialize,
    MicBridge_CreateDevice,
    MicBridge_DestroyDevice,
    MicBridge_AddDeviceClient,
    MicBridge_RemoveDeviceClient,
    MicBridge_PerformDeviceConfigurationChange,
    MicBridge_AbortDeviceConfigurationChange,
    MicBridge_HasProperty,
    MicBridge_IsPropertySettable,
    MicBridge_GetPropertyDataSize,
    MicBridge_GetPropertyData,
    MicBridge_SetPropertyData,
    MicBridge_StartIO,
    MicBridge_StopIO,
    MicBridge_GetZeroTimeStamp,
    MicBridge_WillDoIOOperation,
    MicBridge_BeginIOOperation,
    MicBridge_DoIOOperation,
    MicBridge_EndIOOperation
};

AudioServerPlugInDriverInterface* gDriverInterfacePtr = &gDriverInterface;

HRESULT MicBridge_QueryInterface(void* inDriver, REFIID inUUID, LPVOID* outInterface) {
    if (outInterface == nullptr) {
        return E_POINTER;
    }

    CFUUIDRef interfaceUUID = CFUUIDCreateFromUUIDBytes(kCFAllocatorDefault, inUUID);
    if (interfaceUUID == nullptr) {
        *outInterface = nullptr;
        return E_NOINTERFACE;
    }

    const bool isMatch = CFEqual(interfaceUUID, IUnknownUUID) || CFEqual(interfaceUUID, kAudioServerPlugInDriverInterfaceUUID);
    CFRelease(interfaceUUID);

    if (isMatch) {
        MicBridge_AddRef(inDriver);
        *outInterface = inDriver;
        return S_OK;
    }

    *outInterface = nullptr;
    return E_NOINTERFACE;
}

ULONG MicBridge_AddRef(void* /*inDriver*/) {
    return ++gState.refCount;
}

ULONG MicBridge_Release(void* /*inDriver*/) {
    UInt32 previous = gState.refCount.fetch_sub(1);
    if (previous == 0) {
        gState.refCount = 0;
        return 0;
    }
    return previous - 1;
}

OSStatus MicBridge_Initialize(AudioServerPlugInDriverRef /*inDriver*/, AudioServerPlugInHostRef inHost) {
    gState.host = inHost;
    gState.anchorHostTime = AudioGetCurrentHostTime();
    gState.ringReadFrame = 0;
    gState.ringWriteFrame = 0;
    return noErr;
}

OSStatus MicBridge_CreateDevice(AudioServerPlugInDriverRef /*inDriver*/, CFDictionaryRef /*inDescription*/, const AudioServerPlugInClientInfo* /*inClientInfo*/, AudioObjectID* /*outDeviceObjectID*/) {
    return kAudioHardwareUnsupportedOperationError;
}

OSStatus MicBridge_DestroyDevice(AudioServerPlugInDriverRef /*inDriver*/, AudioObjectID /*inDeviceObjectID*/) {
    return kAudioHardwareUnsupportedOperationError;
}

OSStatus MicBridge_AddDeviceClient(AudioServerPlugInDriverRef /*inDriver*/, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo* /*inClientInfo*/) {
    if (IsDeviceObject(inDeviceObjectID)) {
        return noErr;
    }
    return kAudioHardwareBadObjectError;
}

OSStatus MicBridge_RemoveDeviceClient(AudioServerPlugInDriverRef /*inDriver*/, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo* /*inClientInfo*/) {
    if (IsDeviceObject(inDeviceObjectID)) {
        return noErr;
    }
    return kAudioHardwareBadObjectError;
}

OSStatus MicBridge_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef /*inDriver*/, AudioObjectID inDeviceObjectID, UInt64 /*inChangeAction*/, void* /*inChangeInfo*/) {
    if (IsDeviceObject(inDeviceObjectID)) {
        return noErr;
    }
    return kAudioHardwareBadObjectError;
}

OSStatus MicBridge_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef /*inDriver*/, AudioObjectID inDeviceObjectID, UInt64 /*inChangeAction*/, void* /*inChangeInfo*/) {
    if (IsDeviceObject(inDeviceObjectID)) {
        return noErr;
    }
    return kAudioHardwareBadObjectError;
}

Boolean MicBridge_HasProperty(AudioServerPlugInDriverRef /*inDriver*/, AudioObjectID inObjectID, pid_t /*inClientProcessID*/, const AudioObjectPropertyAddress* inAddress) {
    if (inAddress == nullptr) {
        return false;
    }

    if (IsPlugInObject(inObjectID)) {
        switch (inAddress->mSelector) {
            case kAudioObjectPropertyBaseClass:
            case kAudioObjectPropertyClass:
            case kAudioObjectPropertyOwner:
            case kAudioObjectPropertyName:
            case kAudioObjectPropertyManufacturer:
            case kAudioObjectPropertyOwnedObjects:
            case kAudioPlugInPropertyBundleID:
            case kAudioPlugInPropertyDeviceList:
            case kAudioPlugInPropertyTranslateUIDToDevice:
                return true;
            default:
                return false;
        }
    }

    if (IsDeviceObject(inObjectID)) {
        switch (inAddress->mSelector) {
            case kAudioObjectPropertyBaseClass:
            case kAudioObjectPropertyClass:
            case kAudioObjectPropertyOwner:
            case kAudioObjectPropertyName:
            case kAudioObjectPropertyManufacturer:
            case kAudioObjectPropertyOwnedObjects:
            case kAudioDevicePropertyDeviceUID:
            case kAudioDevicePropertyModelUID:
            case kAudioDevicePropertyTransportType:
            case kAudioDevicePropertyRelatedDevices:
            case kAudioDevicePropertyClockDomain:
            case kAudioDevicePropertyDeviceIsAlive:
            case kAudioDevicePropertyDeviceIsRunning:
            case kAudioDevicePropertyDeviceIsRunningSomewhere:
            case kAudioDevicePropertyLatency:
            case kAudioDevicePropertySafetyOffset:
            case kAudioDevicePropertyNominalSampleRate:
            case kAudioDevicePropertyAvailableNominalSampleRates:
            case kAudioDevicePropertyZeroTimeStampPeriod:
            case kAudioDevicePropertyIsHidden:
            case kAudioObjectPropertyControlList:
            case kAudioDevicePropertyPreferredChannelsForStereo:
            case kAudioDevicePropertyStreams:
            case kAudioDevicePropertyStreamConfiguration:
            case kAudioDevicePropertyBufferFrameSize:
            case kAudioDevicePropertyBufferFrameSizeRange:
            case kAudioDevicePropertyUsesVariableBufferFrameSizes:
                return true;
            default:
                return false;
        }
    }

    if (IsStreamObject(inObjectID)) {
        switch (inAddress->mSelector) {
            case kAudioObjectPropertyBaseClass:
            case kAudioObjectPropertyClass:
            case kAudioObjectPropertyOwner:
            case kAudioObjectPropertyName:
            case kAudioStreamPropertyDirection:
            case kAudioStreamPropertyTerminalType:
            case kAudioStreamPropertyStartingChannel:
            case kAudioStreamPropertyLatency:
            case kAudioStreamPropertyVirtualFormat:
            case kAudioStreamPropertyPhysicalFormat:
            case kAudioStreamPropertyAvailableVirtualFormats:
            case kAudioStreamPropertyAvailablePhysicalFormats:
                return true;
            default:
                return false;
        }
    }

    return false;
}

OSStatus MicBridge_IsPropertySettable(AudioServerPlugInDriverRef /*inDriver*/, AudioObjectID inObjectID, pid_t /*inClientProcessID*/, const AudioObjectPropertyAddress* inAddress, Boolean* outIsSettable) {
    if (inAddress == nullptr || outIsSettable == nullptr) {
        return kAudioHardwareIllegalOperationError;
    }

    *outIsSettable = false;

    if (IsDeviceObject(inObjectID)) {
        if (inAddress->mSelector == kAudioDevicePropertyNominalSampleRate || inAddress->mSelector == kAudioDevicePropertyBufferFrameSize) {
            *outIsSettable = true;
        }
    }

    return noErr;
}

OSStatus MicBridge_GetPropertyDataSize(AudioServerPlugInDriverRef /*inDriver*/, AudioObjectID inObjectID, pid_t /*inClientProcessID*/, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32* outDataSize) {
    if (inAddress == nullptr || outDataSize == nullptr) {
        return kAudioHardwareIllegalOperationError;
    }

    if (IsPlugInObject(inObjectID) || IsDeviceObject(inObjectID) || IsStreamObject(inObjectID)) {
        DebugLogProperty("GetPropertyDataSize(call)", inObjectID, inAddress, inQualifierDataSize, 0, noErr);
    }

    if (IsPlugInObject(inObjectID)) {
        switch (inAddress->mSelector) {
            case kAudioObjectPropertyBaseClass:
            case kAudioObjectPropertyClass:
            case kAudioObjectPropertyOwner:
                *outDataSize = sizeof(AudioClassID);
                return noErr;
            case kAudioPlugInPropertyTranslateUIDToDevice:
                *outDataSize = sizeof(AudioObjectID);
                return noErr;
            case kAudioObjectPropertyName:
            case kAudioObjectPropertyManufacturer:
            case kAudioPlugInPropertyBundleID:
                *outDataSize = sizeof(CFStringRef);
                return noErr;
            case kAudioObjectPropertyOwnedObjects:
            case kAudioPlugInPropertyDeviceList: {
                AudioObjectID objects[1] = {kObjectID_Device};
                UInt32 objectCount = 0;
                OSStatus status = BuildFilteredObjectList(objects, 1, inQualifierDataSize, inQualifierData, nullptr, &objectCount);
                DebugLogProperty("GetPropertyDataSize(plugin-owned)", inObjectID, inAddress, inQualifierDataSize, objectCount, status);
                if (status != noErr) {
                    return status;
                }
                *outDataSize = objectCount * static_cast<UInt32>(sizeof(AudioObjectID));
                return noErr;
            }
            default:
                return kAudioHardwareUnknownPropertyError;
        }
    }

    if (IsDeviceObject(inObjectID)) {
        switch (inAddress->mSelector) {
            case kAudioObjectPropertyBaseClass:
            case kAudioObjectPropertyClass:
            case kAudioObjectPropertyOwner:
            case kAudioDevicePropertyTransportType:
            case kAudioDevicePropertyClockDomain:
            case kAudioDevicePropertyDeviceIsAlive:
            case kAudioDevicePropertyDeviceIsRunning:
            case kAudioDevicePropertyDeviceIsRunningSomewhere:
            case kAudioDevicePropertyLatency:
            case kAudioDevicePropertySafetyOffset:
            case kAudioDevicePropertyClockAlgorithm:
            case kAudioDevicePropertyClockIsStable:
            case kAudioDevicePropertyBufferFrameSize:
            case kAudioDevicePropertyUsesVariableBufferFrameSizes:
            case kAudioDevicePropertyIsHidden:
                *outDataSize = sizeof(UInt32);
                return noErr;
            case kAudioObjectPropertyName:
            case kAudioObjectPropertyManufacturer:
            case kAudioDevicePropertyDeviceUID:
            case kAudioDevicePropertyModelUID:
                *outDataSize = sizeof(CFStringRef);
                return noErr;
            case kAudioObjectPropertyOwnedObjects: {
                AudioObjectID candidates[2];
                UInt32 candidateCount = 0;
                if (IsInputScope(inAddress->mScope)) {
                    candidates[0] = kObjectID_Stream_Input;
                    candidateCount = 1;
                } else if (IsOutputScope(inAddress->mScope)) {
                    candidates[0] = kObjectID_Stream_Output;
                    candidateCount = 1;
                } else if (IsGlobalOrWildcardScope(inAddress->mScope)) {
                    candidates[0] = kObjectID_Stream_Input;
                    candidates[1] = kObjectID_Stream_Output;
                    candidateCount = 2;
                } else {
                    return kAudioHardwareIllegalOperationError;
                }

                UInt32 objectCount = 0;
                OSStatus status = BuildFilteredObjectList(candidates, candidateCount, inQualifierDataSize, inQualifierData, nullptr, &objectCount);
                DebugLogProperty("GetPropertyDataSize(device-owned)", inObjectID, inAddress, inQualifierDataSize, objectCount, status);
                if (status != noErr) {
                    return status;
                }
                *outDataSize = objectCount * static_cast<UInt32>(sizeof(AudioObjectID));
                return noErr;
            }
            case kAudioDevicePropertyRelatedDevices:
                *outDataSize = sizeof(AudioObjectID);
                return noErr;
            case kAudioDevicePropertyNominalSampleRate:
                *outDataSize = sizeof(Float64);
                return noErr;
            case kAudioDevicePropertyZeroTimeStampPeriod:
                *outDataSize = sizeof(UInt32);
                return noErr;
            case kAudioDevicePropertyAvailableNominalSampleRates:
                *outDataSize = sizeof(AudioValueRange);
                return noErr;
            case kAudioObjectPropertyControlList:
                *outDataSize = 0;
                return noErr;
            case kAudioDevicePropertyPreferredChannelsForStereo:
                *outDataSize = sizeof(UInt32) * 2;
                return noErr;
            case kAudioDevicePropertyStreams:
                if (IsInputScope(inAddress->mScope) || IsOutputScope(inAddress->mScope)) {
                    *outDataSize = sizeof(AudioObjectID);
                    return noErr;
                }
                if (IsGlobalOrWildcardScope(inAddress->mScope)) {
                    *outDataSize = sizeof(AudioObjectID) * 2;
                    return noErr;
                }
                return kAudioHardwareIllegalOperationError;
            case kAudioDevicePropertyBufferFrameSizeRange:
                *outDataSize = sizeof(AudioValueRange);
                return noErr;
            case kAudioDevicePropertyStreamConfiguration:
                *outDataSize = static_cast<UInt32>(offsetof(AudioBufferList, mBuffers) + sizeof(AudioBuffer));
                return noErr;
            default:
                return kAudioHardwareUnknownPropertyError;
        }
    }

    if (IsStreamObject(inObjectID)) {
        switch (inAddress->mSelector) {
            case kAudioObjectPropertyBaseClass:
            case kAudioObjectPropertyClass:
            case kAudioObjectPropertyOwner:
            case kAudioStreamPropertyDirection:
            case kAudioStreamPropertyTerminalType:
            case kAudioStreamPropertyStartingChannel:
            case kAudioStreamPropertyLatency:
                *outDataSize = sizeof(UInt32);
                return noErr;
            case kAudioObjectPropertyName:
                *outDataSize = sizeof(CFStringRef);
                return noErr;
            case kAudioStreamPropertyVirtualFormat:
            case kAudioStreamPropertyPhysicalFormat:
                *outDataSize = sizeof(AudioStreamBasicDescription);
                return noErr;
            case kAudioStreamPropertyAvailableVirtualFormats:
            case kAudioStreamPropertyAvailablePhysicalFormats:
                *outDataSize = sizeof(AudioStreamRangedDescription);
                return noErr;
            default:
                return kAudioHardwareUnknownPropertyError;
        }
    }

    return kAudioHardwareBadObjectError;
}

OSStatus MicBridge_GetPropertyData(AudioServerPlugInDriverRef /*inDriver*/, AudioObjectID inObjectID, pid_t /*inClientProcessID*/, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, UInt32* outDataSize, void* outData) {
    if (inAddress == nullptr || outDataSize == nullptr) {
        return kAudioHardwareIllegalOperationError;
    }

    if (IsPlugInObject(inObjectID) || IsDeviceObject(inObjectID) || IsStreamObject(inObjectID)) {
        DebugLogProperty("GetPropertyData(call)", inObjectID, inAddress, inQualifierDataSize, 0, noErr);
    }

    if (IsPlugInObject(inObjectID)) {
        switch (inAddress->mSelector) {
            case kAudioObjectPropertyBaseClass:
                return CopyUInt32ToOutData(kAudioObjectClassID, inDataSize, outDataSize, outData);
            case kAudioObjectPropertyClass:
                return CopyUInt32ToOutData(kAudioPlugInClassID, inDataSize, outDataSize, outData);
            case kAudioObjectPropertyOwner:
                return CopyUInt32ToOutData(kAudioObjectSystemObject, inDataSize, outDataSize, outData);
            case kAudioObjectPropertyName:
                return CopyCFStringToOutData(kPlugInName, inDataSize, outDataSize, outData);
            case kAudioObjectPropertyManufacturer:
                return CopyCFStringToOutData(kPlugInManufacturer, inDataSize, outDataSize, outData);
            case kAudioPlugInPropertyBundleID:
                return CopyCFStringToOutData(kPlugInBundleID, inDataSize, outDataSize, outData);
            case kAudioObjectPropertyOwnedObjects:
            case kAudioPlugInPropertyDeviceList: {
                AudioObjectID objects[1] = {kObjectID_Device};
                UInt32 objectCount = 0;
                OSStatus status = BuildFilteredObjectList(objects, 1, inQualifierDataSize, inQualifierData, objects, &objectCount);
                DebugLogProperty("GetPropertyData(plugin-owned)", inObjectID, inAddress, inQualifierDataSize, objectCount, status);
                if (status != noErr) {
                    return status;
                }
                return CopyObjectIDArrayToOutData(objects, objectCount, inDataSize, outDataSize, outData);
            }
            case kAudioPlugInPropertyTranslateUIDToDevice: {
                if (inDataSize < sizeof(AudioObjectID) || outData == nullptr) {
                    return kAudioHardwareBadPropertySizeError;
                }

                AudioObjectID translated = kAudioObjectUnknown;
                if (inQualifierDataSize == sizeof(CFStringRef) && inQualifierData != nullptr) {
                    auto requestedUID = *reinterpret_cast<const CFStringRef*>(inQualifierData);
                    if (requestedUID != nullptr && CFEqual(requestedUID, kDeviceUID)) {
                        translated = kObjectID_Device;
                    }
                }

                *reinterpret_cast<AudioObjectID*>(outData) = translated;
                *outDataSize = sizeof(AudioObjectID);
                return noErr;
            }
            default:
                return kAudioHardwareUnknownPropertyError;
        }
    }

    if (IsDeviceObject(inObjectID)) {
        std::lock_guard<std::mutex> lock(gState.configMutex);

        switch (inAddress->mSelector) {
            case kAudioObjectPropertyBaseClass:
                return CopyUInt32ToOutData(kAudioObjectClassID, inDataSize, outDataSize, outData);
            case kAudioObjectPropertyClass:
                return CopyUInt32ToOutData(kAudioDeviceClassID, inDataSize, outDataSize, outData);
            case kAudioObjectPropertyOwner:
                return CopyUInt32ToOutData(kAudioObjectPlugInObject, inDataSize, outDataSize, outData);
            case kAudioObjectPropertyName:
                return CopyCFStringToOutData(kDeviceName, inDataSize, outDataSize, outData);
            case kAudioObjectPropertyManufacturer:
                return CopyCFStringToOutData(kDeviceManufacturer, inDataSize, outDataSize, outData);
            case kAudioDevicePropertyDeviceUID:
                return CopyCFStringToOutData(kDeviceUID, inDataSize, outDataSize, outData);
            case kAudioDevicePropertyModelUID:
                return CopyCFStringToOutData(kDeviceModelUID, inDataSize, outDataSize, outData);
            case kAudioObjectPropertyOwnedObjects: {
                AudioObjectID candidates[2];
                UInt32 candidateCount = 0;
                if (IsInputScope(inAddress->mScope)) {
                    candidates[0] = kObjectID_Stream_Input;
                    candidateCount = 1;
                } else if (IsOutputScope(inAddress->mScope)) {
                    candidates[0] = kObjectID_Stream_Output;
                    candidateCount = 1;
                } else if (IsGlobalOrWildcardScope(inAddress->mScope)) {
                    candidates[0] = kObjectID_Stream_Input;
                    candidates[1] = kObjectID_Stream_Output;
                    candidateCount = 2;
                } else {
                    return kAudioHardwareIllegalOperationError;
                }

                AudioObjectID filtered[2] = {};
                UInt32 filteredCount = 0;
                OSStatus status = BuildFilteredObjectList(candidates, candidateCount, inQualifierDataSize, inQualifierData, filtered, &filteredCount);
                DebugLogProperty("GetPropertyData(device-owned)", inObjectID, inAddress, inQualifierDataSize, filteredCount, status);
                if (status != noErr) {
                    return status;
                }
                return CopyObjectIDArrayToOutData(filtered, filteredCount, inDataSize, outDataSize, outData);
            }
            case kAudioDevicePropertyTransportType:
                return CopyUInt32ToOutData(kAudioDeviceTransportTypeVirtual, inDataSize, outDataSize, outData);
            case kAudioDevicePropertyRelatedDevices:
                if (inDataSize < sizeof(AudioObjectID) || outData == nullptr) {
                    return kAudioHardwareBadPropertySizeError;
                }
                *reinterpret_cast<AudioObjectID*>(outData) = kObjectID_Device;
                *outDataSize = sizeof(AudioObjectID);
                return noErr;
            case kAudioDevicePropertyClockDomain:
                return CopyUInt32ToOutData(0, inDataSize, outDataSize, outData);
            case kAudioDevicePropertyClockAlgorithm:
                return CopyUInt32ToOutData(kAudioDeviceClockAlgorithmSimpleIIR, inDataSize, outDataSize, outData);
            case kAudioDevicePropertyClockIsStable:
                return CopyUInt32ToOutData(1, inDataSize, outDataSize, outData);
            case kAudioDevicePropertyDeviceIsAlive:
                return CopyUInt32ToOutData(1, inDataSize, outDataSize, outData);
            case kAudioDevicePropertyDeviceIsRunning:
            case kAudioDevicePropertyDeviceIsRunningSomewhere:
                return CopyUInt32ToOutData(gState.ioClients.load() > 0 ? 1 : 0, inDataSize, outDataSize, outData);
            case kAudioDevicePropertyLatency:
            case kAudioDevicePropertySafetyOffset:
                return CopyUInt32ToOutData(0, inDataSize, outDataSize, outData);
            case kAudioDevicePropertyNominalSampleRate:
                return CopyFloat64ToOutData(gState.sampleRate, inDataSize, outDataSize, outData);
            case kAudioDevicePropertyZeroTimeStampPeriod:
                return CopyUInt32ToOutData(ZeroTimestampPeriodFramesForSampleRate(gState.sampleRate), inDataSize, outDataSize, outData);
            case kAudioDevicePropertyAvailableNominalSampleRates: {
                if (inDataSize < sizeof(AudioValueRange) || outData == nullptr) {
                    return kAudioHardwareBadPropertySizeError;
                }
                auto* range = reinterpret_cast<AudioValueRange*>(outData);
                range->mMinimum = kDefaultSampleRate;
                range->mMaximum = kDefaultSampleRate;
                *outDataSize = sizeof(AudioValueRange);
                return noErr;
            }
            case kAudioObjectPropertyControlList:
                DebugLogProperty("GetPropertyData(device-controls)", inObjectID, inAddress, inQualifierDataSize, 0, noErr);
                *outDataSize = 0;
                return noErr;
            case kAudioDevicePropertyIsHidden:
                return CopyUInt32ToOutData(0, inDataSize, outDataSize, outData);
            case kAudioDevicePropertyPreferredChannelsForStereo: {
                if (inDataSize < sizeof(UInt32) * 2 || outData == nullptr) {
                    return kAudioHardwareBadPropertySizeError;
                }
                auto* channels = reinterpret_cast<UInt32*>(outData);
                channels[0] = 1;
                channels[1] = 1;
                *outDataSize = sizeof(UInt32) * 2;
                return noErr;
            }
            case kAudioDevicePropertyStreams: {
                AudioObjectID streams[2] = {};
                UInt32 streamCount = 0;

                if (IsInputScope(inAddress->mScope)) {
                    streams[0] = kObjectID_Stream_Input;
                    streamCount = 1;
                } else if (IsOutputScope(inAddress->mScope)) {
                    streams[0] = kObjectID_Stream_Output;
                    streamCount = 1;
                } else if (IsGlobalOrWildcardScope(inAddress->mScope)) {
                    streams[0] = kObjectID_Stream_Input;
                    streams[1] = kObjectID_Stream_Output;
                    streamCount = 2;
                } else {
                    return kAudioHardwareIllegalOperationError;
                }

                return CopyObjectIDArrayToOutData(streams, streamCount, inDataSize, outDataSize, outData);
            }
            case kAudioDevicePropertyStreamConfiguration: {
                UInt32 requiredSize = static_cast<UInt32>(offsetof(AudioBufferList, mBuffers) + sizeof(AudioBuffer));
                if (inDataSize < requiredSize || outData == nullptr) {
                    return kAudioHardwareBadPropertySizeError;
                }

                auto* list = reinterpret_cast<AudioBufferList*>(outData);
                list->mNumberBuffers = 1;
                list->mBuffers[0].mNumberChannels = kChannelCount;
                list->mBuffers[0].mDataByteSize = 0;
                list->mBuffers[0].mData = nullptr;
                *outDataSize = requiredSize;
                return noErr;
            }
            case kAudioDevicePropertyBufferFrameSize:
                return CopyUInt32ToOutData(gState.bufferFrameSize, inDataSize, outDataSize, outData);
            case kAudioDevicePropertyBufferFrameSizeRange: {
                if (inDataSize < sizeof(AudioValueRange) || outData == nullptr) {
                    return kAudioHardwareBadPropertySizeError;
                }
                auto* range = reinterpret_cast<AudioValueRange*>(outData);
                range->mMinimum = kMinBufferFrameSize;
                range->mMaximum = kMaxBufferFrameSize;
                *outDataSize = sizeof(AudioValueRange);
                return noErr;
            }
            case kAudioDevicePropertyUsesVariableBufferFrameSizes:
                return CopyUInt32ToOutData(0, inDataSize, outDataSize, outData);
            default:
                return kAudioHardwareUnknownPropertyError;
        }
    }

    if (IsStreamObject(inObjectID)) {
        std::lock_guard<std::mutex> lock(gState.configMutex);

        switch (inAddress->mSelector) {
            case kAudioObjectPropertyBaseClass:
                return CopyUInt32ToOutData(kAudioObjectClassID, inDataSize, outDataSize, outData);
            case kAudioObjectPropertyClass:
                return CopyUInt32ToOutData(kAudioStreamClassID, inDataSize, outDataSize, outData);
            case kAudioObjectPropertyOwner:
                return CopyUInt32ToOutData(kObjectID_Device, inDataSize, outDataSize, outData);
            case kAudioObjectPropertyName:
                return CopyCFStringToOutData(IsInputStreamObject(inObjectID) ? kInputStreamName : kOutputStreamName, inDataSize, outDataSize, outData);
            case kAudioStreamPropertyDirection:
                return CopyUInt32ToOutData(IsInputStreamObject(inObjectID) ? 1 : 0, inDataSize, outDataSize, outData);
            case kAudioStreamPropertyTerminalType:
                return CopyUInt32ToOutData(IsInputStreamObject(inObjectID) ? kAudioStreamTerminalTypeMicrophone : kAudioStreamTerminalTypeSpeaker, inDataSize, outDataSize, outData);
            case kAudioStreamPropertyStartingChannel:
                return CopyUInt32ToOutData(1, inDataSize, outDataSize, outData);
            case kAudioStreamPropertyLatency:
                return CopyUInt32ToOutData(0, inDataSize, outDataSize, outData);
            case kAudioStreamPropertyVirtualFormat:
            case kAudioStreamPropertyPhysicalFormat: {
                if (inDataSize < sizeof(AudioStreamBasicDescription) || outData == nullptr) {
                    return kAudioHardwareBadPropertySizeError;
                }
                *reinterpret_cast<AudioStreamBasicDescription*>(outData) = MakeFormat(gState.sampleRate);
                *outDataSize = sizeof(AudioStreamBasicDescription);
                return noErr;
            }
            case kAudioStreamPropertyAvailableVirtualFormats:
            case kAudioStreamPropertyAvailablePhysicalFormats: {
                if (inDataSize < sizeof(AudioStreamRangedDescription) || outData == nullptr) {
                    return kAudioHardwareBadPropertySizeError;
                }
                AudioStreamRangedDescription description = MakeRangedFormat(gState.sampleRate);
                if (kEnableDriverDebugLogs) {
                    os_log_error(OS_LOG_DEFAULT,
                                 "MicBridge stream format obj=%u selector=%u sampleRate=%f",
                                 inObjectID, inAddress->mSelector, description.mFormat.mSampleRate);
                }
                *reinterpret_cast<AudioStreamRangedDescription*>(outData) = description;
                *outDataSize = sizeof(AudioStreamRangedDescription);
                return noErr;
            }
            default:
                return kAudioHardwareUnknownPropertyError;
        }
    }

    return kAudioHardwareBadObjectError;
}

OSStatus MicBridge_SetPropertyData(AudioServerPlugInDriverRef /*inDriver*/, AudioObjectID inObjectID, pid_t /*inClientProcessID*/, const AudioObjectPropertyAddress* inAddress, UInt32 /*inQualifierDataSize*/, const void* /*inQualifierData*/, UInt32 inDataSize, const void* inData) {
    if (!IsDeviceObject(inObjectID) || inAddress == nullptr || inData == nullptr) {
        return kAudioHardwareIllegalOperationError;
    }

    if (inAddress->mSelector == kAudioDevicePropertyNominalSampleRate) {
        if (inDataSize < sizeof(Float64)) {
            return kAudioHardwareBadPropertySizeError;
        }

        Float64 requestedRate = *reinterpret_cast<const Float64*>(inData);
        if (requestedRate != kDefaultSampleRate) {
            return kAudioHardwareIllegalOperationError;
        }

        std::lock_guard<std::mutex> lock(gState.configMutex);
        gState.sampleRate = requestedRate;
        gState.zeroTimestampSeed.fetch_add(1);

        AudioObjectPropertyAddress deviceChanged = {kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
        AudioObjectPropertyAddress streamChanged[] = {
            {kAudioStreamPropertyVirtualFormat, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain},
            {kAudioStreamPropertyPhysicalFormat, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain}
        };

        NotifyPropertiesChanged(kObjectID_Device, 1, &deviceChanged);
        NotifyPropertiesChanged(kObjectID_Stream_Input, 2, streamChanged);
        NotifyPropertiesChanged(kObjectID_Stream_Output, 2, streamChanged);
        return noErr;
    }

    if (inAddress->mSelector == kAudioDevicePropertyBufferFrameSize) {
        if (inDataSize < sizeof(UInt32)) {
            return kAudioHardwareBadPropertySizeError;
        }

        UInt32 requestedSize = *reinterpret_cast<const UInt32*>(inData);
        if (requestedSize < kMinBufferFrameSize || requestedSize > kMaxBufferFrameSize) {
            return kAudioHardwareIllegalOperationError;
        }

        std::lock_guard<std::mutex> lock(gState.configMutex);
        gState.bufferFrameSize = requestedSize;
        gState.zeroTimestampSeed.fetch_add(1);

        AudioObjectPropertyAddress changed = {kAudioDevicePropertyBufferFrameSize, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
        NotifyPropertiesChanged(kObjectID_Device, 1, &changed);
        return noErr;
    }

    return kAudioHardwareUnknownPropertyError;
}

OSStatus MicBridge_StartIO(AudioServerPlugInDriverRef /*inDriver*/, AudioObjectID inDeviceObjectID, UInt32 /*inClientID*/) {
    if (!IsDeviceObject(inDeviceObjectID)) {
        return kAudioHardwareBadObjectError;
    }

    gState.ioClients.fetch_add(1);
    return noErr;
}

OSStatus MicBridge_StopIO(AudioServerPlugInDriverRef /*inDriver*/, AudioObjectID inDeviceObjectID, UInt32 /*inClientID*/) {
    if (!IsDeviceObject(inDeviceObjectID)) {
        return kAudioHardwareBadObjectError;
    }

    UInt32 clients = gState.ioClients.load();
    if (clients > 0) {
        gState.ioClients.fetch_sub(1);
    }
    return noErr;
}

OSStatus MicBridge_GetZeroTimeStamp(AudioServerPlugInDriverRef /*inDriver*/, AudioObjectID inDeviceObjectID, UInt32 /*inClientID*/, Float64* outSampleTime, UInt64* outHostTime, UInt64* outSeed) {
    if (!IsDeviceObject(inDeviceObjectID) || outSampleTime == nullptr || outHostTime == nullptr || outSeed == nullptr) {
        return kAudioHardwareIllegalOperationError;
    }

    UInt64 hostNow = AudioGetCurrentHostTime();
    UInt64 anchor = gState.anchorHostTime.load();
    Float64 hostFrequency = AudioGetHostClockFrequency();

    std::lock_guard<std::mutex> lock(gState.configMutex);
    Float64 sampleRate = gState.sampleRate;
    UInt32 period = ZeroTimestampPeriodFramesForSampleRate(sampleRate);

    Float64 elapsedSeconds = static_cast<Float64>(hostNow - anchor) / hostFrequency;
    Float64 elapsedFrames = std::floor(elapsedSeconds * sampleRate);
    UInt64 elapsedFramesInt = static_cast<UInt64>(std::max<Float64>(0.0, elapsedFrames));
    UInt64 periodCount = elapsedFramesInt / static_cast<UInt64>(period);
    UInt64 quantizedFrames = periodCount * static_cast<UInt64>(period);

    *outSampleTime = static_cast<Float64>(quantizedFrames);
    *outHostTime = anchor + static_cast<UInt64>((static_cast<Float64>(quantizedFrames) / sampleRate) * hostFrequency);
    *outSeed = gState.zeroTimestampSeed.load() + periodCount;
    return noErr;
}

OSStatus MicBridge_WillDoIOOperation(AudioServerPlugInDriverRef /*inDriver*/, AudioObjectID inDeviceObjectID, UInt32 /*inClientID*/, UInt32 inOperationID, Boolean* outWillDo, Boolean* outWillDoInPlace) {
    if (!IsDeviceObject(inDeviceObjectID) || outWillDo == nullptr || outWillDoInPlace == nullptr) {
        return kAudioHardwareIllegalOperationError;
    }

    if (inOperationID == kAudioServerPlugInIOOperationReadInput || inOperationID == kAudioServerPlugInIOOperationWriteMix) {
        *outWillDo = true;
        *outWillDoInPlace = true;
        return noErr;
    }

    *outWillDo = false;
    *outWillDoInPlace = true;
    return noErr;
}

OSStatus MicBridge_BeginIOOperation(AudioServerPlugInDriverRef /*inDriver*/, AudioObjectID inDeviceObjectID, UInt32 /*inClientID*/, UInt32 /*inOperationID*/, UInt32 /*inIOBufferFrameSize*/, const AudioServerPlugInIOCycleInfo* /*inIOCycleInfo*/) {
    if (IsDeviceObject(inDeviceObjectID)) {
        return noErr;
    }
    return kAudioHardwareBadObjectError;
}

OSStatus MicBridge_DoIOOperation(AudioServerPlugInDriverRef /*inDriver*/, AudioObjectID inDeviceObjectID, AudioObjectID inStreamObjectID, UInt32 /*inClientID*/, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* /*inIOCycleInfo*/, void* ioMainBuffer, void* /*ioSecondaryBuffer*/) {
    if (!IsDeviceObject(inDeviceObjectID)) {
        return kAudioHardwareBadObjectError;
    }

    if (ioMainBuffer == nullptr || inIOBufferFrameSize == 0) {
        return noErr;
    }

    auto* buffer = reinterpret_cast<Float32*>(ioMainBuffer);

    if (inOperationID == kAudioServerPlugInIOOperationWriteMix && IsOutputStreamObject(inStreamObjectID)) {
        WriteRing(buffer, inIOBufferFrameSize);
        return noErr;
    }

    if (inOperationID == kAudioServerPlugInIOOperationReadInput && IsInputStreamObject(inStreamObjectID)) {
        ReadRing(buffer, inIOBufferFrameSize);
        return noErr;
    }

    return noErr;
}

OSStatus MicBridge_EndIOOperation(AudioServerPlugInDriverRef /*inDriver*/, AudioObjectID inDeviceObjectID, UInt32 /*inClientID*/, UInt32 /*inOperationID*/, UInt32 /*inIOBufferFrameSize*/, const AudioServerPlugInIOCycleInfo* /*inIOCycleInfo*/) {
    if (IsDeviceObject(inDeviceObjectID)) {
        return noErr;
    }
    return kAudioHardwareBadObjectError;
}

}  // namespace

extern "C" void* MicBridgePlugInFactory(CFAllocatorRef /*inAllocator*/, CFUUIDRef inRequestedTypeUUID) {
    if (inRequestedTypeUUID == nullptr) {
        return nullptr;
    }

    if (!CFEqual(inRequestedTypeUUID, kAudioServerPlugInTypeUUID)) {
        return nullptr;
    }

    MicBridge_AddRef(&gDriverInterfacePtr);
    return &gDriverInterfacePtr;
}
