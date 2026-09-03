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
    let headers_index = events
        .iter()
        .position(|event| matches!(event, ImportEvent::Headers { .. }))
        .expect("reports source headers");
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
    assert!(headers_index < preview_index);
    assert!(preview_index < completion_index);
    assert!(events.iter().any(|event| matches!(
        event,
        ImportEvent::Headers { values } if values == &vec!["name".to_owned(), "age".to_owned()]
    )));
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
        .import_csv_records_with_progress(
            1,
            ["Ada", "Lin", "Maya", "Noah"]
                .into_iter()
                .map(|name| Ok(vec![name.to_owned()])),
            |_| {},
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
fn preserves_order_when_a_csv_header_is_named_rowid() {
    let connection = Connection::open_in_memory().expect("opens in-memory cache");
    let mut cache = CsvCache {
        connection,
        path: PathBuf::from(":memory:"),
    };
    let columns = cache
        .create_csv_table([
            CsvColumn {
                source_name: "rowid".to_owned(),
                column_type: ColumnType::Text,
            },
            CsvColumn {
                source_name: "__virgule_row_id".to_owned(),
                column_type: ColumnType::Text,
            },
        ])
        .expect("creates CSV schema with colliding headers");
    assert_eq!(columns[0].sql_name, "rowid");
    assert_eq!(columns[1].sql_name, "__virgule_row_id_2");

    cache
        .import_csv_records_with_progress(
            2,
            [
                Ok(vec!["user row id 2".to_owned(), "first".to_owned()]),
                Ok(vec!["user row id 1".to_owned(), "second".to_owned()]),
            ],
            |_| {},
        )
        .expect("imports records without shadowing the engine key");

    assert_eq!(
        cache.read_csv_page(0, 2).expect("reads ordered page"),
        CsvPage {
            offset: 0,
            rows: vec![
                CsvPageRow {
                    source_row: 1,
                    values: vec!["user row id 2".to_owned(), "first".to_owned()],
                },
                CsvPageRow {
                    source_row: 2,
                    values: vec!["user row id 1".to_owned(), "second".to_owned()],
                },
            ],
        }
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
            ("__virgule_row_id".to_owned(), "INTEGER".to_owned()),
            ("Name".to_owned(), "TEXT".to_owned()),
            ("Age".to_owned(), "INTEGER".to_owned()),
            ("Created at".to_owned(), "TEXT".to_owned()),
        ]
    );
    let names = cache
        .connection()
        .prepare("SELECT source_name, sql_name, inferred_type FROM csv_columns ORDER BY ordinal")
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
        .import_csv_records_with_progress(
            3,
            vec![Ok(vec![
                "Ada".to_owned(),
                "first".to_owned(),
                "second".to_owned(),
            ])],
            |_| {},
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
