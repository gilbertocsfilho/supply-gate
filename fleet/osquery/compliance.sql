SELECT
  path,
  directory,
  filename,
  size,
  mtime
FROM file
WHERE
  path LIKE '/Users/%/.local/share/supply-chain-protect/runtime/state.conf'
  OR path LIKE '/Users/%/.local/share/supply-chain-protect/runtime/binmap.conf'
  OR path LIKE '/Users/%/.local/share/supply-chain-protect/attestation/status.env';

SELECT
  path,
  sha256
FROM hash
WHERE
  path LIKE '/Users/%/.local/share/supply-chain-protect/runtime/manager-wrapper.sh'
  OR path LIKE '/Users/%/.local/share/supply-chain-protect/runtime/profile.sh';
