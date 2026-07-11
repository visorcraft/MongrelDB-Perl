# MongrelDB Perl client.
#
# Pure Perl HTTP client for mongreldb-server. Talks JSON over the Kit
# transaction, query, and SQL endpoints, with a small typed exception
# hierarchy and a native query builder.
#
# Depends only on core modules: HTTP::Tiny and JSON::PP have shipped with
# Perl since 5.14, so no CPAN installs are needed.
#
# Usage:
#   use MongrelDB;
#   my $db = MongrelDB::connect('http://127.0.0.1:8453');
#   $db->createTable('orders', \@columns);
#   $db->put('orders', { 1 => 1, 2 => 'Alice', 3 => 99.5 });

package MongrelDB;
use strict;
use warnings;
use utf8;

our $VERSION = '0.1.0';

use Carp qw(croak);
use HTTP::Tiny ();
use JSON::PP ();
use Scalar::Util qw(looks_like_number refaddr);

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

# Map an HTTP status code to the right error category. Mirrors the other
# MongrelDB clients so callers can match by category across languages.
my %KIND_FOR_STATUS = (
    401 => 'auth',
    403 => 'auth',
    404 => 'not_found',
    409 => 'constraint',
);

# Friendly aliases translated to the server's canonical wire keys. Mirrors
# the other clients (column -> column_id, min/max -> lo/hi, etc.).
my %ALIAS = (
    column         => 'column_id',
    min            => 'lo',
    max            => 'hi',
    min_inclusive  => 'lo_inclusive',
    max_inclusive  => 'hi_inclusive',
);

# ---------------------------------------------------------------------------
# Exception package
# ---------------------------------------------------------------------------

# MongrelDB::Error objects carry a {type} category so callers can match by
# category. They stringify as "type: message" and are thrown with die().
package    # hide from PAUSE
    MongrelDB::Error;

use overload '""' => sub {
    my $self = shift;
    return $self->{type} . ': ' . $self->{message};
}, fallback => 1;

package MongrelDB;

# ---------------------------------------------------------------------------

# Build an exception object. kind is one of the category strings above (or
# 'query' / 'connection'). Callers can match on $err->{type}.
sub _make_error {
    my ($kind, $message, $extra) = @_;
    my $err = { type => $kind, message => $message };
    if ($extra) {
        for my $k (keys %$extra) { $err->{$k} = $extra->{$k}; }
    }
    return bless $err, 'MongrelDB::Error';
}

# Percent-encode a single URL path segment so a table name containing '/',
# '?', '#', or spaces cannot inject extra segments or break routing.
sub _encode_segment {
    my ($seg) = @_;
    $seg = '' unless defined $seg;
    $seg =~ s/([^A-Za-z0-9\-_.~])/sprintf("%%%02X", ord($1))/ge;
    return $seg;
}

# Decode the daemon's {"error":{"message":...,"code":...,"op_index":...}}
# envelope when present. Returns ($message, $code, $op_index).
sub _parse_error_envelope {
    my ($body) = @_;
    return ($body, undef, undef) unless defined $body && length $body;
    my $decoded = eval { JSON::PP->new->decode($body) };
    return ($body, undef, undef) unless ref $decoded eq 'HASH';
    if (ref $decoded->{error} eq 'HASH') {
        my $e = $decoded->{error};
        return ($e->{message} // $body, $e->{code}, $e->{op_index});
    }
    if (exists $decoded->{error} && !ref $decoded->{error}) {
        return ($decoded->{error}, undef, undef);
    }
    return ($body, undef, undef);
}

# Translate friendly aliases for one condition into wire keys.
sub _normalize_condition {
    my ($cond_type, $params) = @_;
    my %out;
    for my $k (keys %$params) {
        my $key = $k;
        if (($cond_type eq 'fm_contains' || $cond_type eq 'fm_contains_all')
            && $k eq 'value') {
            $key = 'pattern';
        }
        $out{ $ALIAS{$key} // $key } = $params->{$k};
    }
    return \%out;
}

# Recursively walk a payload and die with a query error if any numeric value
# is NaN or Infinity. These have no valid JSON representation; rejecting them
# here keeps the request from corrupting data on the server. Tracks seen refs
# to avoid infinite recursion on cyclic data structures.
sub _reject_nonfinite {
    my ($val, $seen) = @_;
    $seen //= {};
    my $ref = ref $val;
    if (!$ref) {
        if (defined $val && Scalar::Util::looks_like_number($val)) {
            my $num = $val + 0;
            # NaN compares unequal to itself; Inf is the largest magnitude.
            if ($num != $num || abs($num) == 9**9**9) {
                die _make_error('query',
                    'cannot JSON-encode NaN or Infinity');
            }
        }
        return;
    }
    # Guard against cycles: use the refaddr as a visit marker.
    my $addr = Scalar::Util::refaddr($val);
    return if $seen->{$addr}++;
    if ($ref eq 'ARRAY') {
        _reject_nonfinite($_, $seen) for @$val;
        return;
    }
    if ($ref eq 'HASH') {
        _reject_nonfinite($_, $seen) for values %$val;
        return;
    }
    return;
}

# Core request helper. Returns the decoded JSON body (or undef for empty
# bodies). Throws a MongrelDB::Error of the appropriate category for
# non-2xx or network failures.
sub _request {
    my ($self, $method, $path, $payload) = @_;

    my $url = $self->{url} . '/' . $path;
    my @headers;
    if ($self->{auth_header}) {
        push @headers, 'Authorization' => $self->{auth_header};
    }

    my $content;
    if (defined $payload) {
        _reject_nonfinite($payload);
        $content = eval { $self->{json}->encode($payload) };
        if ($@) {
            die _make_error('query',
                'request payload cannot be JSON-encoded: ' . $@);
        }
        push @headers, 'Content-Type' => 'application/json';
    }

    my $resp = $self->{http}->request($method, $url, {
        headers => { @headers },
        (defined $content ? (content => $content) : ()),
    });

    if (!$resp->{success}) {
        # HTTP::Tiny folds network failures into {status} = 599 with a
        # {content} describing the problem. Map those to a connection error
        # so callers can distinguish them from server responses.
        if ($resp->{status} == 599) {
            die _make_error('connection', $resp->{content} // 'network error');
        }
        my $status = $resp->{status};
        my ($message, $code, $op_index) = _parse_error_envelope($resp->{content});
        $message = "Server error ($status)" if !defined $message || $message eq '';
        my $kind = $KIND_FOR_STATUS{$status} // 'query';
        die _make_error($kind, $message, {
            error_code => $code,
            op_index   => $op_index,
            status     => $status,
        });
    }

    my $body = $resp->{content};
    return undef unless defined $body && length $body;
    # Cap the response body at 256 MB so a runaway query or a misbehaving
    # daemon cannot exhaust memory. HTTP::Tiny is told to abort past this size
    # in the constructor; this is a belt-and-suspenders check for custom
    # transports and for responses that slip through.
    my $max_bytes = 256 * 1024 * 1024;    # 268435456 bytes
    if (length($body) > $max_bytes) {
        die _make_error('query',
            "response body exceeds $max_bytes bytes (" . length($body) . " bytes)");
    }
    # The client requests the JSON result format, so guard against non-JSON so
    # the caller can treat responses as best-effort.
    return eval { JSON::PP->new->decode($body) };
}

# ---------------------------------------------------------------------------

# Construct a new client. Internal; callers use connect().
sub _new {
    my ($class, $url, $opts) = @_;
    $opts ||= {};

    # Reject CR/LF in any auth credential: token/username/password are placed
    # verbatim into the Authorization header, so an embedded newline would
    # allow header injection (request splitting). Validate before use.
    for my $field (qw(token username password)) {
        next unless defined $opts->{$field};
        if ($opts->{$field} =~ /[\r\n]/) {
            die _make_error('auth',
                "auth $field must not contain CR or LF");
        }
    }

    my $auth_header;
    if (defined $opts->{token}) {
        $auth_header = 'Bearer ' . $opts->{token};
    } elsif (defined $opts->{username}) {
        require MIME::Base64;
        my $creds = $opts->{username} . ':' . ($opts->{password} // '');
        $auth_header = 'Basic ' . MIME::Base64::encode_base64($creds, '');
    }

    my $json = JSON::PP->new;
    $json->ascii(1);                    # safe ASCII output
    $json->allow_nonref(1);
    $json->canonical(0);                # preserve insertion order for clarity

    return bless {
        url         => $url,
        auth_header => $auth_header,
        http        => $opts->{http} || HTTP::Tiny->new(
            timeout       => 60,
            agent         => 'mongreldb-perl/' . $VERSION,
            keep_alive    => 1,
            # Real streaming size guard: HTTP::Tiny aborts the connection as
            # soon as the response body crosses this limit instead of buffering
            # it all first. The post-check in _request stays as a
            # belt-and-suspenders guard for custom transports passed via
            # $opts->{http}.
            max_size      => 268435456,
            # Security: never follow redirects (an Authorization header could
            # follow a redirect to an attacker-controlled host) and never use
            # proxy env vars unless the caller explicitly opts in via
            # $opts->{http}. This prevents DB auth/data leaking to a proxy.
            max_redirect  => 0,
            proxy         => undef,
            http_proxy    => undef,
            https_proxy   => undef,
        ),
        json        => $json,
    }, $class;
}

# ---------------------------------------------------------------------------
# Public functional API
# ---------------------------------------------------------------------------

sub connect {
    my ($url, $opts) = @_;
    return __PACKAGE__->_new($url, $opts);
}

# Build a normalized condition (translates friendly aliases).
sub condition {
    my ($type, $params) = @_;
    return { $type => _normalize_condition($type, $params) };
}

# ---------------------------------------------------------------------------
# Public OO API
# ---------------------------------------------------------------------------

# Check daemon health. Returns true on success, false on failure (never
# throws, so it is safe for startup checks).
sub health {
    my ($self) = @_;
    my $ok = eval { $self->_request('GET', 'health'); 1 };
    return $ok ? 1 : 0;
}

sub historyRetentionEpochs { 0 + ($_[0]->_request('GET', 'history/retention')->{history_retention_epochs} // 0) }
sub earliestRetainedEpoch { 0 + ($_[0]->_request('GET', 'history/retention')->{earliest_retained_epoch} // 0) }
sub setHistoryRetentionEpochs {
    my ($self, $epochs) = @_;
    return $self->_request('PUT', 'history/retention', { history_retention_epochs => 0 + $epochs });
}

# List all table names.
sub tables {
    my ($self) = @_;
    my $data = $self->_request('GET', 'tables');
    return [] unless ref $data eq 'ARRAY';
    return $data;
}

# Create a table. Optional $constraints is sent as the top-level engine
# constraints object (for example { checks => [...] }).
sub createTable {
    my ($self, $name, $columns, $constraints) = @_;
    my $payload = { name => $name, columns => $columns };
    $payload->{constraints} = $constraints if defined $constraints;
    my $data = $self->_request('POST', 'kit/create_table',
        $payload);
    return (ref $data eq 'HASH') ? ($data->{table_id} // 0) : 0;
}

# Drop a table by name.
sub dropTable {
    my ($self, $name) = @_;
    $self->_request('DELETE', "tables/" . _encode_segment($name));
    return;
}

# Row count for a table.
sub count {
    my ($self, $table) = @_;
    my $data = $self->_request('GET', "tables/" . _encode_segment($table) . "/count");
    if (ref $data eq 'HASH' && defined $data->{count}
        && Scalar::Util::looks_like_number($data->{count})) {
        return $data->{count} + 0;
    }
    die _make_error('query', 'malformed count response from server');
}

# Insert a row. $cells maps column id to value ({ 1 => 1, 2 => 'Alice' }).
sub put {
    my ($self, $table, $cells) = @_;
    my $data = $self->_request('POST', 'kit/txn', {
        ops => [ { put => { table => $table, cells => _flatten_cells($cells) } } ],
    });
    return _first_result($data);
}

# Upsert (insert or update on PK conflict).
sub upsert {
    my ($self, $table, $cells, $update_cells) = @_;
    my $op = { table => $table, cells => _flatten_cells($cells) };
    if ($update_cells) {
        $op->{update_cells} = _flatten_cells($update_cells);
    }
    my $data = $self->_request('POST', 'kit/txn', {
        ops => [ { upsert => $op } ],
    });
    return _first_result($data);
}

# Delete a row by its internal row id.
sub delete {
    my ($self, $table, $row_id) = @_;
    $self->_request('POST', 'kit/txn', {
        ops => [ { delete => { table => $table, row_id => $row_id } } ],
    });
    return;
}

# Delete a row by its primary key value.
sub deleteByPk {
    my ($self, $table, $pk) = @_;
    $self->_request('POST', 'kit/txn', {
        ops => [ { delete_by_pk => { table => $table, pk => $pk } } ],
    });
    return;
}

# Execute SQL. Requests the JSON result format, so a SELECT returns a JSON
# array of row objects keyed by column name. Returns the decoded rows for
# SELECTs, or undef for statements (INSERT/UPDATE) that produce no rows.
sub sql {
    my ($self, $statement) = @_;
    return $self->_request('POST', 'sql',
        { sql => $statement, format => 'json' });
}

# Run a native query. $conditions is an arrayref of { type => \%params }
# hashes (see MongrelDB::condition). Optional: projection (arrayref of
# column ids), limit (int). Returns ($rows, $truncated).
sub query {
    my ($self, $table, $conditions, $opts) = @_;
    $opts ||= {};
    my %payload = (table => $table);
    $payload{conditions} = $conditions if $conditions && @$conditions;
    $payload{projection} = $opts->{projection} if $opts->{projection};
    $payload{limit}      = $opts->{limit}      if $opts->{limit};
    my $data = $self->_request('POST', 'kit/query', \%payload);
    return ([], 0) unless ref $data eq 'HASH';
    return ($data->{rows} // [], $data->{truncated} ? 1 : 0);
}

# Full schema catalog (hash of table name -> descriptor).
sub schema {
    my ($self) = @_;
    my $data = $self->_request('GET', 'kit/schema');
    return {} unless ref $data eq 'HASH';
    return $data->{tables} // {};
}

# Descriptor for a single table.
sub schemaFor {
    my ($self, $table) = @_;
    my $data = $self->_request('GET', "kit/schema/" . _encode_segment($table));
    return (ref $data eq 'HASH') ? $data : {};
}

# Stage and commit a batch transaction atomically. $ops is an arrayref of
# { put => {...} }, { upsert => {...} }, { delete => {...} },
# { delete_by_pk => {...} } hashes. Optional idempotency key for safe retries.
sub transaction {
    my ($self, $ops, $idempotency_key) = @_;
    my %payload = (ops => $ops);
    $payload{idempotency_key} = $idempotency_key if defined $idempotency_key;
    my $data = $self->_request('POST', 'kit/txn', \%payload);
    return (ref $data eq 'HASH' && ref $data->{results} eq 'ARRAY')
        ? $data->{results} : [];
}

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

# Flatten { col_id => value } into [ col_id, value, col_id, value, ... ]
# to match the on-wire shape for batch ops. Column ids are sorted ascending.
sub _flatten_cells {
    my ($cells) = @_;
    return [] unless ref $cells eq 'HASH';
    my @flat;
    for my $k (sort { $a <=> $b } keys %$cells) {
        push @flat, int($k), $cells->{$k};
    }
    return \@flat;
}

# Pull the first per-op result out of a txn response.
sub _first_result {
    my ($data) = @_;
    return {} unless ref $data eq 'HASH' && ref $data->{results} eq 'ARRAY';
    return $data->{results}[0] // {};
}

1;

__END__

=head1 NAME

MongrelDB - Pure Perl HTTP client for mongreldb-server

=head1 SYNOPSIS

    use MongrelDB;

    my $db = MongrelDB::connect('http://127.0.0.1:8453');
    $db->createTable('orders', [
        { id => 1, name => 'id',       ty => 'int64',   primary_key => 1, nullable => 0 },
        { id => 2, name => 'customer', ty => 'varchar', primary_key => 0, nullable => 0 },
    ]);
    $db->put('orders', { 1 => 1, 2 => 'Alice', 3 => 99.5 });
    my ($rows) = $db->query('orders', [ MongrelDB::condition('pk', { value => 1 }) ]);

=head1 DESCRIPTION

Pure Perl client for MongrelDB. Talks JSON over the Kit transaction, query,
and SQL endpoints of a running C<mongreldb-server> daemon. No external CPAN
dependencies are required: L<HTTP::Tiny> and L<JSON::PP> are core modules.

=head1 ERROR HANDLING

Methods throw C<MongrelDB::Error> objects on failure. Match on
C<< $err->{type} >>:

    eval { $db->put('orders', { 1 => 1 }) };
    if (my $e = $@) {
        if ($e->{type} eq 'constraint') { warn $e->{error_code}; }
        elsif ($e->{type} eq 'auth')    { warn $e->{message}; }
    }

The categories are C<auth> (401/403), C<not_found> (404), C<constraint>
(409), C<connection> (network), and C<query> (everything else).

=head1 LICENSE

Dual MIT OR Apache-2.0.

=cut
