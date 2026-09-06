# Contributing

Thanks for your interest. Please read this first, because this repository does
not work the way most do.

## Pull requests are not merged here

This tree is extracted from a private monorepo that holds the control plane,
the Terraform that provisions machines, and the operational history. Changes
are made there and published here. Merging a pull request in this repository
would put the two trees out of step in a way a running workspace would discover
at sync time — which is the one failure mode this whole design exists to
prevent.

**Issues and discussion are very welcome.** So is a patch attached to an issue:
we will apply it upstream and credit you. What we cannot do is merge it here.

If you run a fork of this tree — which is a supported thing to do, see
[ARCHITECTURE.md](./ARCHITECTURE.md) — you own your fork's merges, and
nothing about that requires our involvement.

## What a good issue looks like

- The chart or manifest, and the behaviour you saw versus expected.
- Which revision your workspace is pinned to (the `targetRevision` on your
  root Argo CD Application).
- No credentials, and no hostnames you would not put on a postcard.

## Reporting security issues

See [SECURITY.md](./SECURITY.md) — privately, please.
