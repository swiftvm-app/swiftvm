//! Where SwiftVM keeps its data and listens, and which copy of it a program belongs to.

use std::collections::HashMap;
use std::path::{Component, Path, PathBuf};

/// Which copy of SwiftVM a program is part of: the app people use, or the development copy that
/// `swift run SwiftVM` makes. The two keep their data apart.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum AppIdentity {
    Release,
    Development,
}

impl AppIdentity {
    pub fn bundle_identifier(self) -> &'static str {
        match self {
            AppIdentity::Release => "com.swiftvm.app",
            AppIdentity::Development => "com.swiftvm.app.dev",
        }
    }

    /// What the copy calls itself.
    pub fn name(self) -> &'static str {
        match self {
            AppIdentity::Release => "SwiftVM",
            AppIdentity::Development => "SwiftVM Dev",
        }
    }

    /// The folder the copy keeps its machines, its settings and its control socket in.
    pub fn data_directory_name(self) -> &'static str {
        if cfg!(target_os = "macos") {
            match self {
                AppIdentity::Release => "SwiftVM",
                AppIdentity::Development => "SwiftVM-Dev",
            }
        } else {
            match self {
                AppIdentity::Release => "swiftvm",
                AppIdentity::Development => "swiftvm-dev",
            }
        }
    }

    /// The copy the program at `program` is part of: the one whose app it is inside. A program outside
    /// an app goes with the app people use, and so does one inside an app that goes by another name.
    ///
    /// `Err` names the app when the program is inside one that doesn't say what it is. Taking it for
    /// the app would hand it the app's machines, and it may be a development copy.
    pub fn of_program(program: &Path) -> Result<AppIdentity, PathBuf> {
        let Some(app) = app_bundle_containing(program) else { return Ok(AppIdentity::Release) };
        match bundle_identifier_of_app(&app) {
            Some(identifier) if identifier == AppIdentity::Development.bundle_identifier() => Ok(AppIdentity::Development),
            Some(_) => Ok(AppIdentity::Release),
            None => Err(app),
        }
    }
}

/// The app that `program` is inside, be it the app's own program or a tool in its `Contents/Helpers`.
/// A link to the tool, like the one in `/usr/local/bin`, leads to the tool's app.
pub fn app_bundle_containing(program: &Path) -> Option<PathBuf> {
    let resolved = program.canonicalize().unwrap_or_else(|_| program.to_path_buf());
    resolved.ancestors().skip(1).find(|folder| folder.extension().is_some_and(|extension| extension == "app")).map(Path::to_path_buf)
}

#[cfg(target_os = "macos")]
fn bundle_identifier_of_app(app: &Path) -> Option<String> {
    let value = plist::Value::from_file(app.join("Contents/Info.plist")).ok()?;
    value.as_dictionary()?.get("CFBundleIdentifier")?.as_string().map(str::to_string)
}

#[cfg(not(target_os = "macos"))]
fn bundle_identifier_of_app(_app: &Path) -> Option<String> {
    None
}

/// Where a copy of SwiftVM listens and where its generated files live.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ControlPaths {
    pub data: PathBuf,
}

impl ControlPaths {
    /// Points the app and the `swiftvm` tool at another data folder, for a copy with machines of its own.
    pub const HOME_ENVIRONMENT_KEY: &'static str = "SWIFTVM_HOME";

    /// `SWIFTVM_HOME` goes first. Without it each copy has a folder of its own in `home`: in Application
    /// Support on a Mac, in the XDG data folder elsewhere.
    pub fn new(identity: AppIdentity, environment: &HashMap<String, String>, home: &Path) -> Self {
        if let Some(data) = environment.get(Self::HOME_ENVIRONMENT_KEY).filter(|data| !data.is_empty()) {
            return ControlPaths { data: PathBuf::from(standardized_path(data)) };
        }
        let base = if cfg!(target_os = "macos") {
            home.join("Library/Application Support")
        } else {
            environment
                .get("XDG_DATA_HOME")
                .filter(|folder| folder.starts_with('/'))
                .map(PathBuf::from)
                .unwrap_or_else(|| home.join(".local/share"))
        };
        ControlPaths { data: base.join(identity.data_directory_name()) }
    }

    pub fn socket(&self) -> PathBuf {
        self.data.join("control.sock")
    }

    pub fn ssh_config(&self) -> PathBuf {
        self.data.join("ssh_config")
    }
}

/// The account's home folder. On a Mac it is the account's own, as Foundation has it whatever `HOME`
/// says; elsewhere `HOME` goes first, as it does for every other program there.
pub fn home_directory() -> PathBuf {
    let from_environment = || std::env::var_os("HOME").filter(|home| !home.is_empty()).map(PathBuf::from);
    if cfg!(target_os = "macos") {
        account_home().or_else(from_environment).unwrap_or_else(|| PathBuf::from("/"))
    } else {
        from_environment().or_else(account_home).unwrap_or_else(|| PathBuf::from("/"))
    }
}

/// The home folder in the account's entry in the user database.
fn account_home() -> Option<PathBuf> {
    use std::ffi::CStr;
    use std::os::unix::ffi::OsStrExt;
    let mut buffer = vec![0 as libc::c_char; 16 * 1024];
    // SAFETY: zeroed passwd and result are valid for getpwuid_r to fill in, and the buffer outlives them.
    unsafe {
        let mut entry: libc::passwd = std::mem::zeroed();
        let mut result: *mut libc::passwd = std::ptr::null_mut();
        if libc::getpwuid_r(libc::getuid(), &mut entry, buffer.as_mut_ptr(), buffer.len(), &mut result) != 0
            || result.is_null()
            || entry.pw_dir.is_null()
        {
            return None;
        }
        let folder = CStr::from_ptr(entry.pw_dir).to_bytes();
        (!folder.is_empty()).then(|| PathBuf::from(std::ffi::OsStr::from_bytes(folder)))
    }
}

/// `path` from the root, as Foundation's `URL(fileURLWithPath:).standardizedFileURL.path` has it: `~/`
/// at its start is the home folder, a relative path counts from the current folder, and `.` and `..`
/// are taken out without asking the disk. A `~` anywhere else is a name like any other. On a Mac a
/// leading `/private` goes where the path is there without it, as `/tmp` and `/var` are: the app keeps
/// paths that way, and a path it is asked about has to match the one it keeps.
pub fn standardized_path(path: &str) -> String {
    let absolute = if path.starts_with('/') {
        PathBuf::from(path)
    } else if let Some(rest) = path.strip_prefix("~/") {
        home_directory().join(rest)
    } else {
        std::env::current_dir().unwrap_or_else(|_| PathBuf::from("/")).join(path)
    };
    let mut parts: Vec<String> = Vec::new();
    for component in absolute.components() {
        match component {
            Component::Normal(part) => parts.push(part.to_string_lossy().into_owned()),
            Component::ParentDir => {
                parts.pop();
            }
            Component::RootDir | Component::CurDir | Component::Prefix(_) => {}
        }
    }
    let standardized = format!("/{}", parts.join("/"));
    if cfg!(target_os = "macos")
        && let Some(public) = standardized.strip_prefix("/private").filter(|public| public.starts_with('/'))
        && Path::new(public).exists()
    {
        return public.to_string();
    }
    standardized
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn swiftvm_home_comes_before_the_copys_own_folder() {
        let home = Path::new("/Users/u");
        let environment = HashMap::from([("SWIFTVM_HOME".to_string(), "/tmp/a/../b/".to_string())]);
        assert_eq!(ControlPaths::new(AppIdentity::Development, &environment, home).socket(), PathBuf::from("/tmp/b/control.sock"));
        let data = ControlPaths::new(AppIdentity::Development, &HashMap::new(), home).data;
        if cfg!(target_os = "macos") {
            assert_eq!(data, PathBuf::from("/Users/u/Library/Application Support/SwiftVM-Dev"));
        } else {
            assert_eq!(data, PathBuf::from("/Users/u/.local/share/swiftvm-dev"));
        }
    }

    #[test]
    fn a_path_is_read_from_the_root_with_a_leading_tilde_as_home() {
        let home = home_directory().to_string_lossy().into_owned();
        assert_eq!(standardized_path("~/notes/../x.txt"), format!("{home}/x.txt"));
        let here = std::env::current_dir().unwrap().to_string_lossy().into_owned();
        assert_eq!(standardized_path("~"), format!("{here}/~"));
        assert_eq!(standardized_path("a/~/b/"), format!("{here}/a/~/b"));
        if cfg!(target_os = "macos") {
            assert_eq!(standardized_path("/private/etc/hosts"), "/etc/hosts");
            assert_eq!(standardized_path("/private/tmp/swiftvm-nothing-here"), "/private/tmp/swiftvm-nothing-here");
        }
    }

    #[test]
    fn a_program_outside_an_app_goes_with_the_release() {
        assert_eq!(AppIdentity::of_program(Path::new("/usr/local/libexec/swiftvm-nowhere")), Ok(AppIdentity::Release));
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn a_program_inside_the_development_app_goes_with_it() {
        let root = std::env::temp_dir().join(format!("swiftvm-identity-{}", std::process::id()));
        let helpers = root.join("SwiftVM Dev.app/Contents/Helpers");
        std::fs::create_dir_all(&helpers).unwrap();
        let tool = helpers.join("swiftvm");
        std::fs::write(&tool, b"").unwrap();
        let info = root.join("SwiftVM Dev.app/Contents/Info.plist");
        let unreadable = AppIdentity::of_program(&tool);
        std::fs::write(&info, br#"<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.swiftvm.app.dev</string></dict></plist>"#).unwrap();
        let identity = AppIdentity::of_program(&tool);
        std::fs::remove_dir_all(&root).unwrap();
        assert!(unreadable.is_err());
        assert_eq!(identity, Ok(AppIdentity::Development));
    }
}
