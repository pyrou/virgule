//! C ABI boundary for the native macOS host.

use std::ffi::{c_void, CStr, CString};
use std::fmt;
use std::os::raw::c_char;
use std::path::{Path, PathBuf};

use rusqlite::Connection;

use crate::{import_source_file, CsvCache, ImportError, ImportEvent, VirguleEngine};

/// C-compatible import event. All string pointers are valid only for the callback.
#[repr(C)]
pub struct VirguleImportEvent {
    kind: u32,
    row: usize,
    imported_rows: usize,
    total_bytes: u64,
    values: *const *const c_char,
    value_count: usize,
    message: *const c_char,
}

pub type VirguleImportCallback = unsafe extern "C" fn(*const VirguleImportEvent, *mut c_void);

/// C-compatible CSV result row. All borrowed data remains valid only during
/// the page callback that receives it.
#[repr(C)]
pub struct VirgulePageRow {
    result_row: usize,
    source_row: i64,
    values: *const *const c_char,
    value_count: usize,
    message: *const c_char,
}

pub type VirgulePageCallback = unsafe extern "C" fn(*const VirgulePageRow, *mut c_void);

fn emit_ffi_event(callback: VirguleImportCallback, context: *mut c_void, event: ImportEvent) {
    let (kind, row, imported_rows, total_bytes, values, message) = match event {
        ImportEvent::Started { total_bytes } => (0, 0, 0, total_bytes, Vec::new(), String::new()),
        ImportEvent::Headers { values } => (5, 0, 0, 0, values, String::new()),
        ImportEvent::Preview { row, values } => (1, row, 0, 0, values, String::new()),
        ImportEvent::Progress {
            imported_rows,
            total_bytes,
        } => (2, 0, imported_rows, total_bytes, Vec::new(), String::new()),
        ImportEvent::Completed {
            imported_rows,
            cache_path,
        } => (
            3,
            0,
            imported_rows,
            0,
            Vec::new(),
            cache_path.display().to_string(),
        ),
    };
    let values = values
        .into_iter()
        .map(|value| CString::new(value).unwrap_or_else(|_| CString::default()))
        .collect::<Vec<_>>();
    let pointers = values
        .iter()
        .map(|value| value.as_ptr())
        .collect::<Vec<_>>();
    let message = CString::new(message).expect("cache paths cannot contain NUL");
    let ffi_event = VirguleImportEvent {
        kind,
        row,
        imported_rows,
        total_bytes,
        values: pointers.as_ptr(),
        value_count: pointers.len(),
        message: message.as_ptr(),
    };
    // SAFETY: callback and context are supplied by the C host; all event storage lives for this call.
    unsafe { callback(&ffi_event, context) };
}

fn emit_ffi_error(callback: VirguleImportCallback, context: *mut c_void, error: &ImportError) {
    let message = CString::new(error.to_string()).unwrap_or_else(|_| CString::default());
    let event = VirguleImportEvent {
        kind: 4,
        row: 0,
        imported_rows: 0,
        total_bytes: 0,
        values: std::ptr::null(),
        value_count: 0,
        message: message.as_ptr(),
    };
    // SAFETY: callback and context are supplied by the C host; message lives for this call.
    unsafe { callback(&event, context) };
}

fn emit_ffi_query_description(
    callback: VirguleImportCallback,
    context: *mut c_void,
    columns: Vec<String>,
    row_count: usize,
) {
    let values = columns
        .into_iter()
        .map(|value| CString::new(value).unwrap_or_default())
        .collect::<Vec<_>>();
    let pointers = values
        .iter()
        .map(|value| value.as_ptr())
        .collect::<Vec<_>>();
    let message = CString::default();
    let event = VirguleImportEvent {
        kind: 5,
        row: 0,
        imported_rows: row_count,
        total_bytes: 0,
        values: pointers.as_ptr(),
        value_count: pointers.len(),
        message: message.as_ptr(),
    };
    // SAFETY: callback and all borrowed event data are valid for this call.
    unsafe { callback(&event, context) };
}

/// Emits a successful validation using the existing event ABI. A headers event
/// is an unambiguous success marker and does not require transferring schema
/// metadata or evaluating the query.
fn emit_ffi_query_validation(callback: VirguleImportCallback, context: *mut c_void) {
    let message = CString::default();
    let event = VirguleImportEvent {
        kind: 5,
        row: 0,
        imported_rows: 0,
        total_bytes: 0,
        values: std::ptr::null(),
        value_count: 0,
        message: message.as_ptr(),
    };
    // SAFETY: callback and its borrowed message are valid for this call.
    unsafe { callback(&event, context) };
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

/// Imports a UTF-8 filesystem path, synchronously delivering lifecycle events to
/// `callback`. The callback and its borrowed event data are never retained.
///
/// Returns `0` after a valid call (including an import error delivered as an
/// event), or `-1` for invalid FFI arguments.
///
/// # Safety
/// `engine` must be an engine returned by `virgule_engine_create`; `source_path`
/// and `cache_directory` must be NUL-terminated UTF-8 strings; and `callback`
/// must remain callable until this function returns.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn virgule_engine_import_csv(
    engine: *mut VirguleEngine,
    source_path: *const c_char,
    cache_directory: *const c_char,
    callback: Option<VirguleImportCallback>,
    context: *mut c_void,
) -> i32 {
    let Some(callback) = callback else {
        return -1;
    };
    if engine.is_null() || source_path.is_null() || cache_directory.is_null() {
        return -1;
    }
    // SAFETY: required by this function's C contract.
    let source_path = unsafe { CStr::from_ptr(source_path) };
    let Ok(source_path) = source_path.to_str() else {
        let error = ImportError::Io(std::io::Error::new(
            std::io::ErrorKind::InvalidInput,
            "The source path is not UTF-8.",
        ));
        emit_ffi_error(callback, context, &error);
        return 0;
    };
    // SAFETY: required by this function's C contract.
    let cache_directory = unsafe { CStr::from_ptr(cache_directory) };
    let Ok(cache_directory) = cache_directory.to_str() else {
        let error = ImportError::Io(std::io::Error::new(
            std::io::ErrorKind::InvalidInput,
            "The cache directory path is not UTF-8.",
        ));
        emit_ffi_error(callback, context, &error);
        return 0;
    };
    if let Err(error) = import_source_file(
        Path::new(source_path),
        Path::new(cache_directory),
        |event| emit_ffi_event(callback, context, event),
    ) {
        emit_ffi_error(callback, context, &error);
    }
    0
}

fn emit_ffi_page_error(
    callback: VirgulePageCallback,
    context: *mut c_void,
    error: impl fmt::Display,
) {
    let message = CString::new(error.to_string()).unwrap_or_else(|_| CString::default());
    let event = VirgulePageRow {
        result_row: usize::MAX,
        source_row: 0,
        values: std::ptr::null(),
        value_count: 0,
        message: message.as_ptr(),
    };
    // SAFETY: callback and context are supplied by the C host; message lives for this call.
    unsafe { callback(&event, context) };
}

/// Reads one bounded result page from a completed cache. The cache path is
/// supplied by the host from the completion import event, so the engine never
/// needs to retain a source file handle.
///
/// # Safety
/// `engine` must be an engine returned by `virgule_engine_create`; `cache_path`
/// must be a NUL-terminated UTF-8 string; and `callback` must remain callable
/// until this function returns.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn virgule_engine_read_csv_page(
    engine: *mut VirguleEngine,
    cache_path: *const c_char,
    offset: usize,
    limit: usize,
    callback: Option<VirgulePageCallback>,
    context: *mut c_void,
) -> i32 {
    let Some(callback) = callback else {
        return -1;
    };
    if engine.is_null() || cache_path.is_null() || limit == 0 {
        return -1;
    }
    // SAFETY: required by this function's C contract.
    let cache_path = unsafe { CStr::from_ptr(cache_path) };
    let Ok(cache_path) = cache_path.to_str() else {
        emit_ffi_page_error(callback, context, "The cache path is not UTF-8.");
        return 0;
    };
    let path = PathBuf::from(cache_path);
    let connection = match Connection::open(&path) {
        Ok(connection) => connection,
        Err(error) => {
            emit_ffi_page_error(callback, context, error);
            return 0;
        }
    };
    let cache = CsvCache { connection, path };
    let page = match cache.read_csv_page(offset, limit) {
        Ok(page) => page,
        Err(error) => {
            emit_ffi_page_error(callback, context, error);
            return 0;
        }
    };
    for (index, row) in page.rows.into_iter().enumerate() {
        let values = row
            .values
            .into_iter()
            .map(|value| CString::new(value).unwrap_or_else(|_| CString::default()))
            .collect::<Vec<_>>();
        let pointers = values
            .iter()
            .map(|value| value.as_ptr())
            .collect::<Vec<_>>();
        let message = CString::default();
        let event = VirgulePageRow {
            result_row: page.offset + index,
            source_row: row.source_row,
            values: pointers.as_ptr(),
            value_count: pointers.len(),
            message: message.as_ptr(),
        };
        // SAFETY: callback and context are supplied by the C host; all event storage lives for this call.
        unsafe { callback(&event, context) };
    }
    0
}

fn ffi_string(value: *const c_char) -> Result<String, &'static str> {
    if value.is_null() {
        return Err("A required query argument is missing.");
    }
    unsafe { CStr::from_ptr(value) }
        .to_str()
        .map(str::to_owned)
        .map_err(|_| "A query argument is not UTF-8.")
}

/// Validates a query and returns its result schema and count through the
/// existing import-style callback, avoiding an ABI-only allocation type.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn virgule_engine_describe_query(
    engine: *mut VirguleEngine,
    cache_path: *const c_char,
    sql: *const c_char,
    callback: Option<VirguleImportCallback>,
    context: *mut c_void,
) -> i32 {
    let Some(callback) = callback else {
        return -1;
    };
    if engine.is_null() {
        return -1;
    }
    let (Ok(cache_path), Ok(sql)) = (ffi_string(cache_path), ffi_string(sql)) else {
        emit_ffi_error(
            callback,
            context,
            &ImportError::Io(std::io::Error::new(
                std::io::ErrorKind::InvalidInput,
                "Invalid query arguments.",
            )),
        );
        return 0;
    };
    let connection = match Connection::open(&cache_path) {
        Ok(value) => value,
        Err(error) => {
            emit_ffi_error(
                callback,
                context,
                &ImportError::Io(std::io::Error::other(error)),
            );
            return 0;
        }
    };
    let cache = CsvCache {
        connection,
        path: PathBuf::from(&cache_path),
    };
    match cache.describe_query(&sql) {
        Ok(description) => emit_ffi_query_description(
            callback,
            context,
            description.column_names,
            description.row_count,
        ),
        Err(error) => emit_ffi_error(
            callback,
            context,
            &ImportError::Io(std::io::Error::new(std::io::ErrorKind::InvalidInput, error)),
        ),
    }
    0
}

/// Checks the current editor SQL without executing it or counting result rows.
/// A headers event signals success; an error event includes a one-based line
/// and column when SQLite identifies the invalid token.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn virgule_engine_validate_query(
    engine: *mut VirguleEngine,
    cache_path: *const c_char,
    sql: *const c_char,
    callback: Option<VirguleImportCallback>,
    context: *mut c_void,
) -> i32 {
    let Some(callback) = callback else {
        return -1;
    };
    if engine.is_null() {
        return -1;
    }
    let (Ok(cache_path), Ok(sql)) = (ffi_string(cache_path), ffi_string(sql)) else {
        emit_ffi_error(
            callback,
            context,
            &ImportError::Io(std::io::Error::new(
                std::io::ErrorKind::InvalidInput,
                "Invalid query arguments.",
            )),
        );
        return 0;
    };
    let connection = match Connection::open(&cache_path) {
        Ok(value) => value,
        Err(error) => {
            emit_ffi_error(
                callback,
                context,
                &ImportError::Io(std::io::Error::other(error)),
            );
            return 0;
        }
    };
    let cache = CsvCache {
        connection,
        path: PathBuf::from(&cache_path),
    };
    match cache.validate_query(&sql) {
        Ok(()) => emit_ffi_query_validation(callback, context),
        Err(error) => emit_ffi_error(
            callback,
            context,
            &ImportError::Io(std::io::Error::new(std::io::ErrorKind::InvalidInput, error)),
        ),
    }
    0
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn virgule_engine_read_query_page(
    engine: *mut VirguleEngine,
    cache_path: *const c_char,
    sql: *const c_char,
    offset: usize,
    limit: usize,
    callback: Option<VirgulePageCallback>,
    context: *mut c_void,
) -> i32 {
    let Some(callback) = callback else {
        return -1;
    };
    if engine.is_null() || limit == 0 {
        return -1;
    }
    let (Ok(cache_path), Ok(sql)) = (ffi_string(cache_path), ffi_string(sql)) else {
        emit_ffi_page_error(callback, context, "Invalid query arguments.");
        return 0;
    };
    let connection = match Connection::open(&cache_path) {
        Ok(value) => value,
        Err(error) => {
            emit_ffi_page_error(callback, context, error);
            return 0;
        }
    };
    let cache = CsvCache {
        connection,
        path: PathBuf::from(&cache_path),
    };
    let page = match cache.read_query_page(&sql, offset, limit) {
        Ok(value) => value,
        Err(error) => {
            emit_ffi_page_error(callback, context, error);
            return 0;
        }
    };
    for (index, row) in page.rows.into_iter().enumerate() {
        let values = row
            .values
            .into_iter()
            .map(|value| CString::new(value).unwrap_or_default())
            .collect::<Vec<_>>();
        let pointers = values
            .iter()
            .map(|value| value.as_ptr())
            .collect::<Vec<_>>();
        let message = CString::default();
        let event = VirgulePageRow {
            result_row: page.offset + index,
            source_row: row.source_row,
            values: pointers.as_ptr(),
            value_count: pointers.len(),
            message: message.as_ptr(),
        };
        unsafe { callback(&event, context) };
    }
    0
}
