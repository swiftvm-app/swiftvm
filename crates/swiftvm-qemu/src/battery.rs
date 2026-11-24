//! The host's battery, passed through to guests (qemu-battery.patch): only the computer's internal one,
//! not a UPS or a battery in an accessory.

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct HostBattery {
    pub percentage: u32,
    pub is_on_ac: bool,
    pub is_charging: bool,
}

impl HostBattery {
    /// The one status word the patched QEMU takes. Zero is no battery.
    pub fn status(self) -> u32 {
        self.percentage.min(100) | 0x100 | if self.is_on_ac { 0x200 } else { 0 } | if self.is_charging { 0x400 } else { 0 }
    }

    /// The status word for the battery there is now: zero without one.
    pub fn current_status() -> u32 {
        read().map_or(0, HostBattery::status)
    }
}

#[cfg(target_os = "macos")]
pub fn read() -> Option<HostBattery> {
    macos::read()
}

#[cfg(target_os = "linux")]
pub fn read() -> Option<HostBattery> {
    linux::read(std::path::Path::new("/sys/class/power_supply"))
}

#[cfg(not(any(target_os = "macos", target_os = "linux")))]
pub fn read() -> Option<HostBattery> {
    None
}

#[cfg(target_os = "linux")]
pub mod linux {
    use super::HostBattery;
    use std::path::Path;

    /// The first system battery under `folder` (`/sys/class/power_supply`), with whether mains power is on.
    pub fn read(folder: &Path) -> Option<HostBattery> {
        let entries: Vec<_> = std::fs::read_dir(folder).ok()?.flatten().map(|entry| entry.path()).collect();
        let text = |path: &Path, name: &str| std::fs::read_to_string(path.join(name)).ok().map(|text| text.trim().to_string());
        let battery = entries
            .iter()
            .find(|path| text(path, "type").as_deref() == Some("Battery") && text(path, "scope").as_deref() != Some("Device"))?;
        let percentage = text(battery, "capacity")?.parse::<u32>().ok()?.min(100);
        let status = text(battery, "status").unwrap_or_default();
        let is_on_ac = entries.iter().any(|path| {
            // A USB-C charger is a supply of the USB kind.
            matches!(text(path, "type").as_deref(), Some("Mains" | "USB")) && text(path, "online").as_deref() == Some("1")
        }) || status == "Charging"
            || status == "Full";
        Some(HostBattery { percentage, is_on_ac, is_charging: status == "Charging" })
    }
}

#[cfg(target_os = "macos")]
mod macos {
    //! IOKit's power sources, through CoreFoundation.
    use super::HostBattery;
    use std::ffi::{CString, c_void};

    type CFTypeRef = *const c_void;
    type CFIndex = isize;

    #[link(name = "IOKit", kind = "framework")]
    unsafe extern "C" {
        fn IOPSCopyPowerSourcesInfo() -> CFTypeRef;
        fn IOPSCopyPowerSourcesList(blob: CFTypeRef) -> CFTypeRef;
        fn IOPSGetPowerSourceDescription(blob: CFTypeRef, source: CFTypeRef) -> CFTypeRef;
    }

    #[link(name = "CoreFoundation", kind = "framework")]
    unsafe extern "C" {
        fn CFRelease(value: CFTypeRef);
        fn CFArrayGetCount(array: CFTypeRef) -> CFIndex;
        fn CFArrayGetValueAtIndex(array: CFTypeRef, index: CFIndex) -> CFTypeRef;
        fn CFDictionaryGetValue(dictionary: CFTypeRef, key: CFTypeRef) -> CFTypeRef;
        fn CFStringCreateWithCString(allocator: CFTypeRef, text: *const i8, encoding: u32) -> CFTypeRef;
        fn CFStringGetCString(string: CFTypeRef, buffer: *mut i8, size: CFIndex, encoding: u32) -> bool;
        fn CFNumberGetValue(number: CFTypeRef, kind: CFIndex, value: *mut c_void) -> bool;
        fn CFBooleanGetValue(boolean: CFTypeRef) -> bool;
        fn CFGetTypeID(value: CFTypeRef) -> usize;
        fn CFStringGetTypeID() -> usize;
        fn CFNumberGetTypeID() -> usize;
        fn CFBooleanGetTypeID() -> usize;
    }

    const UTF8: u32 = 0x0800_0100;
    const NUMBER_SINT64: CFIndex = 4;

    /// A CoreFoundation object this owns, released when dropped.
    struct Owned(CFTypeRef);

    impl Drop for Owned {
        fn drop(&mut self) {
            if !self.0.is_null() {
                // SAFETY: the object came from a Copy or Create function.
                unsafe { CFRelease(self.0) }
            }
        }
    }

    fn key(text: &str) -> Owned {
        let text = CString::new(text).unwrap_or_default();
        // SAFETY: a NUL-terminated string.
        Owned(unsafe { CFStringCreateWithCString(std::ptr::null(), text.as_ptr(), UTF8) })
    }

    fn value(dictionary: CFTypeRef, name: &str) -> CFTypeRef {
        let key = key(name);
        if key.0.is_null() {
            return std::ptr::null();
        }
        // SAFETY: a dictionary and a string key.
        unsafe { CFDictionaryGetValue(dictionary, key.0) }
    }

    fn string(dictionary: CFTypeRef, name: &str) -> Option<String> {
        let value = value(dictionary, name);
        // SAFETY: the type is checked before the value is read as a string.
        unsafe {
            if value.is_null() || CFGetTypeID(value) != CFStringGetTypeID() {
                return None;
            }
            let mut buffer = [0i8; 256];
            CFStringGetCString(value, buffer.as_mut_ptr(), buffer.len() as CFIndex, UTF8)
                .then(|| std::ffi::CStr::from_ptr(buffer.as_ptr()).to_string_lossy().into_owned())
        }
    }

    fn number(dictionary: CFTypeRef, name: &str) -> Option<i64> {
        let value = value(dictionary, name);
        // SAFETY: the type is checked before the value is read as a number.
        unsafe {
            if value.is_null() || CFGetTypeID(value) != CFNumberGetTypeID() {
                return None;
            }
            let mut result: i64 = 0;
            CFNumberGetValue(value, NUMBER_SINT64, (&mut result as *mut i64).cast()).then_some(result)
        }
    }

    fn boolean(dictionary: CFTypeRef, name: &str) -> Option<bool> {
        let value = value(dictionary, name);
        // SAFETY: the type is checked before the value is read as a boolean.
        unsafe { (!value.is_null() && CFGetTypeID(value) == CFBooleanGetTypeID()).then(|| CFBooleanGetValue(value)) }
    }

    pub fn read() -> Option<HostBattery> {
        // SAFETY: each Copy result is owned and released; descriptions are borrowed from the info blob.
        unsafe {
            let info = Owned(IOPSCopyPowerSourcesInfo());
            if info.0.is_null() {
                return None;
            }
            let list = Owned(IOPSCopyPowerSourcesList(info.0));
            if list.0.is_null() {
                return None;
            }
            for index in 0..CFArrayGetCount(list.0) {
                let description = IOPSGetPowerSourceDescription(info.0, CFArrayGetValueAtIndex(list.0, index));
                if description.is_null() {
                    continue;
                }
                if let Some(battery) = battery(description) {
                    return Some(battery);
                }
            }
            None
        }
    }

    fn battery(description: CFTypeRef) -> Option<HostBattery> {
        if string(description, "Type").as_deref() != Some("InternalBattery") || boolean(description, "Is Present") != Some(true) {
            return None;
        }
        let current = number(description, "Current Capacity").filter(|value| *value >= 0)?;
        let maximum = number(description, "Max Capacity").filter(|value| *value > 0)?;
        let source = string(description, "Power Source State")?;
        if source != "AC Power" && source != "Battery Power" {
            return None;
        }
        let is_on_ac = source == "AC Power";
        Some(HostBattery {
            percentage: ((current as f64 * 100.0 / maximum as f64).floor() as u32).min(100),
            is_on_ac,
            is_charging: is_on_ac && boolean(description, "Is Charging") == Some(true),
        })
    }
}
