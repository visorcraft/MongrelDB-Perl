#!/usr/bin/env perl
# Offline unit tests for 0.64 durable HLC recovery parsers.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use MongrelDB;

my $fixture = {
    query_id             => 'abcdefabcdefabcdefabcdefabcdefab',
    status               => 'committed',
    state                => 'completed',
    server_state         => 'completed',
    terminal_state       => 'committed',
    committed            => 1,
    committed_statements => 1,
    last_commit_epoch    => 17,
    last_commit_hlc      => {
        physical_micros => 1700000000000000,
        logical         => 3,
        node_tiebreaker => 7,
    },
    outcome => {
        committed            => 1,
        last_commit_epoch    => 17,
        last_commit_hlc      => {
            physical_micros => 1700000000000000,
            logical         => 3,
            node_tiebreaker => 7,
        },
        serialization        => 'succeeded',
        serialization_state  => 'succeeded',
        terminal_state       => 'committed',
    },
    durable => {
        committed            => 1,
        last_commit_epoch    => 17,
        last_commit_hlc      => {
            physical_micros => 1700000000000000,
            logical         => 3,
            node_tiebreaker => 7,
        },
        serialization        => 'succeeded',
        serialization_state  => 'succeeded',
        terminal_state       => 'committed',
    },
};

my $status = MongrelDB::parse_query_status($fixture);
ok($status->{committed}, 'committed');
my $hlc = $status->commit_hlc;
ok(defined $hlc, 'commit_hlc present');
is($hlc->{physical_micros}, 1700000000000000, 'physical_micros');
is($hlc->{logical}, 3, 'logical');
is($hlc->{node_tiebreaker}, 7, 'node_tiebreaker');
is($status->serialization_state, 'succeeded', 'serialization_state');
is($status->{outcome}{last_commit_epoch}, 17, 'outcome epoch structural');

ok(!defined MongrelDB::parse_commit_hlc(undef), 'nil hlc');
ok(!defined MongrelDB::parse_commit_hlc({}), 'empty hlc');
ok(!defined MongrelDB::parse_commit_hlc({ logical => 1 }), 'missing physical');

is($MongrelDB::VERSION, '0.64.4', 'version');

done_testing();
