# Security Policy

## Reporting a vulnerability

Please report vulnerabilities privately through GitHub's vulnerability
reporting: on the repository page, go to **Security → Report a vulnerability**
(or use
[this link](https://github.com/fairtier/workspace-gitops/security/advisories/new)).

Please do **not** open a public issue for anything security-sensitive. Every
FairTier-hosted workspace deploys from this tree, so a finding here is a
finding on live infrastructure.

Worth knowing before you report: this repository is public *by design* and
contains no credentials. Every secret a workspace uses is either generated on
the machine itself or delivered to it over an authenticated channel the machine
opens outbound. If you believe you have found a credential here, that is
exactly the report we want.

We aim to acknowledge reports within a few business days. Please give us a
reasonable window to ship a fix before any public disclosure.

## Supported versions

Fixes land on `master` and in the latest release tag. Older tags are not
patched — a workspace should be moved forward to take one.
