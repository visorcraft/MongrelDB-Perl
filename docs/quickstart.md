# Quickstart

This guide walks through installing the MongrelDB Perl client, connecting to a
running `mongreldb-server`, and doing your first round-trip of CRUD and query.

## Prerequisites

- Perl 5.14 or newer.
- The core modules `HTTP::Tiny` and `JSON::PP` (both ship with Perl).
- A running [`mongreldb-server`](https://github.com/visorcraft/MongrelDB)
  daemon. The simplest start is the prebuilt Linux binary:

  ```sh
  curl -L -o mongreldb-server \
    https://github.com/visorcraft/MongrelDB/releases/download/v0.60.2/mongreldb-server-linux-x64
  chmod +x mongreldb-server
  ./mongreldb-server ./data --port 8453
  ```

## Install

Copy `lib/MongrelDB.pm` into your project's library path, or build and install
from source:

```sh
perl Makefile.PL
make
make test
make install
```

The client has no CPAN dependencies beyond Perl's standard library, so there
is nothing extra to install from CPAN.

## Connect

```perl
use MongrelDB;

my $db = MongrelDB::connect('http://127.0.0.1:8453');
print $db->health() ? "true\n" : "false\n";   # true
```

## Create a table and insert rows

```perl
use JSON::PP ();
my ($T, $F) = (JSON::PP::true, JSON::PP::false);

# The daemon requires JSON booleans for primary_key / nullable.
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

# Cells map column id to value.
$db->put('orders', { 1 => 1, 2 => 'Alice', 3 => 99.50,  4 => 'active' });
$db->put('orders', { 1 => 2, 2 => 'Bob',   3 => 150.00, 4 => 'pending' });

print $db->count('orders'), "\n";   # 2
```

## Schema options

Column descriptors are pass-through: any extra keys are forwarded
verbatim to the daemon. The most useful keys are `enum_variants`
(a list of allowed string values for a varchar column), `default_value`
(filled in when a `put` does not supply one), and `default_expr` for dynamic
`now` / `uuid` defaults. `default_value` may be any JSON scalar; pass the type
expected by the column. An explicit JSON `null` stays a static null, a missing
`default_value` means no default, and literal `"now"` / `"uuid"` values in
`default_value` are treated as static strings — use `default_expr` for dynamic
defaults:

```perl
{
    id            => 2,
    name          => 'status',
    ty            => 'varchar',
    primary_key   => $F,
    nullable      => $F,
    enum_variants => [ 'pending', 'active', 'closed' ],
    default_value => 'pending',
}
```

All supported static-default shapes pass through with their original JSON
types:

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

The Perl client does not interpret these keys — they are part of the
on-wire schema contract with `mongreldb-server`. The
`t/wire_shape_test.t` suite pins the JSON shape so the contract stays
covered offline.

## Run a query

```perl
my ($rows) = $db->query('orders', [
    MongrelDB::condition('pk', { value => 1 }),
]);
```

## History retention

Control the time-travel window and query historical rows with `AS OF EPOCH`:

```perl
my $window   = $db->historyRetentionEpochs;
my $earliest = $db->earliestRetainedEpoch;

# Requires admin auth. Increasing the window cannot restore already-pruned
# history past the previous earliest epoch.
$db->setHistoryRetentionEpochs($window + 10);

my $rows = $db->sql("SELECT id FROM orders AS OF EPOCH $earliest");
```

## Next steps

- [Transactions](transactions.md) for atomic multi-op commits.
- [Queries](queries.md) for the native index condition API.
- [SQL](sql.md) for DataFusion-backed ad-hoc SQL.
- [Auth](auth.md) for Bearer and Basic authentication.
- [Errors](errors.md) for the exception hierarchy.
