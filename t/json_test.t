#!/usr/bin/env perl
# Pure unit tests for the MongrelDB Perl client.
#
# No daemon is needed. These tests exercise the JSON encoder/decoder
# behavior, the cell-flattening helper, and the condition alias
# normalization, so the wire-format contract stays covered offline.
#
#   prove -v t/json_test.t
#   perl -Ilib t/json_test.t

use strict;
use warnings;
use utf8;
use Test::More tests => 23;

# The module pulls in HTTP::Tiny / JSON::PP (both core). If HTTP::Tiny is
# somehow missing, skip cleanly instead of failing to load.
BEGIN {
    eval { require HTTP::Tiny; 1 }
        or plan skip_all => 'HTTP::Tiny (core module) not available';
}

use_ok('MongrelDB');

# --- JSON round-trip via the module's encoder -----------------------------

# The module keeps a JSON::PP instance that we exercise through connect() so
# the same encoder used for real requests is what we test here.
my $db = MongrelDB::connect('http://127.0.0.1:8453');
my $json = $db->{json};

# Scalars round-trip cleanly.
is($json->decode($json->encode(42)),       42,  'integer round-trips');
is($json->decode($json->encode(3.14)),     3.14, 'float round-trips');
is($json->decode($json->encode("hello")),  'hello', 'string round-trips');
is($json->decode($json->encode(\1)),       1,    'true round-trips');
is($json->decode($json->encode(\0)),       0,    'false round-trips');

# Booleans decode as non-overloaded scalars (JSON::PP::true/false) but compare
# truthy / falsy cleanly.
ok($json->decode($json->encode(\1)),  'true is truthy');
ok(!$json->decode($json->encode(\0)), 'false is falsy');

# Arrays and objects.
is_deeply($json->decode($json->encode([1, 2, 3])), [1, 2, 3], 'array round-trips');
is_deeply($json->decode($json->encode({a => 1})), {a => 1}, 'object round-trips');

# UTF-8 strings survive the round-trip (the encoder is ascii => 1, which
# escapes non-ASCII to \uXXXX, then decodes back).
my $flap = "mångrel";
is($json->decode($json->encode($flap)), $flap, 'UTF-8 string round-trips');

# NaN and Infinity have no valid JSON representation. The client rejects
# them at the request boundary (_reject_nonfinite) before encoding so they
# never reach the daemon. Verify the boundary check throws on +Inf.
my $inf = 9**9**9;            # +Infinity
eval { MongrelDB::_reject_nonfinite([$inf]); };
ok($@, 'non-finite values are rejected at the request boundary, not serialized as Inf');

# --- Cell flattening ------------------------------------------------------

{
    # _flatten_cells sorts keys ascending and interleaves [col_id, value].
    my $flat = MongrelDB::_flatten_cells({ 3 => 99.5, 1 => 1, 2 => 'Alice' });
    is_deeply($flat, [1, 1, 2, 'Alice', 3, 99.5],
        'cells are flattened to sorted [id, value, ...]');
}

{
    my $flat = MongrelDB::_flatten_cells({});
    is_deeply($flat, [], 'empty cells flatten to an empty array');
}

{
    my $flat = MongrelDB::_flatten_cells({ 1 => 'x' });
    is_deeply($flat, [1, 'x'], 'single-cell flatten');
}

# --- Condition alias normalization ---------------------------------------

{
    my $c = MongrelDB::condition('range', { column => 3, min => 10.0, max => 100.0 });
    is_deeply($c, { range => { column_id => 3, lo => 10.0, hi => 100.0 } },
        'range aliases map to column_id/lo/hi');
}

{
    my $c = MongrelDB::condition('pk', { value => 42 });
    is_deeply($c, { pk => { value => 42 } },
        'pk condition passes value through unchanged');
}

{
    my $c = MongrelDB::condition('fm_contains', { column => 2, value => 'database' });
    is_deeply($c, { fm_contains => { column_id => 2, pattern => 'database' } },
        'fm_contains value alias maps to pattern');
}

{
    # Canonical wire keys are accepted directly (no aliasing needed).
    my $c = MongrelDB::condition('range', { column_id => 3, lo => 1, hi => 9 });
    is_deeply($c, { range => { column_id => 3, lo => 1, hi => 9 } },
        'canonical wire keys pass through unchanged');
}

{
    my $c = MongrelDB::condition('ann', { column => 2, query => [0.1, 0.2, 0.3], k => 10 });
    is_deeply($c, { ann => { column_id => 2, query => [0.1, 0.2, 0.3], k => 10 } },
        'ann condition maps column alias and keeps query/k');
}

# --- Error object shape --------------------------------------------------

{
    my $err = MongrelDB::_make_error('constraint', 'dup', {
        error_code => 'UNIQUE_VIOLATION', op_index => 1, status => 409,
    });
    is($err->{type},       'constraint',        'error type set');
    is($err->{error_code}, 'UNIQUE_VIOLATION',  'error code carried through');
    like("$err", qr/^constraint: dup$/, 'error stringifies as "type: message"');
}

done_testing();
