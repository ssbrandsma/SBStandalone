# Codex Prompt: Deploy A Squeezebox Applet

Copy the prompt below into a Codex session running on this PC. Replace every
value in angle brackets before starting.

```text
Deploy <APPLET_NAME> version <VERSION> from <APPLET_REPOSITORY_PATH> to the
Squeezebox server at <VPS_HOST>. Complete the deployment and verification;
do not merely describe the commands.

Known environment:

- Bootstrap repository: <BOOTSTRAP_REPOSITORY_PATH>
- VPS login: <VPS_SSH_TARGET>
- SSH key: <VPS_SSH_KEY_PATH>
- Merged public repository XML on the VPS:
  <MERGED_REPOSITORY_XML_PATH>
- Bootstrap configuration on the VPS:
  <BOOTSTRAP_CONFIG_PATH>
- Bootstrap container: <BOOTSTRAP_CONTAINER>
- The host config is bind-mounted into the container as /config/config.json.
  Edit/install the host file, then restart the container. Do not edit only the
  container copy.

Use this procedure:

1. Read AGENTS.md, the applet repository's deployment/build documentation,
   VERSION file, build scripts, and recent release history. Inspect the applet
   and bootstrap Git working trees. Preserve all unrelated and untracked user
   work. Do not commit, discard, or overwrite unrelated changes.

2. Determine the applet's existing public directory, package naming, targets,
   metadata, owner, and URL from its build documentation and the existing local
   and remote metadata. Do not guess a new server path. If no existing path can
   be established safely, stop and ask me for it.

3. Set the requested version in the authoritative version file. Update any
   embedded versioned User-Agent strings and the release description where the
   project convention requires it. Use the repository's normal build command.
   Run its parser, tests, static checks, and `git diff --check` before deploying.

4. Build a fresh versioned ZIP and applet-specific extensions.xml. Validate the
   archive layout, parse the XML, and calculate the ZIP SHA-1. Confirm every
   target entry uses <VERSION>, the versioned public URL, and that exact SHA-1.
   Never reuse or overwrite an old version's ZIP filename.

5. Update the local bootstrap metadata in
   <BOOTSTRAP_REPOSITORY_PATH>:

   - Update or add only <APPLET_NAME>'s target entries in config.json.
   - Update or add only <APPLET_NAME>'s entries in config.example.json when that
     file is intended to track the public catalog.
   - Update or add only <APPLET_NAME>'s entries in merged-extensions.xml.
   - Preserve all other applet entries and server settings unless I explicitly
     request their removal or modification.
   - Validate both JSON files and all XML files after editing.

6. Perform a read-only VPS preflight over SSH using BatchMode=yes. Confirm the
   destination directory, merged XML, host config, and named Docker container
   exist. Inspect current ownership and modes. Do not continue if the resolved
   destinations differ from the documented/current locations.

7. Upload all files to unique names under /tmp first, using `scp -i` with the
   key above. Upload the versioned ZIP, applet-specific extensions.xml, merged
   extensions.xml, and bootstrap config.json. Stop immediately if any upload
   fails.

8. In one fail-fast remote installation script (`set -eu`):

   - Create timestamped `.bak.YYYYMMDD-HHMMSS` copies of the current
     applet-specific extensions.xml, merged extensions.xml, and bootstrap
     config.json.
   - Install the versioned ZIP and applet-specific XML into the established
     applet public directory.
   - Install merged-extensions.xml at the merged public XML path.
   - Install config.json at the host bootstrap config path.
   - Preserve the existing owners and use mode 0644 for metadata and ZIP files.
   - Verify the installed ZIP SHA-1 before restarting anything.
   - Parse the installed JSON and XML and confirm the intended applet entries,
     version, targets, URL, and SHA-1.
   - Restart <BOOTSTRAP_CONTAINER> and confirm its state
     is `running`.

9. Verify the live container reads /config/config.json and sees the requested
   applet metadata. Review recent container logs and confirm the service listens
   on UDP/TCP 3483 and TCP 9000 without startup errors.

10. Verify from this PC that all relevant public URLs return HTTP 200. Download
    the public versioned ZIP to a temporary file and compare its SHA-1 with the
    local build. Parse both the applet-specific public extensions.xml and
    http://www.bytestack.nl/squeezebox/extensions.xml. Confirm the correct
    number of target entries and exact version, URL, and SHA-1 values.

11. Do not delete old versioned packages or timestamped backups. If validation
    fails after installation, report the exact failure and rollback using the
    backups when that is the safest way to restore the previous working state.

12. Do not commit, tag, or push unless I explicitly request it. At completion,
    report the package path, SHA-1, public URLs, container status, backup
    timestamp, tests performed, and any remaining local changes. Never print
    private-key contents, passwords, tokens, or unrelated config secrets.
```

## Values To Supply

- `<APPLET_NAME>`: the exact metadata name, such as `SpotifyConnect`.
- `<VERSION>`: a new semantic version, such as `0.5.5`.
- `<APPLET_REPOSITORY_PATH>`: the absolute local source repository path.

Add any intentional catalog removals, configuration changes, or commit/tag
instructions explicitly after the prompt. Those operations should never be
inferred from a routine applet deployment.
