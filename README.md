# KeyAlive

**Keep Bluetooth keyboards awake on macOS.**

Many Bluetooth keyboards turn their radio off after a few idle minutes to save battery. When you come back, the first keystrokes are lost, the keyboard takes seconds to reconnect, or macOS doesn't find it again until you re-pair it. KeyAlive is a tiny background agent that stops that from happening.

- **Finds your keyboards on its own.** It asks macOS which Bluetooth LE devices are keyboards, so there are no names or addresses to set up.
- **Keeps them awake.** Every 60 s it reads one byte (the battery level) from each keyboard. The keyboard sees traffic and doesn't fall asleep.
- **Reconnects them.** If a keyboard drops anyway, KeyAlive keeps a pending connection open, and the keyboard is re-attached the moment it wakes. It also remembers keyboards across reboots.
- **Costs nothing.** Measured at 0.0 % CPU and a few MB of memory. It is a single native binary with no dependencies.

> Trade-off: a keyboard that never sleeps uses more of its own battery. For keyboards that are usually plugged in or charged often, that's the point.

## Requirements

- macOS 12 or later should work; so far it has only been tested on macOS 26.5 (Apple Silicon).
- A **Bluetooth Low Energy** keyboard. Most current keyboards are, especially ones advertised as "Bluetooth 5.x". Run `keyalive list` to check: if your keyboard appears under "BLE keyboards", it's supported.
- Xcode Command Line Tools (`xcode-select --install`) to build.

## Install

```sh
git clone https://github.com/Saul-Punybz/keyalive.git
cd keyalive
make install
```

This builds `keyalive`, copies it to `~/.local/bin`, and registers a LaunchAgent that starts it at login and restarts it if it ever exits. The first time it runs, macOS asks for Bluetooth access. Click **Allow**. If you missed the prompt, enable it under System Settings → Privacy & Security → Bluetooth.

Options for the background agent go in `ARGS`:

```sh
make install ARGS="--interval 45"            # ping more often
make install ARGS="--name keychron"          # only this keyboard
make install ARGS="--include-mice"           # also keep BLE mice awake
```

## Use

```sh
make status        # is the agent running?
make log           # last 30 log lines (~/Library/Logs/keyalive.log)
keyalive list      # BLE keyboards macOS knows + a 15 s scan of nearby devices
make uninstall     # remove everything
```

A healthy log looks like this:

```
2026-10-02 14:11:03  keyalive 0.1.0 starting
2026-10-02 14:11:03  Bluetooth on — looking for BLE keyboards (ping every 60 s)
2026-10-02 14:11:03  found: BT5.2 Keyboard
2026-10-02 14:11:03  CONNECTED BT5.2 Keyboard
2026-10-02 14:11:03  battery BT5.2 Keyboard: 100%
```

`DISCONNECTED … will reconnect when it wakes` followed by `CONNECTED` means KeyAlive caught a drop and reattached the keyboard.

## Options

| Option | Default | What it does |
|---|---|---|
| `--interval SECONDS` | `60` | Time between pings (minimum 5). Use a value shorter than your keyboard's sleep timeout. |
| `--name TEXT` | all keyboards | Only handle devices whose name contains `TEXT`. Repeatable. |
| `--include-mice` | off | Also keep BLE mice and trackpads awake. |

## Troubleshooting

**My keyboard doesn't show up in Bluetooth settings at all.**
- Many keyboards name themselves something generic, like `BT5.2 Keyboard` or `BT 5.0 KB`, not the brand name.
- A multi-device keyboard that was paired to an iPad or iPhone tries to reconnect to that device first. While it's doing that, it doesn't appear under "Nearby Devices". Turn Bluetooth off on the other devices, then hold the keyboard's Bluetooth channel key until its light blinks fast.
- `keyalive list` scans for BLE devices, including ones macOS hides from the settings list.

**It still sleeps.** Some keyboard firmware only counts keystrokes as activity and ignores radio traffic. KeyAlive will still reconnect it the moment you press a key, but it can't keep that model awake. Please open an issue with the keyboard model so others know.

**Classic (non-LE) Bluetooth keyboards.** These aren't supported yet. Apple's Bluetooth LE framework, which KeyAlive uses, can't talk to them.

## How it works

1. IOKit's HID manager lists the devices whose transport is `Bluetooth Low Energy` and whose usage is *Keyboard*. These are the keyboards macOS itself is using.
2. CoreBluetooth retrieves those same devices from the system connection. This doesn't take the keyboard away from macOS; typing keeps working. KeyAlive then finds a small readable characteristic on each one, preferring Battery Level (`0x2A19`).
3. A timer reads that characteristic every `--interval` seconds.
4. On disconnect, KeyAlive calls `connect` again with no timeout. CoreBluetooth completes it whenever the keyboard advertises again.
5. Keyboards it has seen are saved in `~/Library/Application Support/keyalive/known.json`, so a keyboard that's asleep at login is still re-attached.

## License

MIT. See [LICENSE](LICENSE).

---

*Leer en español:* KeyAlive mantiene despiertos los teclados Bluetooth en macOS. Cada 60 s les lee la batería para que no se duerman, y si se caen, los reconecta solo apenas despiertan. Para instalarlo: `git clone`, `cd keyalive`, `make install`. Cuando macOS pida acceso a Bluetooth, dale "Permitir".
