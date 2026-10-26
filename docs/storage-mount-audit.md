# Storage mount compatibility audit ? Radio 0.9.17

Custom stations were incorrectly routed to internal storage when sbdata was
mounted with native `ubifs`. Base already recognized the native filesystem;
Radio recognized only the legacy `sbubifs` name. No configuration data was lost.

Radio now matches Base: exact mount `/mnt/sbdata`, volume `ubi0:sbdata` or
`/dev/ubi0_5`, and filesystem `ubifs` or `sbubifs`. Uploaded-logo paths follow
the selected configuration root. Revision/path cache invalidation is preserved.

Audited Base: InstallerCompat, radio_stations.c, repository.c, image_render.c,
firmware.c, sb_storage_helper.c, storage-boot.sh and storage-setup.sh. General
storage consumers already accept both names. Legacy driver registration,
initialization and recovery checks intentionally require sbubifs; verified
native mounting/repair takes its separate branch. They must not be globally
rewritten. Base needs no new release for this fix.

Regression coverage includes both volume identifiers and filesystem names,
foreign volumes, incorrect filesystem/mountpoint, bind-only mounts, malformed
mount data, storage removal and unreadable mount metadata.
