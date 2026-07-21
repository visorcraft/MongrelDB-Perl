#!/usr/bin/env perl
# Wire-shape conformance tests for the MongrelDB Perl client.
#
# These tests assert that payloads the client sends over HTTP are shaped
# correctly for the mongreldb-server wire contract. They use a fake
# HTTP::Tiny-compatible transport passed in via $opts->{http} so they run
# offline (no daemon required) and never actually open a socket.
#
#   prove -v t/wire_shape_test.t
#   perl -Ilib t/wire_shape_test.t

use strict;
use warnings;
use utf8;
use Test::More;

BEGIN {
    eval { require HTTP::Tiny; 1 }
        or plan skip_all => 'HTTP::Tiny (core module) not available';
}

use MongrelDB;
use JSON::PP ();

# ---------------------------------------------------------------------------
# Fake HTTP transport
# ---------------------------------------------------------------------------
#
# Mimics the HTTP::Tiny interface used by MongrelDB: ->request($method, $url,
# \%opts) returning { success => 1, status => 200, content => $body }. The
# fake records the most recent request and returns a canned response body,
# so the test can inspect exactly what would have been put on the wire.

package MongrelDB::Test::FakeHTTP;

sub new {
    my ($class, %opts) = @_;
    return bless {
        response_status => $opts{status}   // 200,
        response_body   => $opts{body}     // '{"table_id":1}',
        last_request    => undef,
    }, $class;
}

sub request {
    my ($self, $method, $url, $opts) = @_;
    $self->{last_request} = {
        method  => $method,
        url     => $url,
        headers => $opts->{headers} // {},
        content => $opts->{content},
    };
    my $status = $self->{response_status};
    return {
        success => ($status >= 200 && $status < 300) ? 1 : 0,
        status  => $status,
        content => $self->{response_body},
    };
}

package main;

# ---------------------------------------------------------------------------
# createTable: enum_variants and default_value must reach the wire verbatim
# ---------------------------------------------------------------------------

# Build a column with a varchar carrying enum_variants and a default_value.
# These keys are sent as a hash ref; the client must NOT mangle or strip
# them. They should land in the JSON body exactly as the caller passed them.
{
    my $fake = MongrelDB::Test::FakeHTTP->new(
        status => 200,
        body   => '{"table_id":42}',
    );
    my $db = MongrelDB::connect('http://127.0.0.1:8453', { http => $fake });

    my ($T, $F) = (JSON::PP::true, JSON::PP::false);
    my $columns = [
        { id => 1, name => 'id',   ty => 'int64',   primary_key => $T, nullable => $F },
        {
            id            => 2,
            name          => 'status',
            ty            => 'varchar',
            primary_key   => $F,
            nullable      => $F,
            enum_variants => [ 'pending', 'active', 'closed' ],
            default_value => 'pending',
        },
        { id => 3, name => 'retries', ty => 'int64', primary_key => $F,
          nullable => $F, default_value => 3 },
        { id => 4, name => 'created_at', ty => 'timestamp', primary_key => $F,
          nullable => $F, default_expr => 'now' },
        { id => 5, name => 'enabled', ty => 'bool', primary_key => $F, nullable => $F,
          default_value => $T },
        { id => 6, name => 'optional', ty => 'varchar', primary_key => $F, nullable => $T,
          default_value => undef },
    ];
    my $constraints = {
        checks => [
            { id => 1, name => 'id_present', expr => { IsNotNull => 1 } },
        ],
    };

    my $table_id = $db->createTable('orders', $columns, $constraints);
    is($table_id, 42, 'createTable returns the table_id from the server response');

    # Decode the body the client would have sent. JSON::PP cannot decode
    # tagged booleans back to a bool, so compare the raw stringified form.
    my $req = $fake->{last_request};
    ok(defined $req->{content}, 'createTable sent a request body');

    my $body = JSON::PP->new->decode($req->{content});
    is($body->{name}, 'orders', 'wire body carries the table name');

    is(ref $body->{columns}, 'ARRAY', 'wire body carries columns as an array');
    is(scalar @{ $body->{columns} }, 6, 'wire body carries all columns');

    my $status_col = $body->{columns}[1];
    is($status_col->{name}, 'status', 'second column is the status column');

    is_deeply(
        $status_col->{enum_variants},
        [ 'pending', 'active', 'closed' ],
        'enum_variants array survives the JSON round-trip verbatim',
    );
    is(
        $status_col->{default_value}, 'pending',
        'default_value scalar survives the JSON round-trip verbatim',
    );
    is(
        $status_col->{ty}, 'varchar',
        'ty field is not disturbed by the additional keys',
    );
    is_deeply(
        $body->{constraints}{checks}, $constraints->{checks},
        'top-level constraints.checks survives the JSON round-trip',
    );
    is($body->{columns}[2]{default_value}, 3,
        'static numeric default_value stays a JSON number');
    is($body->{columns}[3]{default_expr}, 'now',
        'dynamic default_expr survives verbatim');
    ok($body->{columns}[4]{default_value}, 'boolean default stays true');
    ok(exists $body->{columns}[5]{default_value} && !defined $body->{columns}[5]{default_value},
        'null default stays null');
}

# ---------------------------------------------------------------------------
# Regression: columns without enum_variants / default_value must NOT gain
# those keys implicitly. This guards against accidental cross-key
# normalization.
# ---------------------------------------------------------------------------

{
    my $fake = MongrelDB::Test::FakeHTTP->new(
        status => 200,
        body   => '{"table_id":7}',
    );
    my $db = MongrelDB::connect('http://127.0.0.1:8453', { http => $fake });

    my ($T, $F) = (JSON::PP::true, JSON::PP::false);
    my $columns = [
        { id => 1, name => 'id',   ty => 'int64',   primary_key => $T, nullable => $F },
        { id => 2, name => 'note', ty => 'varchar', primary_key => $F, nullable => $F },
    ];

    $db->createTable('notes', $columns);

    my $body = JSON::PP->new->decode($fake->{last_request}{content});
    my $note_col = $body->{columns}[1];
    ok(!exists $note_col->{enum_variants},
        'columns without enum_variants do not gain the key');
    ok(!exists $note_col->{default_value},
        'columns without default_value do not gain the key');
}

# ---------------------------------------------------------------------------
# The body builder is just JSON encoding the caller's hashref: pass
# arbitrary extra keys and confirm they all land.
# ---------------------------------------------------------------------------

{
    my $fake = MongrelDB::Test::FakeHTTP->new(
        status => 200,
        body   => '{"table_id":9}',
    );
    my $db = MongrelDB::connect('http://127.0.0.1:8453', { http => $fake });

    my ($T, $F) = (JSON::PP::true, JSON::PP::false);
    my $columns = [
        {
            id            => 1,
            name          => 'kind',
            ty            => 'varchar',
            primary_key   => $T,
            nullable      => $F,
            enum_variants => [ 'a', 'b' ],
            default_value => 'a',
            # A made-up extra key, just to confirm the client is pass-through.
            doc           => 'free-form metadata',
        },
    ];

    $db->createTable('kinds', $columns);

    my $body = JSON::PP->new->decode($fake->{last_request}{content});
    my $col  = $body->{columns}[0];
    is(
        $col->{doc}, 'free-form metadata',
        'arbitrary extra keys are forwarded verbatim',
    );
    is_deeply(
        $col->{enum_variants}, [ 'a', 'b' ],
        'enum_variants survives when paired with other extra keys',
    );
    is(
        $col->{default_value}, 'a',
        'default_value survives when paired with other extra keys',
    );
}

# ---------------------------------------------------------------------------
# Full static-default matrix: every supported default shape reaches the wire
# with the correct JSON type and default_expr suppresses default_value.
# ---------------------------------------------------------------------------

{
    my $fake = MongrelDB::Test::FakeHTTP->new(
        status => 200,
        body   => '{"table_id":11}',
    );
    my $db = MongrelDB::connect('http://127.0.0.1:8453', { http => $fake });

    my ($T, $F) = (JSON::PP::true, JSON::PP::false);
    my $columns = [
        { id => 10, name => 's',       ty => 'varchar', primary_key => $F, nullable => $F,
          default_value => 'hello' },
        { id => 11, name => 'n',       ty => 'int64',   primary_key => $F, nullable => $F,
          default_value => 42 },
        { id => 12, name => 'b',       ty => 'bool',    primary_key => $F, nullable => $F,
          default_value => $T },
        { id => 13, name => 'nl',      ty => 'varchar', primary_key => $F, nullable => $F,
          default_value => undef },
        { id => 14, name => 'now_lit', ty => 'varchar', primary_key => $F, nullable => $F,
          default_value => 'now' },
        { id => 15, name => 'uuid_lit',ty => 'varchar', primary_key => $F, nullable => $F,
          default_value => 'uuid' },
        { id => 16, name => 'expr',    ty => 'timestamp', primary_key => $F, nullable => $F,
          default_value => 'ignored', default_expr => 'now' },
    ];

    $db->createTable('matrix', $columns);

    my $body = JSON::PP->new->decode($fake->{last_request}{content});
    my @cols = @{ $body->{columns} };
    is($cols[0]{default_value}, 'hello', 'string default_value');
    is($cols[1]{default_value}, 42,      'numeric default_value');
    ok($cols[2]{default_value},          'boolean default_value');
    ok(exists $cols[3]{default_value} && !defined $cols[3]{default_value},
       'null default_value');
    is($cols[4]{default_value}, 'now',   'literal "now" default_value stays a string');
    is($cols[5]{default_value}, 'uuid',  'literal "uuid" default_value stays a string');
    is($cols[6]{default_expr}, 'now',    'default_expr survives');
    is($cols[6]{default_value}, 'ignored',
       'default_expr and default_value both forwarded when caller supplies both');
}

# ---------------------------------------------------------------------------
# History retention wire shape
# ---------------------------------------------------------------------------

{
    my $fake = MongrelDB::Test::FakeHTTP->new(
        status => 200,
        body   => '{"history_retention_epochs":100,"earliest_retained_epoch":7}',
    );
    my $db = MongrelDB::connect('http://127.0.0.1:8453', { http => $fake });

    $fake->{last_request} = undef;
    is($db->historyRetentionEpochs, 100, 'historyRetentionEpochs parses int');
    is($fake->{last_request}{method}, 'GET', 'historyRetentionEpochs uses GET');
    is($fake->{last_request}{url}, 'http://127.0.0.1:8453/history/retention',
       'historyRetentionEpochs hits /history/retention');

    $fake->{last_request} = undef;
    is($db->earliestRetainedEpoch, 7,    'earliestRetainedEpoch parses int');
    is($fake->{last_request}{method}, 'GET', 'earliestRetainedEpoch uses GET');
    is($fake->{last_request}{url}, 'http://127.0.0.1:8453/history/retention',
       'earliestRetainedEpoch hits /history/retention');

    $fake->{last_request} = undef;
    $fake->{response_body} = '{"history_retention_epochs":200}';
    my $set = $db->setHistoryRetentionEpochs(200);
    is($set->{history_retention_epochs}, 200, 'setHistoryRetentionEpochs returns payload');
    is($fake->{last_request}{method}, 'PUT', 'setHistoryRetentionEpochs uses PUT');
    is($fake->{last_request}{url}, 'http://127.0.0.1:8453/history/retention',
       'setHistoryRetentionEpochs hits /history/retention');
    my $put_body = JSON::PP->new->decode($fake->{last_request}{content});
    is($put_body->{history_retention_epochs}, 200,
       'setHistoryRetentionEpochs body contains history_retention_epochs');
    ok(!exists $put_body->{earliest_retained_epoch},
       'setHistoryRetentionEpochs body does not contain earliest_retained_epoch');
}

# ---------------------------------------------------------------------------
# Error propagation: a non-2xx response must surface as a MongrelDB::Error
# of the correct category, not a silent success.
# ---------------------------------------------------------------------------

{
    my $fake = MongrelDB::Test::FakeHTTP->new(
        status => 503,
        body   => '{"error":{"message":"server overloaded","code":"UNAVAILABLE"}}',
    );
    my $db = MongrelDB::connect('http://127.0.0.1:8453', { http => $fake });

    # GET path: historyRetentionEpochs must die.
    my $err;
    eval { $db->historyRetentionEpochs };
    $err = $@;
    ok(ref($err) && ref($err) eq 'MongrelDB::Error',
       'non-2xx GET /history/retention raises MongrelDB::Error');
    is($err->{type}, 'query',
       '503 maps to the query error category');
    is($err->{status}, 503,
       'error object carries the HTTP status code');

    # PUT path: setHistoryRetentionEpochs must also die.
    $fake->{last_request} = undef;
    eval { $db->setHistoryRetentionEpochs(99) };
    $err = $@;
    ok(ref($err) && ref($err) eq 'MongrelDB::Error',
       'non-2xx PUT /history/retention raises MongrelDB::Error');
    is($err->{type}, 'query',
       '503 PUT maps to the query error category');

    # Verify the request was still sent with the right method/path/body.
    is($fake->{last_request}{method}, 'PUT',
       'error-path PUT still sends the PUT method');
    is($fake->{last_request}{url}, 'http://127.0.0.1:8453/history/retention',
       'error-path PUT still hits /history/retention');
}

{
    my $fake = MongrelDB::Test::FakeHTTP->new(status => 200, body => '{"table_id":1}');
    my $db = MongrelDB::connect('http://127.0.0.1:8453', { http => $fake });
    my $columns = [
        { id => 1, name => 'id', ty => 'int64', primary_key => JSON::PP::true },
        { id => 2, name => 'embedding', ty => 'embedding(384)', embedding_source => {
            kind => 'configured_model', provider_id => 'docs', model_id => 'model', model_version => '1',
        } },
    ];
    my $indexes = [
        { name => 'bm', column_id => 1, kind => 'bitmap' },
        { name => 'fm', column_id => 1, kind => 'fm_index' },
        { name => 'ann', column_id => 2, kind => 'ann', predicate => 'embedding IS NOT NULL',
          options => { ann => { m => 24, ef_construction => 96, ef_search => 48,
                                quantization => 'dense' } } },
        { name => 'range', column_id => 1, kind => 'learned_range' },
        { name => 'minhash', column_id => 1, kind => 'minhash' },
        { name => 'sparse', column_id => 1, kind => 'sparse' },
    ];
    is($db->createTable('search_docs', $columns, undef, $indexes), 1,
       'createTable with indexes returns table id');
    my $body = JSON::PP->new->decode($fake->{last_request}{content});
    is($body->{columns}[1]{embedding_source}{kind}, 'configured_model',
       'embedding source reaches wire');
    is_deeply([map { $_->{kind} } @{$body->{indexes}}],
              [qw(bitmap fm_index ann learned_range minhash sparse)],
              'all public index kinds reach wire');
    is($body->{indexes}[2]{options}{ann}{quantization}, 'dense',
       'Dense ANN reaches wire');
    is($body->{indexes}[2]{predicate}, 'embedding IS NOT NULL',
       'index predicate reaches wire');
}

done_testing();
