//! Native macOS file-Keychain operations for the Hippocampus database key.
//!
//! This adapter owns the narrow unsafe Security.framework boundary. Every
//! query pins `kSecUseDataProtectionKeychain=false` and
//! `kSecAttrSynchronizable=false`; creation additionally requires a non-empty
//! `SecAccess` trusted-application list.

use std::path::Path;

/// A native Keychain operation failure.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum Error {
    /// Security.framework returned an `OSStatus` value.
    Status(i32),
    /// A trusted-application or `SecAccess` object could not be created.
    AclStatus(i32),
    /// Creation was attempted without any trusted applications.
    EmptyTrustedApplications,
    /// A trusted executable path contained a NUL byte.
    InvalidPath,
    /// A successful read returned something other than `CFData`.
    InvalidResult,
}

/// Read a generic password from the non-sync file-based Keychain domain.
pub fn read_file_generic_password(service: &str, account: &str) -> Result<Vec<u8>, Error> {
    imp::read_file_generic_password(service, account)
}

/// Add a generic password with an explicit file-Keychain `SecAccess` ACL.
pub fn add_file_generic_password_with_acl(
    service: &str,
    account: &str,
    secret: &[u8],
    trusted_application_paths: &[impl AsRef<Path>],
) -> Result<(), Error> {
    imp::add_file_generic_password_with_acl(service, account, secret, trusted_application_paths)
}

#[cfg(target_os = "macos")]
mod imp {
    use std::ffi::{c_void, CString};
    use std::path::Path;
    use std::ptr;

    use core_foundation::array::CFArray;
    use core_foundation::base::{CFType, TCFType};
    use core_foundation::boolean::CFBoolean;
    use core_foundation::data::CFData;
    use core_foundation::dictionary::CFDictionary;
    use core_foundation::string::CFString;
    use core_foundation_sys::array::CFArrayRef;
    use core_foundation_sys::base::{CFGetTypeID, CFTypeRef, OSStatus};
    use core_foundation_sys::string::CFStringRef;
    use security_framework_sys::base::errSecSuccess;
    use security_framework_sys::item::{
        kSecAttrAccount, kSecAttrService, kSecAttrSynchronizable, kSecClass,
        kSecClassGenericPassword, kSecMatchLimit, kSecReturnData, kSecUseDataProtectionKeychain,
        kSecValueData,
    };
    use security_framework_sys::keychain_item::{SecItemAdd, SecItemCopyMatching};

    use super::Error;

    #[link(name = "Security", kind = "framework")]
    extern "C" {
        static kSecAttrAccess: CFStringRef;
        static kSecMatchLimitOne: CFStringRef;
        fn SecTrustedApplicationCreateFromPath(
            path: *const i8,
            application: *mut *mut c_void,
        ) -> OSStatus;
        fn SecAccessCreate(
            descriptor: CFStringRef,
            trusted_list: CFArrayRef,
            access: *mut *mut c_void,
        ) -> OSStatus;
    }

    fn base_pairs(service: &str, account: &str) -> Vec<(CFString, CFType)> {
        unsafe {
            vec![
                (
                    CFString::wrap_under_get_rule(kSecClass),
                    CFString::wrap_under_get_rule(kSecClassGenericPassword).into_CFType(),
                ),
                (
                    CFString::wrap_under_get_rule(kSecAttrService),
                    CFString::new(service).into_CFType(),
                ),
                (
                    CFString::wrap_under_get_rule(kSecAttrAccount),
                    CFString::new(account).into_CFType(),
                ),
                (
                    CFString::wrap_under_get_rule(kSecUseDataProtectionKeychain),
                    CFBoolean::false_value().into_CFType(),
                ),
                (
                    CFString::wrap_under_get_rule(kSecAttrSynchronizable),
                    CFBoolean::false_value().into_CFType(),
                ),
            ]
        }
    }

    pub(super) fn read_file_generic_password(
        service: &str,
        account: &str,
    ) -> Result<Vec<u8>, Error> {
        let mut pairs = base_pairs(service, account);
        pairs.push(unsafe {
            (
                CFString::wrap_under_get_rule(kSecReturnData),
                CFBoolean::true_value().into_CFType(),
            )
        });
        pairs.push(unsafe {
            (
                CFString::wrap_under_get_rule(kSecMatchLimit),
                CFString::wrap_under_get_rule(kSecMatchLimitOne).into_CFType(),
            )
        });
        let query = CFDictionary::from_CFType_pairs(&pairs);
        let mut result: CFTypeRef = ptr::null();
        let status = unsafe { SecItemCopyMatching(query.as_concrete_TypeRef(), &mut result) };
        if status != errSecSuccess {
            return Err(Error::Status(status));
        }
        if result.is_null() || unsafe { CFGetTypeID(result) } != CFData::type_id() {
            if !result.is_null() {
                unsafe { core_foundation_sys::base::CFRelease(result) };
            }
            return Err(Error::InvalidResult);
        }
        let data = unsafe {
            CFData::wrap_under_create_rule(result.cast::<core_foundation_sys::data::__CFData>())
        };
        Ok(data.bytes().to_vec())
    }

    pub(super) fn add_file_generic_password_with_acl(
        service: &str,
        account: &str,
        secret: &[u8],
        trusted_application_paths: &[impl AsRef<Path>],
    ) -> Result<(), Error> {
        if trusted_application_paths.is_empty() {
            return Err(Error::EmptyTrustedApplications);
        }
        let mut trusted = Vec::with_capacity(trusted_application_paths.len());
        for path in trusted_application_paths {
            let path = CString::new(path.as_ref().as_os_str().as_encoded_bytes())
                .map_err(|_| Error::InvalidPath)?;
            let mut application = ptr::null_mut();
            let status =
                unsafe { SecTrustedApplicationCreateFromPath(path.as_ptr(), &mut application) };
            if status != errSecSuccess || application.is_null() {
                return Err(Error::AclStatus(status));
            }
            trusted.push(unsafe { CFType::wrap_under_create_rule(application as CFTypeRef) });
        }

        let trusted_array = CFArray::from_CFTypes(&trusted);
        let descriptor = CFString::new("Hippocampus database key");
        let mut access = ptr::null_mut();
        let status = unsafe {
            SecAccessCreate(
                descriptor.as_concrete_TypeRef(),
                trusted_array.as_concrete_TypeRef(),
                &mut access,
            )
        };
        if status != errSecSuccess || access.is_null() {
            return Err(Error::AclStatus(status));
        }

        let mut pairs = base_pairs(service, account);
        pairs.push(unsafe {
            (
                CFString::wrap_under_get_rule(kSecValueData),
                CFData::from_buffer(secret).into_CFType(),
            )
        });
        pairs.push(unsafe {
            (
                CFString::wrap_under_get_rule(kSecAttrAccess),
                CFType::wrap_under_create_rule(access as CFTypeRef),
            )
        });
        let attributes = CFDictionary::from_CFType_pairs(&pairs);
        let status = unsafe { SecItemAdd(attributes.as_concrete_TypeRef(), ptr::null_mut()) };
        if status == errSecSuccess {
            Ok(())
        } else {
            Err(Error::Status(status))
        }
    }
}

#[cfg(not(target_os = "macos"))]
mod imp {
    use std::path::Path;

    use super::Error;

    pub(super) fn read_file_generic_password(
        _service: &str,
        _account: &str,
    ) -> Result<Vec<u8>, Error> {
        Err(Error::Status(-4))
    }

    pub(super) fn add_file_generic_password_with_acl(
        _service: &str,
        _account: &str,
        _secret: &[u8],
        _trusted_application_paths: &[impl AsRef<Path>],
    ) -> Result<(), Error> {
        if _trusted_application_paths.is_empty() {
            Err(Error::EmptyTrustedApplications)
        } else {
            Err(Error::Status(-4))
        }
    }
}
