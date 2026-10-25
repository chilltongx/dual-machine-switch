# Third-party components

## m1ddc

- Upstream: https://github.com/waydabber/m1ddc
- Vendored revision: `04d949794102eb8df01ad3681afff6464a3eede2`
- License: MIT; see [vendor/m1ddc/LICENSE](vendor/m1ddc/LICENSE).
- Local changes: [vendor/m1ddc-local.patch](vendor/m1ddc-local.patch).

The local changes correct DDC read checksums, retain zero checksum bytes,
decode reply values without an overrun, validate replies, and use a longer
DDC interval. The upstream copyright notice is retained.

Deskflow was used during an earlier prototype. The current device-selective
backend does not link to or redistribute Deskflow, and does not require it.
