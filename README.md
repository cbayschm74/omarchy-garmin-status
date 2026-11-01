# Garmin status

Read-only Omarchy bar widget (`org.garminlinux.status`). It shows whether any Garmin USB storage is connected and how many physical Garmin devices that storage belongs to. Edge internal storage and an SD card on the same Edge count as one device and two volumes.

A left click opens Garmin Linux Companion only when a launch command has been configured. The count itself does not need that application.

The widget does not mount volumes, open Garmin files, or display device names, labels, paths, or serial numbers.

## Dependencies

- Omarchy with shell plugins. Checked on Omarchy 4.0.6-1.
- `python3`. The bundled `status.py` uses the Python standard library only.
- `lsblk` from `util-linux`, for USB vendor and transport metadata.

No extra Python packages are installed. The widget does not download files, run a shell pipeline, or change system configuration by itself. Plugins run as unsandboxed code inside `omarchy-shell`. Review `BarWidget.qml` and `status.py` before enabling this one.

Garmin Linux Companion is optional. Install it separately when you want the bar click to open the desktop app.

## Install

`omarchy plugin add` asks for confirmation, clones this repository, and validates it before the plugin is enabled. Pass `--yes` only after that review. `--enable` places the widget on the right side of the bar:

```sh
omarchy plugin add https://github.com/cbayschm74/omarchy-garmin-status.git --enable
```

Without `--enable`, enable it later:

```sh
omarchy plugin enable org.garminlinux.status --section right
```

Enabling adds this widget to the bar. It does not change other plugins, write Garmin settings, or replace an existing plugin with the same id. If `org.garminlinux.status` is already installed, disable and remove that copy with the commands below before adding this repository.

After installation the widget runs `status.py` with `python3`. No companion checkout path is required for the count. To open Garmin Linux Companion from a left click, set that command yourself:

```sh
omarchy bar set org.garminlinux.status launchCommand '["/home/you/.local/bin/garmin-linux-companion"]'
```

That write is explicit. Leave it unset and the click does nothing.

## Removal

Remove only this plugin:

```sh
omarchy plugin disable org.garminlinux.status
omarchy plugin remove org.garminlinux.status
```

`remove` asks for confirmation unless you pass `--yes`. It disables the widget first. A Git checkout is deleted and this GitHub repository is left in place. A folder that is not a Git checkout is moved to a hidden backup under `~/.config/omarchy/plugins/` and is not loaded.

Removal does not uninstall Garmin Linux Companion, delete `~/GarminBackups`, or change any other plugin.

## License

MIT. See [LICENSE](LICENSE).

This repository is not listed at plugins.omarchy.org until a maintainer approves a submission.
