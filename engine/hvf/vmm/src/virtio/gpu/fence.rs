//! Fenced virtio-gpu requests waiting for the renderer (GPU mode).
//!
//! A request with VIRTIO_GPU_FLAG_FENCE is answered only when gfxstream
//! signals its fence: the guest driver signals its dma-fence when the
//! answer arrives. Fences live on rings, the global one or one per context
//! ring (VIRTIO_GPU_FLAG_INFO_RING_IDX); a signal completes every fence on
//! that ring up to its id, in order, and rings are independent.

use std::collections::{HashMap, VecDeque};
use std::time::{Duration, Instant};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Ring {
    Global,
    Context(u32, u8),
}

struct Pending<T> {
    id: u64,
    token: T,
    since: Instant,
}

struct RingState<T> {
    pending: VecDeque<Pending<T>>,
    /// The highest id signalled so far.
    completed: u64,
}

impl<T> Default for RingState<T> {
    fn default() -> Self {
        RingState { pending: VecDeque::new(), completed: 0 }
    }
}

pub struct FenceQueue<T> {
    rings: HashMap<Ring, RingState<T>>,
}

impl<T> Default for FenceQueue<T> {
    fn default() -> Self {
        FenceQueue { rings: HashMap::new() }
    }
}

impl<T> FenceQueue<T> {
    /// Waits for fence `id` on `ring`; gives `token` back right away when
    /// that fence was already signalled.
    pub fn push(&mut self, ring: Ring, id: u64, token: T, now: Instant) -> Option<T> {
        let state = self.rings.entry(ring).or_default();
        if id <= state.completed {
            return Some(token);
        }
        state.pending.push_back(Pending { id, token, since: now });
        None
    }

    /// A fence that nothing will signal (the renderer refused it): done with
    /// the newest one waiting on its ring, so never ahead of it; `token`
    /// back right away when none waits.
    pub fn push_after(&mut self, ring: Ring, token: T, now: Instant) -> Option<T> {
        let Some(state) = self.rings.get_mut(&ring) else { return Some(token) };
        let Some(last) = state.pending.back().map(|p| p.id) else { return Some(token) };
        state.pending.push_back(Pending { id: last, token, since: now });
        None
    }

    /// Fence `id` of `ring` signalled: the tokens of every fence up to it on
    /// that ring, oldest first.
    pub fn signal(&mut self, ring: Ring, id: u64) -> Vec<T> {
        let state = self.rings.entry(ring).or_default();
        state.completed = state.completed.max(id);
        let (done, waiting): (VecDeque<_>, VecDeque<_>) = state.pending.drain(..).partition(|p| p.id <= id);
        state.pending = waiting;
        done.into_iter().map(|p| p.token).collect()
    }

    /// How long the oldest fence has been waiting.
    pub fn oldest(&self, now: Instant) -> Option<Duration> {
        self.oldest_since().map(|since| now.saturating_duration_since(since))
    }

    /// When the oldest waiting fence was pushed.
    pub fn oldest_since(&self) -> Option<Instant> {
        self.rings.values().flat_map(|r| r.pending.iter().map(|p| p.since)).min()
    }

    pub fn len(&self) -> usize {
        self.rings.values().map(|r| r.pending.len()).sum()
    }

    /// Forgets every fence (device reset): their requests are never answered.
    pub fn clear(&mut self) {
        self.rings.clear();
    }

    /// Context `ctx` was destroyed, so nothing signals its rings any more:
    /// drops them and gives back the tokens still waiting there, oldest first.
    pub fn remove_context(&mut self, ctx: u32) -> Vec<T> {
        let mut waiting = Vec::new();
        self.rings.retain(|ring, state| {
            let gone = matches!(ring, Ring::Context(c, _) if *c == ctx);
            if gone {
                waiting.extend(state.pending.drain(..));
            }
            !gone
        });
        waiting.sort_by_key(|p: &Pending<T>| (p.since, p.id));
        waiting.into_iter().map(|p| p.token).collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_signal_completes_its_ring_up_to_its_id_in_order() {
        let now = Instant::now();
        let mut queue = FenceQueue::default();
        let ring = Ring::Context(1, 0);
        for id in [3, 4, 6] {
            assert_eq!(queue.push(ring, id, id, now), None);
        }
        assert_eq!(queue.signal(ring, 4), [3, 4]);
        assert_eq!(queue.len(), 1);
        assert_eq!(queue.signal(ring, 9), [6]);
        assert_eq!(queue.len(), 0);
    }

    #[test]
    fn rings_are_independent() {
        let now = Instant::now();
        let mut queue = FenceQueue::default();
        queue.push(Ring::Global, 1, "global", now);
        queue.push(Ring::Context(1, 0), 2, "ctx 1 ring 0", now);
        queue.push(Ring::Context(1, 1), 3, "ctx 1 ring 1", now);
        queue.push(Ring::Context(2, 0), 4, "ctx 2 ring 0", now);
        assert_eq!(queue.signal(Ring::Context(1, 1), 10), ["ctx 1 ring 1"]);
        assert_eq!(queue.signal(Ring::Global, 10), ["global"]);
        assert_eq!(queue.len(), 2);
    }

    #[test]
    fn a_fence_signalled_before_its_push_completes_at_once() {
        let mut queue = FenceQueue::default();
        assert!(queue.signal(Ring::Global, 5).is_empty());
        assert_eq!(queue.push(Ring::Global, 5, 'a', Instant::now()), Some('a'));
        assert_eq!(queue.push(Ring::Global, 6, 'b', Instant::now()), None);
    }

    #[test]
    fn clear_forgets_fences_and_their_history() {
        let now = Instant::now();
        let mut queue = FenceQueue::default();
        queue.push(Ring::Global, 1, 1, now);
        queue.signal(Ring::Context(1, 0), 50);
        queue.clear();
        assert_eq!(queue.len(), 0);
        assert!(queue.signal(Ring::Global, 1).is_empty());
        assert_eq!(queue.push(Ring::Context(1, 0), 2, 2, now), None, "a new boot counts from 1 again");
    }

    #[test]
    fn a_destroyed_context_gives_back_the_fences_of_its_rings_only() {
        let start = Instant::now();
        let later = start + Duration::from_secs(1);
        let mut queue = FenceQueue::default();
        queue.push(Ring::Context(1, 1), 5, "ctx 1 ring 1", start);
        queue.push(Ring::Context(1, 0), 7, "ctx 1 ring 0, later", later);
        queue.push(Ring::Context(1, 0), 3, "ctx 1 ring 0", start);
        queue.push(Ring::Context(2, 0), 4, "ctx 2 ring 0", start);
        queue.push(Ring::Global, 6, "global", start);
        assert_eq!(queue.remove_context(1), ["ctx 1 ring 0", "ctx 1 ring 1", "ctx 1 ring 0, later"]);
        assert_eq!(queue.len(), 2);
        assert!(queue.remove_context(1).is_empty(), "nothing is given back twice");
        assert_eq!(queue.signal(Ring::Context(2, 0), 4), ["ctx 2 ring 0"]);
        assert_eq!(queue.signal(Ring::Global, 6), ["global"]);
    }

    #[test]
    fn a_fence_nothing_signals_is_done_with_the_one_before_it() {
        let now = Instant::now();
        let mut queue = FenceQueue::default();
        let ring = Ring::Context(1, 0);
        assert_eq!(queue.push_after(ring, 'a', now), Some('a'), "nothing waits before it");
        queue.push(ring, 3, 'b', now);
        assert_eq!(queue.push_after(ring, 'c', now), None);
        queue.push(ring, 5, 'd', now);
        assert_eq!(queue.push_after(Ring::Global, 'e', now), Some('e'), "rings are independent");
        assert_eq!(queue.signal(ring, 3), ['b', 'c']);
        assert_eq!(queue.signal(ring, 5), ['d']);
    }

    #[test]
    fn the_oldest_fence_gives_the_stall_age() {
        let start = Instant::now();
        let mut queue = FenceQueue::default();
        assert_eq!(queue.oldest(start), None);
        queue.push(Ring::Global, 1, (), start);
        queue.push(Ring::Context(1, 0), 2, (), start + Duration::from_secs(4));
        assert_eq!(queue.oldest(start + Duration::from_secs(11)), Some(Duration::from_secs(11)));
        queue.signal(Ring::Global, 1);
        assert_eq!(queue.oldest(start + Duration::from_secs(11)), Some(Duration::from_secs(7)));
    }
}
