use std::alloc::{GlobalAlloc, Layout, System};
use std::cell::Cell;

thread_local! {
    // A const-initialized native TLS slot lets allocator callbacks check only
    // the current thread without allocating or touching shared atomics.
    static ACTIVE_MEASUREMENT: Cell<*mut AllocationStats> = const {
        Cell::new(std::ptr::null_mut())
    };
}

pub(crate) struct CountingAllocator;

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub(crate) struct AllocationStats {
    pub(crate) allocations: usize,
    pub(crate) requested_bytes: usize,
}

#[global_allocator]
static GLOBAL_ALLOCATOR: CountingAllocator = CountingAllocator;

// SAFETY: Every operation delegates to `System` with the original layout and
// pointer. The added bookkeeping only observes successful allocation results.
unsafe impl GlobalAlloc for CountingAllocator {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        // SAFETY: The caller provides the layout required by `GlobalAlloc`.
        let pointer = unsafe { System.alloc(layout) };
        if !pointer.is_null() {
            record_allocation(layout.size());
        }
        pointer
    }

    unsafe fn alloc_zeroed(&self, layout: Layout) -> *mut u8 {
        // SAFETY: The caller provides the layout required by `GlobalAlloc`.
        let pointer = unsafe { System.alloc_zeroed(layout) };
        if !pointer.is_null() {
            record_allocation(layout.size());
        }
        pointer
    }

    unsafe fn dealloc(&self, pointer: *mut u8, layout: Layout) {
        // SAFETY: The caller guarantees that this pointer and layout describe a
        // live allocation from this allocator.
        unsafe { System.dealloc(pointer, layout) };
    }

    unsafe fn realloc(&self, pointer: *mut u8, layout: Layout, new_size: usize) -> *mut u8 {
        // SAFETY: The caller guarantees that the existing allocation and new
        // size satisfy `GlobalAlloc::realloc`.
        let new_pointer = unsafe { System.realloc(pointer, layout, new_size) };
        if !new_pointer.is_null() {
            record_allocation(new_size);
        }
        new_pointer
    }
}

pub(crate) fn measure<T>(operation: impl FnOnce() -> T) -> (T, AllocationStats) {
    let mut stats = AllocationStats::default();
    let guard = MeasurementGuard::start(&mut stats);
    let output = operation();
    guard.stop();
    (output, stats)
}

fn record_allocation(requested_bytes: usize) {
    let _ = ACTIVE_MEASUREMENT.try_with(|active| {
        let stats = active.get();
        if stats.is_null() {
            return;
        }

        // SAFETY: The pointer refers to `measure`'s stack-local stats for this
        // thread. The guard clears TLS before those stats can be moved or
        // dropped, and nested owner-thread measurements are rejected.
        let stats = unsafe { &mut *stats };
        stats.allocations = stats.allocations.wrapping_add(1);
        stats.requested_bytes = stats.requested_bytes.wrapping_add(requested_bytes);
    });
}

struct MeasurementGuard<'a> {
    active: bool,
    _stats: std::marker::PhantomData<&'a mut AllocationStats>,
}

impl<'a> MeasurementGuard<'a> {
    fn start(stats: &'a mut AllocationStats) -> Self {
        ACTIVE_MEASUREMENT.with(|active| {
            assert!(
                active.get().is_null(),
                "allocation measurements cannot overlap on one thread"
            );
            active.set(stats);
        });
        Self {
            active: true,
            _stats: std::marker::PhantomData,
        }
    }

    fn stop(mut self) {
        ACTIVE_MEASUREMENT.with(|active| active.set(std::ptr::null_mut()));
        self.active = false;
    }
}

impl Drop for MeasurementGuard<'_> {
    fn drop(&mut self) {
        if self.active {
            let _ = ACTIVE_MEASUREMENT.try_with(|active| active.set(std::ptr::null_mut()));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::panic::{catch_unwind, AssertUnwindSafe};
    use std::sync::atomic::{AtomicU8, Ordering};
    use std::sync::Arc;

    fn allocate(layout: Layout) -> *mut u8 {
        // SAFETY: The returned pointer is checked and deallocated with the same layout.
        let pointer = unsafe { GLOBAL_ALLOCATOR.alloc(layout) };
        assert!(!pointer.is_null());
        std::hint::black_box(pointer)
    }

    fn deallocate(pointer: *mut u8, layout: Layout) {
        // SAFETY: `pointer` was returned by this allocator for `layout` and is still live.
        unsafe { GLOBAL_ALLOCATOR.dealloc(pointer, layout) };
    }

    #[test]
    fn noop_measurement_counts_nothing() {
        let (value, stats) = measure(|| std::hint::black_box(42));

        assert_eq!(value, 42);
        assert_eq!(
            stats,
            AllocationStats {
                allocations: 0,
                requested_bytes: 0
            }
        );
    }

    #[test]
    fn measurement_counts_known_allocation_and_requested_bytes() {
        let layout = Layout::from_size_align(37, 8).unwrap();
        let (pointer, stats) = measure(|| allocate(layout));

        assert_eq!(
            stats,
            AllocationStats {
                allocations: 1,
                requested_bytes: 37
            }
        );
        deallocate(pointer, layout);
    }

    #[test]
    fn measurement_excludes_deallocations() {
        let layout = Layout::from_size_align(29, 8).unwrap();
        let pointer = allocate(layout);

        let ((), stats) = measure(|| deallocate(pointer, layout));

        assert_eq!(
            stats,
            AllocationStats {
                allocations: 0,
                requested_bytes: 0
            }
        );
    }

    #[test]
    fn measurement_counts_successful_reallocation_at_the_new_size() {
        let old_layout = Layout::from_size_align(17, 8).unwrap();
        let pointer = allocate(old_layout);
        let (new_pointer, stats) = measure(|| {
            // SAFETY: `pointer` is live for `old_layout`; 53 is a valid new size.
            let pointer = unsafe { GLOBAL_ALLOCATOR.realloc(pointer, old_layout, 53) };
            assert!(!pointer.is_null());
            std::hint::black_box(pointer)
        });

        assert_eq!(
            stats,
            AllocationStats {
                allocations: 1,
                requested_bytes: 53
            }
        );
        deallocate(new_pointer, Layout::from_size_align(53, 8).unwrap());
    }

    #[test]
    fn measurement_rejects_overlap_on_the_owner_thread() {
        let result = catch_unwind(AssertUnwindSafe(|| measure(|| measure(|| ()))));

        assert!(result.is_err());
    }

    #[test]
    fn measurement_recovers_after_the_measured_operation_panics() {
        let result = catch_unwind(AssertUnwindSafe(|| measure(|| panic!("expected panic"))));
        assert!(result.is_err());

        let (_, stats) = measure(|| ());
        assert_eq!(
            stats,
            AllocationStats {
                allocations: 0,
                requested_bytes: 0
            }
        );
    }

    #[test]
    fn measurement_excludes_allocations_from_unrelated_threads() {
        let state = Arc::new(AtomicU8::new(0));
        let worker = {
            let state = Arc::clone(&state);
            std::thread::spawn(move || {
                while state.load(Ordering::Acquire) != 1 {
                    std::hint::spin_loop();
                }
                let layout = Layout::from_size_align(41, 8).unwrap();
                let pointer = allocate(layout);
                state.store(2, Ordering::Release);
                deallocate(pointer, layout);
            })
        };

        let (_, stats) = measure(|| {
            state.store(1, Ordering::Release);
            while state.load(Ordering::Acquire) != 2 {
                std::hint::spin_loop();
            }
        });
        worker.join().unwrap();

        assert_eq!(
            stats,
            AllocationStats {
                allocations: 0,
                requested_bytes: 0
            }
        );
    }
}
