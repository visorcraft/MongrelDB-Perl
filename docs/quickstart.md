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
    https://github.com/visorcraft/MongrelDB/releases/download/v0.44.1/mongreldb-server-linux-x64
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
]);

# Cells map column id to value.
$db->put('orders', { 1 => 1, 2 => 'Alice', 3 => 99.50 });
$db->put('orders', { 1 => 2, 2 => 'Bob',   3 => 150.00 });

print $db->count('orders'), "\n";   # 2
```

## Run a query

```perl
my ($rows) = $db->query('orders', [
    MongrelDB::condition('pk', { value => 1 }),
]);
```

## Next steps

- [Transactions](transactions.md) for atomic multi-op commits.
- [Queries](queries.md) for the native index condition API.
- [SQL](sql.md) for DataFusion-backed ad-hoc SQL.
- [Auth](auth.md) for Bearer and Basic authentication.
- [Errors](errors.md) for the exception hierarchy.
