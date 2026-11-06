# Deploy Station templates

The build and deploy pieces that application repositories reuse (docs/DESIGN.md §11, decisions D15–D18 and D22). Target servers can be Windows Server or Ubuntu 22.04 / 24.04.

They are published, without `server/` and `tests/`, to the public repository [itsteven-newboss/deploy-station-templates](https://github.com/itsteven-newboss/deploy-station-templates), which application repositories of any owner use.

| Path | What it is |
|---|---|
| `../.github/workflows/tpl-build-*.yml` | Reusable build workflows: .NET, Python, Node.js, custom script |
| `../.github/workflows/tpl-deploy.yml` | Reusable deploy workflow: one target server at a time, Windows or Ubuntu |
| `actions/package/` | Composite action: builds the package and publishes it to the pre-release `v<version>` |
| `actions/fetch-package/` | Composite action: downloads and verifies the package for the server's OS |
| `engine/` | The deploy engines, shipped inside every package as `_ds/`: `deploy.ps1` (Windows) and `deploy.sh` (Ubuntu) |
| `server/` | Target-server setup and gatekeeper: `install-runner.ps1` + `pre-job.ps1` (Windows), `install-runner.sh` + `pre-job.sh` (Ubuntu). Not published: Deploy Station uploads them itself. |
| `examples/` | Example `ds.json` files, validated by `tests/Test-DsManifests.ps1` |
| `tests/` | Windows PowerShell 5.1 and bash tests, run by `templates-ci.yml`. Not published. |
| `public-repo/` | The public repository's own README and `.gitattributes` |

The PowerShell here targets Windows PowerShell 5.1 (on every Windows Server) and must stay ASCII. The bash scripts need `jq`, `curl` and `unzip`, which `install-runner.sh` installs.

## Sharing and releasing

- Application repositories call the templates from the public repository, by tag: `itsteven-newboss/deploy-station-templates/.github/workflows/tpl-build-dotnet.yml@tpl-v6`. Being public, they work for repositories of any owner, private or public.
- The source stays here, where `templates-ci.yml` tests it. Only what workflows need is published: the `tpl-*.yml` workflows, `actions/`, `engine/`, `examples/` and this README.
- To release `tpl-vN`:
  1. Change every `@tpl-v…` reference in `.github/workflows/tpl-*.yml` and `examples/*/.github/workflows/` to the new tag (template workflows reference the composite actions by full path and tag, not `./`, because `./` would point at the calling app repository).
  2. Commit, and tag this repository `tpl-vN`.
  3. Run `node scripts/publish-templates.mjs tpl-vN`. It checks that every reference points at the public repository and the new tag, copies the files into a clone of it, commits and tags them, and shows what changed. Add `--push` to publish.
- Breaking changes get a new tag, so apps on an older one keep working. A published tag is never moved.
- Tags up to `tpl-v5` exist only in this private repository, shared through its **Settings → Actions → General → Access** setting with repositories owned by `itsteven-newboss`. `tpl-v6` is the first public one.

## Packages for one or both OSes

- **Portable build** (`target-os: any`, the default for .NET, Node and scripts): one `package.zip` deploys to Windows and Ubuntu servers.
- **OS-specific build** (`target-os: windows | linux | both`): `package-windows.zip` and/or `package-linux.zip`. This is needed for Python wheels and Node native modules. `tpl-build-python.yml` builds both in parallel with `both`.
- **On each server**, `fetch-package` takes `package-<its OS>.zip` when the release has one, otherwise `package.zip`.

## `ds.json`

Shared settings at the top level; a `windows` or `linux` section overrides them on that OS (top-level keys replaced), so one app can deploy to both (D17).

| Field | Required | Meaning |
|---|---|---|
| `name` | yes | App name; letters, digits, `.`, `_`, `-` |
| `strategy` | yes | Windows: `iis-site`, `windows-service`, `script`. Ubuntu: `systemd-service`, `nginx-site`, `script` |
| `appRoot` | no | Install folder. Default `C:\apps\<name>` on Windows, `/opt/apps/<name>` on Ubuntu |
| `keepReleases` | no | Release folders to keep on each server. Default 5 |
| `health.url` | no | Checked after start; a failure rolls the server back. Without it, a service must stay running for 10 seconds, and a site or script is not checked. |
| `health.timeoutSeconds` | no | Default 60 |
| `python.interpreter` | no | Python on the server, used to create `.venv` in each release. Default `python` (Windows) / `python3` (Ubuntu) |
| `python.requirements`, `python.wheelhouse` | no | Defaults `requirements.txt`, `wheels` (as produced by `tpl-build-python.yml`) |
| `prerequisites.aptPackages` | no | Ubuntu only: apt packages the app needs, e.g. `["aspnetcore-runtime-10.0"]`. Missing ones are installed before each deployment; installed ones are skipped (D21) |
| `prerequisites.aptRepositories` | no | Launchpad PPAs added only when a package is not in the server's sources, e.g. `["ppa:dotnet/backports"]` for .NET 10 on 22.04 |
| `prerequisites.windowsFeatures` | no | Windows Server only: features installed with `Install-WindowsFeature` when missing, e.g. `["Web-Server", "Web-Scripting-Tools"]` for IIS (the iis-site strategy needs both) |
| `prerequisites.installers` | no | Windows only: `[{ "name", "url", "sha512" or "sha256", "arguments", "installedPath" }]`. Run when any `installedPath` (wildcards allowed) is missing; the download must be https and match the checksum; exit codes 0 and 3010 count as success. IIS is restarted after an installer runs. See the [IIS example](examples/iis-aspnetcore.ds.json) for the ASP.NET Core Hosting Bundle |
| `windows`, `linux` | no | Overrides for that OS |

**Windows strategies**

| Field | Required | Meaning |
|---|---|---|
| `iis.siteName` | iis-site | IIS site to deploy |
| `iis.appPoolName` | no | Default: the site name |
| `iis.managedRuntimeVersion` | no | `""` (No Managed Code) for ASP.NET Core, Python and Node; `"v4.0"` for .NET Framework |
| `iis.bindings` | to create the site | `[{ "protocol", "port", "hostName", "ipAddress" }]`. Used only when the site does not exist yet |
| `service.serviceName`, `service.executable` | windows-service | Windows service name; executable relative to `<appRoot>\current` or absolute |
| `service.arguments`, `service.displayName`, `service.startupType` | no | Used when the service is first registered |
| `service.wrapper` | no | `winsw` for programs that are not native services (`python.exe`, `node.exe`, console apps) |
| `script.path` | script | A `.ps1` called with `-Action Stop` / `-Action Start`, `-AppRoot`, `-ReleaseDir`, `-Version` |

**Ubuntu strategies**

| Field | Required | Meaning |
|---|---|---|
| `service.serviceName`, `service.executable` | systemd-service | systemd unit name; executable relative to `<appRoot>/current` or absolute (e.g. `/usr/bin/dotnet`) |
| `service.arguments` | no | Appended to the executable in `ExecStart` |
| `service.user` | no | System user the app runs as; created if missing. Default: the app name |
| `service.environment` | no | `{ "NAME": "value" }`, written as `Environment=` lines |
| `service.environmentFile` | no | File under `current` loaded with `EnvironmentFile=` (e.g. secrets placed in `config/`) |
| `nginx.listen`, `nginx.serverName` | nginx-site | Port and server name of the nginx site |
| `nginx.root`, `nginx.spa` | no | Folder under `current` to serve (default `.`); `spa: true` falls back to `index.html` |
| `nginx.proxyPass` | with systemd-service | Optional reverse proxy in front of a service, e.g. `http://127.0.0.1:5000` |
| `script.path` | script | A bash script called as `<script> stop|start <appRoot> <releaseDir> <version>` |

Examples:
- **Windows:** [IIS / ASP.NET Core](examples/iis-aspnetcore.ds.json), [.NET Windows service](examples/service-dotnet.ds.json), [Python service via WinSW](examples/service-python.ds.json), [Node service via WinSW](examples/service-node.ds.json).
- **Ubuntu:** [.NET service behind nginx](examples/linux-dotnet-service.ds.json), [Python service](examples/linux-python-service.ds.json), [static site](examples/linux-static-site.ds.json).
- **Both:** [custom script for both OSes](examples/script.ds.json), the .NET sample app's [`ds.json`](../examples/sample-app/ds.json) (an IIS site on Windows, a systemd service on Ubuntu) and the [Python sample app's](../examples/sample-python-app/ds.json) (a WinSW service on Windows, a systemd service on Ubuntu, Python installed from ds.json).

The engines create a missing IIS site/app pool, Windows service, systemd unit or nginx site on first deployment. They never change an existing one (bindings, certificates, accounts and custom settings stay manual), and they never touch databases (D13).

## Layout on a target server

```text
Windows                                   Ubuntu
C:\apps\<name>\                           /opt/apps/<name>/
  releases\<version>\                       releases/<version>/      one folder per deployed version
  current\  (junction)                      current  (symlink)       the running release
  config\                                   config/                  server-held settings and secrets
  service\  (WinSW wrapper)                 ds-state.json            last result, incl. automatic rollbacks
  ds-state.json

C:\deploy-station\                        /etc/deploy-station/gatekeeper/
  gatekeeper\pre-job.ps1, <runner>.json     pre-job.sh, <runner>.json  (root-owned; token readable by ds-runner)
  runners\<runner>\  (LocalSystem)        /opt/deploy-station/runners/<runner>/  (systemd, user ds-runner, full sudo)
  tools\WinSW-x64.exe                     /etc/systemd/system/<service>.service, /etc/nginx/sites-available/<site>.conf
```

## Tests

```powershell
.\tests\Test-DsSyntax.ps1     # parse + ASCII check of every PowerShell script
.\tests\Test-DsManifests.ps1  # every example ds.json is accepted for the OSes it targets; bad ones are rejected
.\tests\Test-DsEngine.ps1     # Windows engine: deploy, switch, config overlay, health rollback, pruning
.\tests\Test-DsPackage.ps1    # package contents, checksum and per-OS names, then deploy from the extracted package
```

```bash
bash tests/test-ds-engine.sh  # Ubuntu engine, with stub systemctl/nginx/apt: same behaviour plus units, sites and prerequisites
```

Under Git Bash on Windows, run it with `MSYS=winsymlinks:nativestrict` so `ln -s` makes real symlinks (needs Developer Mode).

## Setting up a server

Deploy Station does it over SSH: add the server on the project's **Servers** tab, give its address and an SSH user (with sudo on Ubuntu; an Administrator with OpenSSH Server on Windows) and a password or private key. It uploads `server/`, runs the installer with a fresh gatekeeper token and a runner registration token from GitHub, removes the upload and pings the server (D20). Running it again updates the gatekeeper's URL and token; the runner stays registered.

By hand: copy `server/` to the server and run the install command Deploy Station shows under **Set up by hand instead**.

The real IIS, Windows-service, systemd and nginx operations need a server with admin rights, so they are verified there (spike S3 in `docs/PHASE0.md`).
