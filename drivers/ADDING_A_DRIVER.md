# Adding a New Database Driver

Adding support for a new database backend is a **self-contained task** — you only
create files inside a new `drivers/<name>/` directory. You never need to touch
`populate.sh` or `sync.sh`.

---

## Step 1 — Create the driver directory

```
drivers/
  mysql/            ← your new directory (use a short lowercase name)
    driver.sh       ← required: implements the db_* interface
    sql/
      01_schema.sql ← recommended: DDL for your backend
      02_load.sql   ← recommended: bulk-load statements (if applicable)
      04_flatten.sql ← recommended: final flatten query
```

---

## Step 2 — Implement `driver.sh`

Your `driver.sh` is sourced (not executed) by the orchestrators.
It must implement all six functions below.

Two variables are pre-set before your driver is sourced:

| Variable | Value |
|---|---|
| `DRIVER_DIR` | Absolute path to your `drivers/<name>/` directory |
| `DATABASE_URL` | Connection string (if your DB uses one) |
| `SQLITE_PATH` | File path (only used by the sqlite driver) |

You may add your own env vars — just document them in `.env.example`.

### Required functions

```bash
# Return a human-readable name for log output.
db_name() { echo "MySQL"; }

# Exit with a non-zero code if a required tool is missing.
# Use the require_cmd helper from lib/core.sh.
db_check_deps() {
  require_cmd "mysql" "Install MySQL client: https://dev.mysql.com/downloads/"
  if [[ -z "${DATABASE_URL:-}" ]]; then
    log_error "DATABASE_URL is not set."; exit 1
  fi
}

# Create all tables, indexes, and seed rows.
db_init() {
  log_step "Creating schema..."
  mysql "$DATABASE_URL" < "$DRIVER_DIR/sql/01_schema.sql"
}

# Import the raw GeoNames TSV files from the ./data/ directory.
# Files available after download_geonames_data() runs:
#   data/cities1000.txt
#   data/admin1CodesASCII.txt
#   data/admin2Codes.txt
#   data/adminCode5.txt
db_load() {
  log_step "Loading raw data..."
  mysql "$DATABASE_URL" < "$DRIVER_DIR/sql/02_load.sql"
}

# Join/flatten the staging tables into the final geonames_cities table.
db_flatten() {
  log_step "Flattening..."
  mysql "$DATABASE_URL" < "$DRIVER_DIR/sql/04_flatten.sql"
}

# Return 0 if incremental sync is supported, 1 if not.
db_supports_sync() { return 0; }   # or: return 1

# Apply the GeoNames daily delta for a given date.
# $1 = date string YYYY-MM-DD
# Called only when db_supports_sync returns 0.
db_sync() {
  local date="$1"
  # download_geonames_delta "$date" is already called by sync.sh before this.
  # data/mods.txt and data/deletes.txt are available.
  ...
}
```

### Helpers available from `lib/core.sh`

| Helper | Purpose |
|---|---|
| `log_info MSG` | Print an informational message |
| `log_step MSG` | Print a bold section header |
| `log_success MSG` | Print a success message |
| `log_warn MSG` | Print a warning to stderr |
| `log_error MSG` | Print an error to stderr |
| `require_cmd CMD HINT` | Exit if CMD is not on PATH |
| `download_geonames_data` | Download + unpack all GeoNames source files into `./data/` |
| `download_geonames_delta DATE` | Download daily delta into `data/mods.txt` + `data/deletes.txt` |
| `cleanup` | Remove the `./data/` temp directory |
| `yesterday` | Print yesterday's date as `YYYY-MM-DD` (macOS + Linux portable) |

---

## Step 3 — Add your env vars to `.env.example`

Document any connection variables your driver needs:

```bash
# ---------------------------------------------------------------------------
# MySQL (only required when DB_DRIVER=mysql)
# ---------------------------------------------------------------------------
DATABASE_URL=mysql://user:pass@host:3306/dbname
```

---

## Step 4 — Test it

```bash
export DB_DRIVER=mysql
export DATABASE_URL="mysql://user:pass@localhost/locationdb"
./populate.sh
```

---

## Checklist

- [ ] `drivers/<name>/driver.sh` exists and implements all six `db_*` functions
- [ ] Private helpers use a `_<name>_` prefix to avoid collisions with other drivers
- [ ] SQL files live inside `drivers/<name>/sql/`
- [ ] New env vars are documented in `.env.example`
- [ ] `README.md` comparison table is updated
