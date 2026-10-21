//! Avo's Linux host daemon, begun with the engine-facing plumbing its
//! control session needs: the vsock's Unix-socket transport (`vsock`), the
//! control channel's framing and protobuf envelopes (`control`, `proto`),
//! the engine's shared-memory frame rings, read for a window shim
//! (`frames`), the guest's input channel's fixed-layout records
//! (`input`), the engine's sound rings, read and filled past the
//! engine's process (`audio`), a local TCP relay the user's own adb
//! speaks into (`adb`), the daemon's client for the engine's own runtime
//! socket (`engine`), and the desktop's notification service, spoken
//! through libdbus (`notifications`), and the daemon's one process: the
//! body that binds the engine, the session, the relay and the notification
//! desk into the loop (`body`, the `avod` binary's whole). The Mac's daemon
//! (host/AvoDaemon, host/AvoKit) is the reference; phase 3 of
//! docs/linux-port.md replaces it.

pub mod adb;
pub mod adbkey;
pub mod adbc;
pub mod audio;
pub mod body;
pub mod control;
pub mod engine;
pub mod frames;
pub mod input;
pub mod notifications;
pub mod proto;
pub mod roles;
pub mod session;
pub mod vsock;

/// The guest's vsock ports the daemon drives (docs/protocol.md).
pub const ADB_PORT: u32 = 5555;
pub const CONTROL_PORT: u32 = 6000;
pub const INPUT_PORT: u32 = 6001;
