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

BEGIN {
    eval { require HTTP::Tiny; 1 }
        or plan skip_all => 'HTTP::Tiny (core module) not available';
}

use MongrelDB;
use JSON::PP ();

my $url = $ENV{MONGRELDB_URL} || 'http://127.0.0.1:8453';

# Probe the daemon once. If it is not up, skip every live test.
sub server_reachable {
    my $db = MongrelDB::connect($url);
    return 0 unless eval { $db->health };
    return 1;
}

unless (server_reachable()) {
    plan skip_all => "MONGRELDB_URL not reachable at $url";
}

plan tests => 9;

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
}

# 3. Upsert updates on PK conflict.
{
    my $db   = MongrelDB::connect($url);
    my $name = "perl_upsert_$unique";
    $db->createTable($name, $columns);
    $db->put($name, { 1 => 1, 2 => 'alpha', 3 => 10.0 });
    $db->upsert($name, { 1 => 1, 2 => 'alpha', 3 => 99.0 }, { 3 => 99.0 });
    is($db->count($name), 1, 'upsert does not duplicate the row');
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
