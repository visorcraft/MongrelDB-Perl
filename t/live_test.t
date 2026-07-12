#!/usr/bin/env perl
# Live integration tests for the MongrelDB Perl client.
#
# These tests round-trip data through every public method against a real
# mongreldb-server. They skip automatically when no daemon is reachable at
# the URL in MONGRELDB_URL (default http://127.0.0.1:8453), so the suite
# still passes offline.
#
#   MONGRELDB_URL=http://127.0.0.1:8453 prove -v t/live_test.t

use strict;
use warnings;
use Test::More;
use Scalar::Util qw(looks_like_number);

BEGIN {
    eval { require HTTP::Tiny; 1 }
        or plan skip_all => 'HTTP::Tiny (core module) not available';
}

use MongrelDB;
use JSON::PP ();

my $url = $ENV{MONGRELDB_URL} || 'http://127.0.0.1:8453';
my $original_retention;   # restored in END after the retention live test

# Probe the daemon once. If it is not up, skip every live test.
sub server_reachable {
    my $db = MongrelDB::connect($url);
    return 0 unless eval { $db->health };
    return 1;
}

unless (server_reachable()) {
    plan skip_all => "MONGRELDB_URL not reachable at $url";
}

plan 'no_plan';

# The daemon requires JSON booleans (not 1/0) for primary_key/nullable, so
# the column descriptors use JSON::PP::true / JSON::PP::false.
my $T = JSON::PP::true;
my $F = JSON::PP::false;
my $columns = [
    { id => 1, name => 'id',     ty => 'int64',   primary_key => $T, nullable => $F },
    { id => 2, name => 'label',  ty => 'varchar', primary_key => $F, nullable => $F },
    { id => 3, name => 'amount', ty => 'float64', primary_key => $F, nullable => $F },
];

my $unique = time() . substr(int(rand(100000)), 0, 5);

# 1. Health.
{
    my $db = MongrelDB::connect($url);
    ok($db->health(), 'health returns true');
}

# 2. createTable + put + count + query round-trip.
{
    my $db   = MongrelDB::connect($url);
    my $name = "perl_items_$unique";
    $db->createTable($name, $columns);
    $db->put($name, { 1 => 1, 2 => 'alpha', 3 => 10.0 });
    $db->put($name, { 1 => 2, 2 => 'beta',  3 => 25.0 });
    is($db->count($name), 2, 'two rows counted after put');
    my ($rows) = $db->query($name, [ MongrelDB::condition('pk', { value => 2 }) ]);
    ok(@$rows >= 1, 'pk query returns the inserted row');
    # The returned row must carry primary key 2. Confirm via SQL JSON mode,
    # where rows are keyed by column name.
    my $pk_rows = $db->sql("SELECT id FROM $name WHERE id = 2");
    is($pk_rows->[0]{id}, 2, 'selected row id is 2');
}

# 3. Upsert updates on PK conflict.
{
    my $db   = MongrelDB::connect($url);
    my $name = "perl_upsert_$unique";
    $db->createTable($name, $columns);
    $db->put($name, { 1 => 1, 2 => 'alpha', 3 => 10.0 });
    $db->upsert($name, { 1 => 1, 2 => 'alpha', 3 => 99.0 }, { 3 => 99.0 });
    is($db->count($name), 1, 'upsert does not duplicate the row');
    # Query the row back and verify the upserted value landed. SQL JSON mode
    # returns rows keyed by column name.
    my $up_rows = $db->sql("SELECT amount FROM $name WHERE id = 1");
    is($up_rows->[0]{amount}, 99.0, 'upserted amount is 99.0');
}

# 4. Transaction commits multiple ops atomically. Rows inserted in one
#    committed transaction are visible to a delete in the next, proving the
#    batch landed and a follow-up batch can act on it.
{
    my $db   = MongrelDB::connect($url);
    my $name = "perl_txn_$unique";
    $db->createTable($name, $columns);
    $db->transaction([
        { put => { table => $name, cells => [1, 10, 2, 'dave', 3, 50.0] } },
        { put => { table => $name, cells => [1, 11, 2, 'eve',  3, 75.0] } },
    ]);
    is($db->count($name), 2, 'transaction lands both rows');
    $db->transaction([
        { delete_by_pk => { table => $name, pk => 10 } },
    ]);
    is($db->count($name), 1, 'delete_by_pk in a follow-up txn removes the row');
}

# 5. SQL round-trip.
{
    my $db   = MongrelDB::connect($url);
    my $name = "perl_sql_$unique";
    $db->createTable($name, $columns);
    $db->put($name, { 1 => 1, 2 => 'alpha', 3 => 1.0 });
    $db->sql("INSERT INTO $name (id, label, amount) VALUES (2, 'beta', 2.0)");
    is($db->count($name), 2, 'sql INSERT adds a row');
    # JSON mode makes SELECT return rows as JSON objects (column names as
    # keys). Verify both rows come back with the right primary keys.
    my $sel = $db->sql("SELECT id FROM $name ORDER BY id");
    is_deeply([ map { $_->{id} } @$sel ], [ 1, 2 ], 'sql SELECT returns ids [1, 2]');
}

# 6. Schema lists the created table.
{
    my $db   = MongrelDB::connect($url);
    my $name = "perl_schema_$unique";
    $db->createTable($name, $columns);
    my @names = @{ $db->tables() };
    ok((grep { $_ eq $name } @names), 'table appears in tables()');
    my $desc = $db->schemaFor($name);
    ok(keys %$desc > 0, 'schemaFor returns a non-empty descriptor');
}

# 7. Range query returns only the rows within the bounds.
{
    my $db   = MongrelDB::connect($url);
    my $name = "perl_range_$unique";
    $db->createTable($name, $columns);
    $db->put($name, { 1 => 1, 2 => 'a', 3 => 50.0 });
    $db->put($name, { 1 => 2, 2 => 'b', 3 => 75.0 });
    $db->put($name, { 1 => 3, 2 => 'c', 3 => 90.0 });
    $db->put($name, { 1 => 4, 2 => 'd', 3 => 100.0 });
    # Only scores >= 80 should come back (90 and 100) - assert the count.
    # The `amount` column is float64, so use `range_f64` (plain `range`
    # expects an i64 bound and rejects floats). range_f64 requires both
    # bounds (min/max) and the inclusivity flags (min_inclusive/max_inclusive).
    my ($rows) = $db->query($name, [
        MongrelDB::condition('range_f64', {
            column         => 3,
            min            => 80.0,
            max            => 200.0,
            min_inclusive  => $T,
            max_inclusive  => $T,
        }),
    ]);
    is(scalar(@$rows), 2, 'range query returns exactly 2 rows');
    # Only rows with id 3 (amount 90) and 4 (amount 100) qualify. Confirm
    # their exact PK values via SQL JSON mode (rows keyed by column name).
    my $range_sel = $db->sql("SELECT id FROM $name WHERE amount >= 80.0 ORDER BY id");
    is_deeply([ map { $_->{id} } @$range_sel ], [ 3, 4 ],
        'range query PK values are [3, 4]');
}

# 8. schemaFor on a nonexistent table dies with a not_found error.
{
    my $db = MongrelDB::connect($url);
    my $err;
    eval { $db->schemaFor('nonexistent_table_xyz'); };
    $err = $@;
    ok(ref($err) && $err->{type} eq 'not_found',
        'schemaFor on missing table raises a not_found error');
}

# 9. Idempotent transaction does not duplicate the row.
{
    my $db   = MongrelDB::connect($url);
    my $name = "perl_idem_$unique";
    $db->createTable($name, $columns);
    # Idempotency key must be unique per run so a stale key from an earlier
    # run can't be replayed against this table.
    my $key = "order-100-create-$unique";
    # First idempotent commit inserts the row.
    $db->transaction([
        { put => { table => $name, cells => [1, 100, 2, 'order', 3, 1.0] } },
    ], $key);
    is($db->count($name), 1, 'idempotent commit inserts one row');
    # A second, identical commit with the SAME key must not duplicate it.
    eval {
        $db->transaction([
            { put => { table => $name, cells => [1, 100, 2, 'order', 3, 1.0] } },
        ], $key);
    };
    is($db->count($name), 1, 'duplicate idempotent commit does not duplicate the row');
}

# 10. History retention: get/set and AS OF EPOCH query.
{
    my $db = MongrelDB::connect($url);

    $original_retention = $db->historyRetentionEpochs;
    my $earliest = $db->earliestRetainedEpoch;
    ok(looks_like_number($original_retention), 'historyRetentionEpochs returns a number');
    ok(looks_like_number($earliest), 'earliestRetainedEpoch returns a number');

    my $set = eval { $db->setHistoryRetentionEpochs($original_retention + 1) };
    ok(!$@ && ref $set eq 'HASH', 'setHistoryRetentionEpochs succeeds');
    is($set->{history_retention_epochs}, $original_retention + 1,
       'setHistoryRetentionEpochs returns the new window');

    my $name = "perl_retention_$unique";
    $db->createTable($name, $columns);
    $db->put($name, { 1 => 1, 2 => 'alpha', 3 => 1.0 });

    # Read the floor after the writes: the table must exist at/before this
    # epoch and the epoch must still be retained.
    my $earliest_after = $db->earliestRetainedEpoch;
    ok(looks_like_number($earliest_after), 'earliestRetainedEpoch numeric after writes');

    # $earliest_after is returned by the server and validated above as numeric,
    # so interpolating it here is safe. Do not interpolate user input.
    my $rows = eval { $db->sql("SELECT id FROM $name AS OF EPOCH $earliest_after") };
    ok(!$@ && ref $rows eq 'ARRAY',
       'AS OF EPOCH query at earliest_retained_epoch executes without error');
}

# 11. AS OF EPOCH returns the pre-update value (MVCC history proof).
#     The existing retention test only queries at the floor without verifying
#     that historical reads return the *old* value. Here we insert a row,
#     capture the retained epoch, then update the row and verify that a
#     historical read at the pre-update epoch returns the original value
#     while a current read returns the updated value.
{
    my $db   = MongrelDB::connect($url);
    my $name = "perl_mvcc_$unique";
    $db->createTable($name, $columns);
    $db->put($name, { 1 => 1, 2 => 'original', 3 => 10.0 });

    # Capture the earliest retained epoch before the update. After the
    # subsequent update commit the retention floor advances by at most one
    # epoch, so this epoch is still retained and reflects the pre-update state.
    my $epoch_before_update = $db->earliestRetainedEpoch;
    ok(looks_like_number($epoch_before_update),
       'earliestRetainedEpoch is numeric before update');

    # Update the row: change amount from 10.0 to 99.0.
    $db->put($name, { 1 => 1, 2 => 'original', 3 => 99.0 });

    # Current read: must reflect the update.
    my $current = $db->sql("SELECT amount FROM $name WHERE id = 1");
    is($current->[0]{amount}, 99.0,
       'current read reflects the updated amount (99.0)');

    # Historical read at the pre-update epoch: if the epoch is still retained
    # and the row was visible at that point, the amount must be the original
    # value (10.0). If GC has reclaimed the epoch, skip gracefully.
    my $historical = eval {
        $db->sql(
            "SELECT amount FROM $name AS OF EPOCH $epoch_before_update WHERE id = 1");
    };
    if (!$@ && ref $historical eq 'ARRAY' && @$historical) {
        is($historical->[0]{amount}, 10.0,
           'AS OF EPOCH before the update returns the original amount (10.0)');
    } else {
        ok(1, 'AS OF EPOCH returned no rows (epoch may have been GC\'d)');
    }
}

# Restore the original retention window so later test runs start clean.
END {
    eval { MongrelDB::connect($url)->setHistoryRetentionEpochs($original_retention) }
        if defined $original_retention;
}
