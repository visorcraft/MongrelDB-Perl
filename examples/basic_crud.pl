#!/usr/bin/env perl
# Basic CRUD example for the MongrelDB Perl client.
#
# Connects to a running mongreldb-server, creates a table, inserts rows,
# queries them back, and prints the count.
#
#   perl -Ilib examples/basic_crud.pl

use strict;
use warnings;
use lib 'lib';
use MongrelDB;
use JSON::PP ();

my $url = $ENV{MONGRELDB_URL} || 'http://127.0.0.1:8453';
my $db  = MongrelDB::connect($url);

print "health: ", ($db->health() ? "true" : "false"), "\n";

# Per-run unique suffix so concurrent/CI runs never collide on a table name.
my $table = 'perl_orders_example_' . time();

# The daemon requires JSON booleans (not 1/0) for primary_key/nullable.
my ($T, $F) = (JSON::PP::true, JSON::PP::false);
my $columns = [
    { id => 1, name => 'id',       ty => 'int64',   primary_key => $T, nullable => $F },
    { id => 2, name => 'customer', ty => 'varchar', primary_key => $F, nullable => $F },
    { id => 3, name => 'amount',   ty => 'float64', primary_key => $F, nullable => $F },
];

$db->createTable($table, $columns);

# Cells map column id to value.
$db->put($table, { 1 => 1, 2 => 'Alice', 3 => 99.50 });
$db->put($table, { 1 => 2, 2 => 'Bob',   3 => 150.00 });

# Upsert updates on PK conflict.
$db->upsert($table, { 1 => 1, 2 => 'Alice', 3 => 120.00 }, { 3 => 120.00 });

print "count: ", $db->count($table), "\n";

# Query with a native index condition (primary key match).
my ($rows) = $db->query($table, [ MongrelDB::condition('pk', { value => 1 }) ]);
for my $r (@$rows) {
    print "row: ", join(', ', @{ $r->{cells} // [] }), "\n";
}

# Run SQL.
$db->sql("UPDATE $table SET amount = 200.0 WHERE customer = 'Bob'");
print "count after sql: ", $db->count($table), "\n";

# Guaranteed cleanup: ALWAYS drop the table at exit, even if the body dies,
# so CI runs never leave an orphan table behind.
END { eval { $db->dropTable($table) } }
