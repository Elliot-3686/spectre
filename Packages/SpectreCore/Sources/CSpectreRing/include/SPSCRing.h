#ifndef SPSC_RING_H
#define SPSC_RING_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Opaque lock-free single-producer / single-consumer float ring buffer.
/// The producer side (spsc_write*) is real-time safe: no locks, no allocation.
typedef struct SPSCRing SPSCRing;

SPSCRing *spsc_create(uint32_t minimumCapacity);
void spsc_destroy(SPSCRing *ring);

/// Producer. Writes `count` mono samples (drops what does not fit).
/// Returns 1 when the consumer should be woken up (at least `threshold`
/// samples are readable and the consumer has not been notified yet).
int spsc_write(SPSCRing *ring, const float *src, uint32_t count, uint32_t threshold);

/// Producer. Mixes `channelCount` non-interleaved channels down to mono (average).
int spsc_write_mix(SPSCRing *ring, const float *const *channels, uint32_t channelCount,
                   uint32_t frames, uint32_t threshold);

/// Producer. Mixes an interleaved buffer down to mono (average).
int spsc_write_interleaved_mix(SPSCRing *ring, const float *src, uint32_t channelCount,
                               uint32_t frames, uint32_t threshold);

/// Consumer.
uint32_t spsc_available(SPSCRing *ring);
uint32_t spsc_read(SPSCRing *ring, float *dst, uint32_t count);
uint32_t spsc_skip(SPSCRing *ring, uint32_t count);
/// Consumer: call before draining so that the next write crossing the
/// threshold wakes the consumer again.
void spsc_clear_notify(SPSCRing *ring);

uint64_t spsc_dropped(SPSCRing *ring);
/// Only call when neither side is running.
void spsc_reset(SPSCRing *ring);

#ifdef __cplusplus
}
#endif

#endif
