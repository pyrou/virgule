//! The data engine exposed to the macOS application through a stable C ABI.

use std::ffi::{CStr, CString, c_void};
use std::fmt;
use std::fs;
use std::os::raw::c_char;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

use rusqlite::Connection;
use rusqlite::hooks::{AuthAction, AuthContext, Authorization};
use rusqlite::types::ValueRef;

/// Opaque state: its layout is intentionally private to Rust.
pub struct VirguleEngine {
    _private: (),
}

/// A notification emitted while importing a source file.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum ImportEvent {
    Started {
        total_bytes: u64,
    },
    Preview {
        row: usize,
        values: Vec<String>,
    },
    Progress {
        imported_rows: usize,
        total_bytes: u64,
    },
    Completed {
        imported_rows: usize,
        cache_path: PathBuf,
    },
}

const PREVIEW_ROW_LIMIT: usize = 20;
const PROGRESS_ROW_INTERVAL: usize = 1_000;

/// A local SQLite cache that is distinct from its read-only CSV source file.
pub struct CsvCache {
    connection: Connection,
    path: PathBuf,
}

/// One row of a result page. `source_row` remains stable while the cache exists.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CsvPageRow {
    pub source_row: i64,
    pub values: Vec<String>,
}

/// A bounded result slice for the virtualized grid.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CsvPage {
    pub offset: usize,
    pub rows: Vec<CsvPageRow>,
}

/// Why a SQL statement cannot be run against the read-only CSV cache.
#[derive(Debug)]
pub enum SqlValidationError {
    Empty,
    UnsupportedStatement { keyword: String },
    WriteOperation,
    Invalid(rusqlite::Error),
}

impl fmt::Display for SqlValidationError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Empty => formatter.write_str("Enter a SQL query."),
            Self::UnsupportedStatement { keyword } => write!(
                formatter,
                "Only SELECT, WITH, and EXPLAIN queries are allowed (found {keyword})."
            ),
            Self::WriteOperation => formatter.write_str("Queries must not modify the local cache."),
            Self::Invalid(error) => write!(formatter, "Invalid SQL query: {error}"),
        }
    }
}

impl std::error::Error for SqlValidationError {}

impl CsvCache {
    /// Creates or opens the cache associated with `source_file` in `cache_directory`.
    pub fn open_for_source(
        source_file: &Path,
        cache_directory: &Path,
    ) -> Result<Self, ImportError> {
        fs::create_dir_all(cache_directory).map_err(|error| ImportError::CacheDirectory {
            path: cache_directory.to_owned(),
            error,
        })?;
        let path = cache_path_for(source_file, cache_directory);
        let connection = Connection::open(&path)?;
        Ok(Self { connection, path })
    }

    /// The SQLite file managed by this cache.
    pub fn path(&self) -> &Path {
        &self.path
    }

    /// Provides the cache connection to the importer and query engine.
    pub fn connection(&self) -> &Connection {
        &self.connection
    }

    /// Validates one read-only SQLite query without executing it.
    ///
    /// The leading keyword is constrained for a predictable query-bar contract,
    /// while SQLite's authorizer rejects writes hidden inside common table
    /// expressions or an EXPLAIN statement.
    pub fn validate_query(&self, sql: &str) -> Result<(), SqlValidationError> {
        let keyword = first_sql_keyword(sql).ok_or(SqlValidationError::Empty)?;
        if !matches!(keyword.as_str(), "SELECT" | "WITH" | "EXPLAIN") {
            return Err(SqlValidationError::UnsupportedStatement { keyword });
        }

        let write_was_requested = Arc::new(AtomicBool::new(false));
        let authorizer_flag = Arc::clone(&write_was_requested);
        self.connection
            .authorizer(Some(move |context: AuthContext<'_>| {
                if is_read_only_action(context.action) {
                    Authorization::Allow
                } else {
                    authorizer_flag.store(true, Ordering::Relaxed);
                    Authorization::Deny
                }
            }));
        let validation = match self.connection.prepare(sql) {
            Ok(statement) if statement.readonly() => Ok(()),
            Ok(_) => Err(SqlValidationError::WriteOperation),
            Err(error) => Err(SqlValidationError::Invalid(error)),
        };
        self.connection
            .authorizer(None::<fn(AuthContext<'_>) -> Authorization>);

        if write_was_requested.load(Ordering::Relaxed) {
            return Err(SqlValidationError::WriteOperation);
        }
        validation
    }

    /// Loads exactly one bounded page from `csv`, never materializing the full
    /// result set for the AppKit host.
    pub fn read_csv_page(&self, offset: usize, limit: usize) -> rusqlite::Result<CsvPage> {
        let mut statement = self
            .connection
            .prepare("SELECT rowid, * FROM csv ORDER BY rowid LIMIT ?1 OFFSET ?2")?;
        let column_count = statement.column_count();
        let rows = statement
            .query_map((limit, offset), |row| {
                let source_row = row.get(0)?;
                let values = (1..column_count)
                    .map(|index| sqlite_value_to_string(row.get_ref(index)?))
                    .collect::<rusqlite::Result<Vec<_>>>()?;
                Ok(CsvPageRow { source_row, values })
            })
            .and_then(Iterator::collect)?;
        Ok(CsvPage { offset, rows })
    }

    /// Imports parsed records into an existing table as one all-or-nothing SQLite
    /// transaction. The destination table must have exactly `column_count` columns.
    ///
    /// Rows are inserted using one prepared statement, keeping the import bounded
    /// in SQLite rather than constructing a statement per CSV record.
    pub fn import_records<I>(
        &mut self,
        table_name: &str,
        column_count: usize,
        records: I,
    ) -> Result<usize, ImportError>
    where
        I: IntoIterator<Item = Result<Vec<String>, CsvParseError>>,
    {
        self.import_records_with_progress(table_name, column_count, records, |_| {})
    }

    fn import_records_with_progress<I, F>(
        &mut self,
        table_name: &str,
        column_count: usize,
        records: I,
        mut report_progress: F,
    ) -> Result<usize, ImportError>
    where
        I: IntoIterator<Item = Result<Vec<String>, CsvParseError>>,
        F: FnMut(usize),
    {
        if column_count == 0 {
            return Err(ImportError::NoColumns);
        }
        let table_name = quote_identifier(table_name);
        let placeholders = (1..=column_count)
            .map(|index| format!("?{index}"))
            .collect::<Vec<_>>()
            .join(", ");
        let sql = format!("INSERT INTO {table_name} VALUES ({placeholders})");
        let transaction = self.connection.transaction()?;
        let mut statement = transaction.prepare(&sql)?;
        let mut imported_rows = 0;
        for (record_index, record) in records.into_iter().enumerate() {
            let values = record?;
            if values.len() != column_count {
                return Err(ImportError::UnexpectedColumnCount {
                    record: record_index + 1,
                    expected: column_count,
                    actual: values.len(),
                });
            }
            statement.execute(rusqlite::params_from_iter(values))?;
            imported_rows += 1;
            if imported_rows % PROGRESS_ROW_INTERVAL == 0 {
                report_progress(imported_rows);
            }
        }
        drop(statement);
        transaction.commit()?;
        Ok(imported_rows)
    }

    /// Recreates the `csv` view table and its column metadata for one import.
    ///
    /// Source header labels are retained in `csv_columns`; SQL column identifiers
    /// are made non-empty and unique so every CSV can be queried safely.
    pub fn create_csv_table(
        &mut self,
        columns: impl IntoIterator<Item = CsvColumn>,
    ) -> rusqlite::Result<Vec<CsvColumnMetadata>> {
        let metadata = column_metadata(columns);
        let column_definitions = metadata
            .iter()
            .map(|column| {
                format!(
                    "{} {}",
                    quote_identifier(&column.sql_name),
                    sqlite_type_for(column.column_type)
                )
            })
            .collect::<Vec<_>>()
            .join(", ");
        let transaction = self.connection.transaction()?;
        transaction.execute_batch(
            "DROP TABLE IF EXISTS csv;\
             DROP TABLE IF EXISTS csv_columns;\
             CREATE TABLE csv_columns (\
                 ordinal INTEGER PRIMARY KEY,\
                 source_name TEXT NOT NULL,\
                 sql_name TEXT NOT NULL UNIQUE,\
                 inferred_type TEXT NOT NULL\
             );",
        )?;
        transaction.execute_batch(&format!("CREATE TABLE csv ({column_definitions})"))?;
        let mut statement = transaction.prepare(
            "INSERT INTO csv_columns (ordinal, source_name, sql_name, inferred_type) \
             VALUES (?1, ?2, ?3, ?4)",
        )?;
        for column in &metadata {
            statement.execute((
                column.ordinal,
                &column.source_name,
                &column.sql_name,
                column_type_name(column.column_type),
            ))?;
        }
        drop(statement);
        transaction.commit()?;
        Ok(metadata)
    }
}

fn first_sql_keyword(sql: &str) -> Option<String> {
    let mut remaining = sql;
    loop {
        remaining = remaining.trim_start();
        if let Some(comment) = remaining.strip_prefix("--") {
            remaining = comment.find('\n').map_or("", |end| &comment[end + 1..]);
            continue;
        }
        if let Some(comment) = remaining.strip_prefix("/*") {
            let end = comment.find("*/")?;
            remaining = &comment[end + 2..];
            continue;
        }
        break;
    }

    let keyword = remaining
        .chars()
        .take_while(|character| character.is_ascii_alphabetic())
        .collect::<String>();
    (!keyword.is_empty()).then(|| keyword.to_ascii_uppercase())
}

fn is_read_only_action(action: AuthAction<'_>) -> bool {
    matches!(
        action,
        AuthAction::Read { .. }
            | AuthAction::Select
            | AuthAction::Function { .. }
            | AuthAction::Recursive
    )
}

fn sqlite_value_to_string(value: ValueRef<'_>) -> rusqlite::Result<String> {
    match value {
        ValueRef::Null => Ok(String::new()),
        ValueRef::Integer(value) => Ok(value.to_string()),
        ValueRef::Real(value) => Ok(value.to_string()),
        ValueRef::Text(value) => Ok(std::str::from_utf8(value)
            .map_err(|error| {
                rusqlite::Error::FromSqlConversionFailure(
                    0,
                    rusqlite::types::Type::Text,
                    Box::new(error),
                )
            })?
            .to_owned()),
        ValueRef::Blob(_) => Err(rusqlite::Error::InvalidColumnType(
            0,
            "value".to_owned(),
            rusqlite::types::Type::Blob,
        )),
    }
}

/// A CSV column as detected from its header and values.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CsvColumn {
    pub source_name: String,
    pub column_type: ColumnType,
}

/// The mapping between a source CSV label and its queryable SQLite column.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CsvColumnMetadata {
    pub ordinal: usize,
    pub source_name: String,
    pub sql_name: String,
    pub column_type: ColumnType,
}

/// An error that prevents a CSV cache import from completing.
#[derive(Debug)]
pub enum ImportError {
    Io(std::io::Error),
    CacheDirectory {
        path: PathBuf,
        error: std::io::Error,
    },
    Decode(DecodeError),
    Csv(CsvParseError),
    Database(rusqlite::Error),
    NoColumns,
    NoRecords,
    NoDelimiter,
    UnexpectedColumnCount {
        record: usize,
        expected: usize,
        actual: usize,
    },
}

impl fmt::Display for ImportError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Io(error) => write!(formatter, "Could not read the CSV file: {error}"),
            Self::CacheDirectory { path, error } => write!(
                formatter,
                "Could not create the local cache directory at {}: {error}",
                path.display()
            ),
            Self::Decode(error) => write!(formatter, "Could not decode the CSV file: {error:?}"),
            Self::Csv(error) => write!(formatter, "Could not parse the CSV file: {error:?}"),
            Self::Database(error) => write!(formatter, "Could not create the local cache: {error}"),
            Self::NoColumns => formatter.write_str("The CSV file has no columns."),
            Self::NoRecords => formatter.write_str("The CSV file has no records."),
            Self::NoDelimiter => {
                formatter.write_str("Could not detect a delimiter; choose one manually.")
            }
            Self::UnexpectedColumnCount {
                record,
                expected,
                actual,
            } => write!(
                formatter,
                "Record {record} has {actual} columns; expected {expected}."
            ),
        }
    }
}

impl From<CsvParseError> for ImportError {
    fn from(error: CsvParseError) -> Self {
        Self::Csv(error)
    }
}

impl From<std::io::Error> for ImportError {
    fn from(error: std::io::Error) -> Self {
        Self::Io(error)
    }
}
impl From<DecodeError> for ImportError {
    fn from(error: DecodeError) -> Self {
        Self::Decode(error)
    }
}

impl From<rusqlite::Error> for ImportError {
    fn from(error: rusqlite::Error) -> Self {
        Self::Database(error)
    }
}

fn quote_identifier(identifier: &str) -> String {
    format!("\"{}\"", identifier.replace('"', "\"\""))
}

fn column_metadata(columns: impl IntoIterator<Item = CsvColumn>) -> Vec<CsvColumnMetadata> {
    let mut sql_names = Vec::<String>::new();
    columns
        .into_iter()
        .enumerate()
        .map(|(ordinal, column)| {
            let sql_name = unique_sql_name(&column.source_name, ordinal, &sql_names);
            sql_names.push(sql_name.clone());
            CsvColumnMetadata {
                ordinal,
                source_name: column.source_name,
                sql_name,
                column_type: column.column_type,
            }
        })
        .collect()
}

fn unique_sql_name(source_name: &str, ordinal: usize, existing_names: &[String]) -> String {
    let base_name = if source_name.trim().is_empty() {
        format!("column_{}", ordinal + 1)
    } else {
        source_name.to_owned()
    };
    if !existing_names
        .iter()
        .any(|name| name.eq_ignore_ascii_case(&base_name))
    {
        return base_name;
    }

    let mut suffix = 2;
    loop {
        let candidate = format!("{base_name}_{suffix}");
        if !existing_names
            .iter()
            .any(|name| name.eq_ignore_ascii_case(&candidate))
        {
            return candidate;
        }
        suffix += 1;
    }
}

fn sqlite_type_for(column_type: ColumnType) -> &'static str {
    match column_type {
        ColumnType::Boolean | ColumnType::Integer => "INTEGER",
        ColumnType::Decimal => "REAL",
        ColumnType::Null | ColumnType::Date | ColumnType::DateTime | ColumnType::Text => "TEXT",
    }
}

fn column_type_name(column_type: ColumnType) -> &'static str {
    match column_type {
        ColumnType::Null => "null",
        ColumnType::Boolean => "boolean",
        ColumnType::Integer => "integer",
        ColumnType::Decimal => "decimal",
        ColumnType::Date => "date",
        ColumnType::DateTime => "datetime",
        ColumnType::Text => "text",
    }
}

/// Returns a cache path that never writes beside the source CSV.
pub fn cache_path_for(source_file: &Path, cache_directory: &Path) -> PathBuf {
    let file_name = source_file
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or("csv");
    let source_identifier = source_file
        .canonicalize()
        .unwrap_or_else(|_| source_file.to_owned());
    cache_directory.join(format!(
        "{file_name}-{:016x}.virgule.sqlite",
        fnv1a_64(source_identifier.to_string_lossy().as_bytes())
    ))
}

fn fnv1a_64(bytes: &[u8]) -> u64 {
    bytes.iter().fold(0xcbf29ce484222325_u64, |hash, byte| {
        (hash ^ u64::from(*byte)).wrapping_mul(0x100000001b3)
    })
}

/// Delimiters supported by the CSV importer.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Delimiter {
    Comma,
    Semicolon,
    Tab,
    Pipe,
}

/// The delimiter selection requested by the caller for one import.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum DelimiterSelection {
    /// Inspect the input sample and choose a supported delimiter.
    Automatic,
    /// Use a user-selected delimiter without inspecting the input.
    Manual(Delimiter),
}

/// Text encodings accepted by the importer.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum TextEncoding {
    Utf8,
    Utf16LittleEndian,
    Utf16BigEndian,
    Windows1252,
}

/// The text encoding selection requested by the caller for one import.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum TextEncodingSelection {
    Automatic,
    Manual(TextEncoding),
}

/// An invalid byte sequence for the requested text encoding.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum DecodeError {
    InvalidUtf8,
    OddUtf16ByteCount,
    InvalidUtf16,
}

/// How the importer should interpret the first CSV record.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum HeaderSelection {
    /// Infer whether the first record contains column names.
    Automatic,
    /// Treat the first record as column names.
    Present,
    /// Treat every record as data.
    Absent,
}

impl HeaderSelection {
    /// Resolves the header choice from the first two parsed records.
    pub fn resolve(self, first_record: &[String], second_record: Option<&[String]>) -> bool {
        match self {
            Self::Automatic => looks_like_header(first_record, second_record),
            Self::Present => true,
            Self::Absent => false,
        }
    }
}

fn looks_like_header(first_record: &[String], second_record: Option<&[String]>) -> bool {
    if first_record.is_empty() || first_record.iter().any(|value| value.trim().is_empty()) {
        return false;
    }
    for (index, value) in first_record.iter().enumerate() {
        if first_record[..index]
            .iter()
            .any(|previous| previous.eq_ignore_ascii_case(value))
        {
            return false;
        }
    }
    second_record.is_some_and(|record| {
        record.len() == first_record.len()
            && record.iter().zip(first_record).any(|(data, name)| {
                data != name && data_looks_typed(data) && !data_looks_typed(name)
            })
    })
}

fn data_looks_typed(value: &str) -> bool {
    value.parse::<f64>().is_ok()
        || matches!(
            value.to_ascii_lowercase().as_str(),
            "true" | "false" | "yes" | "no"
        )
}

impl TextEncodingSelection {
    /// Decodes bytes using the requested encoding or a conservative detected encoding.
    pub fn decode(self, bytes: &[u8]) -> Result<String, DecodeError> {
        let encoding = match self {
            Self::Automatic => detect_text_encoding(bytes),
            Self::Manual(encoding) => encoding,
        };
        decode_text(bytes, encoding)
    }
}

/// Detects byte-order marks, UTF-8, and UTF-16 streams with an ASCII-shaped sample.
///
/// A byte stream that is valid UTF-8 is deliberately treated as UTF-8; Windows-1252
/// is used only as the lossless fallback for invalid UTF-8 input.
pub fn detect_text_encoding(bytes: &[u8]) -> TextEncoding {
    if bytes.starts_with(&[0xEF, 0xBB, 0xBF]) {
        TextEncoding::Utf8
    } else if bytes.starts_with(&[0xFF, 0xFE]) {
        TextEncoding::Utf16LittleEndian
    } else if bytes.starts_with(&[0xFE, 0xFF]) {
        TextEncoding::Utf16BigEndian
    } else if std::str::from_utf8(bytes).is_ok() {
        TextEncoding::Utf8
    } else if looks_like_utf16(bytes, true) {
        TextEncoding::Utf16LittleEndian
    } else if looks_like_utf16(bytes, false) {
        TextEncoding::Utf16BigEndian
    } else {
        TextEncoding::Windows1252
    }
}

/// Decodes a byte stream in a known supported encoding.
pub fn decode_text(bytes: &[u8], encoding: TextEncoding) -> Result<String, DecodeError> {
    match encoding {
        TextEncoding::Utf8 => {
            let bytes = bytes.strip_prefix(&[0xEF, 0xBB, 0xBF]).unwrap_or(bytes);
            std::str::from_utf8(bytes)
                .map(str::to_owned)
                .map_err(|_| DecodeError::InvalidUtf8)
        }
        TextEncoding::Utf16LittleEndian => decode_utf16(bytes, true),
        TextEncoding::Utf16BigEndian => decode_utf16(bytes, false),
        TextEncoding::Windows1252 => Ok(decode_windows_1252(bytes)),
    }
}

fn looks_like_utf16(bytes: &[u8], little_endian: bool) -> bool {
    let sample = &bytes[..bytes.len().min(100) / 2 * 2];
    if sample.len() < 4 {
        return false;
    }
    let nulls_in_expected_half = sample
        .chunks_exact(2)
        .filter(|pair| pair[usize::from(little_endian)] == 0)
        .count();
    nulls_in_expected_half * 2 >= sample.len() / 2
}

fn decode_utf16(bytes: &[u8], little_endian: bool) -> Result<String, DecodeError> {
    let bytes = match (little_endian, bytes) {
        (true, [0xFF, 0xFE, rest @ ..]) | (false, [0xFE, 0xFF, rest @ ..]) => rest,
        _ => bytes,
    };
    let chunks = bytes.chunks_exact(2);
    if !chunks.remainder().is_empty() {
        return Err(DecodeError::OddUtf16ByteCount);
    }
    let units = chunks.map(|pair| {
        if little_endian {
            u16::from_le_bytes([pair[0], pair[1]])
        } else {
            u16::from_be_bytes([pair[0], pair[1]])
        }
    });
    std::char::decode_utf16(units)
        .collect::<Result<String, _>>()
        .map_err(|_| DecodeError::InvalidUtf16)
}

fn decode_windows_1252(bytes: &[u8]) -> String {
    bytes
        .iter()
        .map(|&byte| match byte {
            0x80 => '€',
            0x82 => '‚',
            0x83 => 'ƒ',
            0x84 => '„',
            0x85 => '…',
            0x86 => '†',
            0x87 => '‡',
            0x88 => 'ˆ',
            0x89 => '‰',
            0x8A => 'Š',
            0x8B => '‹',
            0x8C => 'Œ',
            0x8E => 'Ž',
            0x91 => '‘',
            0x92 => '’',
            0x93 => '“',
            0x94 => '”',
            0x95 => '•',
            0x96 => '–',
            0x97 => '—',
            0x98 => '˜',
            0x99 => '™',
            0x9A => 'š',
            0x9B => '›',
            0x9C => 'œ',
            0x9E => 'ž',
            0x9F => 'Ÿ',
            _ => char::from(byte),
        })
        .collect()
}

/// A syntax error encountered while reading CSV records.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum CsvParseError {
    UnterminatedQuotedField,
    UnexpectedCharacterAfterClosingQuote,
}

/// The storage type inferred from a complete CSV column.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ColumnType {
    Null,
    Boolean,
    Integer,
    Decimal,
    Date,
    DateTime,
    Text,
}

/// Infers a column type without coercing ambiguous values.
pub fn infer_column_type<'value>(values: impl IntoIterator<Item = &'value str>) -> ColumnType {
    let mut inferred = ColumnType::Null;
    for value in values {
        let value_type = classify_value(value);
        inferred = merge_column_types(inferred, value_type);
        if inferred == ColumnType::Text {
            return ColumnType::Text;
        }
    }
    inferred
}

fn classify_value(value: &str) -> ColumnType {
    if value.is_empty() {
        ColumnType::Null
    } else if matches!(value, "true" | "false") {
        ColumnType::Boolean
    } else if is_unambiguous_integer(value) {
        ColumnType::Integer
    } else if is_decimal(value) {
        ColumnType::Decimal
    } else if is_datetime(value) {
        ColumnType::DateTime
    } else if is_date(value) {
        ColumnType::Date
    } else {
        ColumnType::Text
    }
}

fn merge_column_types(current: ColumnType, next: ColumnType) -> ColumnType {
    match (current, next) {
        (ColumnType::Null, value) | (value, ColumnType::Null) => value,
        (left, right) if left == right => left,
        (ColumnType::Integer, ColumnType::Decimal) | (ColumnType::Decimal, ColumnType::Integer) => {
            ColumnType::Decimal
        }
        (ColumnType::Date, ColumnType::DateTime) | (ColumnType::DateTime, ColumnType::Date) => {
            ColumnType::DateTime
        }
        _ => ColumnType::Text,
    }
}

fn is_unambiguous_integer(value: &str) -> bool {
    let digits = value.strip_prefix('-').unwrap_or(value);
    !digits.is_empty()
        && (digits == "0" || !digits.starts_with('0'))
        && value.parse::<i64>().is_ok()
}

fn is_decimal(value: &str) -> bool {
    (value.contains('.') || value.contains('e') || value.contains('E'))
        && value.parse::<f64>().is_ok_and(f64::is_finite)
}

fn is_date(value: &str) -> bool {
    let Some((year, month, day)) = split_date(value) else {
        return false;
    };
    if year.len() != 4
        || !year.bytes().all(|byte| byte.is_ascii_digit())
        || month.len() != 2
        || day.len() != 2
    {
        return false;
    }
    let (Ok(year), Ok(month), Ok(day)) =
        (year.parse::<u16>(), month.parse::<u8>(), day.parse::<u8>())
    else {
        return false;
    };
    day > 0 && day <= days_in_month(year, month)
}

fn days_in_month(year: u16, month: u8) -> u8 {
    match month {
        1 | 3 | 5 | 7 | 8 | 10 | 12 => 31,
        4 | 6 | 9 | 11 => 30,
        2 if year % 400 == 0 || (year % 4 == 0 && year % 100 != 0) => 29,
        2 => 28,
        _ => 0,
    }
}

fn is_datetime(value: &str) -> bool {
    let Some((date, time)) = value.split_once('T').or_else(|| value.split_once(' ')) else {
        return false;
    };
    let Some((hour, minute)) = time.split_once(':') else {
        return false;
    };
    let Some(minute_prefix) = minute.get(..2) else {
        return false;
    };
    is_date(date)
        && hour.len() == 2
        && minute.len() >= 2
        && hour.parse::<u8>().is_ok_and(|hour| hour < 24)
        && minute_prefix.parse::<u8>().is_ok_and(|minute| minute < 60)
}

fn split_date(value: &str) -> Option<(&str, &str, &str)> {
    let mut components = value.split('-');
    Some((components.next()?, components.next()?, components.next()?))
        .filter(|_| components.next().is_none())
}

/// An iterator over CSV records that retains only the current record in memory.
pub struct CsvRecords<'input> {
    input: &'input str,
    delimiter: char,
    position: usize,
}

impl<'input> CsvRecords<'input> {
    pub fn new(input: &'input str, delimiter: Delimiter) -> Self {
        Self {
            input,
            delimiter: delimiter.as_char(),
            position: 0,
        }
    }

    fn next_record(&mut self) -> Option<Result<Vec<String>, CsvParseError>> {
        if self.position == self.input.len() {
            return None;
        }

        let mut fields = Vec::new();
        let mut field = String::new();
        let mut quoted = false;
        let mut after_quote = false;
        let record_start = self.position;
        let mut iterator = self.input[record_start..].char_indices().peekable();

        while let Some((offset, character)) = iterator.next() {
            let next_position = record_start + offset + character.len_utf8();
            if quoted {
                if character == '"' {
                    if iterator.peek().is_some_and(|(_, next)| *next == '"') {
                        let (escaped_offset, escaped_quote) =
                            iterator.next().expect("peeked quote");
                        field.push(escaped_quote);
                        self.position = record_start + escaped_offset + escaped_quote.len_utf8();
                    } else {
                        quoted = false;
                        after_quote = true;
                        self.position = next_position;
                    }
                } else {
                    field.push(character);
                    self.position = next_position;
                }
                continue;
            }

            if after_quote && character != self.delimiter && character != '\n' && character != '\r'
            {
                self.position = next_position;
                return Some(Err(CsvParseError::UnexpectedCharacterAfterClosingQuote));
            }
            if character == '"' && field.is_empty() && !after_quote {
                quoted = true;
                self.position = next_position;
            } else if character == self.delimiter {
                fields.push(std::mem::take(&mut field));
                after_quote = false;
                self.position = next_position;
            } else if character == '\n' || character == '\r' {
                if character == '\r' && iterator.peek().is_some_and(|(_, next)| *next == '\n') {
                    let (line_feed_offset, line_feed) = iterator.next().expect("peeked line feed");
                    self.position = record_start + line_feed_offset + line_feed.len_utf8();
                } else {
                    self.position = next_position;
                }
                fields.push(field);
                return Some(Ok(fields));
            } else {
                field.push(character);
                self.position = next_position;
            }
        }

        if quoted {
            self.position = self.input.len();
            Some(Err(CsvParseError::UnterminatedQuotedField))
        } else {
            self.position = self.input.len();
            fields.push(field);
            Some(Ok(fields))
        }
    }
}

impl Iterator for CsvRecords<'_> {
    type Item = Result<Vec<String>, CsvParseError>;

    fn next(&mut self) -> Option<Self::Item> {
        self.next_record()
    }
}

impl DelimiterSelection {
    /// Resolves this selection against an input sample.
    pub fn resolve(self, input: &str) -> Option<Delimiter> {
        match self {
            Self::Automatic => detect_delimiter(input),
            Self::Manual(delimiter) => Some(delimiter),
        }
    }
}

impl Delimiter {
    const CANDIDATES: [Self; 4] = [Self::Comma, Self::Semicolon, Self::Tab, Self::Pipe];

    const fn as_char(self) -> char {
        match self {
            Self::Comma => ',',
            Self::Semicolon => ';',
            Self::Tab => '\t',
            Self::Pipe => '|',
        }
    }
}

/// Selects the delimiter that produces the most consistent multi-column records.
///
/// At most the first 100 non-empty records are inspected. Delimiter-like characters
/// inside quoted fields are ignored, including after escaped (`""`) quotes.
pub fn detect_delimiter(input: &str) -> Option<Delimiter> {
    let mut best = None;

    for delimiter in Delimiter::CANDIDATES {
        let record_widths = record_widths(input, delimiter.as_char());
        let Some((consistent_records, width)) = most_common_width(&record_widths) else {
            continue;
        };

        if width < 2 {
            continue;
        }

        let score = (consistent_records, width);
        if best.is_none_or(|(_, best_score)| score > best_score) {
            best = Some((delimiter, score));
        }
    }

    best.map(|(delimiter, _)| delimiter)
}

fn record_widths(input: &str, delimiter: char) -> Vec<usize> {
    const SAMPLE_RECORDS: usize = 100;
    let mut widths = Vec::with_capacity(SAMPLE_RECORDS);
    let mut fields = 1;
    let mut in_quotes = false;
    let mut has_content = false;
    let mut characters = input.chars().peekable();

    while let Some(character) = characters.next() {
        if character == '"' {
            if in_quotes && characters.peek() == Some(&'"') {
                characters.next();
                has_content = true;
            } else {
                in_quotes = !in_quotes;
            }
            continue;
        }

        if !in_quotes && character == delimiter {
            fields += 1;
            has_content = true;
        } else if !in_quotes && (character == '\n' || character == '\r') {
            if character == '\r' && characters.peek() == Some(&'\n') {
                characters.next();
            }
            if has_content {
                widths.push(fields);
                if widths.len() == SAMPLE_RECORDS {
                    break;
                }
            }
            fields = 1;
            has_content = false;
        } else {
            has_content = true;
        }
    }

    if has_content && widths.len() < SAMPLE_RECORDS {
        widths.push(fields);
    }
    widths
}

fn most_common_width(widths: &[usize]) -> Option<(usize, usize)> {
    let mut candidates: Vec<(usize, usize)> = Vec::new();
    for &width in widths {
        if let Some((count, _)) = candidates.iter_mut().find(|(_, value)| *value == width) {
            *count += 1;
        } else {
            candidates.push((1, width));
        }
    }
    candidates.into_iter().max()
}

/// Imports a source file into its local cache and reports preview and lifecycle events.
/// Preview events are delivered before the SQLite transaction commits, allowing the
/// host to show rows while the cache is still being populated.
pub fn import_source_file(
    source_file: &Path,
    cache_directory: &Path,
    mut report: impl FnMut(ImportEvent),
) -> Result<(), ImportError> {
    let bytes = fs::read(source_file)?;
    let total_bytes = bytes.len() as u64;
    report(ImportEvent::Started { total_bytes });
    let input = TextEncodingSelection::Automatic.decode(&bytes)?;
    let delimiter = DelimiterSelection::Automatic
        .resolve(&input)
        .ok_or(ImportError::NoDelimiter)?;
    let mut records = CsvRecords::new(&input, delimiter);
    let first = records.next().transpose()?.ok_or(ImportError::NoRecords)?;
    let second = records.next().transpose()?;
    let has_header = HeaderSelection::Automatic.resolve(&first, second.as_deref());
    let headers = if has_header {
        first.clone()
    } else {
        (0..first.len())
            .map(|index| format!("column_{}", index + 1))
            .collect()
    };
    if headers.is_empty() {
        return Err(ImportError::NoColumns);
    }
    let mut data = Vec::new();
    if !has_header {
        data.push(first);
    }
    if let Some(record) = second {
        data.push(record);
    }
    for record in records {
        data.push(record?);
    }
    for (index, row) in data.iter().take(PREVIEW_ROW_LIMIT).enumerate() {
        report(ImportEvent::Preview {
            row: index + 1,
            values: row.clone(),
        });
    }
    let columns = headers.iter().enumerate().map(|(index, name)| CsvColumn {
        source_name: name.clone(),
        column_type: infer_column_type(
            data.iter()
                .filter_map(|row| row.get(index).map(String::as_str)),
        ),
    });
    let mut cache = CsvCache::open_for_source(source_file, cache_directory)?;
    cache.create_csv_table(columns)?;
    let imported_rows = cache.import_records_with_progress(
        "csv",
        headers.len(),
        data.into_iter().map(Ok),
        |rows| {
            report(ImportEvent::Progress {
                imported_rows: rows,
                total_bytes,
            });
        },
    )?;
    report(ImportEvent::Progress {
        imported_rows,
        total_bytes,
    });
    report(ImportEvent::Completed {
        imported_rows,
        cache_path: cache.path().to_owned(),
    });
    Ok(())
}

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

fn emit_ffi_event(callback: VirguleImportCallback, context: *mut c_void, event: ImportEvent) {
    let (kind, row, imported_rows, total_bytes, values, message) = match event {
        ImportEvent::Started { total_bytes } => (0, 0, 0, total_bytes, Vec::new(), String::new()),
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn import_file_reports_preview_before_completion() {
        let directory =
            std::env::temp_dir().join(format!("virgule-engine-events-{}", std::process::id()));
        fs::create_dir_all(&directory).expect("creates temporary directory");
        let source = directory.join("people.csv");
        let source_bytes = b"name,age\nAda,42\nLin,35\n";
        fs::write(&source, source_bytes).expect("writes CSV fixture");
        let mut events = Vec::new();

        let cache_directory = directory.join("cache");
        import_source_file(&source, &cache_directory, |event| events.push(event))
            .expect("imports fixture");

        assert!(
            matches!(events.first(), Some(ImportEvent::Started { total_bytes }) if *total_bytes == source_bytes.len() as u64)
        );
        let preview_index = events
            .iter()
            .position(|event| matches!(event, ImportEvent::Preview { .. }))
            .expect("reports preview");
        let completion_index = events
            .iter()
            .position(|event| {
                matches!(
                    event,
                    ImportEvent::Completed {
                        imported_rows: 2,
                        ..
                    }
                )
            })
            .expect("reports completion");
        assert!(preview_index < completion_index);
        assert!(events.iter().any(|event| matches!(event, ImportEvent::Preview { values, .. } if values == &vec!["Ada".to_owned(), "42".to_owned()])));
        assert!(events.iter().any(|event| matches!(
            event,
            ImportEvent::Completed { cache_path, .. } if cache_path.starts_with(&cache_directory)
        )));
        assert_eq!(
            fs::read(&source).expect("rereads CSV fixture"),
            source_bytes
        );

        fs::remove_file(cache_path_for(&source, &cache_directory)).expect("removes cache fixture");
        fs::remove_dir(cache_directory).expect("removes cache directory");
        fs::remove_file(source).expect("removes CSV fixture");
        fs::remove_dir(directory).expect("removes temporary directory");
    }

    #[test]
    fn detects_each_supported_delimiter() {
        for (input, expected) in [
            ("name,city\nAda,Paris\nLin,Tokyo", Delimiter::Comma),
            ("name;city\nAda;Paris\nLin;Tokyo", Delimiter::Semicolon),
            ("name\tcity\nAda\tParis\nLin\tTokyo", Delimiter::Tab),
            ("name|city\nAda|Paris\nLin|Tokyo", Delimiter::Pipe),
        ] {
            assert_eq!(detect_delimiter(input), Some(expected));
        }
    }

    #[test]
    fn ignores_delimiters_inside_quoted_fields() {
        let input = "name;note\nAda;\"Paris, France | Île-de-France\"\nLin;\"Tokyo, Japan\"";
        assert_eq!(detect_delimiter(input), Some(Delimiter::Semicolon));
    }

    #[test]
    fn handles_escaped_quotes_when_detecting_delimiter() {
        let input = "name,quote\nAda,\"She said \"\"hello, world\"\"\"\nLin,ok";
        assert_eq!(detect_delimiter(input), Some(Delimiter::Comma));
    }

    #[test]
    fn returns_none_for_a_single_column_file() {
        assert_eq!(detect_delimiter("name\nAda\nLin"), None);
    }

    #[test]
    fn manual_delimiter_selection_takes_precedence_over_detection() {
        let input = "name,city\nAda,Paris";
        assert_eq!(
            DelimiterSelection::Manual(Delimiter::Pipe).resolve(input),
            Some(Delimiter::Pipe)
        );
    }

    #[test]
    fn automatic_delimiter_selection_uses_detection() {
        let input = "name\tcity\nAda\tParis";
        assert_eq!(
            DelimiterSelection::Automatic.resolve(input),
            Some(Delimiter::Tab)
        );
    }

    #[test]
    fn decodes_utf8_with_a_bom() {
        assert_eq!(
            TextEncodingSelection::Automatic.decode(b"\xEF\xBB\xBFname,city"),
            Ok("name,city".to_owned())
        );
    }

    #[test]
    fn detects_and_decodes_utf16_with_bom() {
        let utf16_le = [0xFF, 0xFE, b'n', 0, b'a', 0, b'm', 0, b'e', 0];
        assert_eq!(
            TextEncodingSelection::Automatic.decode(&utf16_le),
            Ok("name".to_owned())
        );
    }

    #[test]
    fn decodes_manually_selected_utf16_big_endian() {
        let utf16_be = [0, b'n', 0, b'a', 0, b'm', 0, b'e'];
        assert_eq!(
            TextEncodingSelection::Manual(TextEncoding::Utf16BigEndian).decode(&utf16_be),
            Ok("name".to_owned())
        );
    }

    #[test]
    fn falls_back_to_windows_1252_for_invalid_utf8() {
        assert_eq!(
            TextEncodingSelection::Automatic.decode(b"caf\xE9 \x80"),
            Ok("café €".to_owned())
        );
    }

    #[test]
    fn reports_invalid_manually_selected_utf8() {
        assert_eq!(
            TextEncodingSelection::Manual(TextEncoding::Utf8).decode(b"\xE9"),
            Err(DecodeError::InvalidUtf8)
        );
    }

    #[test]
    fn cache_path_uses_the_app_cache_directory_without_replacing_the_source() {
        let source = Path::new("/tmp/export.csv");
        let cache_directory = Path::new("/tmp/Virgule");
        assert_eq!(
            cache_path_for(source, cache_directory),
            PathBuf::from("/tmp/Virgule/export.csv-b4252aaf68ef7074.virgule.sqlite")
        );
    }

    #[test]
    fn imports_records_with_one_prepared_statement() {
        let connection = Connection::open_in_memory().expect("opens in-memory SQLite");
        connection
            .execute_batch("CREATE TABLE import_target (name TEXT, city TEXT)")
            .expect("creates import target");
        let mut cache = CsvCache {
            connection,
            path: PathBuf::from(":memory:"),
        };
        let records = CsvRecords::new("Ada,Paris\nLin,Tokyo", Delimiter::Comma);

        assert!(matches!(
            cache.import_records("import_target", 2, records),
            Ok(2)
        ));
        let mut statement = cache
            .connection()
            .prepare("SELECT name, city FROM import_target ORDER BY rowid")
            .expect("prepares result query");
        let rows = statement
            .query_map([], |row| {
                Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
            })
            .expect("queries imported rows")
            .collect::<Result<Vec<_>, _>>()
            .expect("reads imported rows");
        assert_eq!(
            rows,
            vec![
                ("Ada".to_owned(), "Paris".to_owned()),
                ("Lin".to_owned(), "Tokyo".to_owned()),
            ]
        );
    }

    #[test]
    fn reads_only_the_requested_csv_page_with_stable_row_numbers() {
        let connection = Connection::open_in_memory().expect("opens in-memory cache");
        let mut cache = CsvCache {
            connection,
            path: PathBuf::from(":memory:"),
        };
        cache
            .create_csv_table([CsvColumn {
                source_name: "name".to_owned(),
                column_type: ColumnType::Text,
            }])
            .expect("creates CSV table");
        cache
            .import_records(
                "csv",
                1,
                ["Ada", "Lin", "Maya", "Noah"]
                    .into_iter()
                    .map(|name| Ok(vec![name.to_owned()])),
            )
            .expect("imports rows");

        assert_eq!(
            cache.read_csv_page(1, 2).expect("reads bounded page"),
            CsvPage {
                offset: 1,
                rows: vec![
                    CsvPageRow {
                        source_row: 2,
                        values: vec!["Lin".to_owned()],
                    },
                    CsvPageRow {
                        source_row: 3,
                        values: vec!["Maya".to_owned()],
                    },
                ],
            }
        );
        assert!(
            cache
                .read_csv_page(4, 2)
                .expect("reads final page")
                .rows
                .is_empty()
        );
    }

    #[test]
    fn validates_read_only_select_with_and_explain_queries() {
        let connection = Connection::open_in_memory().expect("opens in-memory cache");
        connection
            .execute_batch("CREATE TABLE csv (name TEXT); INSERT INTO csv VALUES ('Ada')")
            .expect("creates CSV fixture");
        let cache = CsvCache {
            connection,
            path: PathBuf::from(":memory:"),
        };

        for sql in [
            "SELECT name FROM csv",
            "-- a saved query\nWITH people AS (SELECT name FROM csv) SELECT * FROM people",
            "EXPLAIN QUERY PLAN SELECT name FROM csv",
        ] {
            assert!(cache.validate_query(sql).is_ok(), "should accept: {sql}");
        }
    }

    #[test]
    fn rejects_write_and_non_query_sql() {
        let connection = Connection::open_in_memory().expect("opens in-memory cache");
        connection
            .execute_batch("CREATE TABLE csv (name TEXT)")
            .expect("creates CSV fixture");
        let cache = CsvCache {
            connection,
            path: PathBuf::from(":memory:"),
        };

        for sql in [
            "INSERT INTO csv VALUES ('Ada')",
            "UPDATE csv SET name = 'Lin'",
            "DELETE FROM csv",
            "DROP TABLE csv",
            "ATTACH DATABASE ':memory:' AS other",
            "CREATE TABLE temporary_table (value TEXT)",
            "EXPLAIN UPDATE csv SET name = 'Maya'",
        ] {
            assert!(
                matches!(
                    cache.validate_query(sql),
                    Err(SqlValidationError::WriteOperation)
                        | Err(SqlValidationError::UnsupportedStatement { .. })
                ),
                "should reject: {sql}"
            );
        }
        assert!(matches!(
            cache.validate_query("SELECT * FROM csv; DELETE FROM csv"),
            Err(SqlValidationError::Invalid(_)) | Err(SqlValidationError::WriteOperation)
        ));
    }

    #[test]
    fn rolls_back_the_entire_import_after_a_csv_error() {
        let connection = Connection::open_in_memory().expect("opens in-memory SQLite");
        connection
            .execute_batch("CREATE TABLE import_target (value TEXT)")
            .expect("creates import target");
        let mut cache = CsvCache {
            connection,
            path: PathBuf::from(":memory:"),
        };
        let records = vec![
            Ok(vec!["kept only if committed".to_owned()]),
            Err(CsvParseError::UnterminatedQuotedField),
        ];

        assert!(matches!(
            cache.import_records("import_target", 1, records),
            Err(ImportError::Csv(CsvParseError::UnterminatedQuotedField))
        ));
        let count: i64 = cache
            .connection()
            .query_row("SELECT COUNT(*) FROM import_target", [], |row| row.get(0))
            .expect("counts rows after failed import");
        assert_eq!(count, 0);
    }

    #[test]
    fn rolls_back_the_entire_import_when_a_record_has_the_wrong_width() {
        let connection = Connection::open_in_memory().expect("opens in-memory SQLite");
        connection
            .execute_batch("CREATE TABLE import_target (first TEXT, second TEXT)")
            .expect("creates import target");
        let mut cache = CsvCache {
            connection,
            path: PathBuf::from(":memory:"),
        };

        let error = cache
            .import_records(
                "import_target",
                2,
                vec![
                    Ok(vec!["Ada".to_owned(), "Paris".to_owned()]),
                    Ok(vec!["Lin".to_owned()]),
                ],
            )
            .expect_err("rejects an uneven CSV record");
        assert!(matches!(
            error,
            ImportError::UnexpectedColumnCount {
                record: 2,
                expected: 2,
                actual: 1,
            }
        ));
        let count: i64 = cache
            .connection()
            .query_row("SELECT COUNT(*) FROM import_target", [], |row| row.get(0))
            .expect("counts rows after failed import");
        assert_eq!(count, 0);
    }

    #[test]
    fn creates_the_csv_table_and_retains_column_metadata() {
        let connection = Connection::open_in_memory().expect("opens in-memory SQLite");
        let mut cache = CsvCache {
            connection,
            path: PathBuf::from(":memory:"),
        };

        let columns = cache
            .create_csv_table([
                CsvColumn {
                    source_name: "Name".to_owned(),
                    column_type: ColumnType::Text,
                },
                CsvColumn {
                    source_name: "Age".to_owned(),
                    column_type: ColumnType::Integer,
                },
                CsvColumn {
                    source_name: "Created at".to_owned(),
                    column_type: ColumnType::DateTime,
                },
            ])
            .expect("creates CSV schema");

        assert_eq!(
            columns,
            vec![
                CsvColumnMetadata {
                    ordinal: 0,
                    source_name: "Name".to_owned(),
                    sql_name: "Name".to_owned(),
                    column_type: ColumnType::Text,
                },
                CsvColumnMetadata {
                    ordinal: 1,
                    source_name: "Age".to_owned(),
                    sql_name: "Age".to_owned(),
                    column_type: ColumnType::Integer,
                },
                CsvColumnMetadata {
                    ordinal: 2,
                    source_name: "Created at".to_owned(),
                    sql_name: "Created at".to_owned(),
                    column_type: ColumnType::DateTime,
                },
            ]
        );
        let types = cache
            .connection()
            .prepare("PRAGMA table_info(csv)")
            .expect("prepares schema query")
            .query_map([], |row| {
                Ok((row.get::<_, String>(1)?, row.get::<_, String>(2)?))
            })
            .expect("queries schema")
            .collect::<Result<Vec<_>, _>>()
            .expect("reads schema");
        assert_eq!(
            types,
            vec![
                ("Name".to_owned(), "TEXT".to_owned()),
                ("Age".to_owned(), "INTEGER".to_owned()),
                ("Created at".to_owned(), "TEXT".to_owned()),
            ]
        );
        let names = cache
            .connection()
            .prepare(
                "SELECT source_name, sql_name, inferred_type FROM csv_columns ORDER BY ordinal",
            )
            .expect("prepares metadata query")
            .query_map([], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, String>(2)?,
                ))
            })
            .expect("queries metadata")
            .collect::<Result<Vec<_>, _>>()
            .expect("reads metadata");
        assert_eq!(
            names,
            vec![
                ("Name".to_owned(), "Name".to_owned(), "text".to_owned()),
                ("Age".to_owned(), "Age".to_owned(), "integer".to_owned()),
                (
                    "Created at".to_owned(),
                    "Created at".to_owned(),
                    "datetime".to_owned(),
                ),
            ]
        );
    }

    #[test]
    fn makes_empty_and_duplicate_headers_queryable_without_losing_the_source_labels() {
        let connection = Connection::open_in_memory().expect("opens in-memory SQLite");
        let mut cache = CsvCache {
            connection,
            path: PathBuf::from(":memory:"),
        };

        let columns = cache
            .create_csv_table([
                CsvColumn {
                    source_name: "".to_owned(),
                    column_type: ColumnType::Text,
                },
                CsvColumn {
                    source_name: "name".to_owned(),
                    column_type: ColumnType::Text,
                },
                CsvColumn {
                    source_name: "name".to_owned(),
                    column_type: ColumnType::Text,
                },
            ])
            .expect("creates CSV schema");

        assert_eq!(
            columns
                .iter()
                .map(|column| column.sql_name.as_str())
                .collect::<Vec<_>>(),
            vec!["column_1", "name", "name_2"]
        );
        cache
            .import_records(
                "csv",
                3,
                vec![Ok(vec![
                    "Ada".to_owned(),
                    "first".to_owned(),
                    "second".to_owned(),
                ])],
            )
            .expect("imports using generated names");
        let row: (String, String, String) = cache
            .connection()
            .query_row("SELECT column_1, name, name_2 FROM csv", [], |row| {
                Ok((row.get(0)?, row.get(1)?, row.get(2)?))
            })
            .expect("queries imported row");
        assert_eq!(
            row,
            ("Ada".to_owned(), "first".to_owned(), "second".to_owned())
        );
    }

    #[test]
    fn explicit_header_selection_supports_files_with_and_without_headers() {
        let first_record = vec!["Ada".to_owned(), "Paris".to_owned()];
        assert!(HeaderSelection::Present.resolve(&first_record, None));
        assert!(!HeaderSelection::Absent.resolve(&first_record, None));
    }

    #[test]
    fn automatic_header_selection_recognizes_names_followed_by_typed_data() {
        let header = vec!["name".to_owned(), "active".to_owned(), "age".to_owned()];
        let data = vec!["Ada".to_owned(), "true".to_owned(), "42".to_owned()];
        assert!(HeaderSelection::Automatic.resolve(&header, Some(&data)));
    }

    #[test]
    fn automatic_header_selection_keeps_ambiguous_text_rows_as_data() {
        let first_row = vec!["Ada".to_owned(), "Paris".to_owned()];
        let second_row = vec!["Lin".to_owned(), "Tokyo".to_owned()];
        assert!(!HeaderSelection::Automatic.resolve(&first_row, Some(&second_row)));
    }

    #[test]
    fn stream_parses_a_quoted_comma() {
        let records = CsvRecords::new("name,note\nAda,\"Paris, France\"", Delimiter::Comma)
            .collect::<Result<Vec<_>, _>>();
        assert_eq!(
            records,
            Ok(vec![
                vec!["name".to_owned(), "note".to_owned()],
                vec!["Ada".to_owned(), "Paris, France".to_owned()],
            ])
        );
    }

    #[test]
    fn stream_parses_a_quoted_line_break() {
        let records = CsvRecords::new(
            "name,note\nAda,\"first line\nsecond line\"",
            Delimiter::Comma,
        )
        .collect::<Result<Vec<_>, _>>();
        assert_eq!(
            records,
            Ok(vec![
                vec!["name".to_owned(), "note".to_owned()],
                vec!["Ada".to_owned(), "first line\nsecond line".to_owned()],
            ])
        );
    }

    #[test]
    fn stream_parses_escaped_quotes() {
        let records = CsvRecords::new(
            "name,note\nAda,\"She said \"\"hello\"\"\"",
            Delimiter::Comma,
        )
        .collect::<Result<Vec<_>, _>>();
        assert_eq!(
            records,
            Ok(vec![
                vec!["name".to_owned(), "note".to_owned()],
                vec!["Ada".to_owned(), "She said \"hello\"".to_owned()],
            ])
        );
    }

    #[test]
    fn infers_null_boolean_integer_decimal_date_and_datetime_columns() {
        assert_eq!(infer_column_type(["", ""]), ColumnType::Null);
        assert_eq!(
            infer_column_type(["true", "false", ""]),
            ColumnType::Boolean
        );
        assert_eq!(infer_column_type(["42", "-7", ""]), ColumnType::Integer);
        assert_eq!(infer_column_type(["42", "-7.5", ""]), ColumnType::Decimal);
        assert_eq!(
            infer_column_type(["2026-09-03", "2025-01-01"]),
            ColumnType::Date
        );
        assert_eq!(
            infer_column_type(["2026-09-03T12:30", "2025-01-01 00:00"]),
            ColumnType::DateTime
        );
    }

    #[test]
    fn preserves_text_when_values_are_ambiguous_or_mixed() {
        assert_eq!(infer_column_type(["00123", "00456"]), ColumnType::Text);
        assert_eq!(infer_column_type(["true", "unknown"]), ColumnType::Text);
        assert_eq!(infer_column_type(["42", "2026-09-03"]), ColumnType::Text);
    }

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
