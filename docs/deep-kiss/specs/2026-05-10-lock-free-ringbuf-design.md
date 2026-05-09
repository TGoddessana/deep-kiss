# Lock-Free Ring Buffer Design
## Single-Producer Single-Consumer (SPSC) for Kernel-Userspace IPC

**Date:** 2026-05-10  
**Status:** Design Approved  
**Scope:** Linux kernel module, interrupt-safe ring buffer for IPC

---

## 1. Problem and Constraints

### Problem
A Linux kernel module (interrupt handler context) must communicate with a user-space daemon using a ring buffer. The interrupt handler runs in hard IRQ context where spinlocks cannot be used, requiring a completely lock-free synchronization mechanism.

### Key Constraints
- **Context:** Interrupt handler (hard IRQ) → user-space daemon (normal process context)
- **Pattern:** Single Producer (interrupt handler) / Single Consumer (user-space daemon) = SPSC
- **Buffer Shape:** Power-of-2 entries (1024), fixed 64-byte entry size
- **Zero-Copy Access:** User-space must see the buffer via `mmap()` on a character device
- **Memory Ordering:** Must use `smp_store_release()` / `smp_load_acquire()` to enforce correct ordering across CPU cores
- **Target Kernel:** Linux 5.x+

### Success Criteria
1. Interrupt handler can enqueue messages without blocking or spinning
2. User-space daemon reads enqueued messages with zero-copy semantics (mmap)
3. No race conditions across CPU cores (verified by memory-ordering primitives)
4. Clear boundary: buffer logic is independent, no external dependencies

---

## 2. Architecture Overview

### Isolated Unit Design
The implementation lives in two files (`lf_ringbuf.h` / `lf_ringbuf.c`) with:
- **Zero external dependencies** beyond Linux kernel headers
- **Single responsibility:** SPSC lock-free ring buffer with atomic head/tail counters
- **Clear interface:** 3–4 public functions (init, enqueue, dequeue, metadata)

### Data Layout

```
Shared Memory (mmap'd by user-space):
┌─────────────────────────────────────────────┐
│ struct lf_ringbuf_header                    │
│   - uint32_t head (read index)              │
│   - uint32_t tail (write index)             │
│   - uint32_t capacity                       │
│   - uint32_t entry_size                     │
│   - uint32_t [padding]                      │
│   - uint64_t dropped (overrun counter)      │
└─────────────────────────────────────────────┘
│ Entry 0 (64 bytes)                          │
│ Entry 1 (64 bytes)                          │
│ ...                                         │
│ Entry 1023 (64 bytes)                       │
└─────────────────────────────────────────────┘
```

All fields aligned to cache-line boundaries to avoid false sharing.

### Synchronization Model

**Write Path (Interrupt Handler):**
1. Load current `tail` with no ordering constraint
2. Calculate next index: `next_tail = (tail + 1) & (capacity - 1)` (no modulo division)
3. Check if `next_tail == head`; if true, drop message and increment `dropped` counter (atomic_inc)
4. Write entry data into buffer at `entries[tail]`
5. **Release:** `smp_store_release(&header->tail, next_tail)` — signals to consumer that entry is ready

**Read Path (User-space Daemon):**
1. **Acquire:** `smp_load_acquire(&header->tail)` — ensures we see all prior writes from producer
2. If `tail == head`, no entries available, return empty
3. Read entry data from `entries[head]`
4. Increment head: `head = (head + 1) & (capacity - 1)`
5. Update `header->head` (local write, no special ordering needed since only consumer touches it)

**Rationale:**
- **smp_store_release on write:** Ensures the entry is fully written before the tail pointer is visible to the reader
- **smp_load_acquire on read:** Ensures we see the tail update and all prior entry writes before proceeding
- **Power-of-2 modulo:** `& (capacity - 1)` is cheaper than `% capacity` and always works (no branch prediction penalty)
- **Per-CPU atomicity:** Because it is SPSC, the only shared fields are `tail` (written by producer, read by consumer) and `head` (written by consumer, read by producer for overflow check)

---

## 3. Components and Interfaces

### Header File: `lf_ringbuf.h`

```c
#ifndef LF_RINGBUF_H
#define LF_RINGBUF_H

#include <linux/types.h>
#include <linux/atomic.h>

/* Fixed sizes */
#define LF_RINGBUF_ENTRY_SIZE  64
#define LF_RINGBUF_CAPACITY    1024

/* Shared memory header (user-space and kernel can both see) */
struct lf_ringbuf_header {
    atomic_t head;          /* Consumer read index */
    atomic_t tail;          /* Producer write index */
    uint32_t capacity;      /* Number of entries (always 1024) */
    uint32_t entry_size;    /* Size of each entry (always 64) */
    uint32_t _pad1;
    atomic64_t dropped;     /* Overrun counter */
    /* Pad to cache line to prevent false sharing */
    char _pad2[64 - sizeof(struct { atomic_t; atomic_t; uint32_t; uint32_t; uint32_t; atomic64_t; })];
};

/* Full ring buffer (kernel private) */
struct lf_ringbuf {
    struct lf_ringbuf_header *header;
    void *entries;          /* Base of entry array */
};

/* Initialize ring buffer in pre-allocated kernel memory */
int lf_ringbuf_init(struct lf_ringbuf *rb, void *mem, size_t mem_size);

/* Enqueue from interrupt handler context (lock-free) */
int lf_ringbuf_enqueue(struct lf_ringbuf *rb, const void *entry);

/* Return total size of shared memory region (header + all entries) */
size_t lf_ringbuf_shm_size(void);

/* Dequeue from user-space context (optional, for validation) */
int lf_ringbuf_dequeue(struct lf_ringbuf *rb, void *entry);

#endif /* LF_RINGBUF_H */
```

### Implementation File: `lf_ringbuf.c`

**Key functions:**

- `lf_ringbuf_init()` — Validates memory layout, initializes atomic counters to 0
- `lf_ringbuf_enqueue()` — Load tail, check overflow, write entry, release-store new tail
- `lf_ringbuf_dequeue()` — Load-acquire tail, check empty, read entry, update head
- `lf_ringbuf_shm_size()` — Returns `sizeof(header) + (capacity * entry_size)`

**Error handling:**
- Enqueue returns `-EAGAIN` if full (producer drops silently but counts it in `dropped`)
- Dequeue returns `-ENODATA` if empty
- Init returns `-EINVAL` if memory size insufficient

---

## 4. Character Device Integration

The character device exposes the ring buffer to user-space via:

**ioctl commands (example):**
- `IOCTL_LF_RINGBUF_GET_SIZE` — returns `lf_ringbuf_shm_size()`
- `IOCTL_LF_RINGBUF_GET_CAPACITY` — returns capacity and entry size

**mmap() callback:**
- Maps the shared memory (header + entries) into user-space VMA
- Pages are marked read-write (write needed for user-space to update `head`)

**User-space access pattern:**
```c
/* In user-space daemon */
fd = open("/dev/mymodule", O_RDWR);
size = ioctl(fd, IOCTL_GET_SIZE);
shm = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);

header = (struct lf_ringbuf_header *)shm;
entries = (char *)shm + sizeof(*header);

while (1) {
    uint32_t tail = atomic_load_acquire(&header->tail);
    if (tail == header->head) continue; /* empty */
    
    memcpy(msg, &entries[header->head * 64], 64);
    header->head = (header->head + 1) & (1024 - 1);
}
```

---

## 5. Error Handling and Edge Cases

### Overflow (Producer Full)
- **Behavior:** Interrupt handler checks `(tail + 1) % capacity == head` before writing
- **Action:** If full, increment `dropped` counter (atomic) and return `-EAGAIN` without blocking
- **User-space monitoring:** Daemon reads `dropped` counter periodically to detect message loss
- **No backpressure:** Interrupt handlers cannot block, so silent drop is the only option

### Empty Buffer (Consumer Side)
- **Behavior:** User-space sees `tail == head`, returns immediately without data
- **Action:** Daemon can poll or use `mmap()` + signals, or sleep/usleep in the loop
- **No blocking:** Character device does not provide blocking reads (design choice: keep it simple)

### Stale Tail Update (Visibility)
- **Handled by:** `smp_store_release()` on producer write, `smp_load_acquire()` on consumer read
- **Result:** Across all CPU cores, consumer is guaranteed to see the tail update and all prior entry writes

### Memory Layout Mismatch
- **Risk:** User-space and kernel disagree on header size or entry size
- **Mitigation:** Header includes explicit `capacity` and `entry_size` fields; user-space code validates before use

---

## 6. Testing Strategy

### Unit Tests (Kernel Module)
1. **Init Test:** Verify `lf_ringbuf_init()` correctly initializes header and validates size
2. **Single Enqueue/Dequeue:** Single producer enqueues, consumer dequeues one entry; verify data integrity
3. **Overflow Test:** Fill buffer to capacity, verify next enqueue returns `-EAGAIN` and increments `dropped`
4. **Empty Test:** Dequeue from empty buffer returns `-ENODATA`
5. **Memory Ordering Test (under heavy contention):**
   - Kernel thread enqueues entries rapidly
   - User-space process reads via mmap simultaneously
   - Verify no lost entries (via `dropped` counter) and no corrupted entry data

### Integration Test
- Load module, open character device, mmap ring buffer
- Kernel timer/interrupt enqueues test messages every 1ms
- User-space daemon reads and validates 100+ messages
- Verify order preservation and zero data corruption

### Stress Test
- Enqueue at maximum rate (test interrupt frequency)
- Multiple reads from user-space
- Verify CPU core synchronization (no false sharing visible via perf)

---

## 7. Trade-offs and Cognitive Debt

### What We Give Up
- **No blocking semantics:** Producer drops on overflow, consumer polls. No sleep/wakeup support (would require additional signaling mechanism).
- **Fixed size:** Capacity and entry size are compile-time constants (1024 × 64). Resizing requires module reload.
- **No fairness guarantee:** If user-space is slow, dropped counter may grow (explicit design: producer never waits).

### What We Gain
- **True lock-free:** Interrupt handler never blocks or uses spinlocks. Safe in any context.
- **Zero-copy:** User-space reads directly from mmap, no extra copy.
- **Minimal code:** ~300 lines of C, no external dependencies, fits entirely in L1 cache.
- **Predictable latency:** No spinlock contention, no allocation failures (pre-allocated memory).

### Cognitive Debt
- **Must keep in mind every time you revisit this code:** Memory ordering primitives (`smp_store_release` / `smp_load_acquire`) are critical for correctness. Any change to the write/read paths must preserve the acquire-release semantics or race conditions will occur on multi-core systems. Tests must verify this under contention.

---

## 8. Dependencies and Integration Points

### Kernel Headers Required
- `<linux/types.h>` (uint32_t, uint64_t)
- `<linux/atomic.h>` (atomic_t, atomic64_t, smp_store_release, smp_load_acquire)

### Module Integration
- Character device driver allocates shared memory region via `kzalloc()` or `vmalloc()`
- Passes pointer to `lf_ringbuf_init()`
- Interrupt handler calls `lf_ringbuf_enqueue()` in IRQ context
- Character device mmap callback exposes the memory region

### No External Dependencies
- Does not use kfifo, spinlock, mutex, or workqueue
- Does not allocate/deallocate at runtime
- Self-contained: header + entries + metadata all in one contiguous block

---

## 9. Future Considerations (Out of Scope)

The following are explicitly out of scope for this design:

1. **Multiple producers or consumers:** Would require different synchronization (CAS loops, full memory barriers). This is a SPSC design only.
2. **Resizable capacity:** Would require pointer updates and epoch-based reclamation. Keep fixed-size.
3. **Variable entry size:** All entries are 64 bytes. Padding is the user's responsibility.
4. **Blocking reads/wakeup signals:** User-space can use eventfd or polling. Ring buffer itself stays signal-agnostic.
5. **Persistence across module reload:** Memory is in-kernel; reloading frees it. User-space must expect loss.

---

## 10. Validation Checklist

- [x] SPSC pattern confirmed (single interrupt handler, single user-space daemon)
- [x] Lock-free: no spinlock, no atomic compare-and-swap in hot path
- [x] Memory ordering: `smp_store_release` / `smp_load_acquire` in place
- [x] Power-of-2 modulo: bitwise AND used throughout, no division
- [x] Zero-copy via mmap: shared memory layout documented
- [x] Fixed size (1024 × 64 bytes) vs. dynamic: trade-offs documented
- [x] Overflow handling: drop + counter, no backpressure
- [x] Error codes: `-EAGAIN`, `-ENODATA`, `-EINVAL` defined
- [x] No external dependencies: only Linux kernel headers
- [x] Testing strategy defined: unit, integration, stress tests

---

## Summary

This design delivers a **self-contained, lock-free SPSC ring buffer** for kernel-userspace communication, optimized for interrupt-handler safety and zero-copy data access. The isolated-unit approach keeps the implementation small, testable, and dependency-free. The core decision points are in synchronization (memory-ordering primitives) and overflow handling (silent drop), both explicitly documented.

**Next step:** Implementation plan (writing-plans skill).
