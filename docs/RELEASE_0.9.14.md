# Standalone Radio 0.9.14

- Add generic RSS podcast browsing directly or through custom OPML directories.
- Parse large feeds incrementally with bounded memory, retaining up to 50 episodes.
- Support finite episode playback, pause/resume, duration, position and episode artwork.
- Fix empty native Now Playing navigation and reject-free publication of unknown audio properties.
- Update OPML user agent to `Standalone/0.9.14` and other Radio versioned user agents.

See [podcast implementation, device validation and limitations](PODCAST_RSS.md).

All 20 Lua suites and four integration checks passed. The 24-file package passed
the deployment validator. Prior device validation on 192.168.1.226 confirmed BBC
feeds, episode playback, artwork, position, pause/resume and stop ownership cleanup.

Package: [StandaloneRadio-0.9.14.zip](http://49.12.198.91/sbstandalone/StandaloneRadio-0.9.14.zip)

SHA-1: `743c649015758ed6e8d3ac0a823bca2b7d6e9916`

Release catalogs update both Radio targets and preserve other applets. Base remains
0.6.1; its local Radio catalog entry is updated. The remote bootstrap installer
retains its existing Base-only catalog policy.
