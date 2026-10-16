#!/usr/bin/python3
"""The SwiftVM guest agent for Linux.

Talks to the SwiftVM app on the Mac over the virtual machine's socket device (virtio-vsock), which
needs no network. A machine that has none, on QEMU, has a serial line for the agent instead, which
carries the same connections in frames (SerialLine below). It tells the app which system this is, which addresses it holds and how the setup
script it was created with is doing, and on the app's request sets the clock, mounts the folders
shared with the machine, or shuts the system down.

The agent listens; the app connects. Each side sends one JSON object per line and ignores what it
doesn't know, so that an agent and an app of different ages get along. The protocol is described
in Sources/GuestChannel of the SwiftVM sources.

On a second port it takes jobs, each on a connection of its own, for whoever drives this machine
from the Mac's command line: run a command, show what is on the screen, use the mouse and the
keyboard, or say what is on the screen as a tree of its parts.

Runs as root, from swiftvm-agent.service, and needs nothing but Python 3's standard library. Only
the tree of what is on the screen takes more: the system's own accessibility, where a desktop
brings it.
"""

import array
import fcntl
import glob
import json
import mmap
import os
import pwd
import re
import select
import selectors
import shlex
import signal
import socket
import struct
import subprocess
import sys
import threading
import time
import zlib

AGENT_VERSION = "1.2"
PROTOCOL_VERSION = 1
# Below 1024, where only root may listen: the app has to know who answers.
PORT = 717
# Where jobs are taken, each on a connection of its own.
JOB_PORT = 718
# What this agent does beyond what every agent does, as it tells the app.
FEATURES = ["exec", "screen", "input", "accessibility", "display-size"]
MAX_LINE = 256 * 1024
MAX_INTERFACES = 64
# A clock that is this close to the Mac's is left to the system's time service.
CLOCK_TOLERANCE_NS = 20 * 1000 * 1000
# An app that doesn't take a message in this time has stopped listening.
SEND_TIMEOUT = 5.0
# The kernel says when addresses change. This is how long things get to settle before a look,
# and how often to look anyway.
SETTLE_TIME = 0.3
POLL_INTERVAL = 30.0
POLL_INTERVAL_WITHOUT_NOTICE = 5.0
# Where the app may have the shared folders mounted.
MOUNT_ROOTS = ("/mnt/", "/media/")
# The serial line of a machine on QEMU, which has no socket device. Its name is the app's.
SERIAL_LINE = "/dev/virtio-ports/org.swiftvm.agent"
# The SSH server, which the app reaches without a network: over the socket device by itself, over
# the serial line through the agent.
SSH_PORT = 22
# How the kernel calls a virtio socket device, in /sys/bus/virtio/devices/*/device.
VIRTIO_SOCKET_DEVICE = "0x0013"
# Where the setup script that SwiftVM put into a new machine leaves word of how it is doing: its
# state and name in "status", one "key=value" to a line, and the step it is at in "step".
SETUP_DIRECTORY = "/var/lib/swiftvm/setup"
SETUP_STATES = ("pending", "running", "finished", "failed")
# A script that is at work is looked at this often, one that has come to its end this often, and
# a system that has no script this often.
SETUP_POLL_INTERVAL = 1.0
SETUP_POLL_INTERVAL_AT_REST = 15.0
SETUP_POLL_INTERVAL_WITHOUT_ONE = 60.0
# The longest a script's name or step is passed on at.
MAX_SETUP_TEXT = 120
# A job's first line has to arrive in this time.
JOB_REQUEST_TIMEOUT = 10.0
# What a job carries after its first two lines: frames of one byte for the kind, four for the
# length, and that many bytes.
FRAME_INPUT, FRAME_OUTPUT, FRAME_ERROR, FRAME_END = 0, 1, 2, 3
MAX_FRAME = 64 * 1024
MAX_ACCEPTED_FRAME = 1024 * 1024
# How long a command that was called off gets to end by itself before it is ended.
KILL_GRACE = 3.0
# How long the app gets to hang up once a job has ended, before the agent does.
HANG_UP_TIMEOUT = 5.0
# How long an output pipe may stay idle once the command has ended. Something it left running
# in the background can hold the pipe open for good; time spent sending to the app doesn't count.
OUTPUT_GRACE = 2.0
# Where a command looks for programs when the system doesn't say.
DEFAULT_PATH = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
# What a session's programs find its screen by, taken over for commands that run as its user.
SESSION_VARIABLES = (
    "DISPLAY", "WAYLAND_DISPLAY", "XAUTHORITY", "XDG_CURRENT_DESKTOP", "XDG_SESSION_TYPE",
    "XDG_SESSION_DESKTOP", "DESKTOP_SESSION",
)
# How long the desktop may take to say what is on the screen.
ACCESSIBILITY_TIMEOUT = 60
# The tree of what is on the screen is cut off after this many parts, this far down unless the
# app asks otherwise, and no part's text is passed on at more than this.
MAX_TREE_NODES = 3000
MAX_TREE_CHILDREN = 500
DEFAULT_TREE_DEPTH = 40
MAX_TREE_TEXT = 200

RTMGRP_LINK = 0x1
RTMGRP_IPV4_IFADDR = 0x10
RTMGRP_IPV6_IFADDR = 0x100


def log(message):
    print(message, flush=True)


class AgentError(Exception):
    """A request can't be carried out. Its text goes back to the app."""


def run(command, timeout=15):
    """Runs a command to its end. Fails with what it printed if it exits with an error."""
    try:
        result = subprocess.run(
            command, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=timeout
        )
    except subprocess.TimeoutExpired:
        raise AgentError("%s didn't finish in %d seconds." % (command[0], timeout))
    except OSError as error:
        raise AgentError("%s couldn't be run: %s" % (command[0], error.strerror or error))
    if result.returncode != 0:
        output = result.stdout.decode("utf-8", "replace").strip()
        raise AgentError(output or "%s failed with status %d." % (command[0], result.returncode))


def shown(text):
    """One short line of what a script says of itself, fit to be passed on and shown."""
    return "".join(character for character in text if character.isprintable()).strip()[:MAX_SETUP_TEXT]


def read_os_release():
    """The system's description of itself, as a dictionary."""
    for path in ("/etc/os-release", "/usr/lib/os-release"):
        try:
            with open(path, encoding="utf-8", errors="replace") as file:
                lines = file.read().splitlines()
        except OSError:
            continue
        values = {}
        for line in lines:
            key, separator, value = line.partition("=")
            if not separator or key.startswith("#"):
                continue
            try:
                words = shlex.split(value)
            except ValueError:
                continue
            values[key.strip()] = words[0] if words else ""
        return values
    return {}


def read_environment_files():
    """What the system gives everyone who logs in: where programs are, and which language."""
    values = {}
    for path in ("/etc/environment", "/etc/default/locale"):
        try:
            with open(path, encoding="utf-8", errors="replace") as file:
                lines = file.read(64 * 1024).splitlines()
        except OSError:
            continue
        for line in lines:
            key, separator, value = line.strip().partition("=")
            key = key.replace("export ", "", 1).strip()
            if not separator or not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", key):
                continue
            try:
                words = shlex.split(value)
            except ValueError:
                continue
            values[key] = words[0] if words else ""
    return values


class System:
    """What the agent knows about the system it runs in, and what it does to it."""

    setup_directory = SETUP_DIRECTORY

    def describe(self):
        release = read_os_release()
        uname = os.uname()
        name = release.get("NAME") or uname.sysname
        return {
            "id": release.get("ID", ""),
            "name": name,
            "version": release.get("VERSION_ID", ""),
            "prettyName": release.get("PRETTY_NAME") or name,
            "kernel": uname.release,
            "architecture": uname.machine,
        }

    def host_name(self):
        return socket.gethostname()

    def interfaces(self):
        """The network cards that hold an address, with their addresses."""
        try:
            output = subprocess.run(
                ["ip", "-json", "address", "show"],
                stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=5, check=True,
            ).stdout
            links = json.loads(output.decode("utf-8", "replace"))
        except (OSError, subprocess.SubprocessError, ValueError):
            return []
        interfaces = []
        for link in links if isinstance(links, list) else []:
            if not isinstance(link, dict) or link.get("link_type") != "ether" or not link.get("address"):
                continue
            # Addresses that only work on the link itself are of no use to the Mac.
            addresses = [
                entry["local"] for entry in link.get("addr_info", [])
                if isinstance(entry, dict) and entry.get("scope") == "global" and isinstance(entry.get("local"), str)
            ]
            if addresses:
                interfaces.append({"name": str(link.get("ifname", "")), "mac": link["address"], "addresses": addresses})
        return interfaces[:MAX_INTERFACES]

    def setup_status(self):
        """How this system's setup script is doing, or None for a system that has none."""
        values = {}
        try:
            with open(os.path.join(self.setup_directory, "status"), encoding="utf-8", errors="replace") as file:
                for line in file.read(4096).splitlines():
                    key, separator, value = line.partition("=")
                    if separator:
                        values[key] = value
        except OSError:
            return None
        if values.get("state") not in SETUP_STATES:
            return None
        status = {"state": values["state"]}
        name = shown(values.get("name", ""))
        if name:
            status["name"] = name
        try:
            with open(os.path.join(self.setup_directory, "step"), encoding="utf-8", errors="replace") as file:
                step = shown(file.readline(4096))
        except OSError:
            step = ""
        if step:
            status["step"] = step
        return status

    def set_clock(self, nanoseconds):
        difference = nanoseconds - time.time_ns()
        if abs(difference) <= CLOCK_TOLERANCE_NS:
            return
        time.clock_settime_ns(time.CLOCK_REALTIME, nanoseconds)
        log("The clock was %.3f s %s and has been set." % (abs(difference) / 1e9, "behind" if difference > 0 else "ahead"))

    def mount_shared_folders(self, tag, mount_point):
        if self.is_mounted(tag):
            return
        os.makedirs(mount_point, exist_ok=True)
        run(["mount", "-t", "virtiofs", "--", tag, mount_point])
        log("Mounted the shared folders at %s." % mount_point)

    def mount_folder_devices(self, folders, mount_point):
        """Mounts the folders that QEMU shares one device each, under their names at `mount_point`.
        The devices are those the machine started with: a folder shared since then has none yet."""
        present = folder_device_tags()
        for folder in folders:
            tag = folder["tag"]
            if tag not in present or self.is_mounted(tag, "9p"):
                continue
            place = os.path.join(mount_point, folder["name"])
            os.makedirs(place, exist_ok=True)
            options = "trans=virtio,version=9p2000.L,msize=524288,access=any"
            if folder["readOnly"]:
                options += ",ro"
            run(["mount", "-t", "9p", "-o", options, "--", tag, place])
            log("Mounted the shared folder %s at %s." % (tag, place))

    def is_mounted(self, tag, kind="virtiofs"):
        """Whether the shared folders are mounted, wherever. Mounting them twice only gets in the way."""
        try:
            with open("/proc/self/mounts", encoding="utf-8", errors="replace") as file:
                for line in file:
                    fields = line.split()
                    if len(fields) >= 3 and fields[0] == tag and fields[2] == kind:
                        return True
        except OSError:
            pass
        return False

    def shut_down(self):
        for command in (["systemctl", "poweroff", "--no-block"], ["shutdown", "-h", "now"], ["poweroff"]):
            try:
                run(command, timeout=10)
            except AgentError:
                continue
            log("Shutting down at the app's request.")
            return
        raise AgentError("This system has no command to shut down with.")

    # Accounts and sessions

    def account(self, name):
        """The account a command is to run as: the one named, or whoever is logged in at the screen."""
        if name is None:
            user = self.session_user()
            if user is None:
                raise AgentError("Nobody is logged in at this system's screen. Name the account to run the command as.")
            try:
                return pwd.getpwuid(user)
            except KeyError:
                raise AgentError("The user at this system's screen has no account.")
        if not isinstance(name, str) or not name:
            raise AgentError("That isn't the name of an account.")
        try:
            return pwd.getpwnam(name)
        except KeyError:
            raise AgentError("This system has no account named “%s”." % name[:64])

    def identity(self, account):
        """What makes a new process run as `account` rather than as root."""
        if account.pw_uid == 0:
            return {}
        groups = os.getgrouplist(account.pw_name, account.pw_gid)
        return {"user": account.pw_uid, "group": account.pw_gid, "extra_groups": groups}

    def session_user(self):
        """The user whose desktop is on the screen, by number, or None when nobody is logged in there."""
        try:
            listing = subprocess.run(
                ["loginctl", "list-sessions", "--no-legend"],
                stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=5, check=True,
            ).stdout.decode("utf-8", "replace")
        except (OSError, subprocess.SubprocessError):
            return None
        waiting = None
        for line in listing.splitlines():
            fields = line.split()
            if not fields:
                continue
            session = self.session_properties(fields[0])
            # The login screen has a session too, of a class of its own, and so has everyone who
            # came in over the network.
            if session.get("Class") != "user" or session.get("Type") not in ("wayland", "x11", "mir"):
                continue
            if session.get("Remote") == "yes" or not session.get("User", "").isdigit():
                continue
            if session.get("State") == "active":
                return int(session["User"])
            # Someone who switched to another user and left their desktop open.
            waiting = int(session["User"]) if waiting is None else waiting
        return waiting

    def session_properties(self, session):
        try:
            output = subprocess.run(
                ["loginctl", "show-session", session, "-p", "User", "-p", "Type", "-p", "Class", "-p", "State", "-p", "Remote"],
                stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=5, check=True,
            ).stdout.decode("utf-8", "replace")
        except (OSError, subprocess.SubprocessError):
            return {}
        return dict(line.split("=", 1) for line in output.splitlines() if "=" in line)

    def environment(self, account):
        """What a command that runs as `account` finds in its environment: what a login would give
        it, and where its user's desktop is, if that user has one."""
        environment = {"PATH": DEFAULT_PATH, "LANG": "C.UTF-8"}
        environment.update(read_environment_files())
        environment.update({
            "HOME": account.pw_dir, "USER": account.pw_name, "LOGNAME": account.pw_name,
            "SHELL": account.pw_shell or "/bin/sh",
        })
        environment.update(self.session_environment(account))
        return environment

    def session_environment(self, account):
        runtime = "/run/user/%d" % account.pw_uid
        if not os.path.isdir(runtime):
            return {}
        environment = {"XDG_RUNTIME_DIR": runtime}
        if os.path.exists(os.path.join(runtime, "bus")):
            environment["DBUS_SESSION_BUS_ADDRESS"] = "unix:path=%s/bus" % runtime
        # The user's own service manager knows where the desktop is, once one has started.
        try:
            output = subprocess.run(
                ["systemctl", "--user", "show-environment"],
                stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=5,
                env=dict(environment, PATH=DEFAULT_PATH), **self.identity(account),
            ).stdout.decode("utf-8", "replace")
        except (OSError, subprocess.SubprocessError):
            return environment
        for line in output.splitlines():
            key, separator, value = line.partition("=")
            # A value with anything unusual in it comes quoted for a shell, and none of these do.
            if separator and key in SESSION_VARIABLES and value and not value.startswith(("$", "'", '"')):
                environment[key] = value
        return environment

    def fit_display(self, width, height, scale):
        """Gives the desktop the size of the window it is shown in on the Mac, in pixels and at its
        scale. Most desktops take a new size from the display itself. Hyprland keeps the sizes it
        was given when it started, and is told: as the user whose desktop it is."""
        user = self.session_user()
        if user is None:
            return
        sockets = glob.glob("/run/user/%d/hypr/*/.socket.sock" % user)
        if not sockets:
            return
        account = pwd.getpwuid(user)
        # The newest, should an older session have left its folder behind.
        signature = os.path.basename(os.path.dirname(max(sockets, key=os.path.getmtime)))
        environment = dict(self.environment(account), HYPRLAND_INSTANCE_SIGNATURE=signature)
        mode = "%dx%d@60" % (width, height)
        scale = ("%.2f" % scale).rstrip("0").rstrip(".")
        # Its configuration in Lua, from 0.56 on, and before that in its own language.
        for command in (
            ["hyprctl", "eval", 'hl.monitor({ output = "", mode = "%s", position = "auto", scale = %s })' % (mode, scale)],
            ["hyprctl", "keyword", "monitor", ",%s,auto,%s" % (mode, scale)],
        ):
            try:
                answer = subprocess.run(
                    command, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                    timeout=5, env=environment, **self.identity(account),
                ).stdout.decode("utf-8", "replace").strip()
            except (OSError, subprocess.SubprocessError):
                return
            if answer in ("", "ok"):
                return

    # The screen, the mouse and the keyboard

    def screenshot(self):
        """What is on the screen right now, as a PNG."""
        return png(*take_picture())

    def pointer(self, request):
        INPUT.pointer(request)

    def keys(self, request):
        INPUT.keys(request)

    def accessibility(self, request):
        """Has the desktop of whoever is logged in at the screen say what is on it, or do something
        to one part of it. Returns what there is to say about that, in JSON.

        The desktop only talks to its own user, so the asking is done by this same program, run as
        that user (accessibility_main).
        """
        user = self.session_user()
        if user is None:
            raise AgentError("Nobody is logged in at this system's screen, so there is nothing on it to read.")
        try:
            account = pwd.getpwuid(user)
        except KeyError:
            raise AgentError("The user at this system's screen has no account.")
        # The job goes in on the helper's input. Among its arguments, the text for a text field
        # would be there for every user of this system to read while it runs.
        command = [sys.executable, "-I", os.path.abspath(__file__), "--accessibility"]
        try:
            result = subprocess.run(
                command, input=json.dumps(request, ensure_ascii=False).encode("utf-8"), stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                timeout=ACCESSIBILITY_TIMEOUT, cwd="/", env=self.environment(account), **self.identity(account),
            )
        except subprocess.TimeoutExpired:
            raise AgentError("The desktop didn't say what is on the screen in %d seconds." % ACCESSIBILITY_TIMEOUT)
        except OSError as error:
            raise AgentError("The desktop couldn't be asked: %s" % (error.strerror or error))
        if result.returncode != 0:
            said = result.stderr.decode("utf-8", "replace").strip().splitlines()
            raise AgentError(said[-1][:500] if said else "The desktop couldn't be asked what is on the screen.")
        return result.stdout


class PretendSystem(System):
    """Says what it would do instead of doing it, for trying the protocol without a virtual machine."""

    def __init__(self, setup_directory=None):
        # This computer's own setup, if it has one, is none of a pretended system's business.
        self.setup_directory = setup_directory or os.devnull

    def set_clock(self, nanoseconds):
        log("Would set the clock to %d." % nanoseconds)

    def mount_shared_folders(self, tag, mount_point):
        log("Would mount %s at %s." % (tag, mount_point))

    def fit_display(self, width, height, scale):
        log("Would make the display %dx%d at %s." % (width, height, scale))

    def mount_folder_devices(self, folders, mount_point):
        for folder in folders:
            log("Would mount %s at %s." % (folder["tag"], os.path.join(mount_point, folder["name"])))

    def shut_down(self):
        log("Would shut down.")

    def identity(self, account):
        # Whoever pretends isn't root, and commands run as they are.
        return {}

    def session_user(self):
        return os.getuid()

    def session_environment(self, account):
        return {}

    def screenshot(self):
        # Two pixels by two, black.
        return png(2, 2, 8, "XR24", bytes(16))

    def pointer(self, request):
        log("Would use the mouse: %s." % json.dumps(request, sort_keys=True))

    def keys(self, request):
        log("Would use the keyboard: %s." % json.dumps(request, sort_keys=True))

    def accessibility(self, request):
        return json.dumps({"applications": []}).encode("utf-8")


# The display
#
# What a display shows is in memory that the kernel's mode setting hands to root: whichever
# desktop put it there, at the login screen, and on a console without any desktop. Nothing has to
# be installed for it and nobody has to be asked.

def drm_request(direction, number, size):
    """The number the kernel's mode setting knows a request by."""
    return (direction << 30) | (size << 16) | (ord("d") << 8) | number


DRM_DROP_MASTER = drm_request(0, 0x1F, 0)
DRM_GETRESOURCES = drm_request(3, 0xA0, 64)
DRM_GETCRTC = drm_request(3, 0xA1, 104)
DRM_GETFB2 = drm_request(3, 0xCE, 104)
DRM_MAP_DUMB = drm_request(3, 0xB3, 16)
# Where red, green and blue are in a pixel's four bytes, by the four letters the kernel has for
# the layout.
PIXEL_LAYOUTS = {"XR24": (2, 1, 0), "AR24": (2, 1, 0), "XB24": (0, 1, 2), "AB24": (0, 1, 2)}


def framebuffer_shown(card):
    """Describes what the first display of an open graphics card shows, or None if none shows anything.

    Returns its width and height, the four letters of its pixel layout, the length of a row in
    bytes, where in its memory the pixels start, and the kernel's handle for that memory, which is
    let go of when the card is closed.
    """
    counts = bytearray(64)
    fcntl.ioctl(card, DRM_GETRESOURCES, counts)
    count = struct.unpack_from("=I", counts, 36)[0]
    if not count:
        return None
    displays = array.array("I", [0] * count)
    request = bytearray(64)
    struct.pack_into("=Q", request, 8, displays.buffer_info()[0])
    struct.pack_into("=I", request, 36, count)
    fcntl.ioctl(card, DRM_GETRESOURCES, request)
    for display in displays:
        state = bytearray(104)
        struct.pack_into("=I", state, 12, display)
        fcntl.ioctl(card, DRM_GETCRTC, state)
        framebuffer = struct.unpack_from("=I", state, 16)[0]
        if not framebuffer:
            continue
        described = bytearray(104)
        struct.pack_into("=I", described, 0, framebuffer)
        fcntl.ioctl(card, DRM_GETFB2, described)
        width, height, layout = struct.unpack_from("=3I", described, 4)
        handle = struct.unpack_from("=I", described, 20)[0]
        pitch = struct.unpack_from("=I", described, 36)[0]
        offset = struct.unpack_from("=I", described, 52)[0]
        return width, height, struct.pack("=I", layout).decode("ascii", "replace"), pitch, offset, handle
    return None


def look_at_display(reading):
    """Opens the graphics cards one after the other and returns what `reading` makes of the first
    that shows something. `reading` gets the open card and what framebuffer_shown says of it."""
    problem = "This system has no display."
    for path in sorted(glob.glob("/dev/dri/card*")):
        try:
            card = os.open(path, os.O_RDWR | os.O_CLOEXEC)
        except OSError as error:
            problem = "The display can't be read: %s" % (error.strerror or error)
            continue
        try:
            # Whoever opens a card that nobody is in charge of is put in charge of it. That is for
            # the desktop that is about to start, not for someone who only looks.
            try:
                fcntl.ioctl(card, DRM_DROP_MASTER)
            except OSError:
                pass
            shown = framebuffer_shown(card)
            if shown is None:
                problem = (
                    "This system's display is turned off, as a desktop does after a while without input. "
                    "A key or the mouse wakes it: swiftvm ui <machine> key shift"
                )
                continue
            return reading(card, *shown)
        except OSError as error:
            problem = "The display can't be read: %s" % (error.strerror or error)
        finally:
            os.close(card)
    raise AgentError(problem)


# The size of the screen when it was last seen showing something.
LAST_SCREEN_SIZE = None


def screen_size():
    """How many pixels the screen is wide and high.

    A display that is turned off shows nothing to measure, and the mouse is what wakes it. Its
    size is then what it was when it last showed something, or what the display says it likes best.
    """
    global LAST_SCREEN_SIZE
    try:
        LAST_SCREEN_SIZE = look_at_display(lambda card, width, height, *rest: (width, height))
    except AgentError:
        if LAST_SCREEN_SIZE is None:
            LAST_SCREEN_SIZE = preferred_screen_size()
        if LAST_SCREEN_SIZE is None:
            raise
    return LAST_SCREEN_SIZE


def preferred_screen_size():
    """The first size the first connected display offers, which is the one it likes best, or None."""
    for connector in sorted(glob.glob("/sys/class/drm/card*-*")):
        try:
            with open(os.path.join(connector, "status"), encoding="ascii", errors="replace") as file:
                if file.read().strip() != "connected":
                    continue
            with open(os.path.join(connector, "modes"), encoding="ascii", errors="replace") as file:
                size = re.fullmatch(r"(\d+)x(\d+)\w*", file.readline().strip())
        except OSError:
            continue
        if size:
            return int(size.group(1)), int(size.group(2))
    return None


def take_picture():
    """What is on the screen right now: its width, height, the length of a row in bytes, the
    layout of its pixels, and the pixels themselves, four bytes each."""
    def read_pixels(card, width, height, layout, pitch, offset, handle):
        global LAST_SCREEN_SIZE
        LAST_SCREEN_SIZE = (width, height)
        if layout not in PIXEL_LAYOUTS:
            raise AgentError("The display's pixels are laid out as “%s”, which this agent can't read." % layout)
        if not handle or width * 4 > pitch:
            raise AgentError("The display's memory can't be read.")
        mapping = bytearray(16)
        struct.pack_into("=I", mapping, 0, handle)
        fcntl.ioctl(card, DRM_MAP_DUMB, mapping)
        where = struct.unpack_from("=Q", mapping, 8)[0]
        length = offset + pitch * height
        with mmap.mmap(card, length, mmap.MAP_SHARED, mmap.PROT_READ, offset=where) as memory:
            return width, height, pitch, layout, memory[offset:length]
    return look_at_display(read_pixels)


def png(width, height, pitch, layout, pixels):
    """A picture as a PNG file, in red, green and blue."""
    red, green, blue = PIXEL_LAYOUTS[layout]
    rows = bytearray()
    # Every row starts with a byte that says its bytes are as they are.
    row = bytearray(1 + width * 3)
    for y in range(height):
        line = pixels[y * pitch:y * pitch + width * 4]
        row[1::3] = line[red::4]
        row[2::3] = line[green::4]
        row[3::3] = line[blue::4]
        rows += row

    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))

    return (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(bytes(rows), 6))
        + chunk(b"IEND", b"")
    )


# The mouse and the keyboard
#
# The kernel lets root make input devices of its own (uinput). What the agent does with them
# reaches the system the way a real keyboard and mouse would: every desktop takes it, and so do
# the login screen and the console.

EV_SYN, EV_KEY, EV_REL, EV_ABS = 0, 1, 2, 3
SYN_REPORT = 0
ABS_X, ABS_Y = 0, 1
REL_HWHEEL, REL_WHEEL = 6, 8
BUTTONS = {"left": 0x110, "right": 0x111, "middle": 0x112}
BUS_VIRTUAL = 0x06
# The pointer says where it is on this scale, whatever the size of the screen.
POINTER_RANGE = 32767
# Whoever reads input devices takes a moment to find a new one.
DEVICE_SETTLE_TIME = 1.0
KEY_PAUSE = 0.008
CLICK_PAUSE = 0.06


def uinput_request(direction, number, size):
    return (direction << 30) | (size << 16) | (ord("U") << 8) | number


UI_DEV_CREATE = uinput_request(0, 1, 0)
UI_DEV_SETUP = uinput_request(1, 3, 92)
UI_ABS_SETUP = uinput_request(1, 4, 28)
UI_SET_EVBIT = uinput_request(1, 100, 4)
UI_SET_KEYBIT = uinput_request(1, 101, 4)
UI_SET_RELBIT = uinput_request(1, 102, 4)
UI_SET_ABSBIT = uinput_request(1, 103, 4)

KEY_SHIFT = 42
MODIFIER_KEYS = {
    "ctrl": 29, "control": 29, "shift": KEY_SHIFT, "alt": 56, "option": 56,
    "super": 125, "cmd": 125, "command": 125, "meta": 125, "win": 125,
}
NAMED_KEYS = {
    "return": 28, "enter": 28, "escape": 1, "esc": 1, "tab": 15, "space": 57, "backspace": 14,
    "delete": 111, "del": 111, "insert": 110, "home": 102, "end": 107, "pageup": 104, "pagedown": 109,
    "up": 103, "down": 108, "left": 105, "right": 106, "capslock": 58, "printscreen": 99, "menu": 127,
    "f1": 59, "f2": 60, "f3": 61, "f4": 62, "f5": 63, "f6": 64, "f7": 65, "f8": 66, "f9": 67, "f10": 68,
    "f11": 87, "f12": 88,
}


def us_keyboard():
    """Which key of a US keyboard types each character, and whether Shift is held for it."""
    keys = {" ": (57, False), "\n": (28, False), "\t": (15, False), "\\": (43, False), "|": (43, True)}
    rows = (
        (2, "1234567890-=", "!@#$%^&*()_+"),
        (16, "qwertyuiop[]", "QWERTYUIOP{}"),
        (30, "asdfghjkl;'`", 'ASDFGHJKL:"~'),
        (44, "zxcvbnm,./", "ZXCVBNM<>?"),
    )
    for first, plain, shifted in rows:
        for index, character in enumerate(plain):
            keys[character] = (first + index, False)
            keys[shifted[index]] = (first + index, True)
    return keys


US_KEYS = us_keyboard()


def keys_of_chord(text):
    """The keys one press is made of, in the order they go down: `ctrl+shift+t`."""
    names = text.split("+")
    # The plus sign is a key too: alone, or as the last of several.
    if text == "+":
        names = ["+"]
    elif len(names) > 2 and names[-1] == "" and names[-2] == "":
        names = names[:-2] + ["+"]
    codes = []
    for position, name in enumerate(names):
        lowered = name.lower()
        if lowered in MODIFIER_KEYS:
            code, shifted = MODIFIER_KEYS[lowered], False
        elif position < len(names) - 1:
            raise AgentError("“%s” isn't a key to hold down. Those are ctrl, shift, alt and super." % name[:32])
        elif lowered in NAMED_KEYS:
            code, shifted = NAMED_KEYS[lowered], False
        elif len(name) == 1 and lowered in US_KEYS:
            # A letter in a shortcut is the key, whichever way it is written.
            code, shifted = US_KEYS[lowered if name.isalpha() else name]
        else:
            raise AgentError("There is no key called “%s”." % name[:32])
        if shifted and KEY_SHIFT not in codes:
            codes.append(KEY_SHIFT)
        if code not in codes:
            codes.append(code)
    return codes


class InputDevices:
    """A keyboard and a pointer of the agent's own making. They are made when first used and stay
    for as long as the agent runs. One thing is done with them at a time."""

    def __init__(self):
        self.lock = threading.Lock()
        self.keyboard = None
        self.mouse = None

    # Making the devices

    def open(self):
        if not os.path.exists("/dev/uinput"):
            # Where it isn't built into the kernel, it is a module.
            try:
                run(["modprobe", "uinput"], timeout=10)
            except AgentError:
                pass
        try:
            return os.open("/dev/uinput", os.O_WRONLY | os.O_CLOEXEC)
        except OSError as error:
            raise AgentError("This system doesn't let input devices be made (/dev/uinput: %s)." % (error.strerror or error))

    def create(self, device, name, product):
        # A device, as the kernel wants it described: where it is from, and what it is called.
        fcntl.ioctl(device, UI_DEV_SETUP, struct.pack("=HHHH80sI", BUS_VIRTUAL, 0x5356, product, 1, name.encode("ascii"), 0))
        fcntl.ioctl(device, UI_DEV_CREATE)
        time.sleep(DEVICE_SETTLE_TIME)

    def keyboard_device(self):
        if self.keyboard is None:
            device = self.open()
            try:
                fcntl.ioctl(device, UI_SET_EVBIT, EV_KEY)
                for code in range(1, 249):
                    fcntl.ioctl(device, UI_SET_KEYBIT, code)
                self.create(device, "SwiftVM keyboard", 1)
            except OSError as error:
                os.close(device)
                raise AgentError("The agent's keyboard couldn't be made: %s" % (error.strerror or error))
            self.keyboard = device
        return self.keyboard

    def mouse_device(self):
        if self.mouse is None:
            device = self.open()
            try:
                fcntl.ioctl(device, UI_SET_EVBIT, EV_KEY)
                for code in BUTTONS.values():
                    fcntl.ioctl(device, UI_SET_KEYBIT, code)
                fcntl.ioctl(device, UI_SET_EVBIT, EV_REL)
                for code in (REL_WHEEL, REL_HWHEEL):
                    fcntl.ioctl(device, UI_SET_RELBIT, code)
                # It says where on the screen it is rather than how far it moved, as a tablet does.
                fcntl.ioctl(device, UI_SET_EVBIT, EV_ABS)
                for code in (ABS_X, ABS_Y):
                    fcntl.ioctl(device, UI_SET_ABSBIT, code)
                    fcntl.ioctl(device, UI_ABS_SETUP, struct.pack("=HxxiiiiiI", code, 0, 0, POINTER_RANGE, 0, 0, 0))
                self.create(device, "SwiftVM pointer", 2)
            except OSError as error:
                os.close(device)
                raise AgentError("The agent's pointer couldn't be made: %s" % (error.strerror or error))
            self.mouse = device
        return self.mouse

    def emit(self, device, *events):
        """Sends events that belong together, each a kind, a code and a value."""
        for kind, code, value in events + ((EV_SYN, SYN_REPORT, 0),):
            # An event, as the kernel reads it: a time it fills in itself, then these three.
            os.write(device, struct.pack("=qqHHi", 0, 0, kind, code, value))

    # The keyboard

    def keys(self, request):
        text = request.get("text")
        chords = request.get("keys")
        if text is not None and not isinstance(text, str):
            raise AgentError("The text to type has to be text.")
        if chords is not None and (not isinstance(chords, list) or not all(isinstance(chord, str) and chord for chord in chords)):
            raise AgentError("The keys to press have to be named.")
        if not text and not chords:
            raise AgentError("The request has neither text to type nor keys to press.")
        # Everything is looked up before anything is typed: half a text is worse than none.
        presses = []
        for character in text or "":
            if character not in US_KEYS:
                raise AgentError(
                    "“%s” isn't on a US keyboard, which is what this types on. Text like that can be put "
                    "into a text field with `swiftvm ui <machine> set`." % character
                )
            code, shifted = US_KEYS[character]
            presses.append([KEY_SHIFT, code] if shifted else [code])
        presses += [keys_of_chord(chord) for chord in chords or []]
        with self.lock:
            device = self.keyboard_device()
            for codes in presses:
                for code in codes:
                    self.emit(device, (EV_KEY, code, 1))
                    time.sleep(KEY_PAUSE)
                for code in reversed(codes):
                    self.emit(device, (EV_KEY, code, 0))
                    time.sleep(KEY_PAUSE)

    # The pointer

    def pointer(self, request):
        action = request.get("action")
        if action not in ("move", "click", "drag", "scroll"):
            raise AgentError("The mouse doesn't do “%s”." % str(action)[:32])
        button = BUTTONS.get(request.get("button") or "left")
        if button is None:
            raise AgentError("The mouse has a left, a right and a middle button.")
        width, height = screen_size()

        def place(x, y):
            if not all(isinstance(value, int) and not isinstance(value, bool) for value in (x, y)):
                raise AgentError("A place on the screen is two whole numbers.")
            if not (0 <= x < width and 0 <= y < height):
                raise AgentError("(%d, %d) isn't on the screen, which is %d by %d." % (x, y, width, height))
            return (
                (EV_ABS, ABS_X, round(x * POINTER_RANGE / max(width - 1, 1))),
                (EV_ABS, ABS_Y, round(y * POINTER_RANGE / max(height - 1, 1))),
            )

        def number(name, default):
            value = request.get(name)
            if value is None:
                return default
            if not isinstance(value, int) or isinstance(value, bool):
                raise AgentError("%s has to be a whole number." % name)
            return value

        start = place(request.get("x"), request.get("y"))
        end = place(request.get("toX"), request.get("toY")) if action == "drag" else None
        count = number("count", 1)
        if not 1 <= count <= 3:
            raise AgentError("A click is one, two or three clicks.")
        delta_x, delta_y = number("deltaX", 0), number("deltaY", 0)
        if abs(delta_x) > 100 or abs(delta_y) > 100:
            raise AgentError("That is further than the wheel is turned in one go.")
        with self.lock:
            device = self.mouse_device()
            self.emit(device, *start)
            time.sleep(CLICK_PAUSE)
            if action == "click":
                for _ in range(count):
                    self.emit(device, (EV_KEY, button, 1))
                    time.sleep(CLICK_PAUSE)
                    self.emit(device, (EV_KEY, button, 0))
                    time.sleep(CLICK_PAUSE)
            elif action == "drag":
                self.emit(device, (EV_KEY, button, 1))
                time.sleep(CLICK_PAUSE)
                # Whatever is dragged follows a pointer that moves, not one that jumps.
                steps = 12
                for step in range(1, steps + 1):
                    self.emit(device, *(
                        (kind, code, round(before + (after - before) * step / steps))
                        for (kind, code, before), (_, _, after) in zip(start, end)
                    ))
                    time.sleep(0.02)
                time.sleep(CLICK_PAUSE)
                self.emit(device, (EV_KEY, button, 0))
            elif action == "scroll":
                # The wheel counts up for away from the hand, which scrolls up. Down is positive here.
                for code, notches in ((REL_WHEEL, -delta_y), (REL_HWHEEL, delta_x)):
                    for _ in range(abs(notches)):
                        self.emit(device, (EV_REL, code, 1 if notches > 0 else -1))
                        time.sleep(0.015)


INPUT = InputDevices()


# What is on the screen, as a tree
#
# A desktop tells its own user what is on the screen, part by part, for screen readers (AT-SPI).
# This is the half of the agent that asks: the same program, run as the user at the screen. It
# takes what Python brings for talking to the desktop, which a desktop system has.

class ScreenTree:
    """What is on the screen as the desktop's accessibility tells it, and what can be done to it."""

    STATES = ("ACTIVE", "FOCUSED", "SELECTED", "CHECKED", "PRESSED", "EXPANDED", "EDITABLE")
    # What pressing a part is called, by the toolkits that draw them.
    PRESSES = ("click", "press", "activate", "toggle", "jump", "open")
    # What makes a part worth showing. Most of a tree is boxes that only hold other boxes.
    TELLING = ("name", "description", "value", "actions", "states")

    def __init__(self, atspi, everything=False):
        self.atspi = atspi
        # Show the boxes too, and every action a part has.
        self.everything = everything
        self.count = 0
        self.truncated = False
        # Under Wayland an application isn't told where on the screen its windows are, and what it
        # says about the places of its parts is not to be clicked on. Whoever draws the screen knows.
        self.compositor = compositor_process()
        self.places_are_real = True

    def applications(self):
        """Every application on the desktop, with its process and the name its parts' ids start with."""
        desktop = self.atspi.get_desktop(0)
        for index in range(desktop.get_child_count()):
            try:
                application = desktop.get_child_at_index(index)
                if application is None:
                    continue
                process = application.get_process_id()
            except Exception:
                # One that has gone, or doesn't answer.
                continue
            # A process is what an application stays through its windows opening and closing.
            yield application, process, str(process) if process > 0 else "n%d" % index

    def read(self, only, depth):
        applications = []
        for application, process, identifier in self.applications():
            try:
                if only and only.lower() not in (application.get_name() or "").lower():
                    continue
                self.places_are_real = self.compositor is None or process == self.compositor
                described = self.describe(application, identifier, depth, 0)
            except Exception:
                continue
            # One without a window on the screen has nothing to show.
            applications += [entry for entry in described if entry.get("children")]
        return {"applications": applications, "truncated": self.truncated}

    def describe(self, node, identifier, depth, level):
        """What there is to show of `node`: the part itself with what is in it, or, for a box that
        says nothing of itself, only what is in it. An application is at level 0, its windows at 1."""
        states = node.get_state_set()
        if level > 0 and not states.contains(self.atspi.StateType.SHOWING):
            return []
        if self.count >= MAX_TREE_NODES:
            self.truncated = True
            return []
        self.count += 1
        entry = {"id": identifier, "role": node.get_role_name()}
        name = node.get_name()
        if name:
            entry["name"] = name[:MAX_TREE_TEXT]
        description = node.get_description()
        if description:
            entry["description"] = description[:MAX_TREE_TEXT]
        value = self.value(node)
        if value not in (None, "", name):
            entry["value"] = value
        named = [state.lower() for state in self.STATES if states.contains(getattr(self.atspi.StateType, state))]
        actions = self.actions(node)
        if not self.everything:
            # Names with a dot are the application's own commands, which every part of a window
            # repeats. They can still be asked for by name.
            actions = [action for action in actions if action and "." not in action]
        if actions:
            entry["actions"] = actions
            if not states.contains(self.atspi.StateType.SENSITIVE):
                named.append("disabled")
        if named:
            entry["states"] = named
        bounds = self.bounds(node) if self.places_are_real else None
        if bounds:
            entry["bounds"] = bounds
        children = []
        if depth > 0:
            total = node.get_child_count()
            if total > MAX_TREE_CHILDREN:
                self.truncated = True
            for index in range(min(total, MAX_TREE_CHILDREN)):
                try:
                    child = node.get_child_at_index(index)
                    if child is not None:
                        children += self.describe(child, "%s/%d" % (identifier, index), depth - 1, level + 1)
                except Exception:
                    continue
        if children:
            entry["children"] = children
        if self.everything or level < 2 or any(key in entry for key in self.TELLING):
            return [entry]
        return children

    def value(self, node):
        try:
            # Asked for by the kind of thing it is: a part has a "get_text" of its own, which is
            # another question.
            text = node.get_text_iface()
            if text is not None:
                count = self.atspi.Text.get_character_count(text)
                return self.atspi.Text.get_text(text, 0, min(count, MAX_TREE_TEXT))
            value = node.get_value_iface()
            if value is not None:
                return self.atspi.Value.get_current_value(value)
        except Exception:
            pass
        return None

    def actions(self, node):
        try:
            action = node.get_action_iface()
            if action is None:
                return []
            return [action.get_action_name(index) for index in range(action.get_n_actions())]
        except Exception:
            return []

    def bounds(self, node):
        try:
            component = node.get_component_iface()
            if component is None:
                return None
            box = component.get_extents(self.atspi.CoordType.SCREEN)
        except Exception:
            return None
        return [box.x, box.y, box.width, box.height] if box.width > 0 and box.height > 0 else None

    def done(self, doing):
        """Whether the application did what was asked of one of its parts. Some say no by failing."""
        try:
            return bool(doing())
        except Exception:
            return False

    def find(self, identifier):
        """The part with this id, as the tree had it."""
        first, *steps = str(identifier).split("/")
        gone = AgentError("Nothing on the screen has the id “%s” any more. Read the tree again." % str(identifier)[:64])
        node = next((application for application, _, name in self.applications() if name == first), None)
        if node is None:
            raise gone
        for step in steps:
            if not step.isdigit() or int(step) >= node.get_child_count():
                raise gone
            node = node.get_child_at_index(int(step))
            if node is None:
                raise gone
        return node

    def act(self, request):
        action = request.get("action")
        node = self.find(request.get("element"))
        what = "The %s “%s”" % (node.get_role_name(), (node.get_name() or "")[:64])
        if action == "press":
            names = self.actions(node)
            wanted = request.get("actionName")
            if wanted is not None:
                # One of the part's actions, asked for by name.
                choice = next((index for index, name in enumerate(names) if name == wanted), None)
            else:
                choice = next((index for index, name in enumerate(names) if name.lower() in self.PRESSES), None)
                if choice is None and len(names) == 1:
                    choice = 0
            if choice is None:
                missing = "has nothing to press" if wanted is None else "has no action called “%s”" % str(wanted)[:64]
                has = "Its actions: %s." % ", ".join(names[:24]) if names else "It has no actions."
                raise AgentError("%s %s. %s" % (what, missing, has))
            if not self.done(lambda: node.get_action_iface().do_action(choice)):
                raise AgentError("%s didn't take the press." % what)
        elif action == "set":
            text = request.get("text")
            if not isinstance(text, str):
                raise AgentError("The request has no text.")
            editable = node.get_editable_text_iface()
            if editable is None:
                # Some text fields say what is in them and don't let it be set.
                raise AgentError(
                    "%s doesn't take text this way. If it is a text field, give it the keyboard with "
                    "`swiftvm ui <machine> focus`, and type." % what
                )
            if not self.done(lambda: editable.set_text_contents(text)):
                raise AgentError("%s didn't take the text." % what)
        elif action == "focus":
            component = node.get_component_iface()
            if component is None or not self.done(component.grab_focus):
                raise AgentError("%s can't be given the keyboard this way. Click on it instead." % what)
        else:
            raise AgentError("A part of the screen can be pressed, set or focused, not “%s”." % str(action)[:32])
        return {"id": str(request.get("element")), "role": node.get_role_name(), "name": node.get_name() or ""}


def compositor_process():
    """The process that draws a Wayland session's screen, or None where there is no such session."""
    runtime, display = os.environ.get("XDG_RUNTIME_DIR"), os.environ.get("WAYLAND_DISPLAY")
    if not runtime or not display:
        return None
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as line:
            line.connect(os.path.join(runtime, display))
            # Who is at the other end, as the kernel knows it: process, user and group.
            return struct.unpack("=iII", line.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, 12))[0]
    except (OSError, AttributeError, struct.error):
        # A Wayland session whose screen can't be asked about: nobody's places are taken as real.
        return 0


def turn_accessibility_on():
    """Says that someone is listening. Some applications only describe themselves once that is said."""
    try:
        from gi.repository import Gio, GLib
        bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
        setting = GLib.Variant("(ssv)", ("org.a11y.Status", "IsEnabled", GLib.Variant("b", True)))
        bus.call_sync(
            "org.a11y.Bus", "/org/a11y/bus", "org.freedesktop.DBus.Properties", "Set", setting, None,
            Gio.DBusCallFlags.NONE, 2000, None,
        )
    except Exception:
        # A desktop that has no such switch describes itself anyway, or not at all.
        pass


def accessibility_main(request):
    """Reads the tree of what is on the screen, or acts on one part of it, and prints what there is
    to say in JSON. Run as the user at the screen, by the agent."""
    try:
        import gi
        gi.require_version("Atspi", "2.0")
        from gi.repository import Atspi
    except (ImportError, ValueError):
        print(
            "Reading what is on the screen takes two packages in the guest that this system doesn't have. "
            "Install them with: sudo apt install python3-gi gir1.2-atspi-2.0"
            " (on Arch Linux: sudo pacman -S python-gobject at-spi2-core)",
            file=sys.stderr,
        )
        return 1
    turn_accessibility_on()
    tree = ScreenTree(Atspi, everything=request.get("all") is True)
    try:
        if request.get("type") == "tree":
            depth = request.get("depth")
            if not isinstance(depth, int) or isinstance(depth, bool) or depth < 1:
                depth = DEFAULT_TREE_DEPTH
            only = request.get("application")
            result = tree.read(only if isinstance(only, str) else None, depth)
        else:
            result = tree.act(request)
    except AgentError as problem:
        print(problem, file=sys.stderr)
        return 1
    except Exception as problem:
        print("The desktop didn't answer: %s" % (str(problem) or type(problem).__name__), file=sys.stderr)
        return 1
    print(json.dumps(result, ensure_ascii=False, separators=(",", ":")))
    return 0


def folder_device_tags():
    """The tags of the folders shared through virtio 9p devices: one each, on QEMU."""
    tags = set()
    for path in glob.glob("/sys/bus/virtio/drivers/9pnet_virtio/*/mount_tag"):
        try:
            with open(path, "rb") as file:
                tags.add(file.read().rstrip(b"\x00\n").decode("utf-8", "replace"))
        except OSError:
            pass
    return tags


def open_address_notices():
    """A socket on which the kernel says that links or addresses have changed, or None."""
    try:
        notices = socket.socket(socket.AF_NETLINK, socket.SOCK_RAW, socket.NETLINK_ROUTE)
        notices.bind((0, RTMGRP_LINK | RTMGRP_IPV4_IFADDR | RTMGRP_IPV6_IFADDR))
        notices.setblocking(False)
        return notices
    except (AttributeError, OSError):
        return None


class Agent:
    """Serves the app, one connection at a time."""

    def __init__(self, listener, system, is_the_app, jobs=None):
        self.listener = listener
        # Where jobs are taken, if this agent takes any.
        self.jobs = jobs
        self.system = system
        # Tells whether a connection comes from the app, from the address it comes from.
        self.is_the_app = is_the_app
        self.selector = selectors.DefaultSelector()
        self.connection = None
        self.received = b""
        # The interfaces as the app was last told.
        self.reported = None
        self.notices = open_address_notices()
        self.poll_interval = POLL_INTERVAL if self.notices else POLL_INTERVAL_WITHOUT_NOTICE
        self.next_look = time.monotonic() + self.poll_interval
        # The setup script's state as the app was last told, and when to look at it again.
        self.setup_reported = None
        self.next_setup_look = time.monotonic()
        self.requests = {
            "set-clock": self.set_clock,
            "mount-shared-folders": self.mount_shared_folders,
            "shut-down": self.shut_down,
            "display-size": self.display_size,
        }

    def run(self):
        self.selector.register(self.listener, selectors.EVENT_READ, self.accept)
        if self.jobs:
            self.selector.register(self.jobs, selectors.EVENT_READ, self.accept_job)
        if self.notices:
            self.selector.register(self.notices, selectors.EVENT_READ, self.addresses_may_have_changed)
        while True:
            # Without the app there is nobody to tell, and nothing to look for.
            next_look = min(self.next_look, self.next_setup_look)
            timeout = max(0.0, next_look - time.monotonic()) if self.connection else None
            for key, _ in self.selector.select(timeout):
                key.data(key.fileobj)
            if self.connection and time.monotonic() >= self.next_look:
                self.report_addresses()
            if self.connection and time.monotonic() >= self.next_setup_look:
                self.report_setup()

    # Connections

    def accept(self, listener):
        try:
            connection, peer = listener.accept()
        except OSError:
            return
        if not self.is_the_app(peer):
            # Something in this system, not the Mac. It has no business here.
            connection.close()
            return
        # The app connects anew after the machine was suspended, when it can no longer use the
        # connection it had. The newest connection is the one that counts.
        self.hang_up()
        connection.settimeout(SEND_TIMEOUT)
        self.connection = connection
        self.selector.register(connection, selectors.EVENT_READ, self.receive)
        self.send({
            "type": "hello",
            "protocol": PROTOCOL_VERSION,
            "agent": AGENT_VERSION,
            "system": self.system.describe(),
            "hostName": self.system.host_name(),
            "features": FEATURES if self.jobs else [],
        })
        self.report_addresses(always=True)
        self.report_setup(always=True)

    def accept_job(self, listener):
        try:
            connection, peer = listener.accept()
        except OSError:
            return
        if not self.is_the_app(peer):
            connection.close()
            return
        # A job takes as long as it takes. It has a thread of its own, and the app is served meanwhile.
        threading.Thread(target=Job(connection, self.system).run, daemon=True).start()

    def hang_up(self):
        if self.connection is None:
            return
        try:
            self.selector.unregister(self.connection)
        except (KeyError, ValueError):
            pass
        self.connection.close()
        self.connection = None
        self.received = b""
        self.reported = None
        self.setup_reported = None

    def send(self, message):
        if self.connection is None:
            return
        try:
            self.connection.sendall(json.dumps(message, separators=(",", ":")).encode("utf-8") + b"\n")
        except OSError:
            self.hang_up()

    def receive(self, connection):
        if connection is not self.connection:
            # A connection that was dropped a moment ago, in the same round of events.
            return
        try:
            data = connection.recv(64 * 1024)
        except (BlockingIOError, InterruptedError, socket.timeout):
            return
        except OSError:
            data = b""
        if not data:
            self.hang_up()
            return
        self.received += data
        while self.connection is connection:
            line, line_break, rest = self.received.partition(b"\n")
            if not line_break:
                break
            self.received = rest
            if line.strip():
                self.handle(line)
        if self.connection is connection and len(self.received) > MAX_LINE:
            # Whatever this is, it isn't the app.
            self.hang_up()

    # Messages

    def handle(self, line):
        try:
            message = json.loads(line.decode("utf-8"))
        except ValueError:
            return
        if not isinstance(message, dict):
            return
        kind = message.get("type")
        identifier = message.get("id")
        if kind == "hello":
            return
        error = None
        request = self.requests.get(kind) if isinstance(kind, str) else None
        if request is None:
            error = "This agent (%s) doesn't know what “%s” is." % (AGENT_VERSION, str(kind)[:64])
        else:
            try:
                request(message)
            except AgentError as problem:
                error = str(problem)
            except KeyError as missing:
                error = "The request has no %s." % missing
            except OSError as problem:
                error = problem.strerror or str(problem)
            except Exception as problem:
                # Whatever went wrong with one request, the next one deserves an agent that is still there.
                error = str(problem) or type(problem).__name__
        # Only what asks for an answer gets one.
        if isinstance(identifier, int) and not isinstance(identifier, bool):
            result = {"type": "result", "id": identifier, "ok": error is None}
            if error is not None:
                result["error"] = error
            self.send(result)

    def set_clock(self, message):
        nanoseconds = message["nanoseconds"]
        if not isinstance(nanoseconds, int) or isinstance(nanoseconds, bool) or nanoseconds <= 0:
            raise AgentError("The time has to be a number of nanoseconds since 1970.")
        self.system.set_clock(nanoseconds)

    def mount_shared_folders(self, message):
        tag = message["tag"]
        mount_point = message["mountPoint"]
        if not isinstance(tag, str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,35}", tag):
            raise AgentError("That isn't the name of a shared folder device.")
        if not isinstance(mount_point, str) or not re.fullmatch(r"/[^\x00-\x1f\x7f]{1,255}", mount_point):
            raise AgentError("That isn't a place to mount the shared folders.")
        # Shared folders belong where things get mounted, and nowhere they could cover up the system.
        mount_point = os.path.normpath(mount_point)
        if not mount_point.startswith(MOUNT_ROOTS):
            raise AgentError("Shared folders are only mounted under /mnt or /media.")
        folders = message.get("folders")
        if folders is None:
            self.system.mount_shared_folders(tag, mount_point)
            return
        # On QEMU each folder is a device of its own, which the app names, with the name it has here.
        if not isinstance(folders, list) or len(folders) > 64:
            raise AgentError("That isn't a list of shared folders.")
        for folder in folders:
            if not isinstance(folder, dict):
                raise AgentError("That isn't a shared folder.")
            if not isinstance(folder.get("tag"), str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,30}", folder["tag"]):
                raise AgentError("That isn't the name of a shared folder device.")
            name = folder.get("name")
            if not isinstance(name, str) or name in (".", "..") or not re.fullmatch(r"[^/\x00-\x1f\x7f]{1,255}", name):
                raise AgentError("That isn't the name of a shared folder.")
            if not isinstance(folder.get("readOnly"), bool):
                raise AgentError("A shared folder says whether it is read-only.")
        self.system.mount_folder_devices(folders, mount_point)

    def shut_down(self, message):
        self.system.shut_down()

    def display_size(self, message):
        width, height, scale = message["width"], message["height"], message["scale"]
        sizes = (width, height)
        if not all(isinstance(size, int) and not isinstance(size, bool) and 320 <= size <= 16384 for size in sizes):
            raise AgentError("That isn't the size of a display.")
        if not isinstance(scale, (int, float)) or isinstance(scale, bool) or not 1 <= scale <= 4:
            raise AgentError("That isn't the scale of a display.")
        # It may take Hyprland a moment, and the app is served meanwhile.
        threading.Thread(target=self.system.fit_display, args=(width, height, float(scale)), daemon=True).start()

    # Addresses

    def addresses_may_have_changed(self, notices):
        try:
            while notices.recv(64 * 1024):
                pass
        except OSError:
            pass
        # One change seldom comes alone. Look once they have settled.
        self.next_look = time.monotonic() + SETTLE_TIME

    def report_addresses(self, always=False):
        self.next_look = time.monotonic() + self.poll_interval
        interfaces = self.system.interfaces()
        if always or interfaces != self.reported:
            self.send({"type": "addresses", "interfaces": interfaces})
            self.reported = interfaces


    # Setup

    def report_setup(self, always=False):
        status = self.system.setup_status()
        if status is None:
            interval = SETUP_POLL_INTERVAL_WITHOUT_ONE
        elif status["state"] in ("pending", "running"):
            interval = SETUP_POLL_INTERVAL
        else:
            interval = SETUP_POLL_INTERVAL_AT_REST
        self.next_setup_look = time.monotonic() + interval
        # A system without a setup script has nothing to say about one.
        if status is not None and (always or status != self.setup_reported):
            self.send(dict(status, type="setup"))
            # A message that didn't get through has hung the line up, and told nobody anything.
            self.setup_reported = status if self.connection else None


class Job:
    """One job for whoever drives this machine from the Mac, on a connection and in a thread of its own.

    The job arrives as one line of JSON and is answered with one: yes, or no and why. After a yes
    the connection carries frames, the last of which says how the job ended. The app hangs up to
    call a job off.
    """

    def __init__(self, connection, system):
        self.connection = connection
        self.system = system
        # Frames are sent whole, also when two threads have something to send.
        self.sending = threading.Lock()

    def run(self):
        try:
            self.connection.settimeout(JOB_REQUEST_TIMEOUT)
            request = self.read_request()
            self.connection.settimeout(None)
            if request is not None:
                self.carry_out(request)
        except OSError:
            # The app has hung up.
            pass
        except Exception as problem:
            log("A job went wrong: %s" % (str(problem) or type(problem).__name__))
        finally:
            self.hang_up()

    def hang_up(self):
        """Ends the connection without cutting off what is still on its way.

        The agent says it has no more to send, and then listens until the app has hung up too.
        Closed at once, with something of the app's still unread, the line could be torn down
        before the app has read how the job ended.
        """
        try:
            self.connection.shutdown(socket.SHUT_WR)
            self.connection.settimeout(HANG_UP_TIMEOUT)
            while self.connection.recv(64 * 1024):
                pass
        except OSError:
            pass
        self.connection.close()

    # The connection

    def read_request(self):
        line = bytearray()
        while True:
            byte = self.connection.recv(1)
            if not byte or len(line) >= MAX_LINE:
                return None
            if byte == b"\n":
                break
            line += byte
        try:
            request = json.loads(line.decode("utf-8"))
        except ValueError:
            request = None
        if not isinstance(request, dict):
            self.answer("That isn't a job.")
            return None
        return request

    def answer(self, error=None):
        answer = {"ok": error is None}
        if error is not None:
            answer["error"] = error
        self.connection.sendall(json.dumps(answer, separators=(",", ":")).encode("utf-8") + b"\n")

    def send_frame(self, kind, payload=b""):
        """Sends what may be long as frames, as many as it takes and at least one."""
        rest = memoryview(payload)
        with self.sending:
            while True:
                piece, rest = rest[:MAX_FRAME], rest[MAX_FRAME:]
                self.connection.sendall(struct.pack(">BI", kind, len(piece)) + piece)
                if not rest:
                    break

    def read_frame(self):
        """The next frame's kind and bytes, or None when the app has hung up."""
        header = self.read_exactly(5)
        if header is None:
            return None
        kind, length = struct.unpack(">BI", header)
        if length > MAX_ACCEPTED_FRAME:
            return None
        payload = self.read_exactly(length) if length else b""
        return None if payload is None else (kind, payload)

    def read_exactly(self, count):
        data = bytearray()
        while len(data) < count:
            piece = self.connection.recv(count - len(data))
            if not piece:
                return None
            data += piece
        return bytes(data)

    def end(self, **how):
        self.send_frame(FRAME_END, json.dumps(how, separators=(",", ":")).encode("utf-8"))

    # Jobs

    def carry_out(self, request):
        kind = request.get("type")
        if sys.version_info < (3, 9):
            # What starts a process as another user came with that version.
            self.answer("This takes Python 3.9 or newer in the guest, which has %d.%d." % sys.version_info[:2])
            return
        if kind == "exec":
            self.run_command(request)
            return
        work = {
            "screenshot": self.system.screenshot,
            "pointer": lambda: self.system.pointer(request),
            "keys": lambda: self.system.keys(request),
            "tree": lambda: self.system.accessibility(request),
            "element": lambda: self.system.accessibility(request),
        }.get(kind if isinstance(kind, str) else None)
        if work is None:
            self.answer("This agent (%s) doesn't know what “%s” is." % (AGENT_VERSION, str(kind)[:64]))
            return
        # The yes comes at once: the app doesn't wait long for it, and some of this takes its time.
        # What goes wrong from here on is how the job ends.
        self.answer()
        try:
            output = work()
        except AgentError as problem:
            self.end(error=str(problem))
            return
        except OSError as problem:
            self.end(error=problem.strerror or str(problem))
            return
        if output:
            self.send_frame(FRAME_OUTPUT, output)
        self.end(status=0)

    def run_command(self, request):
        """Runs a command as an account of this system. What it prints goes to the app as it comes,
        what the app sends is its input, and how it exits ends the job."""
        try:
            arguments = request.get("arguments")
            if (not isinstance(arguments, list) or not arguments or not arguments[0]
                    or not all(isinstance(argument, str) and "\0" not in argument for argument in arguments)):
                raise AgentError("The request has no command.")
            account = self.system.account(request.get("user"))
            environment = self.system.environment(account)
            added = request.get("environment") or {}
            if not isinstance(added, dict) or not all(
                isinstance(name, str) and isinstance(value, str) and name and "=" not in name and "\0" not in name + value
                for name, value in added.items()
            ):
                raise AgentError("The command's environment has to be names and values.")
            environment.update(added)
            directory = request.get("directory") or account.pw_dir
            if not isinstance(directory, str) or "\0" in directory:
                raise AgentError("That isn't a folder to run the command in.")
        except AgentError as problem:
            self.answer(str(problem))
            return
        self.answer()
        try:
            process = subprocess.Popen(
                arguments, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, cwd=directory,
                env=environment, start_new_session=True, **self.system.identity(account),
            )
        except OSError as problem:
            # 127 and 126 are what a shell says for a command that isn't there, and one it can't run.
            missing = isinstance(problem, FileNotFoundError)
            what = problem.filename if isinstance(problem.filename, str) else arguments[0]
            self.end(error="%s: %s" % (what, problem.strerror or problem), status=127 if missing and what != directory else 126)
            return

        finished = threading.Event()
        stopped = threading.Event()
        printers = [
            threading.Thread(target=self.pass_on, args=(process.stdout, FRAME_OUTPUT, finished), daemon=True),
            threading.Thread(target=self.pass_on, args=(process.stderr, FRAME_ERROR, finished), daemon=True),
        ]
        for thread in printers:
            thread.start()
        threading.Thread(target=self.feed, args=(process,), daemon=True).start()
        watcher = threading.Thread(target=self.watch, args=(process, stopped), daemon=True)
        watcher.start()
        status = process.wait()
        finished.set()
        # What the command printed last is still on its way. Only an idle pipe times out, never a
        # thread waiting for the app to take a frame, and the end follows all of those frames.
        for thread in printers:
            thread.join()
        stopped.set()
        watcher.join()
        if status < 0:
            self.end(signal=-status)
        else:
            self.end(status=status)

    def pass_on(self, stream, kind, finished):
        try:
            waiting = select.poll()
            waiting.register(stream, select.POLLIN)
            idle_since = None
            while True:
                if not waiting.poll(250):
                    if finished.is_set():
                        now = time.monotonic()
                        if idle_since is None:
                            idle_since = now
                        elif now - idle_since >= OUTPUT_GRACE:
                            break
                    continue
                data = stream.read1(MAX_FRAME)
                if not data:
                    break
                self.send_frame(kind, data)
                idle_since = None
        except (OSError, ValueError):
            pass
        finally:
            stream.close()

    def feed(self, process):
        """Gives the command what the app sends as its input."""
        try:
            while True:
                frame = self.read_frame()
                if frame is None:
                    break
                kind, payload = frame
                if kind != FRAME_INPUT:
                    continue
                try:
                    if payload:
                        process.stdin.write(payload)
                        process.stdin.flush()
                    else:
                        # An empty frame is the end of the input.
                        process.stdin.close()
                except (OSError, ValueError):
                    # A command that has stopped reading, or has ended.
                    pass
        except OSError:
            pass

    def watch(self, process, stopped):
        """Calls the command off when the app hangs up: whoever wanted it is gone.

        This doesn't go by what the app sends, which may be waiting behind input the command isn't
        reading. It goes by the line itself.
        """
        hung_up = getattr(select, "POLLRDHUP", 0) | select.POLLHUP | select.POLLERR | select.POLLNVAL
        watcher = select.poll()
        try:
            watcher.register(self.connection, getattr(select, "POLLRDHUP", 0))
            while not stopped.is_set():
                if any(events & hung_up for _, events in watcher.poll(500)):
                    break
        except (OSError, ValueError):
            pass
        if stopped.is_set():
            return
        try:
            os.killpg(process.pid, signal.SIGTERM)
            # The parent may take TERM while a child ignores it. Give the whole group this long to
            # end, even when its head has already exited.
            deadline = time.monotonic() + KILL_GRACE
            while time.monotonic() < deadline:
                os.killpg(process.pid, 0)
                time.sleep(0.05)
            os.killpg(process.pid, signal.SIGKILL)
        except OSError:
            pass


# The serial line

class SerialLine:
    """The connections that share the serial line of a machine on QEMU, which has no socket device.

    The app opens a connection to a port, as it would over a socket device, and both ends pass the
    bytes in frames that say which connection they belong to: a byte for the frame's kind, four for
    the connection and four for the length of what follows, most significant first, and then that
    many bytes (ChannelFrame, in Sources/GuestChannel). Each connection is handed to whoever listens
    on its port as one end of a socket pair, so that it serves it as it serves one from the socket
    device. The line itself has a thread that reads it, and each connection one that sends.
    """

    HELLO, OPEN, ACCEPT, REFUSE, DATA, END, CLOSE = range(7)
    HELLO_WORDS = b"swiftvm-agent-channel"
    MAX_PAYLOAD = 64 * 1024

    def __init__(self, open_line):
        # Returns the line as a file descriptor, waiting for as long as it takes.
        self.open_line = open_line
        self.descriptor = None
        self.listeners = {}
        self.connections = {}
        self.lock = threading.Lock()
        self.write_lock = threading.Lock()

    def listen(self, port):
        listener = SerialListener()
        self.listeners[port] = listener
        return listener

    def start(self):
        threading.Thread(target=self.run, daemon=True).start()

    def run(self):
        while True:
            try:
                descriptor = self.open_line()
                with self.write_lock:
                    self.descriptor = descriptor
                self.drop_everything()
                self.send(self.HELLO, 0, self.HELLO_WORDS)
                self.read_frames()
            except OSError as problem:
                log("The serial line to the Mac: %s" % (problem.strerror or problem))
            self.drop_everything()
            with self.write_lock:
                if self.descriptor is not None:
                    try:
                        os.close(self.descriptor)
                    except OSError:
                        pass
                    self.descriptor = None
            time.sleep(2)

    def read_exactly(self, count):
        data = b""
        while len(data) < count:
            chunk = os.read(self.descriptor, count - len(data))
            if not chunk:
                raise OSError("the Mac has closed its end")
            data += chunk
        return data

    def read_frames(self):
        while True:
            kind, connection, length = struct.unpack(">BII", self.read_exactly(9))
            if kind > self.CLOSE or length > self.MAX_PAYLOAD:
                raise OSError("what came on the line isn't frames")
            self.handle(kind, connection, self.read_exactly(length) if length else b"")

    def handle(self, kind, connection, payload):
        if kind == self.HELLO:
            # The app has opened its end anew: whatever was open before is gone.
            self.drop_everything()
            self.send(self.HELLO, 0, self.HELLO_WORDS)
        elif kind == self.OPEN:
            listener = self.listeners.get(struct.unpack(">I", payload)[0]) if len(payload) == 4 else None
            if listener is None:
                self.send(self.REFUSE, connection)
                return
            ours, theirs = socket.socketpair()
            link = SerialConnection(self, connection, ours)
            with self.lock:
                self.connections[connection] = link
            self.send(self.ACCEPT, connection)
            link.start()
            listener.put(theirs)
        else:
            with self.lock:
                link = self.connections.get(connection)
                if kind == self.CLOSE:
                    self.connections.pop(connection, None)
            if link is None:
                return
            # Never waits: what the side here hasn't read yet waits in the connection's queue, so that
            # one connection that is slow to read holds up none of the others, nor the line.
            if kind == self.DATA:
                link.receive(payload)
            elif kind == self.END:
                link.receive(None)
            elif kind == self.CLOSE:
                link.close()

    def forget(self, link, tell=True):
        with self.lock:
            if self.connections.get(link.number) is link:
                del self.connections[link.number]
            else:
                tell = False
        link.close()
        if tell:
            self.send(self.CLOSE, link.number)

    def drop_everything(self):
        with self.lock:
            dropped = list(self.connections.values())
            self.connections.clear()
        for link in dropped:
            link.close()

    def send(self, kind, connection, payload=b""):
        frame = struct.pack(">BII", kind, connection, len(payload)) + payload
        with self.write_lock:
            if self.descriptor is None:
                return
            view = memoryview(frame)
            try:
                while view:
                    view = view[os.write(self.descriptor, view):]
            except OSError:
                # The reader finds out too, and opens the line anew.
                pass


class SerialConnection:
    """One connection on the serial line: the side here is one end of a socket pair. A thread passes
    on what the side here writes, and another writes what came from the Mac, from a queue, so that
    neither ever holds up the line."""

    # What may wait for the side here to read it. A program that reads nothing of what keeps coming
    # loses the connection rather than the agent its memory.
    MAX_QUEUED = 32 * 1024 * 1024

    def __init__(self, line, number, ours):
        self.line = line
        self.number = number
        self.socket = ours
        self.queue = []
        self.queued = 0
        self.closed = False
        self.condition = threading.Condition()

    def start(self):
        threading.Thread(target=self.pass_on, daemon=True).start()
        threading.Thread(target=self.write_out, daemon=True).start()

    def receive(self, data):
        """Queues what came from the Mac: bytes, or None for the end of what it sends."""
        with self.condition:
            if self.closed:
                return
            self.queue.append(data)
            self.queued += len(data or b"")
            overflowing = self.queued > self.MAX_QUEUED
            self.condition.notify()
        if overflowing:
            self.line.forget(self)

    def write_out(self):
        while True:
            with self.condition:
                while not self.queue and not self.closed:
                    self.condition.wait()
                if self.closed:
                    return
                data = self.queue.pop(0)
                self.queued -= len(data or b"")
            try:
                if data is None:
                    self.socket.shutdown(socket.SHUT_WR)
                else:
                    self.socket.sendall(data)
            except OSError:
                # The side here is gone: so is the connection.
                self.line.forget(self)
                return

    def pass_on(self):
        """Sends what the side here writes, until it has no more."""
        while True:
            try:
                data = self.socket.recv(SerialLine.MAX_PAYLOAD)
            except OSError:
                data = None
            with self.line.lock:
                if self.line.connections.get(self.number) is not self:
                    return
            if data:
                self.line.send(SerialLine.DATA, self.number, data)
            elif data == b"":
                # It has no more to send, and may still read.
                self.line.send(SerialLine.END, self.number)
                return
            else:
                self.line.forget(self)
                return

    def close(self):
        with self.condition:
            if self.closed:
                return
            self.closed = True
            self.queue = []
            self.condition.notify()
        # Shut down before closing: a thread waiting on the socket wakes up, and the side here hears
        # that the connection is gone.
        try:
            self.socket.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        try:
            self.socket.close()
        except OSError:
            pass


class SerialListener:
    """Stands in for a listening socket, for the connections on one port of the serial line."""

    def __init__(self):
        self.ready, self.signal = socket.socketpair()
        self.waiting = []
        self.lock = threading.Lock()

    def put(self, connection):
        with self.lock:
            self.waiting.append(connection)
        self.signal.send(b"x")

    def fileno(self):
        return self.ready.fileno()

    def accept(self):
        self.ready.recv(1)
        with self.lock:
            if not self.waiting:
                raise BlockingIOError()
            return self.waiting.pop(0), ("serial", 0)


def relay_to_local_port(listener, port):
    """Connects each connection on `listener` to `port` here: the SSH server, for the Mac's
    `swiftvm ssh --vsock`, which on QEMU has no socket device to reach it through."""
    def relay(source, destination):
        try:
            while True:
                data = source.recv(64 * 1024)
                if not data:
                    break
                destination.sendall(data)
        except OSError:
            pass
        for end, how in ((destination, socket.SHUT_WR), (source, socket.SHUT_RD)):
            try:
                end.shutdown(how)
            except OSError:
                pass

    def serve(connection):
        try:
            local = socket.create_connection(("127.0.0.1", port), timeout=10)
        except OSError:
            connection.close()
            return
        local.settimeout(None)
        other = threading.Thread(target=relay, args=(local, connection), daemon=True)
        other.start()
        relay(connection, local)
        other.join()
        connection.close()
        local.close()

    while True:
        select.select([listener], [], [])
        try:
            connection, _ = listener.accept()
        except OSError:
            continue
        threading.Thread(target=serve, args=(connection,), daemon=True).start()


def has_socket_device():
    """Whether the machine has a virtio socket device: those on Apple's virtualization do, those on
    QEMU have the serial line instead."""
    for path in glob.glob("/sys/bus/virtio/devices/*/device"):
        try:
            with open(path, encoding="ascii") as file:
                if file.read().strip() == VIRTIO_SOCKET_DEVICE:
                    return True
        except OSError:
            pass
    return False


def open_serial_line(path):
    """Opens the serial line, waiting for as long as it takes for it to be there."""
    def opener():
        problem = None
        while True:
            try:
                return os.open(path, os.O_RDWR | os.O_NOCTTY)
            except OSError as error:
                if str(error) != problem:
                    problem = str(error)
                    log("Can't open %s (%s). Trying again until it works." % (path, problem))
                time.sleep(2)
    return opener


def connect_to_unix_socket(path):
    """A pretended serial line: the other end of a Unix socket, for trying the line without QEMU."""
    def opener():
        while True:
            try:
                line = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                line.connect(path)
                return line.detach()
            except OSError:
                time.sleep(0.2)
    return opener


def listen_on_socket_device(port):
    """Listens for the app. Waits for as long as it takes for the socket device to be there."""
    problem = None
    while True:
        try:
            listener = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM)
            try:
                listener.bind((socket.VMADDR_CID_ANY, port))
                listener.listen(4)
            except OSError:
                listener.close()
                raise
            return listener
        except (AttributeError, OSError) as error:
            if str(error) != problem:
                problem = str(error)
                log("Can't listen on port %d of the socket device (%s). Trying again until it works." % (port, problem))
            time.sleep(2)


def listen_on_unix_socket(path):
    try:
        os.unlink(path)
    except OSError:
        pass
    listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    listener.bind(path)
    listener.listen(4)
    return listener


def main(arguments):
    if not arguments and not has_socket_device():
        # Only the app is at the other end of the line.
        line = SerialLine(open_serial_line(SERIAL_LINE))
        agent = Agent(line.listen(PORT), System(), lambda peer: True, line.listen(JOB_PORT))
        threading.Thread(target=relay_to_local_port, args=(line.listen(SSH_PORT), SSH_PORT), daemon=True).start()
        line.start()
        log("SwiftVM guest agent %s, listening on ports %d and %d of the serial line." % (AGENT_VERSION, PORT, JOB_PORT))
    elif not arguments:
        listener = listen_on_socket_device(PORT)
        jobs = listen_on_socket_device(JOB_PORT)
        # Only the Mac may give orders, not a program in this system that connects to the same port.
        agent = Agent(listener, System(), lambda peer: peer[0] == socket.VMADDR_CID_HOST, jobs)
        log("SwiftVM guest agent %s, listening on ports %d and %d of the socket device." % (AGENT_VERSION, PORT, JOB_PORT))
    elif len(arguments) == 2 and arguments[0] == "--pretend-on-line":
        # The serial line, pretended: the other end of a Unix socket, and a system that only says.
        line = SerialLine(connect_to_unix_socket(arguments[1]))
        agent = Agent(line.listen(PORT), PretendSystem(), lambda peer: True, line.listen(JOB_PORT))
        line.start()
        log("SwiftVM guest agent %s, pretending, on the line at %s." % (AGENT_VERSION, arguments[1]))
    elif len(arguments) in (2, 4) and arguments[0] == "--pretend-on" and arguments[2:3] in ([], ["--setup-in"]):
        system = PretendSystem(arguments[3] if len(arguments) == 4 else None)
        jobs = listen_on_unix_socket(arguments[1] + ".jobs")
        agent = Agent(listen_on_unix_socket(arguments[1]), system, lambda peer: True, jobs)
        log("SwiftVM guest agent %s, pretending, listening on %s, and on %s.jobs for jobs." % (AGENT_VERSION, arguments[1], arguments[1]))
    elif arguments == ["--accessibility"]:
        try:
            # All of it: the agent wrote it, and has seen to its length.
            request = json.loads(sys.stdin.buffer.read().decode("utf-8"))
        except ValueError:
            request = None
        if not isinstance(request, dict):
            print("That isn't a job.", file=sys.stderr)
            return 64
        return accessibility_main(request)
    elif arguments == ["--version"]:
        print(AGENT_VERSION)
        return 0
    else:
        print(
            "Usage: swiftvm-agent.py                      serve the SwiftVM app (as root, in a virtual machine)\n"
            "       swiftvm-agent.py --pretend-on-line <path>\n"
            "                                             the same over a pretended serial line: the Unix socket\n"
            "                                             at <path>, which something else listens on\n"
            "       swiftvm-agent.py --pretend-on <path> [--setup-in <folder>]\n"
            "                                             serve on a Unix socket and only say what would be done,\n"
            "                                             with a setup script's state read from that folder.\n"
            "                                             Jobs are taken on <path>.jobs\n"
            "       swiftvm-agent.py --accessibility      read what is on the screen, as the user at it. The job\n"
            "                                             comes on standard input (run by the agent itself)\n"
            "       swiftvm-agent.py --version",
            file=sys.stderr,
        )
        return 64
    try:
        agent.run()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
