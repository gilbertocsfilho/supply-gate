# FleetDM / osquery templates

These queries are starter templates.

- Adjust paths per OS and home directory layout.
- Pair `file`/`hash` checks with process events when available.
- Treat direct execution of real binaries outside the shim root as a bypass signal.
- Use labels or separate queries for `soft` and `hard` mode so compliance expectations stay explicit.
