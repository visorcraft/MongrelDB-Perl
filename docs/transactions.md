# Transactions

The MongrelDB daemon commits batched operations atomically. The Perl client
mirrors that with a `transaction()` method: you build a list of ops (each a
`{ put => {...} }`, `{ upsert => {...} }`, `{ delete => {...} }`, or
`{ delete_by_pk => {...} }` hash) and pass it to `transaction()`, which flushes
the whole batch in a single `/kit/txn` request. Unique, foreign key, and check
constraints are enforced by the engine at commit time, so either every
operation lands or none.

## Basic commit

```perl
my $ops = [
    { put          => { table => 'orders', cells => [1, 10, 2, 'Dave', 3, 50.0] } },
    { put          => { table => 'orders', cells => [1, 11, 2, 'Eve',  3, 75.0] } },
    { delete_by_pk => { table => 'orders', pk => 2 } },
];
my $results = $db->transaction($ops);    # atomic: all or nothing
```

`transaction()` returns a list of per-operation result hashrefs. Each entry
reflects the `kind` the engine took (`put`, `deleted`, `not_found`, etc.).

The `cells` field is a flat array of `[col_id, value, col_id, value, ...]` to
match the on-wire shape for batch ops. When you use `put()` directly, the
client flattens a `{ col_id => value }` hash for you.

Note: a row inserted in one transaction is not visible to a `delete_by_pk` in
the *same* transaction. Commit the inserts first, then delete in a follow-up
batch.

## Idempotent commits

Pass an idempotency key as the second argument to make a commit safe to retry.
If the daemon sees the same key again (even after a crash), it returns the
original response instead of replaying the work:

```perl
$db->transaction($ops, 'order-20-create');
```

Keys are opaque, caller-supplied strings. The client does not derive or store
them.

## Constraint handling

If a staged operation violates a constraint, the engine rejects the whole batch
and the client throws a `MongrelDB::Error` whose `{type}` is `'constraint'`,
with the server's `error_code` (for example, `UNIQUE_VIOLATION`) and, when
reported, the `op_index` of the offending operation:

```perl
eval { $db->transaction($ops) };
if (my $e = $@) {
    if ($e->{type} eq 'constraint') {
        warn "Constraint violated: $e->{error_code} (op $e->{op_index})";
    }
}
```

See [Errors](errors.md) for the full hierarchy.
