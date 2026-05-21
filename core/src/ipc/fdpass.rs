//! `AF_UNIX` `socketpair(2)` + `SCM_RIGHTS` file-descriptor passing for
//! the macOS Swift-helper IPC seam (ADR-0007 / ADR-0014).
//!
//! PROTECTED-SET per `AGENT_PROTOCOL` §5. This module is the *only*
//! place a surface file descriptor crosses the helper → core process
//! boundary. A bug here either stalls the OS frame pool (ADR-0013
//! Amendment 1 §3(d)) or leaks a descriptor — both are protected-set
//! failures.
//!
//! ## Why rustix (ADR-0014)
//!
//! `core/` is `#![forbid(unsafe_code)]`. Hand-written `sendmsg` /
//! `recvmsg` + `SCM_RIGHTS` ancillary parsing is the single
//! highest-risk class of `unsafe` for a privacy daemon. `rustix`
//! exposes a **safe** wrapper over exactly these syscalls (returning
//! `OwnedFd`s, so close-on-drop is automatic), letting us keep
//! `forbid(unsafe_code)` while still doing fd-passing. The binding
//! choice (rustix vs nix vs a libc shim) is recorded as a CSO ADR;
//! rustix is a PROTECTED-SET dependency gated by the ADR-0008
//! supply-chain check (CRS Security-Signal audit in `RESEARCH_DIGEST`).
//!
//! ## Receive-path hardening (ADR-0014 §, CSO veto-gate)
//!
//! `recv_with_fds` asserts, on every call:
//! - **Bounded fd count.** The ancillary buffer is sized for exactly
//!   [`MAX_SCM_FDS`]; a peer cannot make the core allocate an
//!   unbounded control buffer. The caller additionally caps the
//!   accepted count at `max_fds` and any overflow is rejected.
//! - **Truncation rejected.** If the kernel set `MSG_CTRUNC` (the
//!   sender's ancillary did not fit our buffer) the message is
//!   rejected — we never act on a partially-received fd array.
//! - **Duplicate / multi `ScmRights` rejected.** More than one
//!   `SCM_RIGHTS` control message in a single datagram is treated as
//!   hostile and rejected.
//! - **Close-on-every-error-path.** Every received fd is collected
//!   into `OwnedFd`s immediately; on *any* rejection the collection is
//!   dropped before returning `Err`, so RAII closes every descriptor.
//!   No error path can leak an fd.

use std::io::{IoSlice, IoSliceMut};
use std::mem::MaybeUninit;
use std::os::fd::{BorrowedFd, OwnedFd};

use rustix::io::{fcntl_setfd, FdFlags};
use rustix::net::{
    recvmsg, sendmsg, socketpair, AddressFamily, RecvAncillaryBuffer, RecvAncillaryMessage,
    RecvFlags, ReturnFlags, SendAncillaryBuffer, SendAncillaryMessage, SendFlags, SocketFlags,
    SocketType,
};

/// Hard ceiling on file descriptors carried in one `SCM_RIGHTS`
/// message. MCI's protocol attaches **at most one** surface fd per
/// `StateTransitionEvent`; this ceiling is the allocation-DoS guard
/// (mirrors the `MAX_FRAME_PAYLOAD_BYTES` stance in [`super::wire`]).
/// A fuzzed/malicious helper cannot make the core size an unbounded
/// ancillary buffer.
pub const MAX_SCM_FDS: usize = 4;

/// Errors the fd-pass primitive surfaces. Every variant other than a
/// successful receive guarantees no descriptor is leaked.
#[derive(Debug)]
pub enum FdPassError {
    /// `socketpair(2)` / `sendmsg` / `recvmsg` syscall failed.
    Io(std::io::Error),
    /// Caller asked to accept more fds than [`MAX_SCM_FDS`].
    TooManyRequested {
        /// The over-limit `max_fds` the caller passed.
        requested: usize,
    },
    /// The kernel set `MSG_CTRUNC`: the peer's ancillary data did not
    /// fit our (fixed, [`MAX_SCM_FDS`]-sized) control buffer. We never
    /// act on a truncated fd array. Any fds that *did* arrive were
    /// closed before this error was returned.
    AncillaryTruncated,
    /// The datagram carried more `SCM_RIGHTS` descriptors than the
    /// caller's `max_fds` (or more than one `ScmRights` control
    /// message). All received fds were closed before returning.
    TooManyFdsReceived {
        /// How many fds actually arrived.
        got: usize,
        /// The caller's accepted ceiling.
        max: usize,
    },
}

impl std::fmt::Display for FdPassError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Io(e) => write!(f, "fd-pass io: {e}"),
            Self::TooManyRequested { requested } => {
                write!(f, "max_fds {requested} exceeds MAX_SCM_FDS {MAX_SCM_FDS}")
            }
            Self::AncillaryTruncated => {
                write!(f, "SCM_RIGHTS ancillary truncated (MSG_CTRUNC); rejected")
            }
            Self::TooManyFdsReceived { got, max } => {
                write!(
                    f,
                    "received {got} fds, accept ceiling {max}; rejected + closed"
                )
            }
        }
    }
}

impl std::error::Error for FdPassError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::Io(e) => Some(e),
            _ => None,
        }
    }
}

impl From<rustix::io::Errno> for FdPassError {
    fn from(e: rustix::io::Errno) -> Self {
        Self::Io(std::io::Error::from(e))
    }
}

/// What a successful [`recv_with_fds`] yielded: the payload byte count
/// written into the caller's buffer, plus the owned descriptors that
/// rode along out-of-band. Dropping `RecvOutcome` closes any fds the
/// caller did not move out.
#[derive(Debug)]
pub struct RecvOutcome {
    /// Payload bytes written into the caller's buffer.
    pub bytes: usize,
    /// Received descriptors (`SCM_RIGHTS`), already owned ⇒ closed on
    /// drop. Length is in `0..=max_fds`.
    pub fds: Vec<OwnedFd>,
}

/// Create a connected `AF_UNIX` `SOCK_STREAM` pair with close-on-exec
/// set on **both** ends.
///
/// The agent keeps one end and passes the other to the spawned helper
/// (ADR-0007). `CLOEXEC` so an unrelated `exec` cannot silently
/// inherit the IPC socket. `SOCK_CLOEXEC` is not a `socketpair(2)`
/// flag on Apple platforms (rustix gates `SocketFlags::CLOEXEC` off
/// for `apple`), so we set `FD_CLOEXEC` via `fcntl` afterwards — the
/// portable path that also keeps `core/` OS-agnostic (ADR-0003): no
/// `#[cfg(target_os)]`, just one rustix call that does the right
/// thing on macOS and Linux.
///
/// # Errors
/// [`FdPassError::Io`] if `socketpair(2)` or the `fcntl` fails.
pub fn socket_pair() -> Result<(OwnedFd, OwnedFd), FdPassError> {
    let (a, b) = socketpair(
        AddressFamily::UNIX,
        SocketType::STREAM,
        SocketFlags::empty(),
        None,
    )?;
    fcntl_setfd(&a, FdFlags::CLOEXEC)?;
    fcntl_setfd(&b, FdFlags::CLOEXEC)?;
    Ok((a, b))
}

/// Send `payload` plus `fds` over `sock` in one `sendmsg`, the fds
/// carried out-of-band via a single `SCM_RIGHTS` control message.
///
/// `fds.len()` must be `<= MAX_SCM_FDS` (the protocol uses 0 or 1).
///
/// # Errors
/// [`FdPassError::TooManyRequested`] if `fds.len() > MAX_SCM_FDS`;
/// [`FdPassError::Io`] on a `sendmsg` failure.
pub fn send_with_fds(
    sock: BorrowedFd<'_>,
    payload: &[u8],
    fds: &[BorrowedFd<'_>],
) -> Result<usize, FdPassError> {
    if fds.len() > MAX_SCM_FDS {
        return Err(FdPassError::TooManyRequested {
            requested: fds.len(),
        });
    }
    let mut space = [MaybeUninit::uninit(); rustix::cmsg_space!(ScmRights(MAX_SCM_FDS))];
    let mut control = SendAncillaryBuffer::new(&mut space);
    if !fds.is_empty() {
        let pushed = control.push(SendAncillaryMessage::ScmRights(fds));
        debug_assert!(pushed, "ScmRights must fit a MAX_SCM_FDS-sized buffer");
    }
    let iov = [IoSlice::new(payload)];
    let n = sendmsg(sock, &iov, &mut control, SendFlags::empty())?;
    Ok(n)
}

/// Receive a payload + up to `max_fds` `SCM_RIGHTS` descriptors in one
/// `recvmsg`. Hardened per the module docs: bounded count, truncation
/// rejected, no fd leaked on any error path.
///
/// `max_fds` must be `<= MAX_SCM_FDS`. Pass `0` to assert "no fd is
/// expected" — any descriptor the peer attaches is then a protocol
/// violation and is rejected + closed.
///
/// # Errors
/// - [`FdPassError::TooManyRequested`] if `max_fds > MAX_SCM_FDS`.
/// - [`FdPassError::AncillaryTruncated`] if `MSG_CTRUNC` was set.
/// - [`FdPassError::TooManyFdsReceived`] if the peer attached more
///   than `max_fds` descriptors (or >1 `ScmRights` message).
/// - [`FdPassError::Io`] on a `recvmsg` failure.
///
/// In every error case all received descriptors are closed before
/// the error is returned.
pub fn recv_with_fds(
    sock: BorrowedFd<'_>,
    buf: &mut [u8],
    max_fds: usize,
) -> Result<RecvOutcome, FdPassError> {
    if max_fds > MAX_SCM_FDS {
        return Err(FdPassError::TooManyRequested { requested: max_fds });
    }

    let mut space = [MaybeUninit::uninit(); rustix::cmsg_space!(ScmRights(MAX_SCM_FDS))];
    let mut control = RecvAncillaryBuffer::new(&mut space);
    let mut iov = [IoSliceMut::new(buf)];
    let ret = recvmsg(sock, &mut iov, &mut control, RecvFlags::empty())?;

    // Collect EVERY received fd into OwnedFd immediately. From here on
    // any early return drops `fds`, and RAII closes the descriptors —
    // no error path can leak one.
    let mut fds: Vec<OwnedFd> = Vec::new();
    let mut scm_messages = 0usize;
    for msg in control.drain() {
        if let RecvAncillaryMessage::ScmRights(rights) = msg {
            scm_messages += 1;
            for fd in rights {
                fds.push(fd);
            }
        }
        // Any non-ScmRights control message is ignored (and carries no
        // fd to leak). We do not expect SCM_CREDENTIALS etc. on this
        // socket.
    }

    // Truncated ancillary ⇒ the peer tried to send more cmsg than our
    // fixed buffer holds. Reject; `fds` (whatever partial set arrived)
    // drops here and is closed.
    if ret.flags.contains(ReturnFlags::CTRUNC) {
        return Err(FdPassError::AncillaryTruncated);
    }

    // More than one ScmRights message, or more fds than the caller
    // will accept ⇒ hostile/protocol-violating. Reject + close all.
    if scm_messages > 1 || fds.len() > max_fds {
        return Err(FdPassError::TooManyFdsReceived {
            got: fds.len(),
            max: max_fds,
        });
    }

    Ok(RecvOutcome {
        bytes: ret.bytes,
        fds,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{Read, Write};
    use std::os::fd::AsFd;

    /// One end of a fresh socketpair, usable as a passable descriptor
    /// in tests without pulling in the rustix `pipe` feature. The
    /// returned `keep` end is what we read/write through to prove
    /// identity of the `pass` end after it crosses the IPC socket.
    fn passable_fd() -> (OwnedFd, OwnedFd) {
        socket_pair().expect("aux socketpair for a passable fd")
    }

    /// Round-trip a payload + one descriptor. The received fd must
    /// refer to the *same* kernel object: a byte written into the
    /// retained peer is readable through the descriptor that crossed
    /// the IPC socket.
    #[test]
    fn round_trips_payload_and_one_fd() {
        let (tx, rx) = socket_pair().expect("socketpair");
        let (keep, pass) = passable_fd();

        let sent = send_with_fds(tx.as_fd(), b"hello", &[pass.as_fd()]).expect("send");
        assert_eq!(sent, 5);
        drop(pass); // sender no longer needs its copy

        let mut buf = [0u8; 64];
        let out = recv_with_fds(rx.as_fd(), &mut buf, 1).expect("recv");
        assert_eq!(out.bytes, 5);
        assert_eq!(&buf[..out.bytes], b"hello");
        assert_eq!(out.fds.len(), 1, "exactly one fd carried");

        // Prove the received fd is the *same* socket: write via the
        // retained peer, read it back through the passed fd.
        let mut keep_f = std::fs::File::from(keep);
        keep_f.write_all(b"PING").expect("write retained peer");
        let mut passed = std::fs::File::from(out.fds.into_iter().next().unwrap());
        let mut got = [0u8; 4];
        passed.read_exact(&mut got).expect("read passed fd");
        assert_eq!(&got, b"PING", "passed fd refers to the same kernel object");
    }

    /// Payload with NO fds round-trips and yields an empty fd vec.
    #[test]
    fn round_trips_payload_with_no_fds() {
        let (tx, rx) = socket_pair().expect("socketpair");
        send_with_fds(tx.as_fd(), b"\x01\x02\x03", &[]).expect("send");
        let mut buf = [0u8; 16];
        let out = recv_with_fds(rx.as_fd(), &mut buf, 1).expect("recv");
        assert_eq!(&buf[..out.bytes], &[1, 2, 3]);
        assert!(out.fds.is_empty());
    }

    /// Asking to accept more than `MAX_SCM_FDS` is rejected up-front,
    /// before any syscall.
    #[test]
    fn rejects_max_fds_over_ceiling() {
        let (_tx, rx) = socket_pair().expect("socketpair");
        let mut buf = [0u8; 4];
        let err = recv_with_fds(rx.as_fd(), &mut buf, MAX_SCM_FDS + 1).unwrap_err();
        assert!(matches!(
            err,
            FdPassError::TooManyRequested { requested } if requested == MAX_SCM_FDS + 1
        ));
    }

    /// Sending more fds than `MAX_SCM_FDS` is rejected up-front.
    #[test]
    fn rejects_sending_over_ceiling() {
        let (tx, _rx) = socket_pair().expect("socketpair");
        let held: Vec<(OwnedFd, OwnedFd)> = (0..=MAX_SCM_FDS).map(|_| passable_fd()).collect();
        let fds: Vec<BorrowedFd> = held.iter().map(|(_, p)| p.as_fd()).collect();
        let err = send_with_fds(tx.as_fd(), b"x", &fds).unwrap_err();
        assert!(matches!(err, FdPassError::TooManyRequested { .. }));
    }

    /// The peer attaches a descriptor the receiver did not budget for
    /// (`max_fds = 0`): rejected. The smuggled fd is closed (not
    /// leaked) by `OwnedFd` RAII on the early-return drop of `fds`.
    #[test]
    fn rejects_unexpected_fd_when_none_budgeted() {
        let (tx, rx) = socket_pair().expect("socketpair");
        let (_keep, pass) = passable_fd();
        send_with_fds(tx.as_fd(), b"data", &[pass.as_fd()]).expect("send");
        let mut buf = [0u8; 8];
        let err = recv_with_fds(rx.as_fd(), &mut buf, 0).unwrap_err();
        assert!(matches!(
            err,
            FdPassError::TooManyFdsReceived { got: 1, max: 0 }
        ));
    }

    /// `max_fds` within the ceiling but the peer sends one more than
    /// budgeted ⇒ rejected + (RAII) closed.
    #[test]
    fn rejects_more_fds_than_budgeted() {
        let (tx, rx) = socket_pair().expect("socketpair");
        let (_k1, p1) = passable_fd();
        let (_k2, p2) = passable_fd();
        send_with_fds(tx.as_fd(), b"ab", &[p1.as_fd(), p2.as_fd()]).expect("send");
        let mut buf = [0u8; 8];
        let err = recv_with_fds(rx.as_fd(), &mut buf, 1).unwrap_err();
        assert!(matches!(
            err,
            FdPassError::TooManyFdsReceived { got: 2, max: 1 }
        ));
    }
}
