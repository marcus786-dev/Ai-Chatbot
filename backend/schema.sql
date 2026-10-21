PRAGMA foreign_keys = ON;

CREATE TABLE IF NOT EXISTS employee (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    pernr         TEXT NOT NULL UNIQUE,              -- personalenummer (8 cifre)
    name          TEXT NOT NULL,
    role          TEXT NOT NULL CHECK (role IN ('employee','manager','admin')),
    manager_id    INTEGER REFERENCES employee(id),
    weekly_target REAL NOT NULL DEFAULT 37.0         -- ugentlig normtid
);

CREATE TABLE IF NOT EXISTS activity_type (
    code        TEXT PRIMARY KEY,
    description TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS wbs_element (
    code        TEXT PRIMARY KEY,
    description TEXT NOT NULL,
    cost_center TEXT NOT NULL,
    active      INTEGER NOT NULL DEFAULT 1
);

-- En linje = én kombination af WBS-element + aktivitetstype i én uge for én medarbejder.
CREATE TABLE IF NOT EXISTS timesheet_line (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    employee_id   INTEGER NOT NULL REFERENCES employee(id),
    week_start    TEXT NOT NULL,                     -- mandag, YYYY-MM-DD
    wbs_code      TEXT NOT NULL REFERENCES wbs_element(code),
    activity_code TEXT NOT NULL REFERENCES activity_type(code),
    note          TEXT NOT NULL DEFAULT '',
    status        TEXT NOT NULL DEFAULT 'IN_PROCESS'
                  CHECK (status IN ('IN_PROCESS','RELEASED','APPROVED','REJECTED')),
    reject_reason TEXT NOT NULL DEFAULT '',
    UNIQUE (employee_id, week_start, wbs_code, activity_code)
);

-- Kun dage med timer > 0 gemmes.
CREATE TABLE IF NOT EXISTS timesheet_hours (
    line_id   INTEGER NOT NULL REFERENCES timesheet_line(id) ON DELETE CASCADE,
    work_date TEXT NOT NULL,
    hours     REAL NOT NULL CHECK (hours > 0 AND hours <= 24),
    PRIMARY KEY (line_id, work_date)
);

CREATE TABLE IF NOT EXISTS favorite (
    employee_id   INTEGER NOT NULL REFERENCES employee(id),
    wbs_code      TEXT NOT NULL REFERENCES wbs_element(code),
    activity_code TEXT NOT NULL REFERENCES activity_type(code),
    PRIMARY KEY (employee_id, wbs_code, activity_code)
);

CREATE INDEX IF NOT EXISTS idx_line_emp_week ON timesheet_line(employee_id, week_start);
CREATE INDEX IF NOT EXISTS idx_hours_date ON timesheet_hours(work_date);
