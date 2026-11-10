#!/usr/bin/env python3
"""Graphical front end of the installer (GTK 4 + libadwaita).

It only decides and shows: every change to the machine is made by the
`install-nixos` script (install-nixos.sh), run as root with INSTALL_UI=1. The
script reports its steps and asks its questions through lines starting with
"@@" (see "GUI protocol" in the script); everything else it prints is the log.

Pages: network -> choose (automatic / resume / manual) -> progress -> done or
failed. The header bar starts the things to do meanwhile (browser, music,
Bluetooth, sound, terminal, Claude), each as its own tab in the kiosk (sway).

For tests/installer-gui.nix: INSTALLER_FAKE_ENGINE=<program> runs that instead
of `sudo install-nixos`; INSTALLER_TEST=1 skips the internet check and
INSTALLER_TEST=start also starts the engine right away.
"""
import glob
import json
import os
import re
import subprocess
import sys

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")
from gi.repository import Adw, Gio, GLib, Gtk  # noqa: E402

REPO = os.environ.get("ISO_REPO", "/etc/nixos")  # hosts/ as of the image build
LOG = "/tmp/install-nixos.log"
EXTRAS = "/run/installer-extras"  # Chromium with Widevine + Claude Code, fetched after boot
ENGINE_STEPS = [
    "Fetch the configuration",
    "Check machine and disk",
    "Sign in and collect secrets",
    "Partition and encrypt the disk",
    "Enrol the machine's secrets",
    "Install NixOS",
    "Finish up",
]
VAULT_LOGINS = [
    ("1", "Vault: single sign-on in the browser"),
    ("2", "Vault: personal API key"),
    ("3", "No vault: type the passwords"),
]
ANSI = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")
CSS = """
@define-color accent_bg_color ACCENT;
@define-color accent_color ACCENT_LIGHT;
.log { font-family: monospace; font-size: 10pt; }
.step-done { color: ACCENT_LIGHT; }
.step-active { font-weight: bold; }
.step-pending, .step-skipped { opacity: 0.5; }
.danger-text { color: @error_color; font-weight: bold; }
"""


def run(*cmd, timeout=20):
    """Output of a command, or "" if it fails."""
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout).stdout
    except (OSError, subprocess.SubprocessError):
        return ""


def spawn(*cmd):
    try:
        subprocess.Popen(cmd, stdin=subprocess.DEVNULL, start_new_session=True)
    except OSError as e:
        print(f"could not start {cmd[0]}: {e}", file=sys.stderr)


def online():
    if os.environ.get("INSTALLER_TEST"):  # tests/installer-gui.nix has no internet
        return True
    return run("nmcli", "-t", "-f", "CONNECTIVITY", "general").strip() == "full"


def hosts():
    """{host: by-id disk path or None} for every installable host in the repo."""
    found = {}
    for disko in sorted(glob.glob(f"{REPO}/hosts/*/disko.nix")):
        host = os.path.basename(os.path.dirname(disko))
        disk = None
        try:
            m = re.search(r'"(/dev/disk/by-id/[^"]+)"', open(f"{REPO}/hosts/{host}/disk.nix").read())
            disk = m.group(1) if m else None
        except OSError:
            pass
        found[host] = disk
    return found


def disks():
    """Disks that can be installed on: [{name, size, model, parts: [..]}]."""
    boot = run("sh", "-c", "lsblk -no PKNAME \"$(findmnt -no SOURCE /iso)\" 2>/dev/null").strip()
    try:
        tree = json.loads(run("lsblk", "-J", "-o", "NAME,SIZE,MODEL,TYPE,FSTYPE,LABEL"))["blockdevices"]
    except (ValueError, KeyError):
        return []
    out = []
    for d in tree:
        if d["type"] != "disk" or d["name"] == boot or re.match(r"zram|loop", d["name"]):
            continue
        parts = [
            f"{p['name']}  {p['size']}  {p.get('fstype') or 'unformatted'}  {p.get('label') or ''}".rstrip()
            for p in d.get("children", [])
        ]
        out.append({
            "name": d["name"],
            "size": d["size"],
            "model": (d.get("model") or "disk").strip(),
            "parts": parts,
            "luks": any(p.get("fstype") == "crypto_LUKS" for p in d.get("children", [])),
        })
    return out


def disk_of(byid):
    """The entry of disks() behind a /dev/disk/by-id path, if it is plugged in."""
    if not byid or not os.path.exists(byid):
        return None
    name = os.path.basename(os.path.realpath(byid))
    return next((d for d in disks() if d["name"] == name), None)


def mounted_host():
    """Host of a half-finished installation mounted at /mnt, "" if unknown, None if none."""
    if not (os.path.ismount("/mnt") and os.path.isdir("/mnt/etc/nixos")):
        return None
    try:
        return open("/mnt/var/lib/nixos-install/host").read().strip()
    except OSError:
        return ""


class Network(Gtk.Box):
    """Connection status and a wifi picker (NetworkManager through nmcli)."""

    def __init__(self, on_change=None):
        super().__init__(orientation=Gtk.Orientation.VERTICAL, spacing=12)
        self.on_change = on_change
        self.status = Adw.ActionRow(title="Checking the connection…")
        rescan = Gtk.Button(icon_name="view-refresh-symbolic", valign=Gtk.Align.CENTER, tooltip_text="Scan again")
        rescan.connect("clicked", lambda *_: self.refresh(rescan=True))
        self.status.add_suffix(rescan)
        box = Gtk.ListBox(css_classes=["boxed-list"], selection_mode=Gtk.SelectionMode.NONE)
        box.append(self.status)
        self.append(box)
        self.wifi = Gtk.ListBox(css_classes=["boxed-list"], selection_mode=Gtk.SelectionMode.NONE)
        self.wifi.set_placeholder(Gtk.Label(label="No wifi networks found", margin_top=12, margin_bottom=12))
        self.append(self.wifi)
        self.message = Gtk.Label(wrap=True, xalign=0)
        self.append(self.message)
        self.refresh()
        GLib.timeout_add_seconds(5, self.refresh)

    def refresh(self, rescan=False):
        up = online()
        active = run("nmcli", "-t", "-f", "NAME,TYPE", "connection", "show", "--active").splitlines()
        names = [a.rsplit(":", 1)[0] for a in active if not a.endswith(":loopback")]
        self.status.set_title("Connected to the internet" if up else "No internet connection")
        self.status.set_subtitle(", ".join(names) if names else "Plug in Ethernet or pick a wifi network")
        child = self.wifi.get_first_child()
        while child:  # rebuild the list
            self.wifi.remove(child)
            child = self.wifi.get_first_child()
        seen = set()
        scan = run("nmcli", "-t", "-f", "IN-USE,SIGNAL,SECURITY,SSID", "device", "wifi", "list",
                   "--rescan", "yes" if rescan else "auto")
        for line in scan.splitlines():
            used, signal, security, ssid = (line.split(":", 3) + ["", "", ""])[:4]
            if not ssid or ssid in seen:
                continue
            seen.add(ssid)
            row = Adw.ActionRow(title=GLib.markup_escape_text(ssid),
                                subtitle=f"{signal}%  {security or 'open'}")
            if used == "*":
                row.add_suffix(Gtk.Image(icon_name="object-select-symbolic"))
            else:
                button = Gtk.Button(label="Connect", valign=Gtk.Align.CENTER)
                button.connect("clicked", self.connect_wifi, ssid, bool(security and security != "--"))
                row.add_suffix(button)
            self.wifi.append(row)
        if self.on_change:
            self.on_change(up)
        return True

    def connect_wifi(self, _button, ssid, secured):
        if not secured:
            return self.join(ssid, None)
        dialog = Adw.AlertDialog(heading=f"Password for {ssid}")
        entry = Gtk.PasswordEntry(show_peek_icon=True, activates_default=True)
        dialog.set_extra_child(entry)
        dialog.add_response("cancel", "Cancel")
        dialog.add_response("ok", "Connect")
        dialog.set_default_response("ok")
        dialog.set_response_appearance("ok", Adw.ResponseAppearance.SUGGESTED)
        dialog.connect("response", lambda _d, r: r == "ok" and self.join(ssid, entry.get_text()))
        dialog.present(self.get_root())

    def join(self, ssid, password):
        self.message.set_text(f"Connecting to {ssid}…")
        cmd = ["nmcli", "device", "wifi", "connect", ssid] + (["password", password] if password else [])
        proc = Gio.Subprocess.new(cmd, Gio.SubprocessFlags.STDOUT_PIPE | Gio.SubprocessFlags.STDERR_MERGE)

        def done(p, result):
            _ok, out, _err = p.communicate_utf8_finish(result)
            self.message.set_text("" if p.get_successful() else (out or "").strip())
            self.refresh()

        proc.communicate_utf8_async(None, None, done)


class Installer(Adw.ApplicationWindow):
    def __init__(self, app):
        super().__init__(application=app, title="NixOS installer", default_width=1100, default_height=760)
        self.engine = None       # the running install-nixos, a Gio.Subprocess
        self.stdin = None
        self.host = ""
        self.current_step = 0
        self.seen, self.skipped = set(), set()
        self.pulse = None
        self.last_error = ""
        self.log_file = open(LOG, "a", buffering=1)

        self.stack = Gtk.Stack(transition_type=Gtk.StackTransitionType.CROSSFADE, hexpand=True)
        self.stack.add_named(self.page_network(), "network")
        self.stack.add_named(Gtk.Box(), "choose")   # rebuilt each time it is shown
        self.stack.add_named(self.page_progress(), "progress")
        self.stack.add_named(Gtk.Box(), "end")

        split = Gtk.Box()
        split.append(self.sidebar())
        split.append(Gtk.Separator(orientation=Gtk.Orientation.VERTICAL))
        split.append(self.stack)
        view = Adw.ToolbarView(content=split)
        view.add_top_bar(self.header())
        self.set_content(view)
        self.set_steps(0)
        GLib.timeout_add_seconds(3, self.refresh_extras)

    # --- frame ---
    def header(self):
        bar = Adw.HeaderBar(show_end_title_buttons=False, show_start_title_buttons=False)
        self.extras_label = Gtk.Label(css_classes=["dim-label"])

        def button(icon, tip, action, end=False):
            b = Gtk.Button(icon_name=icon, tooltip_text=tip)
            b.connect("clicked", lambda *_: action())
            (bar.pack_end if end else bar.pack_start)(b)
            return b

        button("web-browser-symbolic", "Browser (Chromium)", lambda: spawn("installer-browser"))
        self.music = button("audio-x-generic-symbolic", "Spotify",
                            lambda: spawn("installer-browser", "https://open.spotify.com"))
        button("video-x-generic-symbolic", "YouTube", lambda: spawn("installer-browser", "https://www.youtube.com"))
        button("utilities-terminal-symbolic", "Terminal", lambda: spawn("foot"))
        claude = Gtk.Button(label="Ask Claude", tooltip_text="Claude Code, with the installer's log")
        claude.connect("clicked", lambda *_: self.ask_claude())
        bar.pack_start(claude)
        bar.pack_start(self.extras_label)

        power = Gtk.MenuButton(icon_name="system-shutdown-symbolic", tooltip_text="Power")
        menu = Gio.Menu()
        menu.append("Restart", "app.reboot")
        menu.append("Power off", "app.poweroff")
        power.set_menu_model(menu)
        bar.pack_end(power)
        button("audio-volume-high-symbolic", "Sound", lambda: spawn("pavucontrol"), end=True)
        button("bluetooth-active-symbolic", "Bluetooth devices", lambda: spawn("blueman-manager"), end=True)
        button("network-wireless-symbolic", "Network", self.network_window, end=True)
        return bar

    def sidebar(self):
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10, width_request=290,
                      margin_top=24, margin_bottom=24, margin_start=20, margin_end=20)
        self.step_rows = []
        for title in ["Connect to the internet", "Choose machine and disk"] + ENGINE_STEPS:
            row = Gtk.Box(spacing=10)
            icon = Gtk.Image()
            label = Gtk.Label(label=title, xalign=0, wrap=True)
            row.append(icon)
            row.append(label)
            box.append(row)
            self.step_rows.append((row, icon))
        return box

    def set_steps(self, active, failed=False, skipped=()):
        """Sidebar: steps before `active` are done, `active` is running (or failed)."""
        for i, (row, icon) in enumerate(self.step_rows):
            state = ("skipped" if i in skipped else "done" if i < active
                     else "active" if i == active else "pending")
            row.set_css_classes([f"step-{state}"])
            icon.set_from_icon_name({
                "done": "object-select-symbolic",
                "skipped": "list-remove-symbolic",
                "active": "dialog-error-symbolic" if failed else "media-playback-start-symbolic",
                "pending": "radio-symbolic",
            }[state])

    def page(self, title, subtitle, *children):
        """A centred, scrolling column with a heading."""
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=18,
                      margin_top=32, margin_bottom=32, margin_start=12, margin_end=12)
        box.append(Gtk.Label(label=title, xalign=0, css_classes=["title-1"]))
        if subtitle:
            box.append(Gtk.Label(label=subtitle, xalign=0, wrap=True, css_classes=["dim-label"]))
        for child in children:
            box.append(child)
        return Gtk.ScrolledWindow(child=Adw.Clamp(child=box, maximum_size=760), hscrollbar_policy=Gtk.PolicyType.NEVER)

    def show(self, name, widget=None):
        if widget is not None:
            self.stack.remove(self.stack.get_child_by_name(name))
            self.stack.add_named(widget, name)
        self.stack.set_visible_child_name(name)

    # --- 1. network ---
    def page_network(self):
        self.next_button = Gtk.Button(label="Continue", halign=Gtk.Align.END, sensitive=False,
                                      css_classes=["suggested-action", "pill"])
        self.next_button.connect("clicked", lambda *_: self.choose())
        network = Network(on_change=lambda up: self.next_button.set_sensitive(up))
        return self.page("Connect to the internet",
                         "The installer downloads the system, so it needs a connection. "
                         "Ethernet connects by itself.", network, self.next_button)

    def network_window(self):
        window = Adw.Window(title="Network", transient_for=self, modal=True, default_width=520, default_height=560)
        view = Adw.ToolbarView(content=Gtk.ScrolledWindow(
            child=Adw.Clamp(child=Network(), margin_top=18, margin_bottom=18, margin_start=12, margin_end=12)))
        view.add_top_bar(Adw.HeaderBar())
        window.set_content(view)
        window.present()

    # --- 2. choose ---
    def choose(self):
        self.set_steps(1)
        known = hosts()
        groups = []

        def group(title, description, rows):
            box = Adw.PreferencesGroup(title=title, description=description)
            for row in rows:
                box.add(row)
            return box

        # Resume: an installation already mounted, or a known disk to unlock
        mounted = mounted_host()
        present = {host: disk_of(byid) for host, byid in known.items()}
        if mounted is not None:
            rows = [self.action_row(f"Resume installing {host}", "Mounted at /mnt", "Resume",
                                    lambda _b, h=host: self.start(["--resume", h], h, resuming=True))
                    for host in ([mounted] if mounted else list(known))]
        else:
            rows = [self.action_row(f"Unlock and resume {host}",
                                    f"{disk['model']} ({disk['size']}): asks for its passphrase", "Unlock",
                                    lambda _b, h=host: self.start(["--mount", h], h, resuming=True))
                    for host, disk in present.items() if disk and disk["luks"]]
        if rows:
            groups.append(group("Continue an interrupted installation",
                                "Nothing is erased: the existing disk is reused.", rows))

        if mounted is None:
            # Automatic: a host whose disk (recorded in the repo) is in this machine
            rows = [self.action_row(f"Install {host}",
                                    f"Erases {disk['model']} ({disk['size']}, {disk['name']})", "Install",
                                    lambda _b, h=host, d=disk: self.countdown(h, d, known[h]), destructive=True)
                    for host, disk in present.items() if disk]
            if rows:
                groups.append(group("Automatic", "This machine's disk is recorded in the configuration.", rows))
            groups.append(self.manual_group(known))

        self.show("choose", self.page("Choose machine and disk", None, *groups))

    def action_row(self, title, subtitle, label, callback, destructive=False):
        row = Adw.ActionRow(title=title, subtitle=subtitle)
        button = Gtk.Button(label=label, valign=Gtk.Align.CENTER,
                            css_classes=["destructive-action" if destructive else "suggested-action"])
        button.connect("clicked", callback)
        row.add_suffix(button)
        return row

    def manual_group(self, known):
        group = Adw.PreferencesGroup(title="Manual", description="Pick the machine and the disk to erase.")
        host_names = list(known)
        host_row = Adw.ComboRow(title="Machine", model=Gtk.StringList.new(host_names))
        vault_row = Adw.ComboRow(title="Passwords", model=Gtk.StringList.new([label for _id, label in VAULT_LOGINS]))
        group.add(host_row)
        all_disks = disks()
        checks = []
        first = None
        for disk in all_disks:
            row = Adw.ActionRow(title=f"{disk['model']}  ({disk['size']}, {disk['name']})",
                                subtitle="\n".join(disk["parts"]) or "empty")
            check = Gtk.CheckButton(group=first, valign=Gtk.Align.CENTER)
            first = first or check
            row.add_prefix(check)
            row.set_activatable_widget(check)
            group.add(row)
            checks.append((check, disk))
        if not all_disks:
            group.add(Adw.ActionRow(title="No disk found", subtitle="The USB stick this runs from is hidden."))
        group.add(vault_row)
        confirm = Adw.EntryRow(title="Type the disk's name to confirm erasing it")
        group.add(confirm)
        install = Gtk.Button(label="Erase the disk and install", halign=Gtk.Align.END, sensitive=False,
                             margin_top=12, css_classes=["destructive-action", "pill"])

        def selected():
            return next((d for c, d in checks if c.get_active()), None)

        def update(*_):
            disk = selected()
            if disk:
                confirm.set_title(f"Type “{disk['name']}” to confirm erasing it")
            install.set_sensitive(bool(disk) and bool(host_names) and confirm.get_text() == disk["name"])

        def go(*_):
            disk = selected()
            host = host_names[host_row.get_selected()]
            self.start([], host, disk=f"/dev/{disk['name']}", confirmed=disk["name"],
                       vault=VAULT_LOGINS[vault_row.get_selected()][0])

        for check, _disk in checks:
            check.connect("toggled", update)
        confirm.connect("changed", update)
        install.connect("clicked", go)
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        box.append(group)
        box.append(install)
        return box

    def countdown(self, host, disk, byid):
        """Automatic mode: one click, then ten seconds to change your mind."""
        left = [10]
        dialog = Adw.AlertDialog(heading=f"Installing {host}")
        dialog.add_response("cancel", "Cancel")
        dialog.add_response("now", "Start now")
        dialog.set_response_appearance("now", Adw.ResponseAppearance.DESTRUCTIVE)
        dialog.set_default_response("cancel")
        dialog.set_close_response("cancel")

        def text():
            dialog.set_body(f"Everything on {disk['model']} ({disk['size']}, {disk['name']}) will be erased "
                            f"in {left[0]} seconds.")

        def go():
            self.start([], host, disk=byid, confirmed=disk["name"], vault="1")

        def tick():
            left[0] -= 1
            if left[0] < 0:
                return False  # answered meanwhile
            if left[0] == 0:
                left[0] = -1
                dialog.force_close()
                go()
                return False
            text()
            return True

        def response(_dialog, answer):
            started = left[0] == -1
            left[0] = -1
            if answer == "now" and not started:
                go()

        text()
        dialog.connect("response", response)
        GLib.timeout_add_seconds(1, tick)
        dialog.present(self)

    # --- 3. progress: the engine ---
    def page_progress(self):
        self.progress_title = Gtk.Label(xalign=0, css_classes=["title-1"], wrap=True)
        self.progress_bar = Gtk.ProgressBar()
        self.log_buffer = Gtk.TextBuffer()
        self.log_view = Gtk.TextView(buffer=self.log_buffer, editable=False, cursor_visible=False, monospace=True,
                                     wrap_mode=Gtk.WrapMode.WORD_CHAR, css_classes=["log"],
                                     top_margin=8, bottom_margin=8, left_margin=8, right_margin=8)
        self.log_scroll = Gtk.ScrolledWindow(child=self.log_view, vexpand=True, css_classes=["card"])
        # The engine's question, shown above the log while it waits
        self.ask_label = Gtk.Label(xalign=0, wrap=True, css_classes=["heading"])
        self.ask_fields = Gtk.Box(spacing=8)
        ask = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8, css_classes=["card"])
        for widget in (self.ask_label, self.ask_fields):
            widget.set_margin_start(14)
            widget.set_margin_end(14)
            ask.append(widget)
        self.ask_label.set_margin_top(12)
        self.ask_fields.set_margin_bottom(12)
        self.ask_revealer = Gtk.Revealer(child=ask)
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=14,
                      margin_top=28, margin_bottom=20, margin_start=28, margin_end=28)
        for widget in (self.progress_title, self.progress_bar, self.ask_revealer, self.log_scroll):
            box.append(widget)
        return box

    def start(self, args, host, disk=None, confirmed=None, vault=None, resuming=False):
        self.host = host
        self.last_error = ""
        self.current_step = 0
        self.seen, self.skipped = set(), set()
        env = {
            "INSTALL_UI": "1",
            "INSTALL_UI_USER": os.environ.get("USER", "nixos"),
            "INSTALL_WAYLAND_DISPLAY": os.environ.get("WAYLAND_DISPLAY", ""),
        }
        if not resuming:
            env.update(INSTALL_HOST=host, INSTALL_DISK=disk, INSTALL_CONFIRMED=confirmed)
        if vault:
            env["INSTALL_VAULT_LOGIN"] = vault
        fake = os.environ.get("INSTALLER_FAKE_ENGINE")
        cmd = ([fake] if fake else ["sudo", "-n", "env"] + [f"{k}={v}" for k, v in env.items()] + ["install-nixos"])
        self.log(f"\n=== {' '.join(['install-nixos'] + args)} ===\n")
        self.progress_title.set_text("Starting…")
        self.show("progress")
        try:
            self.engine = Gio.Subprocess.new(
                cmd + args,
                Gio.SubprocessFlags.STDIN_PIPE | Gio.SubprocessFlags.STDOUT_PIPE | Gio.SubprocessFlags.STDERR_MERGE)
        except GLib.Error as e:
            return self.finished(False, str(e))
        self.stdin = self.engine.get_stdin_pipe()
        self.output = self.engine.get_stdout_pipe()
        self.partial = b""
        self.output.read_bytes_async(8192, GLib.PRIORITY_DEFAULT, None, self.on_output)
        self.pulse = GLib.timeout_add(150, lambda: self.progress_bar.pulse() or True)

    def on_output(self, stream, result):
        try:
            data = stream.read_bytes_finish(result).get_data()
        except GLib.Error:
            data = b""
        if not data:  # end of output: the engine is done
            if self.partial:
                self.on_line(self.partial)
            self.engine.wait_async(None, lambda p, r: self.finished(p.wait_finish(r) and p.get_successful()))
            return
        *lines, self.partial = (self.partial + data).replace(b"\r", b"\n").split(b"\n")
        for line in lines:
            self.on_line(line)
        stream.read_bytes_async(8192, GLib.PRIORITY_DEFAULT, None, self.on_output)

    def on_line(self, raw):
        line = ANSI.sub("", raw.decode("utf-8", "replace"))
        if line.startswith("@@STEP "):
            _tag, number, title = line.split(" ", 2)
            self.step(int(number), title)
        elif line.startswith("@@ASK "):
            _tag, kind, prompt = line.split(" ", 2)
            self.ask(kind, prompt)
        else:
            if line.startswith("Error:"):
                self.last_error = line
            self.log(line + "\n")

    def step(self, number, title):
        self.seen.add(number)
        self.current_step = number
        # sidebar rows of engine steps that a resume jumped over
        self.skipped = {n + 1 for n in range(1, number) if n not in self.seen}
        self.progress_title.set_text(title)
        self.set_steps(number + 1, skipped=self.skipped)
        self.log(f"\n--- {number}/7 {title} ---\n")

    def log(self, text):
        self.log_file.write(text)
        self.log_buffer.insert(self.log_buffer.get_end_iter(), text)
        adjustment = self.log_scroll.get_vadjustment()
        GLib.idle_add(lambda: adjustment.set_value(adjustment.get_upper()) and False)

    def ask(self, kind, prompt):
        """Show the engine's question; the answer goes to its stdin as one line."""
        child = self.ask_fields.get_first_child()
        while child:
            self.ask_fields.remove(child)
            child = self.ask_fields.get_first_child()
        self.ask_label.set_text(prompt)
        self.ask_label.remove_css_class("danger-text")

        def send(text):
            self.ask_revealer.set_reveal_child(False)
            self.log(f"{prompt}: {'(hidden)' if kind != 'text' and kind != 'yesno' else text}\n")
            self.stdin.write_all((text + "\n").encode(), None)
            self.stdin.flush(None)

        if kind == "yesno":
            for label, answer in (("Yes", "y"), ("No", "n")):
                button = Gtk.Button(label=label, css_classes=["suggested-action"] if answer == "y" else [])
                button.connect("clicked", lambda _b, a=answer: send(a))
                self.ask_fields.append(button)
        else:
            make = Gtk.Entry if kind == "text" else lambda **kw: Gtk.PasswordEntry(show_peek_icon=True, **kw)
            entries = [make(hexpand=True)] + ([make(hexpand=True)] if kind == "newsecret" else [])
            if kind == "newsecret":
                entries[1].set_property("placeholder-text", "Again")
            ok = Gtk.Button(label="OK", css_classes=["suggested-action"])

            def submit(source=None, *_):
                texts = [e.get_text() for e in entries]
                if source is entries[0] and len(entries) == 2 and not texts[1]:
                    return entries[1].grab_focus()  # Enter in the first field: on to "Again"
                if not texts[0] or len(set(texts)) != 1:
                    self.ask_label.set_text(f"{prompt}  (empty or not matching, try again)")
                    self.ask_label.add_css_class("danger-text")
                    return
                send(texts[0])

            for entry in entries:
                entry.connect("activate", submit)
                self.ask_fields.append(entry)
            ok.connect("clicked", submit)
            self.ask_fields.append(ok)
            GLib.idle_add(lambda: entries[0].grab_focus() and False)
        self.ask_revealer.set_reveal_child(True)
        self.present()

    def finished(self, ok, error=None):
        if self.pulse:
            GLib.source_remove(self.pulse)
            self.pulse = None
        self.ask_revealer.set_reveal_child(False)
        self.engine = None
        if ok:
            self.set_steps(len(self.step_rows), skipped=self.skipped)
            restart = Gtk.Button(label="Restart", halign=Gtk.Align.CENTER, css_classes=["suggested-action", "pill"])
            restart.connect("clicked", lambda *_: spawn("systemctl", "reboot"))
            page = Adw.StatusPage(
                icon_name="object-select-symbolic", title=f"{self.host} is installed",
                description="Remove the USB stick and restart. After logging in, sign in to Bitwarden, enable "
                            "its SSH agent, then commit and push the new files in /etc/nixos.",
                child=restart)
        else:
            self.set_steps(self.current_step + 1, failed=True, skipped=self.skipped)
            buttons = Gtk.Box(spacing=12, halign=Gtk.Align.CENTER)
            claude = Gtk.Button(label="Troubleshoot with Claude", css_classes=["suggested-action", "pill"])
            claude.connect("clicked", lambda *_: self.ask_claude(failed=True))
            buttons.append(claude)
            if mounted_host() is not None:
                resume = Gtk.Button(label="Resume", css_classes=["pill"], tooltip_text="Continue without erasing")
                resume.connect("clicked", lambda *_: self.start(["--resume", self.host], self.host, resuming=True))
                buttons.append(resume)
            for label, action in (("Show the log", lambda *_: self.show("progress")),
                                  ("Start over", lambda *_: self.choose())):
                button = Gtk.Button(label=label, css_classes=["pill"])
                button.connect("clicked", action)
                buttons.append(button)
            where = ENGINE_STEPS[self.current_step - 1] if self.current_step else "Starting"
            page = Adw.StatusPage(
                icon_name="dialog-error-symbolic", title=f"Stopped at: {where}",
                description=GLib.markup_escape_text(error or self.last_error or "See the log for what went wrong."),
                child=buttons)
        self.show("end", page)

    # --- helpers around the installation ---
    def ask_claude(self, failed=False):
        prompt = ("The installation of '%s' stopped at step %d (%s). %s Read %s and help me fix it." % (
            self.host, self.current_step, ENGINE_STEPS[self.current_step - 1] if self.current_step else "start",
            self.last_error, LOG)) if failed else ""
        spawn("foot", "--title", "Claude", "installer-claude", *([prompt] if prompt else []))

    def refresh_extras(self):
        """Header hint while Widevine and Claude Code are still downloading."""
        ready = all(os.path.exists(f"{EXTRAS}/{name}") for name in ("chromium", "claude"))
        self.music.set_sensitive(os.path.exists(f"{EXTRAS}/chromium"))
        self.music.set_tooltip_text("Spotify" if self.music.get_sensitive()
                                    else "Spotify: available once Widevine is downloaded")
        self.extras_label.set_text("" if ready else "Downloading Widevine and Claude…" if online()
                                   else "Widevine and Claude need internet")
        return not ready


class App(Adw.Application):
    def __init__(self):
        super().__init__(application_id="br.dev.zoe.Installer")
        for name, command in (("reboot", "reboot"), ("poweroff", "poweroff")):
            action = Gio.SimpleAction.new(name, None)
            action.connect("activate", lambda *_a, c=command: spawn("systemctl", c))
            self.add_action(action)

    def do_activate(self):
        Adw.StyleManager.get_default().set_color_scheme(Adw.ColorScheme.FORCE_DARK)
        css = Gtk.CssProvider()
        css.load_from_string(CSS.replace("ACCENT_LIGHT", os.environ.get("INSTALLER_ACCENT_LIGHT", "#5fdcc3"))
                             .replace("ACCENT", os.environ.get("INSTALLER_ACCENT", "#1abc9c")))
        window = self.props.active_window or Installer(self)
        Gtk.StyleContext.add_provider_for_display(window.get_display(), css, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)
        window.present()
        if online():
            window.choose()
            window.stack.set_visible_child_name("choose")
        if os.environ.get("INSTALLER_TEST") == "start":  # straight to the (fake) engine
            window.start([], "demo", disk="/dev/null", confirmed="null", vault="3")


if __name__ == "__main__":
    sys.exit(App().run(sys.argv))
