#!/usr/bin/env python3
"""Validate and deploy a StandaloneRadio dist ZIP to a Squeezebox over SSH."""

from __future__ import annotations

import argparse
import getpass
import re
import shlex
import stat
import sys
import time
import warnings
import zipfile
from pathlib import Path, PurePosixPath

try:
    from cryptography.utils import CryptographyDeprecationWarning

    warnings.filterwarnings("ignore", category=CryptographyDeprecationWarning)
    import paramiko
except ImportError:
    sys.stderr.write("deploy_dist requires Paramiko: python -m pip install paramiko\n")
    raise SystemExit(2)


REQUIRED_ROOT = {
    "Countries.lua",
    "HlsMetadata.lua",
    "HttpsProxyStatus.lua",
    "LogoCache.lua",
    "NativeNowPlaying.lua",
    "PresetStore.lua",
    "RadioBrowser.lua",
    "Resolver.lua",
    "StandaloneBaseNowPlaying.lua",
    "StandaloneRadioApplet.lua",
    "StandaloneRadioMeta.lua",
    "Stations.lua",
    "StreamMetadata.lua",
    "StreamPlayer.lua",
    "TrackArtwork.lua",
    "UrlTransport.lua",
    "UserStations.lua",
    "strings.txt",
}
REQUIRED = REQUIRED_ROOT | {"images/radio.png"}
OPML_MODULES = {"OpmlClient.lua", "OpmlParser.lua", "OpmlProviders.lua", "OpmlNavigator.lua"}
TARGET = "/usr/share/jive/applets/StandaloneRadio"


def arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        prog="deploy_dist",
        description="Validate and deploy a StandaloneRadio dist ZIP over SSH.",
    )
    parser.add_argument("zip_file", type=Path, help="ZIP from the dist directory; .zip may be omitted")
    parser.add_argument("target", help="SSH destination in user@host form")
    parser.add_argument("-p", "--password", help="SSH password; -pPASSWORD is accepted")
    parser.add_argument("--port", type=int, default=22, help="SSH port (default: 22)")
    parser.add_argument(
        "--accept-new-host-key",
        action="store_true",
        help="trust an unknown host key for this run (known hosts are verified by default)",
    )
    parser.add_argument("--no-restart", action="store_true", help="do not restart SqueezePlay")
    parser.add_argument("--dry-run", action="store_true", help="validate locally without connecting")
    return parser.parse_args()


def package_path(value: Path) -> Path:
    candidate = value.expanduser()
    if candidate.suffix.lower() != ".zip" and not candidate.is_file():
        candidate = candidate.with_name(candidate.name + ".zip")
    return candidate.resolve()


def validate_package(value: Path) -> tuple[Path, list[str], str]:
    path = package_path(value)
    if not path.is_file():
        raise ValueError(f"package not found: {path}")
    match = re.fullmatch(r"StandaloneRadio-([0-9]+\.[0-9]+\.[0-9]+)\.zip", path.name)
    if not match:
        raise ValueError("package name must be StandaloneRadio-X.Y.Z.zip")
    if path.parent.name.lower() != "dist":
        raise ValueError("package must be located in a dist directory")

    with zipfile.ZipFile(path) as archive:
        infos = archive.infolist()
        names = [entry.filename.replace("\\", "/") for entry in infos if not entry.is_dir()]
        if len(names) != len(set(names)):
            raise ValueError("package contains duplicate entries")
        for entry, name in zip(infos, [item.filename.replace("\\", "/") for item in infos]):
            parts = PurePosixPath(name).parts
            if name.startswith("/") or not parts or any(part in ("", ".", "..") for part in parts):
                raise ValueError(f"unsafe archive entry: {name}")
            mode = entry.external_attr >> 16
            if mode and stat.S_ISLNK(mode):
                raise ValueError(f"symbolic links are not allowed: {name}")
        # Archived releases used the historical RadioFeeds module names.
        legacy = {"RadioFeedsClient.lua", "RadioFeedsOpml.lua"}
        if legacy.intersection(names):
            expected = REQUIRED | legacy
            if OPML_MODULES.intersection(names):
                expected |= OPML_MODULES
        else:
            expected = REQUIRED | OPML_MODULES
        if "PodcastRssParser.lua" in names or ("OpmlClient.lua" in names and b"StandaloneRadio.PodcastRssParser" in archive.read("OpmlClient.lua")):
            expected.add("PodcastRssParser.lua")
        missing = sorted(expected.difference(names))
        unexpected = sorted(set(names).difference(expected))
        if missing:
            raise ValueError("package is missing: " + ", ".join(missing))
        if unexpected:
            raise ValueError("package contains unexpected files: " + ", ".join(unexpected))
        allowed_directories = {"images/"}
        bad_directories = [entry.filename for entry in infos if entry.is_dir() and entry.filename not in allowed_directories]
        if bad_directories:
            raise ValueError("package contains unexpected directories: " + ", ".join(bad_directories))
        if archive.testzip() is not None:
            raise ValueError("package CRC validation failed")
    return path, names, match.group(1)


def split_target(value: str) -> tuple[str, str]:
    if value.count("@") != 1:
        raise ValueError("target must use user@host syntax")
    user, host = value.split("@", 1)
    if not re.fullmatch(r"[A-Za-z0-9_.-]+", user):
        raise ValueError("invalid SSH user")
    if not re.fullmatch(r"[A-Za-z0-9_.:-]+", host):
        raise ValueError("invalid SSH host")
    return user, host


class Radio:
    def __init__(self, user: str, host: str, password: str, port: int, accept_new: bool):
        self.user, self.host, self.password, self.port = user, host, password, port
        self.accept_new = accept_new
        self.client = self._new_client()

    def _new_client(self):
        client = paramiko.SSHClient()
        client.load_system_host_keys()
        client.set_missing_host_key_policy(
            paramiko.AutoAddPolicy() if self.accept_new else paramiko.RejectPolicy()
        )
        return client

    def connect(self) -> None:
        self.client.connect(
            self.host,
            port=self.port,
            username=self.user,
            password=self.password,
            look_for_keys=False,
            allow_agent=False,
            timeout=12,
        )

    def run(self, command: str, attempts: int = 3) -> str:
        marker = "__STANDALONERADIO_DEPLOY_RC="
        last: Exception | None = None
        for attempt in range(attempts):
            try:
                transport = self.client.get_transport()
                if not transport or not transport.is_active():
                    self.client.close()
                    self.client = self._new_client()
                    self.connect()
                wrapped = (
                    "{\n" + command + "\n}\n"
                    "sr_deploy_rc=$?\n"
                    "printf '\\n" + marker + "%s\\n' \"$sr_deploy_rc\""
                )
                _, stdout, stderr = self.client.exec_command(wrapped)
                output = stdout.read().decode(errors="replace")
                error = stderr.read().decode(errors="replace")
                status = stdout.channel.recv_exit_status()
                if marker in output:
                    body, result = output.rsplit(marker, 1)
                    remote_status = int(result.strip().splitlines()[0])
                    if remote_status:
                        raise RuntimeError(f"remote command failed ({remote_status}): {error or body}")
                    return body.rstrip("\r\n")
                if status:
                    raise RuntimeError(f"remote command failed ({status}): {error or output}")
                raise RuntimeError("remote command ended without a completion marker")
            except Exception as exc:
                last = exc
                self.client.close()
                if attempt + 1 < attempts:
                    time.sleep(1)
        raise RuntimeError(str(last))

    def upload_bytes(self, payload: bytes, remote_directory: str, remote_name: str) -> None:
        for attempt in range(3):
            try:
                transport = self.client.get_transport()
                if not transport or not transport.is_active():
                    self.connect()
                    transport = self.client.get_transport()
                channel = transport.open_session()
                channel.exec_command("scp -t " + shlex.quote(remote_directory))
                self._scp_ok(channel)
                channel.sendall(f"C0644 {len(payload)} {remote_name}\n".encode())
                self._scp_ok(channel)
                channel.sendall(payload)
                channel.sendall(b"\0")
                self._scp_ok(channel)
                channel.close()
                return
            except Exception:
                self.client.close()
                if attempt == 2:
                    raise
                self.client = self._new_client()
                time.sleep(1)

    @staticmethod
    def _scp_ok(channel) -> None:
        response = channel.recv(1)
        if response != b"\0":
            detail = channel.recv(1024).decode(errors="replace")
            raise RuntimeError("SCP rejected transfer: " + detail)


def main() -> int:
    args = arguments()
    try:
        package, names, version = validate_package(args.zip_file)
        user, host = split_target(args.target)
    except (ValueError, zipfile.BadZipFile) as exc:
        sys.stderr.write(f"deploy_dist: {exc}\n")
        return 2

    print(f"Validated StandaloneRadio {version}: {package} ({len(names)} files)")
    if args.dry_run:
        print("Dry run complete; no connection or changes made.")
        return 0

    password = args.password if args.password is not None else getpass.getpass("SSH password: ")
    radio = Radio(user, host, password, args.port, args.accept_new_host_key)
    stage = ""
    try:
        radio.connect()
        candidate = radio.run("mktemp -d /tmp/standaloneradio-deploy.XXXXXX").strip()
        if not re.fullmatch(r"/tmp/standaloneradio-deploy\.[A-Za-z0-9]+", candidate):
            raise RuntimeError(f"unsafe staging path returned by radio: {candidate!r}")
        stage = candidate
        qstage = shlex.quote(stage)
        qtarget = shlex.quote(TARGET)
        # Extract locally and transfer each already-validated member. BusyBox
        # unzip on stock 7.7.3 can materialize images/radio.png as a literal
        # `images\radio.png` filename instead of a child of images/.
        radio.run(f"mkdir {qstage}/files && mkdir {qstage}/files/images")
        with zipfile.ZipFile(package) as archive:
            for name in names:
                relative = PurePosixPath(name)
                remote_directory = f"{stage}/files"
                if len(relative.parts) > 1:
                    remote_directory += "/" + "/".join(relative.parts[:-1])
                radio.upload_bytes(archive.read(name), remote_directory, relative.name)
        radio.run(f"mkdir -p {qtarget}/images")
        for name in names:
            source = f"{stage}/files/{name}"
            target = f"{TARGET}/{name}"
            radio.run(
                f"cp {shlex.quote(source)} {shlex.quote(target + '.new')} && "
                f"chmod 644 {shlex.quote(target + '.new')} && "
                f"mv {shlex.quote(target + '.new')} {shlex.quote(target)}"
            )
        # Clean up the malformed filename left by deployer versions that used
        # the target's BusyBox unzip. This happens only after all package files
        # have been installed successfully.
        radio.run("rm -f " + shlex.quote(TARGET + "/images\\radio.png"))
        if not args.no_restart:
            radio.run(
                "nohup sh -c 'sleep 1; /etc/init.d/squeezeplay restart' "
                ">/tmp/standaloneradio-restart.log 2>&1 </dev/null &"
            )
        print(f"Deployed StandaloneRadio {version} to {user}@{host}.")
        print("SqueezePlay restart skipped." if args.no_restart else "SqueezePlay restart scheduled.")
        return 0
    except Exception as exc:
        sys.stderr.write(f"deploy_dist: deployment failed: {exc}\n")
        return 1
    finally:
        if stage:
            try:
                radio.run("rm -rf " + shlex.quote(stage), attempts=2)
            except Exception as exc:
                sys.stderr.write(f"deploy_dist: warning: could not remove {stage}: {exc}\n")
        radio.client.close()


if __name__ == "__main__":
    raise SystemExit(main())
