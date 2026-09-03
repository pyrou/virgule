//! The data engine exposed to the macOS application through a stable C ABI.

/// Opaque state: its layout is intentionally private to Rust.
pub struct VirguleEngine {
    _private: (),
}

/// Allocates a new engine instance for the Swift host.
#[unsafe(no_mangle)]
pub extern "C" fn virgule_engine_create() -> *mut VirguleEngine {
    Box::into_raw(Box::new(VirguleEngine { _private: () }))
}

/// Destroys an engine instance. Passing a null pointer is a no-op.
///
/// # Safety
/// `engine` must be null or a pointer returned by `virgule_engine_create` that
/// has not previously been passed to this function.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn virgule_engine_destroy(engine: *mut VirguleEngine) {
    if !engine.is_null() {
        // SAFETY: the FFI contract above requires an allocation made by create.
        unsafe { drop(Box::from_raw(engine)) };
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn engine_handle_can_be_created_and_destroyed() {
        let engine = virgule_engine_create();
        assert!(!engine.is_null());
        // SAFETY: `engine` was just returned by the matching constructor.
        unsafe { virgule_engine_destroy(engine) };
    }

    #[test]
    fn null_handle_can_be_destroyed() {
        // SAFETY: the public C API explicitly accepts null.
        unsafe { virgule_engine_destroy(std::ptr::null_mut::<VirguleEngine>()) };
    }
}
