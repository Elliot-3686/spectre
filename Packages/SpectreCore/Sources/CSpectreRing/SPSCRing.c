#include "SPSCRing.h"

#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

struct SPSCRing {
    float *buffer;
    uint32_t capacity;
    uint32_t mask;
    _Atomic uint64_t writeIndex;
    _Atomic uint64_t readIndex;
    _Atomic int notified;
    _Atomic uint64_t dropped;
};

SPSCRing *spsc_create(uint32_t minimumCapacity) {
    uint32_t capacity = 1024;
    while (capacity < minimumCapacity && capacity < (1u << 30)) capacity <<= 1;
    SPSCRing *ring = (SPSCRing *)calloc(1, sizeof(SPSCRing));
    if (!ring) return NULL;
    ring->buffer = (float *)calloc(capacity, sizeof(float));
    if (!ring->buffer) { free(ring); return NULL; }
    ring->capacity = capacity;
    ring->mask = capacity - 1;
    atomic_init(&ring->writeIndex, 0);
    atomic_init(&ring->readIndex, 0);
    atomic_init(&ring->notified, 0);
    atomic_init(&ring->dropped, 0);
    return ring;
}

void spsc_destroy(SPSCRing *ring) {
    if (!ring) return;
    free(ring->buffer);
    free(ring);
}

static inline uint32_t spsc_space(SPSCRing *ring, uint64_t w) {
    uint64_t r = atomic_load_explicit(&ring->readIndex, memory_order_acquire);
    return ring->capacity - (uint32_t)(w - r);
}

static inline int spsc_publish(SPSCRing *ring, uint64_t w, uint32_t threshold) {
    atomic_store_explicit(&ring->writeIndex, w, memory_order_release);
    uint64_t r = atomic_load_explicit(&ring->readIndex, memory_order_acquire);
    if ((w - r) >= threshold &&
        !atomic_exchange_explicit(&ring->notified, 1, memory_order_acq_rel)) {
        return 1;
    }
    return 0;
}

static inline uint32_t spsc_clamp(SPSCRing *ring, uint64_t w, uint32_t count) {
    uint32_t space = spsc_space(ring, w);
    if (count > space) {
        atomic_fetch_add_explicit(&ring->dropped, count - space, memory_order_relaxed);
        count = space;
    }
    return count;
}

int spsc_write(SPSCRing *ring, const float *src, uint32_t count, uint32_t threshold) {
    uint64_t w = atomic_load_explicit(&ring->writeIndex, memory_order_relaxed);
    count = spsc_clamp(ring, w, count);
    uint32_t index = (uint32_t)(w & ring->mask);
    uint32_t first = ring->capacity - index;
    if (first > count) first = count;
    memcpy(ring->buffer + index, src, (size_t)first * sizeof(float));
    if (count > first) memcpy(ring->buffer, src + first, (size_t)(count - first) * sizeof(float));
    return spsc_publish(ring, w + count, threshold);
}

int spsc_write_mix(SPSCRing *ring, const float *const *channels, uint32_t channelCount,
                   uint32_t frames, uint32_t threshold) {
    if (channelCount == 0) return 0;
    if (channelCount == 1) return spsc_write(ring, channels[0], frames, threshold);
    uint64_t w = atomic_load_explicit(&ring->writeIndex, memory_order_relaxed);
    frames = spsc_clamp(ring, w, frames);
    const float gain = 1.0f / (float)channelCount;
    for (uint32_t i = 0; i < frames; i++) {
        float s = 0.0f;
        for (uint32_t c = 0; c < channelCount; c++) s += channels[c][i];
        ring->buffer[(uint32_t)((w + i) & ring->mask)] = s * gain;
    }
    return spsc_publish(ring, w + frames, threshold);
}

int spsc_write_interleaved_mix(SPSCRing *ring, const float *src, uint32_t channelCount,
                               uint32_t frames, uint32_t threshold) {
    if (channelCount <= 1) return spsc_write(ring, src, frames, threshold);
    uint64_t w = atomic_load_explicit(&ring->writeIndex, memory_order_relaxed);
    frames = spsc_clamp(ring, w, frames);
    const float gain = 1.0f / (float)channelCount;
    for (uint32_t i = 0; i < frames; i++) {
        float s = 0.0f;
        const float *frame = src + (size_t)i * channelCount;
        for (uint32_t c = 0; c < channelCount; c++) s += frame[c];
        ring->buffer[(uint32_t)((w + i) & ring->mask)] = s * gain;
    }
    return spsc_publish(ring, w + frames, threshold);
}

uint32_t spsc_available(SPSCRing *ring) {
    uint64_t w = atomic_load_explicit(&ring->writeIndex, memory_order_acquire);
    uint64_t r = atomic_load_explicit(&ring->readIndex, memory_order_relaxed);
    return (uint32_t)(w - r);
}

uint32_t spsc_read(SPSCRing *ring, float *dst, uint32_t count) {
    uint64_t w = atomic_load_explicit(&ring->writeIndex, memory_order_acquire);
    uint64_t r = atomic_load_explicit(&ring->readIndex, memory_order_relaxed);
    uint32_t available = (uint32_t)(w - r);
    if (count > available) count = available;
    uint32_t index = (uint32_t)(r & ring->mask);
    uint32_t first = ring->capacity - index;
    if (first > count) first = count;
    memcpy(dst, ring->buffer + index, (size_t)first * sizeof(float));
    if (count > first) memcpy(dst + first, ring->buffer, (size_t)(count - first) * sizeof(float));
    atomic_store_explicit(&ring->readIndex, r + count, memory_order_release);
    return count;
}

uint32_t spsc_skip(SPSCRing *ring, uint32_t count) {
    uint64_t w = atomic_load_explicit(&ring->writeIndex, memory_order_acquire);
    uint64_t r = atomic_load_explicit(&ring->readIndex, memory_order_relaxed);
    uint32_t available = (uint32_t)(w - r);
    if (count > available) count = available;
    atomic_store_explicit(&ring->readIndex, r + count, memory_order_release);
    return count;
}

void spsc_clear_notify(SPSCRing *ring) {
    atomic_store_explicit(&ring->notified, 0, memory_order_release);
}

uint64_t spsc_dropped(SPSCRing *ring) {
    return atomic_load_explicit(&ring->dropped, memory_order_relaxed);
}

void spsc_reset(SPSCRing *ring) {
    atomic_store(&ring->writeIndex, 0);
    atomic_store(&ring->readIndex, 0);
    atomic_store(&ring->notified, 0);
}
