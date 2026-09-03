//! The data engine exposed to the macOS application through a stable C ABI.

/// Opaque state: its layout is intentionally private to Rust.
pub struct VirguleEngine {
    _private: (),
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
