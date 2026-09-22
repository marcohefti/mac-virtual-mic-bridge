#include "BridgeRT.h"
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
// One capture producer, one render consumer. Telemetry never owns a cursor.
// Release/acquire publication prevents reading storage before it is complete,
// and prevents producer reuse until the consumer has finished copying.
struct MBTransport {
    int channels, capacity;
    float *samples;
    float *sincTable;
    double phase, ratio;
    int primed;
    _Atomic double correctionPPM;
    _Atomic uint64_t writeIndex, readIndex;
    _Atomic uint64_t written, consumed, underflow, dropped, inputCalls, outputCalls, errors;
    _Atomic float inputPeak, outputPeak;
    _Atomic int32_t lastError;
};
MBTransport *mb_create(int channels, int capacity) {
    if (channels < 1 || capacity < 1) return NULL;
    MBTransport *p = calloc(1, sizeof(*p));
    if (!p) return NULL;
    p->channels = channels; p->capacity = capacity;
    p->samples = calloc((size_t)channels * capacity, sizeof(float));
    if (!p->samples) { free(p); return NULL; }
    if (!atomic_is_lock_free(&p->writeIndex) || !atomic_is_lock_free(&p->inputPeak)) {
        free(p->samples); free(p); return NULL;
    }
    p->sincTable = calloc(1025 * 32, sizeof(float));
    if (!p->sincTable) { free(p->samples); free(p); return NULL; }
    for (int phase=0; phase<=1024; phase++) {
        double sum=0;
        for (int tap=0;tap<32;tap++) {
            double x=tap-15-(double)phase/1024;
            double weight=(fabs(x)<1e-12 ? 1 : sin(M_PI*x)/(M_PI*x)) * (0.5+0.5*cos(M_PI*x/16));
            p->sincTable[phase*32+tap]=(float)weight; sum+=weight;
        }
        for(int tap=0;tap<32;tap++) p->sincTable[phase*32+tap]/=(float)sum;
    }
    p->ratio=1;
    return p;
}
void mb_destroy(MBTransport *p) { if (p) { free(p->samples); free(p->sincTable); free(p); } }
void mb_clear(MBTransport *p) {
    atomic_store(&p->writeIndex, 0); atomic_store(&p->readIndex, 0);
    p->primed=0; p->phase=0; p->ratio=1;
    atomic_store(&p->correctionPPM,0);
    atomic_store(&p->inputPeak, 0); atomic_store(&p->outputPeak, 0);
}
int mb_fill(MBTransport *p) {
    uint64_t r = atomic_load_explicit(&p->readIndex, memory_order_acquire);
    uint64_t w = atomic_load_explicit(&p->writeIndex, memory_order_acquire);
    return w >= r ? (int)fmin(w-r, p->capacity) : 0;
}
int mb_write(MBTransport *p, const float *input, int frames) {
    if (frames <= 0) return 0;
    uint64_t w = atomic_load_explicit(&p->writeIndex, memory_order_relaxed);
    uint64_t r = atomic_load_explicit(&p->readIndex, memory_order_acquire);
    int count = (int)fmin(frames, p->capacity - (w-r));
    float peak=0;
    for (int i=0; i<frames*p->channels; i++) peak=fmaxf(peak, fabsf(input[i]));
    for (int i=0; i<count; i++) memcpy(p->samples+((w+i)%p->capacity)*p->channels,
        input+i*p->channels, p->channels*sizeof(float));
    atomic_store_explicit(&p->writeIndex, w+count, memory_order_release);
    atomic_store_explicit(&p->inputPeak, peak, memory_order_relaxed);
    atomic_fetch_add_explicit(&p->inputCalls, 1, memory_order_relaxed);
    atomic_fetch_add_explicit(&p->written, count, memory_order_relaxed);
    atomic_fetch_add_explicit(&p->dropped, frames-count, memory_order_relaxed);
    return count;
}
int mb_read(MBTransport *p, float *output, int frames) {
    if (frames <= 0) return 0;
    uint64_t r=atomic_load_explicit(&p->readIndex, memory_order_relaxed);
    uint64_t w=atomic_load_explicit(&p->writeIndex, memory_order_acquire);
    int count=(int)fmin(frames, w-r);
    float peak=0;
    for(int i=0;i<count;i++) memcpy(output+i*p->channels,
        p->samples+((r+i)%p->capacity)*p->channels, p->channels*sizeof(float));
    for(int i=0;i<count*p->channels;i++) peak=fmaxf(peak, fabsf(output[i]));
    atomic_store_explicit(&p->readIndex, r+count, memory_order_release);
    atomic_store_explicit(&p->outputPeak, peak, memory_order_relaxed);
    atomic_fetch_add_explicit(&p->outputCalls, 1, memory_order_relaxed);
    atomic_fetch_add_explicit(&p->consumed, count, memory_order_relaxed);
    atomic_fetch_add_explicit(&p->underflow, frames-count, memory_order_relaxed);
    return count;
}
int mb_trim(MBTransport *p,int high,int target) {
    int fill=mb_fill(p); if(fill<=high) return 0;
    int dropped=fill-target;
    atomic_fetch_add_explicit(&p->readIndex,dropped,memory_order_release);
    atomic_fetch_add_explicit(&p->dropped,dropped,memory_order_relaxed);
    return dropped;
}
void mb_error(MBTransport *p,int32_t error) {
    atomic_store_explicit(&p->lastError,error,memory_order_relaxed);
    atomic_fetch_add_explicit(&p->errors,1,memory_order_relaxed);
}
MBMetrics mb_metrics(MBTransport *p) {
    MBMetrics m={0};
#define READ(name) m.name=atomic_load_explicit(&p->name,memory_order_relaxed)
    READ(written); READ(consumed); READ(underflow); READ(dropped);
    READ(correctionPPM); READ(inputCalls); READ(outputCalls); READ(errors); READ(inputPeak); READ(outputPeak); READ(lastError);
#undef READ
    return m;
}

void mb_observe(MBTransport *p, const float *input, int frames) {
    float peak=0;
    for(int i=0;i<frames*p->channels;i++) peak=fmaxf(peak,fabsf(input[i]));
    atomic_store_explicit(&p->inputPeak,peak,memory_order_relaxed);
    atomic_fetch_add_explicit(&p->inputCalls,1,memory_order_relaxed);
}

// Windowed-sinc fractional resampling with a slowly slewed rate. All tables and
// storage are allocated before IO starts. Only the consumer owns phase/ratio.
int mb_read_adaptive(MBTransport *p, float *output, int frames, double sampleRate) {
    const int target=(int)fmax(sampleRate*0.030, frames*3);
    int fill=mb_fill(p);
    if (!p->primed && fill < target+frames+32) {
        atomic_fetch_add_explicit(&p->outputCalls,1,memory_order_relaxed);
        atomic_fetch_add_explicit(&p->underflow,frames,memory_order_relaxed);
        atomic_store_explicit(&p->outputPeak,0,memory_order_relaxed);
        return 0;
    }
    p->primed=1;
    // Exceptional backlog recovery is deliberately separate from normal drift.
    if(fill > (int)fmax(sampleRate*0.080, frames*4)) {
        mb_trim(p,(int)fmax(sampleRate*0.080,frames*4),target+frames+32);
        p->phase=0; fill=mb_fill(p);
    }
    const double desired=1+fmax(-0.002,fmin(0.002,(fill-target-frames-32)*0.000002));
    p->ratio += (desired-p->ratio)*0.002;
    atomic_store_explicit(&p->correctionPPM,(p->ratio-1)*1e6,memory_order_relaxed);
    uint64_t r=atomic_load_explicit(&p->readIndex,memory_order_relaxed);
    uint64_t w=atomic_load_explicit(&p->writeIndex,memory_order_acquire);
    double position=p->phase; int produced=0; float peak=0;
    for(;produced<frames;produced++) {
        int base=(int)position;
        if(r+base+32>w) break;
        double phase=(position-base)*1024;
        int table=(int)phase; float fraction=(float)(phase-table);
        for(int ch=0;ch<p->channels;ch++) {
            double value=0;
            for(int tap=0;tap<32;tap++) {
                float a=p->sincTable[table*32+tap], b=p->sincTable[(table+1)*32+tap];
                value+=p->samples[((r+base+tap)%p->capacity)*p->channels+ch]*(a+(b-a)*fraction);
            }
            output[produced*p->channels+ch]=(float)value;
            peak=fmaxf(peak,fabsf((float)value));
        }
        position+=p->ratio;
    }
    uint64_t consumed=(uint64_t)position;
    p->phase=position-consumed;
    atomic_store_explicit(&p->readIndex,r+consumed,memory_order_release);
    atomic_fetch_add_explicit(&p->outputCalls,1,memory_order_relaxed);
    atomic_fetch_add_explicit(&p->consumed,consumed,memory_order_relaxed);
    atomic_fetch_add_explicit(&p->underflow,frames-produced,memory_order_relaxed);
    atomic_store_explicit(&p->outputPeak,peak,memory_order_relaxed);
    if(produced<frames) p->primed=0;
    return produced;
}
