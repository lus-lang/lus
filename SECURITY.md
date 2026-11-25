# Security

## Supported versions

The latest release of Lus receives security fixes. Earlier releases do not.

## Reporting a vulnerability

Report vulnerabilities privately through [GitHub's advisory form](https://github.com/lus-lang/lus/security/advisories/new). A report stays private between you and the maintainer until a fix ships, and the advisory then credits you unless you ask otherwise.

A useful report names the version, the platform, and a program or input that reproduces the problem. Escapes from the permission system (`pledge`), memory safety bugs in the runtime or the JIT, and bugs in the TLS, archive, or JSON parsers are the most valuable reports.

Please keep vulnerabilities out of public issues, pull requests, and Discussions until the advisory is published.
