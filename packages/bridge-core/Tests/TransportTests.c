#include "BridgeRT.h"
#include <assert.h>
#include <math.h>
#include <pthread.h>
#include <stdio.h>
#include <sched.h>
static void *produce(void *handle) {
    MBTransport *p=handle; float samples[256];
    for(int block=0;block<10000;block++) {
        for(int i=0;i<256;i++) samples[i]=block*256+i;
        while(mb_fill(p)>4096-256) sched_yield();
        assert(mb_write(p,samples,256)==256);
    }
    return NULL;
}
int main(void) {
    MBTransport *p=mb_create(1,4096); assert(p);
    pthread_t producer; pthread_create(&producer,NULL,produce,p);
    float out[512]; int total=0;
    while(total<2560000) {
        int n=mb_read(p,out,512);
        for(int i=0;i<n;i++) assert(out[i]==total+i);
        total+=n;
    }
    pthread_join(producer,NULL); mb_destroy(p);
    for(int drift=-500;drift<=500;drift+=500) {
        p=mb_create(1,48000); assert(p);
        double inputFrames=0; long generated=0; float in[1600];
        uint64_t startupUnderflow=0; double energy=0; long samples=0;
        for(int block=0;block<12000;block++) {
            inputFrames+=512*(1+drift/1e6);
            // Delay one physical capture callback, then deliver its backlog.
            if(block>20 && block%1000==500) {
                int received=mb_read_adaptive(p,out,512,48000);
                assert(received==512);
                continue;
            }
            int n=(int)inputFrames; inputFrames-=n;
            for(int i=0;i<n;i++) in[i]=(float)(0.25*sin(2*M_PI*997*(generated+i)/48000));
            generated+=n; assert(mb_write(p,in,n)==n);
            int received=mb_read_adaptive(p,out,512,48000);
            if(block==20) startupUnderflow=mb_metrics(p).underflow;
            if(block>20) { assert(received==512); for(int i=0;i<received;i++) { energy+=out[i]*out[i];samples++; } }
        }
        MBMetrics m=mb_metrics(p);
        printf("drift=%dppm correction=%.1fppm fill=%d dropped=%llu underflow=%llu rms=%.8f\n",
            drift,m.correctionPPM,mb_fill(p),(unsigned long long)m.dropped,(unsigned long long)m.underflow,sqrt(energy/samples));
        assert(m.dropped==0 && m.underflow==startupUnderflow);
        assert(fabs(sqrt(energy/samples)-0.25/sqrt(2))<0.0001);
        assert(fabs(m.correctionPPM-drift)<150);
        assert(mb_fill(p)<3072);
        mb_destroy(p);
    }
    puts("Concurrent transport and simulated 128-second clock drift checks passed");
}
