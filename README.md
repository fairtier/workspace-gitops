# workspace-gitops

The complete GitOps tree for a **FairTier workspace**: one machine, running
single-node k3s with its own Argo CD, which syncs this repository.

**Start here: [ARCHITECTURE.md](./ARCHITECTURE.md)** — the component
inventory, the bootstrap chain, day-2 behaviour, and how a deploy actually
happens.

## Why this is public

Every workspace's Argo CD pulls this tree, and it does so **without a
credential**. That is deliberate, and it is the smaller half of the reason.

The larger half: a machine that syncs a repository you cannot read is a machine
you do not control. Published, the manifests that run your workspace are
readable, forkable, and — the part that matters — **pinnable**. A workspace
tracks an immutable commit here. Nothing that happens in this repository moves
a running workspace: not a merge, not a tag, not a branch. Publishing a version
and deploying one are separate acts, with separate operators.

For a FairTier-hosted workspace, a small on-box agent asks the control plane
which commit to run and moves the pin. That agent is one component, and
deleting it is the whole of leaving: no write path remains, because none ever
pointed inward, and the machine keeps running what it is pinned to. What is
left is the same two fields any self-hoster uses.

The full mechanism, both operators, and what to do with it:
[ARCHITECTURE.md § Fleet rollout](./ARCHITECTURE.md#fleet-rollout).

## Layout

One directory per Argo CD `Application`:

```
root-app.yaml      the Application a machine is bootstrapped with; everything
                   below is reached from it
charts/root/       the app-of-apps — one template per component, and the
                   self-managed copy of root-app.yaml
charts/<name>/     one component: an upstream chart pinned with values, or a
                   small chart of our own
```

A machine's manifests say `path: charts/<name>`, resolved at the commit that
machine is pinned to. Nothing outside `charts/` is deployed.

## Conventions

[PUBLIC.md](./PUBLIC.md) — what the comments in these charts
do and do not cite, and why no machine is named in them.

## Contributing

[CONTRIBUTING.md](./CONTRIBUTING.md) — issues yes, pull requests no, and the
reason is mechanical rather than unfriendly.

## License

[Apache 2.0](./LICENSE). See [NOTICE](./NOTICE) for what is and is not
distributed here.
