# Authentication

The `mongreldb-server` daemon has two auth modes. The Perl client supports
both, and sends credentials only in the `Authorization` header.

## Bearer token (--auth-token mode)

Pass a `token` in the options hash. Every request carries an
`Authorization: Bearer <token>` header:

```perl
my $db = MongrelDB::connect('http://127.0.0.1:8453', { token => 'my-secret-token' });
```

## HTTP Basic (--auth-users mode)

Pass a `username` and `password`. The client base64-encodes them once and
sends `Authorization: Basic <credentials>` on every request:

```perl
my $db = MongrelDB::connect('http://127.0.0.1:8453',
    { username => 'admin', password => 's3cret' });
```

If both are supplied, `token` takes precedence.

## No auth (default)

If neither `token` nor `username` is provided, the client sends no
`Authorization` header. This matches a daemon started without `--auth-token`
or `--auth-users`. Any local process can then read or write data, so enable
auth on any shared host.

## TLS

The daemon speaks plain HTTP and binds to `127.0.0.1` by default, so loopback
traffic stays local. For remote or multi-tenant deployments, terminate TLS in a
reverse proxy (nginx, Caddy) in front of the daemon rather than exposing it
directly.

## Auth failures

A 401 or 403 from the daemon throws a `MongrelDB::Error` with
`{type} eq 'auth'`. Catch it with `eval` to react:

```perl
eval { $db->put('orders', { 1 => 1 }) };
if (my $e = $@) {
    if ($e->{type} eq 'auth') {
        warn "Not authorized: $e->{message}";
    }
}
```
