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
