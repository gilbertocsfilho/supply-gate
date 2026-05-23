SELECT
  name,
  path,
  cmdline,
  parent,
  uid,
  start_time
FROM processes
WHERE name IN ('npm', 'pnpm', 'yarn', 'bun', 'pip', 'uv', 'poetry', 'cargo', 'go', 'claude', 'gemini', 'codex');
