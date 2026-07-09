# Error handling

The Perl client reports errors as `MongrelDB::Error` objects. Every error has a
`{type}` field (the category) and a `{message}`, and stringifies as
`"type: message"` so it prints cleanly when caught. You match on `{type}` to
react to the specific category.

## Error types

| `{type}` | Meaning |
|---|---|
| `mongreldb` | Base category, unexpected internal error |
| `auth` | HTTP 401 / 403 |
| `not_found` | HTTP 404 |
| `constraint` | HTTP 409, constraint violation at commit |
| `connection` | Network-level failure (refused, DNS, timeout) |
| `query` | HTTP 400 / 500, malformed payloads, JSON failures |

Perl has no built-in exception type, so the client throws these objects with
`die`; wrap calls in `eval` to catch them.

## Catching by category

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

## Constraint fields

A `constraint` error carries extra fields:

- `error_code` - the server's error code string, e.g. `UNIQUE_VIOLATION`.
- `op_index` - when reported, the index of the offending operation within the
  batch (useful when a [transaction](transactions.md) commit fails).
- `status` - the HTTP status code.

## Connection failures

A `connection` error is thrown for any network-level problem: connection
refused, DNS lookup failure, or a timeout. The `health()` helper swallows these
and returns false instead, which is handy for startup checks:

```perl
unless ($db->health()) {
    # daemon not reachable; degrade gracefully
}
```

## JSON edge cases

The client refuses to send values that have no valid JSON representation:
infinity and NaN. These throw a `query` error at the client boundary rather
than corrupting data on the server. Malformed UTF-8 is passed through so the
daemon can substitute it.
