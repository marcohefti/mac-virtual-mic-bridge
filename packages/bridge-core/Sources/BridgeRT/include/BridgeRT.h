#ifndef BRIDGE_RT_H
#define BRIDGE_RT_H
#include <stdint.h>
#include <stddef.h>
typedef struct MBTransport MBTransport;
typedef struct {
    uint64_t written, consumed, underflow, dropped, inputCalls, outputCalls, errors;
    float inputPeak, outputPeak;
    int32_t lastError;
    double correctionPPM;
} MBMetrics;
MBTransport *mb_create(int channels, int capacity);
void mb_destroy(MBTransport *p);
void mb_clear(MBTransport *p); // only with both audio callbacks stopped
int mb_write(MBTransport *p, const float *input, int frames);
int mb_read_adaptive(MBTransport *p, float *output, int frames, double sampleRate);
int mb_read(MBTransport *p, float *output, int frames);
int mb_fill(MBTransport *p);
int mb_trim(MBTransport *p, int high, int target); // consumer only
void mb_observe(MBTransport *p, const float *input, int frames);
void mb_error(MBTransport *p, int32_t error);
MBMetrics mb_metrics(MBTransport *p);
#endif
