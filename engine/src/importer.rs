//! High-level CSV import orchestration and progress reporting.

use std::fs;
use std::path::Path;

use crate::{
    CsvCache, CsvColumn, CsvRecords, DelimiterSelection, HeaderSelection, ImportError,
    TextEncodingSelection, infer_column_type,
};

const PREVIEW_ROW_LIMIT: usize = 20;

/// A notification emitted while importing a source file.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum ImportEvent {
    Started {
        total_bytes: u64,
    },
    Headers {
        values: Vec<String>,
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
        cache_path: std::path::PathBuf,
    },
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
    report(ImportEvent::Headers {
        values: headers.clone(),
    });
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
