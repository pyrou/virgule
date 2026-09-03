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
