use std::sync::{LazyLock, Mutex};

use rusqlite::Connection;

use crate::paths::CODETRACER_PATHS;

pub static CONNECTION_MUTEX: LazyLock<Mutex<Connection>> = LazyLock::new(|| {
    // TODO: better error handling maybe? (this is sufficient, but the errors aren't exactly user friendly)
    // TODO: implement migrations

    let res = Mutex::new(
        Connection::open(
            CODETRACER_PATHS
                .lock()
                .unwrap()
                .data_path
                .join("trace_index.db"),
        )
        .unwrap(),
    );

    {
        let conn = res.lock().unwrap();
        conn.execute(
            "
            CREATE TABLE IF NOT EXISTS traces (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            program text,
            args text,
            compileCommand text,
            env text,
            workdir text,
            output text,
            sourceFolders text,
            lowLevelFolder text,
            outputFolder text,
            lang integer,
            imported integer,
            shellID integer,
            rrPid integer,
            exitCode integer,
            calltrace integer,
            calltraceMode string,
            date text,
            );
            ",
            (),
        )
        .unwrap();
    }

    res
});
