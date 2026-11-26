#!/usr/bin/env python3
"""KDE Plasma 6 Wayland system tray bridge for Mozilla Thunderbird.

Provides:
- Native KDE StatusNotifierItem tray icon (via Qt6 QSystemTrayIcon)
- Autostart minimized to tray on login (--start-minimized)
- Left-click tray icon to open/raise/toggle Thunderbird on Wayland via KWin scripting
- Automatic taskbar hiding whenever Thunderbird is minimized (paired with Minimize on Close)
"""

import fcntl
import os
import signal
import subprocess
import sys
import time

from PyQt6.QtCore import QTimer
from PyQt6.QtGui import QAction, QIcon
from PyQt6.QtWidgets import QApplication, QMenu, QSystemTrayIcon

THUNDERBIRD_BIN = "/run/current-system/sw/bin/thunderbird"
THUNDERBIRD_ICON = "/run/current-system/sw/share/icons/hicolor/128x128/apps/thunderbird.png"

WATCHER_PLUGIN = "thunderbird-tray-watcher"
STARTUP_PLUGIN = "thunderbird-tray-startup"
TOGGLE_PLUGIN = "thunderbird-tray-toggle"

WATCHER_JS = r"""
function isThunderbirdMain(w) {
  return w && w.resourceClass === "thunderbird" && w.normalWindow;
}
function syncTaskbar(w) {
  if (!isThunderbirdMain(w)) return;
  w.skipTaskbar = w.minimized;
  w.skipPager = w.minimized;
  w.skipSwitcher = w.minimized;
}
function attach(w) {
  if (!isThunderbirdMain(w)) return;
  if (w.__tbTrayAttached) {
    syncTaskbar(w);
    return;
  }
  w.__tbTrayAttached = true;
  w.minimizedChanged.connect(() => syncTaskbar(w));
  syncTaskbar(w);
}
for (const w of workspace.windowList()) {
  attach(w);
}
workspace.windowAdded.connect(attach);
"""

STARTUP_JS = r"""
let handled = false;
let guardUntil = 0;
function isThunderbirdMain(w) {
  return w && w.resourceClass === "thunderbird" && w.normalWindow;
}
function hideWin(w) {
  w.minimized = true;
  w.skipTaskbar = true;
  w.skipPager = true;
  w.skipSwitcher = true;
}
function onWin(w) {
  if (handled || !isThunderbirdMain(w)) return;
  handled = true;
  guardUntil = Date.now() + 2500;
  hideWin(w);
  w.activeChanged.connect(() => {
    if (Date.now() < guardUntil && w.active) {
      hideWin(w);
    }
  });
  w.minimizedChanged.connect(() => {
    if (Date.now() < guardUntil && !w.minimized) {
      hideWin(w);
    }
  });
}
for (const w of workspace.windowList()) {
  onWin(w);
}
workspace.windowAdded.connect(onWin);
"""

TOGGLE_JS = r"""
const wins = workspace.windowList().filter(
  (w) => w && w.resourceClass === "thunderbird" && w.normalWindow
);
if (wins.length > 0) {
  const anyHiddenOrInactive = wins.some((w) => w.minimized || !w.active);
  if (anyHiddenOrInactive) {
    for (const w of wins) {
      w.skipTaskbar = false;
      w.skipPager = false;
      w.skipSwitcher = false;
      w.minimized = false;
      if (workspace.currentDesktop) {
        w.desktops = [workspace.currentDesktop];
      }
      workspace.activeWindow = w;
    }
  } else {
    for (const w of wins) {
      w.minimized = true;
      w.skipTaskbar = true;
      w.skipPager = true;
      w.skipSwitcher = true;
    }
  }
}
"""


def runtime_dir() -> str:
    return os.environ.get("XDG_RUNTIME_DIR") or f"/tmp/thunderbird-tray-{os.getuid()}"


def wait_for_dbus_service(service: str, timeout: float = 30.0) -> bool:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        res = subprocess.run(
            ["busctl", "--user", "status", service],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
        )
        if res.returncode == 0:
            return True
        time.sleep(0.3)
    return False


def kwin_unload(plugin_name: str) -> None:
    subprocess.run(
        [
            "busctl",
            "--user",
            "call",
            "org.kde.KWin",
            "/Scripting",
            "org.kde.kwin.Scripting",
            "unloadScript",
            "s",
            plugin_name,
        ],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )


def kwin_is_loaded(plugin_name: str) -> bool:
    res = subprocess.run(
        [
            "busctl",
            "--user",
            "call",
            "org.kde.KWin",
            "/Scripting",
            "org.kde.kwin.Scripting",
            "isScriptLoaded",
            "s",
            plugin_name,
        ],
        capture_output=True,
        text=True,
        check=False,
    )
    return res.returncode == 0 and "true" in res.stdout.lower()


def kwin_run_script(plugin_name: str, js_code: str, persistent: bool = False) -> None:
    rdir = runtime_dir()
    os.makedirs(rdir, mode=0o700, exist_ok=True)
    script_path = os.path.join(rdir, f"{plugin_name}.js")
    with open(script_path, "w", encoding="utf-8") as fh:
        fh.write(js_code)

    kwin_unload(plugin_name)
    res = subprocess.run(
        [
            "busctl",
            "--user",
            "call",
            "org.kde.KWin",
            "/Scripting",
            "org.kde.kwin.Scripting",
            "loadScript",
            "ss",
            script_path,
            plugin_name,
        ],
        capture_output=True,
        text=True,
        check=False,
    )
    if res.returncode != 0:
        return

    parts = res.stdout.strip().split()
    if len(parts) < 2:
        return
    try:
        script_id = int(parts[1])
    except ValueError:
        return
    if script_id < 0:
        return

    subprocess.run(
        [
            "busctl",
            "--user",
            "call",
            "org.kde.KWin",
            f"/Scripting/Script{script_id}",
            "org.kde.kwin.Script",
            "run",
        ],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )

    if not persistent:
        kwin_unload(plugin_name)


def thunderbird_running() -> bool:
    res = subprocess.run(
        ["pgrep", "-u", str(os.getuid()), "-f", "thunderbird-wrapped_"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    return res.returncode == 0


def launch_thunderbird() -> None:
    subprocess.Popen(
        [THUNDERBIRD_BIN, "--name", "thunderbird"],
        start_new_session=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )


def ensure_watcher() -> None:
    if not kwin_is_loaded(WATCHER_PLUGIN):
        kwin_run_script(WATCHER_PLUGIN, WATCHER_JS, persistent=True)


def main() -> int:
    start_minimized = "--start-minimized" in sys.argv[1:]

    rdir = runtime_dir()
    os.makedirs(rdir, mode=0o700, exist_ok=True)
    lock_path = os.path.join(rdir, "thunderbird-tray.lock")
    lock_fd = open(lock_path, "w", encoding="utf-8")
    try:
        fcntl.flock(lock_fd.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        # Already running; toggle if invoked manually without --start-minimized
        if not start_minimized:
            kwin_unload(STARTUP_PLUGIN)
            ensure_watcher()
            if thunderbird_running():
                kwin_run_script(TOGGLE_PLUGIN, TOGGLE_JS, persistent=False)
            else:
                launch_thunderbird()
        return 0

    wait_for_dbus_service("org.kde.StatusNotifierWatcher")
    wait_for_dbus_service("org.kde.KWin")

    app = QApplication(sys.argv)
    app.setApplicationName("Thunderbird")
    app.setDesktopFileName("thunderbird")
    app.setQuitOnLastWindowClosed(False)

    icon = QIcon.fromTheme("thunderbird", QIcon(THUNDERBIRD_ICON))
    tray = QSystemTrayIcon(icon)
    tray.setToolTip("Thunderbird")

    def toggle_window() -> None:
        kwin_unload(STARTUP_PLUGIN)
        ensure_watcher()
        if not thunderbird_running():
            launch_thunderbird()
            return
        kwin_run_script(TOGGLE_PLUGIN, TOGGLE_JS, persistent=False)

    def quit_all() -> None:
        subprocess.run(
            ["pkill", "-TERM", "-u", str(os.getuid()), "-f", "thunderbird-wrapped_"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
        )
        kwin_unload(STARTUP_PLUGIN)
        kwin_unload(WATCHER_PLUGIN)
        tray.hide()
        app.quit()

    menu = QMenu()
    toggle_action = QAction("Show / Hide Thunderbird", menu)
    toggle_action.triggered.connect(toggle_window)
    menu.addAction(toggle_action)
    menu.addSeparator()
    quit_action = QAction("Quit Thunderbird", menu)
    quit_action.triggered.connect(quit_all)
    menu.addAction(quit_action)

    tray.setContextMenu(menu)

    def on_activated(reason: QSystemTrayIcon.ActivationReason) -> None:
        if reason in (
            QSystemTrayIcon.ActivationReason.Trigger,
            QSystemTrayIcon.ActivationReason.DoubleClick,
        ):
            toggle_window()

    tray.activated.connect(on_activated)
    tray.show()

    def cleanup_and_exit(_signum=None, _frame=None) -> None:
        kwin_unload(STARTUP_PLUGIN)
        kwin_unload(WATCHER_PLUGIN)
        tray.hide()
        app.quit()

    signal.signal(signal.SIGTERM, cleanup_and_exit)
    signal.signal(signal.SIGINT, cleanup_and_exit)

    # Periodic no-op timer so Python processes POSIX signals promptly
    sig_timer = QTimer()
    sig_timer.start(500)
    sig_timer.timeout.connect(lambda: None)

    ensure_watcher()
    if start_minimized:
        kwin_run_script(STARTUP_PLUGIN, STARTUP_JS, persistent=True)
        if not thunderbird_running():
            launch_thunderbird()
        QTimer.singleShot(8000, lambda: kwin_unload(STARTUP_PLUGIN))
    elif not thunderbird_running():
        launch_thunderbird()

    return app.exec()


if __name__ == "__main__":
    raise SystemExit(main())
