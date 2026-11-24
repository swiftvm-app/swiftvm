//! The QEMU that runs machines: in a Mac's app, `Contents/Helpers/QEMU` with the libraries it loads and
//! `Contents/Resources/QEMU/share` with its firmware, next to the `swiftvm` tool in `Contents/Helpers`.
//! `scripts/build-qemu.sh` builds it and `scripts/bundle-app.sh` puts it there.
//!
//! `SWIFTVM_QEMU` (the program) and `SWIFTVM_QEMU_DATA` (its data folder) name another one.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use swiftvm_protocol::qemu::DirectX;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Installation {
    /// `qemu-system-aarch64`.
    pub program: PathBuf,
    /// The folder QEMU looks for its data in: the firmware, and the keyboard layout its VNC server wants.
    pub data_directory: PathBuf,
    /// Whether it has what lets a guest draw with the host's GPU: SPICE with OpenGL, and the library the
    /// app shows such a guest's screen with.
    pub accelerates_graphics: bool,
}

/// The size of the flash a machine's UEFI variables are kept in. QEMU takes nothing else.
const VARIABLE_STORE_SIZE: u64 = 64 << 20;

impl Installation {
    pub fn new(program: PathBuf, data_directory: PathBuf) -> Self {
        let mut installation = Installation { program, data_directory, accelerates_graphics: false };
        installation.accelerates_graphics = installation.display_library().exists();
        installation
    }

    /// The QEMU the environment names, or the one in the app the service's `program` is in. `None` when
    /// there is none, or it is incomplete.
    pub fn find(service_program: &Path) -> Option<Installation> {
        let installation = match (std::env::var_os("SWIFTVM_QEMU"), std::env::var_os("SWIFTVM_QEMU_DATA")) {
            (Some(program), Some(data)) => Installation::new(program.into(), data.into()),
            _ => {
                let helpers = service_program.parent()?;
                Installation::new(helpers.join("QEMU/bin/qemu-system-aarch64"), helpers.parent()?.join("Resources/QEMU/share"))
            }
        };
        installation.is_complete().then_some(installation)
    }

    /// Whether everything a machine needs is there.
    pub fn is_complete(&self) -> bool {
        is_executable(&self.program) && self.firmware().exists() && self.variables_template().exists()
    }

    fn library_directory(&self) -> PathBuf {
        self.program.parent().and_then(Path::parent).map(|prefix| prefix.join("lib")).unwrap_or_default()
    }

    pub fn display_library(&self) -> PathBuf {
        self.library_directory().join("libSwiftVMDisplay.dylib")
    }

    fn dxmt_library(&self) -> PathBuf {
        self.library_directory().join("libdxmt-native.dylib")
    }

    fn d3d_metal_library(&self) -> PathBuf {
        self.library_directory().join("libd3dmetal-native.dylib")
    }

    /// Whether it has DXMT, which Windows' Direct3D goes through. Custom builds can leave it out.
    pub fn supports_direct3d(&self) -> bool {
        self.dxmt_library().exists()
    }

    /// `swtpm`, the TPM 2.0 Windows guests get. Custom builds can leave it out.
    pub fn tpm_emulator(&self) -> PathBuf {
        self.program.with_file_name("swtpm")
    }

    pub fn supports_tpm(&self) -> bool {
        is_executable(&self.tpm_emulator())
    }

    /// The UEFI firmware, without the padding of the machine's flash.
    pub fn firmware(&self) -> PathBuf {
        self.data_directory.join("edk2-aarch64-code.fd")
    }

    /// What a machine's own UEFI variables start out as.
    pub fn variables_template(&self) -> PathBuf {
        self.data_directory.join("edk2-arm-vars.fd")
    }

    /// Writes a fresh store of UEFI variables for a new machine at `path`, as large as the flash and as
    /// sparse as the file system allows.
    pub fn make_variable_store(&self, path: &Path) -> std::io::Result<()> {
        let template = std::fs::read(self.variables_template())?;
        let staging = path.with_extension("fd.new");
        std::fs::write(&staging, template)?;
        std::fs::OpenOptions::new().write(true).open(&staging)?.set_len(VARIABLE_STORE_SIZE)?;
        std::fs::rename(&staging, path)
    }

    /// What QEMU runs with, and its render server after it, for a guest that draws with the GPU, its
    /// Direct3D going to `direct_x`. `directory` is the folder for the render server's sockets.
    pub fn environment(&self, directory: &Path, direct_x: Option<&DirectX>) -> BTreeMap<String, String> {
        let mut environment = BTreeMap::new();
        if !self.accelerates_graphics {
            return environment;
        }
        environment.insert("ANGLE_DEFAULT_PLATFORM".into(), "metal".into());
        environment
            .insert("RENDER_SERVER_EXEC_PATH".into(), self.program.with_file_name("virgl_render_server").to_string_lossy().into_owned());
        environment.insert("XDG_RUNTIME_DIR".into(), directory.to_string_lossy().into_owned());
        let library = match direct_x {
            Some(DirectX { backend, framework: Some(framework) }) if backend == "d3dmetal" => {
                environment.insert("NPT_BACKEND".into(), "d3dmetal".into());
                environment.insert("D3DMETAL_FRAMEWORK_PATH".into(), framework.clone());
                // QEMU tells the guest what the backend has before any render server runs, and can't load
                // the library to look: it is for Intel.
                environment.insert("NPT_CAPSET_D3D12".into(), "1".into());
                self.d3d_metal_library()
            }
            _ => {
                environment.insert("NPT_BACKEND".into(), "dxmt".into());
                self.dxmt_library()
            }
        };
        for name in ["NPT_D3D11_LIBRARY_PATH", "NPT_D3D12_LIBRARY_PATH", "NPT_DXGI_LIBRARY_PATH"] {
            environment.insert(name.into(), library.to_string_lossy().into_owned());
        }
        environment
    }
}

fn is_executable(path: &Path) -> bool {
    use std::os::unix::fs::PermissionsExt;
    std::fs::metadata(path).is_ok_and(|metadata| metadata.is_file() && metadata.permissions().mode() & 0o111 != 0)
}
