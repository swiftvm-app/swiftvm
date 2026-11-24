//! Where the sockets of the machines a service runs are: a folder of their own each, with a short path,
//! as a Unix socket's path is at most 104 bytes on a Mac.
//!
//! `/tmp/swiftvm-<user>/<data folder>/<machine>/` on a Mac, `$XDG_RUNTIME_DIR/swiftvm/<data folder>/<machine>/`
//! on Linux when there is one. The data folder and the machine go by short hashes and IDs, so that a
//! development copy and the release each find only their own.

use std::os::unix::fs::{DirBuilderExt, MetadataExt, PermissionsExt};
use std::path::{Path, PathBuf};

use swiftvm_protocol::wire::Id;

/// The folder the machines of the service for `data_folder` keep their sockets in.
pub fn root_for(data_folder: &Path) -> PathBuf {
    base().join(format!("{:08x}", short_hash(data_folder.to_string_lossy().as_bytes())))
}

fn base() -> PathBuf {
    // SAFETY: getuid can't fail.
    let uid = unsafe { libc::getuid() };
    if cfg!(target_os = "linux")
        && let Some(runtime) = std::env::var_os("XDG_RUNTIME_DIR").filter(|folder| !folder.is_empty())
    {
        return PathBuf::from(runtime).join("swiftvm");
    }
    PathBuf::from(format!("/tmp/swiftvm-{uid}"))
}

/// The folder of the machine `id` under `root`.
pub fn machine_folder(root: &Path, id: &Id) -> PathBuf {
    root.join(&id.0.simple().to_string()[..16])
}

/// FNV-1a, folded to 32 bits: short, and the same in every version.
fn short_hash(bytes: &[u8]) -> u32 {
    let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
    for byte in bytes {
        hash ^= u64::from(*byte);
        hash = hash.wrapping_mul(0x0100_0000_01b3);
    }
    (hash ^ (hash >> 32)) as u32
}

/// Makes `folder` and those above it up to the shared base, each only this user's. A folder that is there
/// already must be a real folder of this user's that nobody else can open: in `/tmp`, another user could
/// have put it there first.
pub fn make_private(folder: &Path) -> std::io::Result<()> {
    let mut missing = Vec::new();
    let mut current = folder;
    loop {
        match std::fs::symlink_metadata(current) {
            Ok(_) => break,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                missing.push(current.to_path_buf());
                match current.parent() {
                    Some(parent) => current = parent,
                    None => break,
                }
            }
            Err(error) => return Err(error),
        }
    }
    for folder in missing.iter().rev() {
        match std::fs::DirBuilder::new().mode(0o700).create(folder) {
            Ok(()) => {}
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {}
            Err(error) => return Err(error),
        }
    }
    // SAFETY: getuid can't fail.
    let uid = unsafe { libc::getuid() };
    let base = base();
    let mut checked = folder;
    loop {
        let metadata = std::fs::symlink_metadata(checked)?;
        if !metadata.is_dir() || metadata.uid() != uid || metadata.permissions().mode() & 0o077 != 0 {
            return Err(std::io::Error::new(
                std::io::ErrorKind::PermissionDenied,
                format!("{} isn't a folder that only this user can open.", checked.display()),
            ));
        }
        if checked == base {
            break;
        }
        match checked.parent() {
            Some(parent) if parent.starts_with(&base) => checked = parent,
            _ => break,
        }
    }
    Ok(())
}
