//! Avo's Linux host daemon, begun with the engine-facing plumbing its
//! control session needs: the vsock's Unix-socket transport (`vsock`), the
//! control channel's framing and protobuf envelopes (`control`, `proto`)
//! and the engine's shared-memory frame rings, read for a window shim
//! (`frames`). The Mac's daemon (host/AvoDaemon, host/AvoKit) is the
//! reference; phase 3 of docs/linux-port.md replaces it.

pub mod control;
pub mod frames;
pub mod proto;
pub mod vsock;

/// The guest's vsock ports the daemon drives (docs/protocol.md).
pub const ADB_PORT: u32 = 5555;
pub const CONTROL_PORT: u32 = 6000;
pub const INPUT_PORT: u32 = 6001;
