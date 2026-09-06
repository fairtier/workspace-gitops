# This repository is public

This is the GitOps tree every FairTier box syncs. Each customer runs a
dedicated VM with its own single-node k3s and its own ArgoCD, and that ArgoCD
pulls **this** repository — so the tree has to be readable without a
credential. That is the whole reason it is public, and it is what closes the
standing problem of a deploy token living in cloud-init on every box: a public
repo needs no token, so there is no token to leak or rotate.

## What this is not

**It is not a place to send patches.** This tree is extracted from a private
monorepo that holds the control plane, the Terraform that provisions boxes, and
the operational history. Changes are made there. Issues and discussion are
welcome; pull requests will not be merged, because merging one here would put
the two trees out of step in a way a box would discover at sync time.

## Where the images come from

Nothing here is built here. The charts reference images published from their
own public repositories:

| Image | Source |
|---|---|
| `ghcr.io/fairtier/workspace-api` | [fairtier/workspace-api](https://github.com/fairtier/workspace-api) |
| `ghcr.io/fairtier/console` | [fairtier/console](https://github.com/fairtier/console) |
| `ghcr.io/fairtier/dlt-worker` | [fairtier/dlt-worker](https://github.com/fairtier/dlt-worker) |
| `ghcr.io/fairtier/iceberg-maintenance` | [fairtier/iceberg-maintenance](https://github.com/fairtier/iceberg-maintenance) |
| `ghcr.io/fairtier/duckflight` | [fairtier/duckflight](https://github.com/fairtier/duckflight) |
| `ghcr.io/fairtier/snapshot-sidecar` | [fairtier/snapshot-sidecar](https://github.com/fairtier/snapshot-sidecar) |
| `ghcr.io/fairtier/rill-deploy-shim` | [fairtier/rill-deploy-shim](https://github.com/fairtier/rill-deploy-shim) |

The DuckFlight chart itself is an OCI chart, `ghcr.io/fairtier/charts/duckflight`,
published from the same repository as its image.

Everything else is upstream (cert-manager, Traefik, ArgoCD, Casdoor, OpenFGA,
Lakekeeper, Rill, Alloy).

## Two conventions worth knowing before you read the comments

**The comments carry the reasoning; they do not cite where it is written
down.** These charts explain their own values — why a threshold is 8 MiB and
not 32, why a request exists at all, what incident a limit came out of. The
design documents that argue those decisions live in the private monorepo, and
this tree does not name them, or any other file in it. A path into a repository
you cannot open is not a citation, it is a map of somebody else's directory
tree; the reasoning is worth publishing, the filenames are not. So where a
comment would have pointed at a document, it states the conclusion instead.

**No box is named here.** Measurements are attributed to a box class ("a
2-vCPU box", "the canary box"), never to a customer slug, and figures that
would describe one box's stored data — object counts, warehouse size, backlog
volumes — are kept out. Every box on the fleet syncs this tree, so anything
written here is read by every customer. The engineering conclusion travels;
whose data produced it does not. A CI guard in the monorepo enforces this.
