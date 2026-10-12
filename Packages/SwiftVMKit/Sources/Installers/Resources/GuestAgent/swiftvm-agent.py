#!/usr/bin/python3
"""The SwiftVM guest agent for Linux.

Talks to the SwiftVM app on the Mac over the virtual machine's socket device (virtio-vsock), which
needs no network. It tells the app which system this is, which addresses it holds and how the setup
script it was created with is doing, and on the app's request sets the clock, mounts the folders
shared with the machine, or shuts the system down.

The agent listens; the app connects. Each side sends one JSON object per line and ignores what it
doesn't know, so that an agent and an app of different ages get along. The protocol is described
in Sources/GuestChannel of the SwiftVM sources.

Runs as root, from swiftvm-agent.service, and needs nothing but Python 3's standard library.
"""

import json
import os
import re
import selectors
import shlex
import socket
import subprocess
import sys
import time

AGENT_VERSION = "1.1"
PROTOCOL_VERSION = 1
# Below 1024, where only root may listen: the app has to know who answers.
PORT = 717
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

    def is_mounted(self, tag):
        """Whether the shared folders are mounted, wherever. Mounting them twice only gets in the way."""
        try:
            with open("/proc/self/mounts", encoding="utf-8", errors="replace") as file:
                for line in file:
                    fields = line.split()
                    if len(fields) >= 3 and fields[0] == tag and fields[2] == "virtiofs":
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


class PretendSystem(System):
    """Says what it would do instead of doing it, for trying the protocol without a virtual machine."""

    def __init__(self, setup_directory=None):
        # This computer's own setup, if it has one, is none of a pretended system's business.
        self.setup_directory = setup_directory or os.devnull

    def set_clock(self, nanoseconds):
        log("Would set the clock to %d." % nanoseconds)

    def mount_shared_folders(self, tag, mount_point):
        log("Would mount %s at %s." % (tag, mount_point))

    def shut_down(self):
        log("Would shut down.")


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

    def __init__(self, listener, system, is_the_app):
        self.listener = listener
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
        }

    def run(self):
        self.selector.register(self.listener, selectors.EVENT_READ, self.accept)
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
        })
        self.report_addresses(always=True)
        self.report_setup(always=True)

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
        self.system.mount_shared_folders(tag, mount_point)

    def shut_down(self, message):
        self.system.shut_down()

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


def listen_on_socket_device():
    """Listens for the app. Waits for as long as it takes for the socket device to be there."""
    problem = None
    while True:
        try:
            listener = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM)
            try:
                listener.bind((socket.VMADDR_CID_ANY, PORT))
                listener.listen(4)
            except OSError:
                listener.close()
                raise
            return listener
        except (AttributeError, OSError) as error:
            if str(error) != problem:
                problem = str(error)
                log("Can't listen on the socket device (%s). Trying again until it works." % problem)
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
    if not arguments:
        listener = listen_on_socket_device()
        # Only the Mac may give orders, not a program in this system that connects to the same port.
        agent = Agent(listener, System(), lambda peer: peer[0] == socket.VMADDR_CID_HOST)
        log("SwiftVM guest agent %s, listening on port %d of the socket device." % (AGENT_VERSION, PORT))
    elif len(arguments) in (2, 4) and arguments[0] == "--pretend-on" and arguments[2:3] in ([], ["--setup-in"]):
        system = PretendSystem(arguments[3] if len(arguments) == 4 else None)
        agent = Agent(listen_on_unix_socket(arguments[1]), system, lambda peer: True)
        log("SwiftVM guest agent %s, pretending, listening on %s." % (AGENT_VERSION, arguments[1]))
    elif arguments == ["--version"]:
        print(AGENT_VERSION)
        return 0
    else:
        print(
            "Usage: swiftvm-agent.py                      serve the SwiftVM app (as root, in a virtual machine)\n"
            "       swiftvm-agent.py --pretend-on <path> [--setup-in <folder>]\n"
            "                                             serve on a Unix socket and only say what would be done,\n"
            "                                             with a setup script's state read from that folder\n"
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
