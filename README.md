# Deploy Station templates

Reusable GitHub Actions workflows and actions that build and deploy applications for **Deploy Station**. Deploy Station tracks what is in Test and Production, who tested it and who released it, and deploys through self-hosted runners on the application's servers.

These files are published from Deploy Station's own (private) repository. Each release is a tag, `tpl-vN`; please don't open pull requests here.

## Using them

An application repository calls the templates from three small workflow files. Deploy Station makes them for each application: **Guides → Set up a project → Workflow files**. The build and deploy jobs look like this:

```yaml
jobs:
  build:
    if: ${{ inputs.build }}
    uses: itsteven-newboss/deploy-station-templates/.github/workflows/tpl-build-dotnet.yml@tpl-v6
    with:
      version: ${{ inputs.version }}
      project: src/MyApp/MyApp.csproj

  deploy:
    needs: build
    uses: itsteven-newboss/deploy-station-templates/.github/workflows/tpl-deploy.yml@tpl-v6
    with:
      version: ${{ inputs.version }}
      targets: ${{ inputs.targets }}
```

Always pin a tag (`@tpl-vN`), never a branch.

| Path | What it is |
|---|---|
| `.github/workflows/tpl-build-dotnet.yml` | Build a .NET (5 and later) application |
| `.github/workflows/tpl-build-python.yml` | Build a Python application, with wheels for the servers' OS |
| `.github/workflows/tpl-build-node.yml` | Build a Node.js service or static website |
| `.github/workflows/tpl-build-script.yml` | Build with the application's own script (e.g. .NET Framework) |
| `.github/workflows/tpl-deploy.yml` | Deploy a package to the servers, one at a time, Windows or Ubuntu |
| `templates/actions/` | The composite actions the workflows use: package, and fetch the package on a server |
| `templates/engine/` | The deploy engines shipped inside every package: `deploy.ps1` (Windows) and `deploy.sh` (Ubuntu) |
| `templates/examples/` | Example `ds.json` files |
| `templates/README.md` | The `ds.json` reference and how an application is laid out on a server |

## Safety

- **No secrets live here.** Application settings and secrets stay on the servers.
- **Nothing deploys without Deploy Station.** Deployment jobs run only on servers whose gatekeeper checks each job with Deploy Station first. A run started by hand, or from any repository Deploy Station did not approve, is refused before it starts.
- **Organizations that allow only selected actions** must allow `itsteven-newboss/deploy-station-templates@*`.

## Versions

| Tag | Changes |
|---|---|
| `tpl-v6` | First public release. The same templates as the earlier, privately shared `tpl-v5`: Windows and Ubuntu servers, application prerequisites in `ds.json`, installers pinned by SHA-256 or SHA-512. |
