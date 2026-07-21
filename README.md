<p align="center">
  <img src="assets/mongrel.png" alt="MongrelDB logo" width="250" />
</p>

<h1 align="center">MongrelDB Perl Client</h1>

<p align="center">
  <b>Pure Perl client for MongrelDB, embedded and server database with SQL, vector search, full-text search, and AI-native retrieval.</b>
</p>

<p align="center">
  <a href="https://metacpan.org/dist/MongrelDB"><img src="https://img.shields.io/badge/CPAN-MongrelDB-39457e.svg" alt="CPAN" /></a>
  <a href="https://www.perl.org/"><img src="https://img.shields.io/badge/Perl-%3E%3D5.14-39457e.svg" alt="Perl" /></a>
  <a href="#license"><img src="https://img.shields.io/badge/license-MIT%20OR%20Apache--2.0-blue.svg" alt="License" /></a>
</p>

## Package

| Surface | Package | Install |
|---|---|---|
| Perl client | `MongrelDB` | `cpanm MongrelDB` or copy `lib/MongrelDB.pm` |

## Requirements

- **Perl 5.14 or newer** (Perl 5.38 and 5.42 supported)
- **HTTP::Tiny** and **JSON::PP** core modules (both ship with Perl)
- A running [`mongreldb-server`](https://github.com/visorcraft/MongrelDB) daemon

## What It Provides

- **Typed CRUD** over the Kit transaction endpoint: `put`, `upsert` (insert-or-update on PK conflict), `delete` by row id or primary key, with idempotency keys for safe retries.
- **Native query conditions** that push down to the engine's specialized indexes for sub-millisecond lookups: bitmap equality/IN, learned-range, null checks, FM-index full-text search, HNSW vector similarity (`ann`), and sparse vector match.
- **Idempotent batch transactions**, all operations staged in a list and committed atomically, with the engine enforcing unique, foreign key, and check constraints at commit time. Idempotency keys return the original response on duplicate commits, even after a crash.
- **Full SQL access** through the DataFusion-backed `/sql` endpoint: recursive CTEs, window functions, `CREATE TABLE AS SELECT`, materialized views, multi-statement execution, and the `mongreldb_fts_rank` relevance-scoring UDF.
- **Schema management**: typed table creation, full schema catalog, and per-table descriptors.
- **HTTP::Tiny transport** with keep-alive connection pooling, built on a core module so there are no CPAN runtime dependencies.
- **Typed exception objects** with a `{type}` field: `auth` (401/403), `not_found` (404), `constraint` (409, with error code and op index), `connection` (network), and `query` (everything else).
- **Robust JSON handling**: NaN and Infinity raise a clear `query` error instead of corrupting data; malformed UTF-8 is passed through so the daemon can substitute it.

## Examples

Runnable, commented examples live in [`examples/`](examples):

- [Basic CRUD](examples/basic_crud.pl), connect, create a table, insert, query, count.

## Quick Example

```perl
use MongrelDB;
use JSON::PP ();

# Connect to a running mongreldb-server daemon.
my $db = MongrelDB::connect('http://127.0.0.1:8453');

# The daemon requires JSON booleans for primary_key / nullable.
my ($T, $F) = (JSON::PP::true, JSON::PP::false);

# Create a table.
$db->createTable('orders', [
    { id => 1, name => 'id',       ty => 'int64',   primary_key => $T, nullable => $F },
    { id => 2, name => 'customer', ty => 'varchar', primary_key => $F, nullable => $F },
    { id => 3, name => 'amount',   ty => 'float64', primary_key => $F, nullable => $F },
    {
        id            => 4,
        name          => 'status',
        ty            => 'varchar',
        primary_key   => $F,
        nullable      => $F,
        enum_variants => [ 'pending', 'active', 'closed' ],
        default_value => 'pending',
    },
]);

# Insert rows. Cells map column id to value.
$db->put('orders', { 1 => 1, 2 => 'Alice', 3 => 99.50,  4 => 'active' });
$db->put('orders', { 1 => 2, 2 => 'Bob',   3 => 150.00, 4 => 'pending' });

# Upsert (insert or update on PK conflict).
$db->upsert('orders', { 1 => 1, 2 => 'Alice', 3 => 120.00, 4 => 'closed' }, { 3 => 120.00 });

# Query with a native index condition (learned-range index).
my ($rows) = $db->query('orders', [
    MongrelDB::condition('range', { column => 3, min => 100.0 }),
], { projection => [1, 2], limit => 100 });

print $db->count('orders'), "\n";   # 2

# Run SQL.
$db->sql("UPDATE orders SET amount = 200.0 WHERE customer = 'Bob'");
```

## Schema options

Column descriptors accept extra keys that the client forwards verbatim
to the daemon. The most useful keys are `enum_variants` (a list of
allowed string values), `default_value` (any JSON scalar, with the caller
supplying the column's expected type), and `default_expr` (`now` or `uuid`,
filled in dynamically). A static default is filled in when a put does
not supply one. An explicit JSON `null` default stays a static null, a
missing `default_value` means no default, and literal `"now"` / `"uuid"`
values in `default_value` are treated as static strings — use
`default_expr` for dynamic defaults:

```perl
$db->createTable('orders', [
    { id => 1, name => 'id',     ty => 'int64',   primary_key => $T, nullable => $F },
    {
        id            => 2,
        name          => 'status',
        ty            => 'varchar',
        primary_key   => $F,
        nullable      => $F,
        enum_variants => [ 'pending', 'active', 'closed' ],
        default_value => 'pending',
    },
]);
```

All static-default shapes are forwarded with their original JSON types:

```perl
$db->createTable('events', [
    { id => 1, name => 'message', ty => 'varchar', primary_key => $F, nullable => $F,
      default_value => 'none' },
    { id => 2, name => 'count',   ty => 'int64',   primary_key => $F, nullable => $F,
      default_value => 0 },
    { id => 3, name => 'active',  ty => 'bool',    primary_key => $F, nullable => $F,
      default_value => $T },
    { id => 4, name => 'extra',   ty => 'varchar', primary_key => $F, nullable => $T,
      default_value => undef },          # explicit JSON null
    { id => 5, name => 'tag',     ty => 'varchar', primary_key => $F, nullable => $F,
      default_value => 'now' },          # static literal, not dynamic
    { id => 6, name => 'created', ty => 'timestamp', primary_key => $F, nullable => $F,
      default_expr => 'now' },           # dynamic default
]);
```

The client does not interpret these keys — they are part of the
on-wire schema contract with `mongreldb-server`. The
`t/wire_shape_test.t` suite pins the JSON shape so the daemon contract
stays covered offline.

Pass an optional third argument to `createTable` for engine constraints:

```perl
$db->createTable('orders', $columns, {
    checks => [
        { id => 1, name => 'id_present', expr => { IsNotNull => 1 } },
    ],
});
```

## Auth

```perl
# Bearer token (--auth-token mode).
my $db = MongrelDB::connect('http://127.0.0.1:8453', { token => 'my-secret-token' });

# HTTP Basic (--auth-users mode).
my $db = MongrelDB::connect('http://127.0.0.1:8453',
    { username => 'admin', password => 's3cret' });
```

## Transactions

Operations are staged in a list and committed atomically. The engine enforces
unique, foreign key, and check constraints at commit time.

```perl
my $ops = [
    { put          => { table => 'orders', cells => [1, 10, 2, 'Dave', 3, 50.0] } },
    { put          => { table => 'orders', cells => [1, 11, 2, 'Eve',  3, 75.0] } },
    { delete_by_pk => { table => 'orders', pk => 2 } },
];

eval { $db->transaction($ops) };    # atomic, all or nothing
if (my $e = $@) {
    if ($e->{type} eq 'constraint') {
        warn "Constraint violated: $e->{error_code} - $e->{message}";
    }
}

# Idempotent commit, safe to retry; daemon returns the original response.
$db->transaction($ops2, 'order-20-create');
```

## Query builder

Conditions push down to the engine's specialized indexes. `MongrelDB::condition`
accepts friendly aliases that are translated to the server's on-wire keys:
`column` (to `column_id`), `min`/`max` (to `lo`/`hi`). The canonical keys are
also accepted directly.

```perl
# Bitmap equality (low-cardinality columns).
$db->query('orders', [ MongrelDB::condition('bitmap_eq', { column => 2, value => 'Alice' }) ]);

# Range query (learned-range index).
$db->query('orders', [
    MongrelDB::condition('range', { column => 3, min => 50.0, max => 150.0 }),
], { limit => 100 });

# Full-text search (FM-index).
$db->query('documents', [
    MongrelDB::condition('fm_contains', { column => 2, pattern => 'database performance' }),
], { limit => 10 });

# Vector similarity search (HNSW).
$db->query('embeddings', [
    MongrelDB::condition('ann', { column => 2, query => [0.1, 0.2, 0.3], k => 10 }),
]);

# Check whether a result was capped by the limit.
my ($rows, $truncated) = $db->query('orders',
    [ MongrelDB::condition('range', { column => 3, min => 0 }) ],
    { limit => 100 });
if ($truncated) {
    # result set hit the limit; more matches exist on the server.
}
```

## SQL

```perl
$db->sql("INSERT INTO orders (id, customer, amount) VALUES (99, 'Zoe', 999.0)");
$db->sql("CREATE TABLE archive AS SELECT * FROM orders WHERE amount > 500");

# Recursive CTEs and window functions.
$db->sql("WITH RECURSIVE r(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM r WHERE n<10) SELECT n FROM r");
$db->sql("SELECT id, ROW_NUMBER() OVER (PARTITION BY customer ORDER BY amount DESC) FROM orders");
```

## ANN index backends

The engine's `ann` index is swappable across three backends - `hnsw` (the default), `diskann`, and `ivf` - selected with the `algorithm` option. Quantization is independently configurable: `dense`, `binary_sign`, or `product` (product quantization, with `num_subvectors`, `bits_per_subvector`, `pq_training_samples`, `pq_seed`, and `pq_rerank_factor`). These are ordinary DDL strings run through `sql`, so no client changes are needed.

```perl
# DiskANN (in-memory Vamana graph)
$db->sql("CREATE INDEX orders_emb_diskann ON orders USING ann (embedding) WITH (algorithm = 'diskann', quantization = 'dense', diskann_l = 50, diskann_r = 64, beam_width = 8)");

# IVF with dense vectors (clustered)
$db->sql("CREATE INDEX orders_emb_ivf ON orders USING ann (embedding) WITH (algorithm = 'ivf', quantization = 'dense', nlist = 1024, nprobe = 16)");

# HNSW with product quantization (recall-tuned)
$db->sql("CREATE INDEX orders_emb_hnsw_pq ON orders USING ann (embedding) WITH (algorithm = 'hnsw', quantization = 'product', m = 16, ef_construction = 200, ef_search = 50, num_subvectors = 32, pq_training_samples = 50000, pq_rerank_factor = 8)");
```


## User and role management

User and role administration is done through SQL against the `/sql` endpoint.
Quote identifiers and escape literals so caller-supplied names are safe to
interpolate.

```perl
$db->sql(q{CREATE USER "admin" WITH PASSWORD 's3cret-pw'});
$db->sql(q{ALTER USER "admin" ADMIN});

$db->sql(q{CREATE ROLE "analyst"});
$db->sql(q{GRANT SELECT ON orders TO "analyst"});
$db->sql(q{GRANT "analyst" TO "alice"});
```

## Error handling

```perl
use MongrelDB;

my $db = MongrelDB::connect('http://127.0.0.1:8453');

eval { $db->put('orders', { 1 => 1 }) };    # duplicate PK
if (my $e = $@) {
    if    ($e->{type} eq 'constraint') { warn "Constraint: $e->{error_code}" }  # UNIQUE_VIOLATION
    elsif ($e->{type} eq 'auth')       { warn "Not authorized: $e->{message}" }
    elsif ($e->{type} eq 'not_found')  { warn "Not found: $e->{message}" }
    elsif ($e->{type} eq 'connection') { warn "Can't reach daemon: $e->{message}" }
    else                               { warn "Error: $e->{message}" }
}
```

## API reference

### `MongrelDB` module

| Function | Description |
|---|---|
| `MongrelDB::connect($url, \%opts)` | Connect to a daemon |
| `MongrelDB::condition($type, \%params)` | Build a normalized condition |

### Client object (from `connect`)

| Method | Description |
|---|---|
| `health()` | Check daemon health |
| `tables()` | List table names |
| `createTable($name, $columns, $constraints, $indexes)` | Create a table with optional constraints and all index definitions |
| `dropTable($name)` | Drop a table |
| `count($table)` | Row count |
| `put($table, $cells)` | Insert a row |
| `upsert($table, $cells, $update)` | Upsert a row |
| `delete($table, $rowId)` | Delete by row ID |
| `deleteByPk($table, $pk)` | Delete by primary key |
| `query($table, $conditions, \%opts)` | Run a native query; opts include `limit` and `offset` |
| `sql($statement)` | Execute SQL |
| `schema()` | Full schema catalog |
| `schemaFor($table)` | Single table schema |
| `transaction($ops, $idempotency_key)` | Commit a batch atomically |
| `historyRetentionEpochs()` | Get the current history-retention window (epochs) |
| `earliestRetainedEpoch()` | Get the oldest epoch still queryable with `AS OF EPOCH` |
| `setHistoryRetentionEpochs($epochs)` | Set the history-retention window; requires admin |

## Building and testing

The test suite is split into a pure unit suite (no daemon needed) and a live
integration suite.

```sh
perl Makefile.PL
make
perl -Ilib t/json_test.t             # pure unit tests, always runnable
```

For the live round-trip suite, start a daemon and point the tests at it:

```sh
MONGRELDB_URL=http://127.0.0.1:8453 perl -Ilib t/live_test.t
```

## Contributing

Contributions are welcome. Please:

1. Open an issue first for non-trivial changes.
2. Add focused tests near your change, the suite must stay green.
3. Keep Perl 5.14 as the minimum supported version.
4. Match the existing style: `strict`/`warnings`, four-space indent, and core
   modules only (no new CPAN runtime dependencies).

See [`CONTRIBUTING.md`](CONTRIBUTING.md) for the full guide.

## History retention

History retention controls how far back `AS OF EPOCH` time-travel queries
can read. Use these methods with `mongreldb-server` 0.48.0+:

```perl
my $db = MongrelDB::connect('http://127.0.0.1:8453');

my $window  = $db->historyRetentionEpochs;   # current retention window
my $earliest = $db->earliestRetainedEpoch;   # oldest readable epoch

# Increase the window. Requires admin auth. Increasing retention cannot
# restore history already pruned past the previous earliest epoch.
$db->setHistoryRetentionEpochs($window + 10);

# Query historical state.
my $rows = $db->sql("SELECT id FROM orders AS OF EPOCH $earliest");
```

## License

Dual-licensed under the **MIT License** or the **Apache License, Version 2.0**,
at your option. See [MIT](LICENSE-MIT) OR [Apache-2.0](LICENSE-APACHE) for the full text.

`SPDX-License-Identifier: MIT OR Apache-2.0`
