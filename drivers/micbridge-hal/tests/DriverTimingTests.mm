#include "../src/MicBridgePlugIn.mm"
#include <chrono>
#include <cstdlib>
#include <iostream>
#include <thread>

static void require(bool condition, const char* message) {
    if (!condition) {
        std::cerr << "Driver regression failed: " << message << '\n';
        std::exit(1);
    }
}

int main() {
    // Run the actual driver implementation in isolation, never the system driver.
    gState.anchorHostTime = AudioGetCurrentHostTime();
    gState.zeroTimestampSeed = 7;
    Float64 sampleA = 0, sampleB = 0;
    UInt64 hostA = 0, hostB = 0, seedA = 0, seedB = 0;
    require(MicBridge_GetZeroTimeStamp(nullptr, kObjectID_Device, 0, &sampleA, &hostA, &seedA) == noErr,
            "first timestamp query failed");
    std::this_thread::sleep_for(std::chrono::milliseconds(300));
    require(MicBridge_GetZeroTimeStamp(nullptr, kObjectID_Device, 0, &sampleB, &hostB, &seedB) == noErr,
            "second timestamp query failed");
    require(sampleB > sampleA && hostB > hostA, "timestamps must advance");
    require(seedA == 7 && seedB == seedA, "ordinary clock progress must not signal a timeline reset");
    gState.zeroTimestampSeed.fetch_add(1);
    MicBridge_GetZeroTimeStamp(nullptr, kObjectID_Device, 0, &sampleB, &hostB, &seedB);
    require(seedB == 8, "an explicit clock generation change must reach clients");

    AudioObjectPropertyAddress rateAddress = {kAudioDevicePropertyNominalSampleRate,
        kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    Float64 unchangedRate = kDefaultSampleRate;
    const auto seedBefore = gState.zeroTimestampSeed.load();
    require(MicBridge_SetPropertyData(nullptr, kObjectID_Device, 0, &rateAddress,
        0, nullptr, sizeof(unchangedRate), &unchangedRate) == noErr, "unchanged rate rejected");
    require(gState.zeroTimestampSeed.load() == seedBefore, "unchanged rate must not reset clock");

    auto writeAt = [](Float64 frame, Float32* data) {
        AudioServerPlugInIOCycleInfo cycle{};
        cycle.mOutputTime.mSampleTime = frame;
        return MicBridge_DoIOOperation(nullptr, kObjectID_Device, kObjectID_Stream_Output,
            1, kAudioServerPlugInIOOperationWriteMix, 256, &cycle, data, nullptr);
    };
    auto readAt = [](Float64 frame, Float32* data) {
        AudioServerPlugInIOCycleInfo cycle{};
        cycle.mInputTime.mSampleTime = frame;
        return MicBridge_DoIOOperation(nullptr, kObjectID_Device, kObjectID_Stream_Input,
            2, kAudioServerPlugInIOOperationReadInput, 256, &cycle, data, nullptr);
    };
    Float32 source[256], captured[256];
    for (int frame = 0; frame < 256; ++frame) source[frame] = Float32(frame - 128) / 128;
    require(writeAt(0, source) == noErr && readAt(0, captured) == noErr, "driver loopback failed");
    for (int frame = 0; frame < 256; ++frame) {
        require(source[frame] == captured[frame], "driver altered a sample");
    }
    std::fill_n(source, 256, 0.25f);
    writeAt(256, source);
    std::fill_n(source, 256, -0.75f);
    writeAt(48000, source);
    readAt(48000, captured);
    for (auto sample : captured) require(sample == -0.75f, "reopened capture replayed stale queued audio");
    readAt(48000, captured);
    for (auto sample : captured) require(sample == -0.75f, "a second reader must receive the same timestamped audio");
    readAt(96000, captured);
    for (auto sample : captured) require(sample == 0, "unwritten timestamps must return silence");
    writeAt(48000 + kRingCapacityFrames, source);
    readAt(48000, captured);
    for (auto sample : captured) require(sample == 0, "wrapped storage must not impersonate old timestamps");
    // Exercise concurrent wraparound. A missed frame may be silent, but a reader
    // must never receive a value belonging to a different timestamp.
    std::atomic<bool> begin{false};
    std::thread writer([&] {
        Float32 data[256];
        while (!begin.load(std::memory_order_acquire)) std::this_thread::yield();
        for (int block = 0; block < 2048; ++block) {
            const int first = 200000 + block * 256;
            for (int i = 0; i < 256; ++i) data[i] = Float32(first + i + 1);
            writeAt(first, data);
        }
    });
    begin.store(true, std::memory_order_release);
    for (int block = 0; block < 2048; ++block) {
        const int first = 200000 + block * 256;
        readAt(first, captured);
        for (int i = 0; i < 256; ++i) {
            require(captured[i] == 0 || captured[i] == Float32(first + i + 1),
                    "concurrent ring overwrite returned the wrong sample");
        }
    }
    writer.join();
    // Model the HAL's legal read-before-write callback ordering. Input safety
    // offset must keep the reader behind the current (not yet written) cycle.
    AudioObjectPropertyAddress safetyAddress = {kAudioDevicePropertySafetyOffset,
        kAudioObjectPropertyScopeInput, kAudioObjectPropertyElementMain};
    UInt32 inputSafety = 0, returnedSize = 0;
    require(MicBridge_GetPropertyData(nullptr, kObjectID_Device, 0, &safetyAddress,
        0, nullptr, sizeof(inputSafety), &returnedSize, &inputSafety) == noErr,
        "input safety offset query failed");
    std::fill_n(source, 256, 0.375f);
    for (int frame = 1000000; frame < 1000000 + kMaxBufferFrameSize; frame += 256) writeAt(frame, source);
    for (int frame = 1000000 + kMaxBufferFrameSize; frame < 1000000 + 4 * kMaxBufferFrameSize; frame += 256) {
        readAt(frame - inputSafety, captured);
        for (auto sample : captured) require(sample == 0.375f,
            "read-before-write scheduling must not produce silence");
        writeAt(frame, source);
    }
    std::cout << "Driver timing and sample integrity checks passed\n";
}
