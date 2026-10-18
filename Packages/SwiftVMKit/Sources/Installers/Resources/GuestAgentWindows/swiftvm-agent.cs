// The guest agent for Windows guests of SwiftVM.
//
// It is compiled in the guest, by the C# compiler that comes with Windows (.NET Framework 4.8), so the
// Mac that builds SwiftVM needs nothing to build it. That compiler reads C# 5: no string interpolation,
// no ?. and no => members.
//
// It runs twice. As a service, as SYSTEM, it talks to the Mac over the serial port "org.swiftvm.agent",
// in frames that carry several connections at once (ChannelFrame in SwiftVM's sources): the agent's own
// line on port 717, and a job each on port 718. As "--session", in the session of whoever is logged
// in, it shares that person's clipboard, which belongs to their session, makes the display follow the
// Mac's window, reports the windows on the screen for the Mac to show one by one, and talks to the
// service over a named pipe.

using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.IO.Pipes;
using System.Linq;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Principal;
using System.ServiceProcess;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;
using System.Windows.Forms;
using Microsoft.Win32;
using Microsoft.Win32.SafeHandles;

[assembly: System.Reflection.AssemblyTitle("SwiftVM Guest Agent")]

namespace SwiftVM
{
    static class Program
    {
        public const string Version = "1.4";
        public const string ServiceName = "SwiftVMAgent";
        public const string PortName = @"\\.\Global\org.swiftvm.agent";
        public const string SessionPipe = "swiftvm-agent-session";
        public const uint AgentPort = 717;
        public const uint JobPort = 718;
        public const int ProtocolVersion = 1;
        public static readonly string DataDirectory = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "SwiftVM");

        [STAThread]
        static int Main(string[] args)
        {
            if (args.Contains("--version"))
            {
                Console.WriteLine(Version);
                return 0;
            }
            if (args.Contains("--session"))
            {
                Log.FileName = "session.log";
                return SessionHalf.Run();
            }
            if (args.Contains("--console"))
            {
                // For trying it out by hand: the service's work, in the foreground.
                var agent = new Agent();
                agent.Start();
                Thread.Sleep(Timeout.Infinite);
                return 0;
            }
            ServiceBase.Run(new AgentService());
            // Windows knows by now that the service stopped. A job's thread still waiting on its command
            // doesn't keep the process, and with it the agent's serial port, from going.
            Environment.Exit(0);
            return 0;
        }
    }

    // MARK: - Log

    static class Log
    {
        static readonly object Gate = new object();
        /// The half in someone's session can't write to the service's log, which is SYSTEM's: it keeps
        /// one of its own next to it.
        public static string FileName = "agent.log";

        public static void Write(string format, params object[] values)
        {
            try
            {
                lock (Gate)
                {
                    Directory.CreateDirectory(Program.DataDirectory);
                    string path = Path.Combine(Program.DataDirectory, FileName);
                    // What is written is kept short: the log only says what went wrong lately.
                    if (File.Exists(path) && new FileInfo(path).Length > 1024 * 1024)
                    {
                        File.Copy(path, path + ".1", true);
                        File.Delete(path);
                    }
                    File.AppendAllText(path, DateTime.Now.ToString("s") + " " + string.Format(format, values) + "\r\n");
                }
            }
            catch (Exception)
            {
            }
        }
    }

    // MARK: - JSON

    static class Json
    {
        static JavaScriptSerializer Make()
        {
            var serializer = new JavaScriptSerializer();
            serializer.MaxJsonLength = int.MaxValue;
            return serializer;
        }

        public static string Write(object value)
        {
            return Make().Serialize(value);
        }

        public static Dictionary<string, object> Read(string line)
        {
            try
            {
                return Make().DeserializeObject(line) as Dictionary<string, object>;
            }
            catch (Exception)
            {
                return null;
            }
        }

        public static string String(Dictionary<string, object> message, string key)
        {
            object value;
            return message != null && message.TryGetValue(key, out value) ? value as string : null;
        }

        public static double? RealNumber(Dictionary<string, object> message, string key)
        {
            object value;
            if (message == null || !message.TryGetValue(key, out value) || value == null) return null;
            try
            {
                double number = Convert.ToDouble(value, System.Globalization.CultureInfo.InvariantCulture);
                return double.IsNaN(number) || double.IsInfinity(number) ? (double?)null : number;
            }
            catch (Exception)
            {
                return null;
            }
        }

        public static bool Flag(Dictionary<string, object> message, string key)
        {
            object value;
            return message != null && message.TryGetValue(key, out value) && Equals(value, true);
        }

        public static long? Number(Dictionary<string, object> message, string key)
        {
            object value;
            if (message == null || !message.TryGetValue(key, out value) || value == null) return null;
            try
            {
                return Convert.ToInt64(value);
            }
            catch (Exception)
            {
                return null;
            }
        }
    }

    // MARK: - The service

    class AgentService : ServiceBase
    {
        Agent agent;

        public AgentService()
        {
            ServiceName = Program.ServiceName;
            CanShutdown = true;
            CanHandleSessionChangeEvent = true;
        }

        /// Whoever logs in gets the half that shares their clipboard and maps the Mac's folders.
        protected override void OnSessionChange(SessionChangeDescription change)
        {
            if (change.Reason == SessionChangeReason.SessionLogon || change.Reason == SessionChangeReason.ConsoleConnect)
            {
                SessionStarter.Ensure((uint)change.SessionId);
            }
        }

        protected override void OnStart(string[] args)
        {
            agent = new Agent();
            agent.Start();
        }

        /// Returning is what tells Windows the service stopped. Ending the process here instead would look
        /// like a crash to it, which it answers by starting the service again.
        protected override void OnStop()
        {
        }
    }

    class Agent
    {
        readonly Channel channel = new Channel();
        readonly SessionLink session;
        readonly object linesGate = new object();
        readonly object seamlessGate = new object();
        readonly List<AgentLine> lines = new List<AgentLine>();

        public Agent()
        {
            session = new SessionLink(this);
        }

        public void Start()
        {
            Log.Write("agent {0} starting", Program.Version);
            ResolutionHelper.TurnOff();
            channel.Listen(Program.AgentPort, delegate(Connection connection)
            {
                var line = new AgentLine(connection, this);
                lock (linesGate) lines.Add(line);
                line.Run();
                lock (linesGate) lines.Remove(line);
            });
            channel.Listen(Program.JobPort, delegate(Connection connection)
            {
                new Job(connection).Run();
            });
            channel.Start();
            session.Start();
            new SpiceDisplayAgent(session).Start();
            // Someone may be logged in already: the service was installed, or restarted, after they were.
            var starter = new Thread(delegate()
            {
                Thread.Sleep(2000);
                uint console = Native.WTSGetActiveConsoleSessionId();
                if (console != 0xFFFFFFFF) SessionStarter.Ensure(console);
            });
            starter.IsBackground = true;
            starter.Start();
        }

        public SessionLink Session
        {
            get { return session; }
        }

        /// Passes on text copied in the guest to every line to the Mac that shares the clipboard.
        public void GuestCopied(string text)
        {
            foreach (var line in Lines()) line.SendClipboard(text);
        }

        public void SessionWantsClipboard()
        {
            foreach (var line in Lines()) line.SendClipboardRequest();
        }

        /// Has the session half report the windows on the screen while any line to the Mac wants them. A
        /// line that is going away may still be on its way out as the Mac's next one asks for them.
        public void SeamlessChanged()
        {
            lock (seamlessGate) session.SetSeamless(Lines().Any(line => line.ShowsWindows));
        }

        /// Passes on what the session half says of the windows on the screen to every line to the Mac
        /// that asked for them: the windows themselves, and what is at a point a line asked about.
        public void WindowsChanged(Dictionary<string, object> message)
        {
            foreach (var line in Lines()) line.SendWindows(message);
        }

        List<AgentLine> Lines()
        {
            lock (linesGate) return new List<AgentLine>(lines);
        }
    }

    /// The resolution service that comes with the 3D display driver. It has Windows switch to the size
    /// the Mac last asked for, which that driver offers Windows only as it starts: Windows puts another,
    /// smaller size in its place, which the Mac's window can only show scaled. The machine starts at
    /// the size its window shows it at instead, and this agent gives Windows the scale for it.
    static class ResolutionHelper
    {
        const string ServiceName = "vgpusrv";

        public static void TurnOff()
        {
            try
            {
                using (var key = Registry.LocalMachine.OpenSubKey(@"SYSTEM\CurrentControlSet\Services\" + ServiceName, true))
                {
                    if (key == null) return;
                    // Disabled, as the driver's next installation would start it again.
                    key.SetValue("Start", 4, RegistryValueKind.DWord);
                }
                using (var service = new ServiceController(ServiceName))
                {
                    if (service.Status != ServiceControllerStatus.Stopped) service.Stop();
                }
            }
            catch (Exception error)
            {
                Log.Write("resolution service: {0}", error.Message);
            }
        }
    }

    /// SPICE's monitor protocol. The server offers the requested mode to the virtio GPU before
    /// forwarding it here; only the active Windows session can apply it and acknowledge success.
    /// Clipboard, files, sound and pointer input use SwiftVM's existing channels instead.
    class SpiceDisplayAgent
    {
        const uint Monitors = 2, Reply = 3, Capabilities = 6, Disconnected = 13;
        const uint DisplayCapabilities = (1u << 1) | (1u << 2);
        readonly SessionLink session;
        readonly object writeGate = new object(), resizeGate = new object();
        FileStream port;
        long generation;
        long latestResize;
        uint peerCapabilities;

        public SpiceDisplayAgent(SessionLink session) { this.session = session; }

        public void Start()
        {
            var thread = new Thread(Run);
            thread.IsBackground = true;
            thread.Start();
        }

        void Run()
        {
            while (true)
            {
                try
                {
                    var handle = Native.CreateFile(@"\\.\Global\com.redhat.spice.0", Native.GenericRead | Native.GenericWrite,
                        0, IntPtr.Zero, Native.OpenExisting, Native.FileFlagOverlapped, IntPtr.Zero);
                    if (handle.IsInvalid) { handle.Dispose(); Thread.Sleep(2000); continue; }
                    using (var connection = new FileStream(handle, FileAccess.ReadWrite, 1, true))
                    {
                        lock (writeGate)
                        {
                            port = connection;
                            generation++;
                            peerCapabilities = 0;
                            Send(1, Capabilities, 1, DisplayCapabilities);
                        }
                        // Server and client messages can interleave between chunks of a message.
                        var pending = new[] { new List<byte>(), new List<byte>() };
                        while (true)
                        {
                            byte[] header = Read(connection, 8);
                            uint source = BitConverter.ToUInt32(header, 0), size = BitConverter.ToUInt32(header, 4);
                            if (source < 1 || source > 2 || size > 2048) throw new IOException("Invalid SPICE display chunk.");
                            var buffer = pending[source - 1];
                            buffer.AddRange(Read(connection, (int)size));
                            while (buffer.Count >= 20)
                            {
                                byte[] bytes = buffer.ToArray();
                                uint length = BitConverter.ToUInt32(bytes, 16);
                                if (BitConverter.ToUInt32(bytes, 0) != 1 || length > 64 * 1024)
                                    throw new IOException("Invalid SPICE display message.");
                                if (buffer.Count < 20 + length) break;
                                uint type = BitConverter.ToUInt32(bytes, 4);
                                byte[] payload = buffer.GetRange(20, (int)length).ToArray();
                                buffer.RemoveRange(0, 20 + (int)length);
                                if (source == 2 && type == Disconnected)
                                {
                                    lock (writeGate) { generation++; peerCapabilities = 0; }
                                    pending[0].Clear();
                                }
                                else if (source == 1) Handle(type, payload);
                            }
                        }
                    }
                }
                catch (Exception error) { Log.Write("display agent: {0}", error.Message); }
                finally { lock (writeGate) { port = null; generation++; } }
                Thread.Sleep(2000);
            }
        }

        static byte[] Read(Stream stream, int count)
        {
            var bytes = new byte[count];
            for (int offset = 0; offset < count; )
            {
                int read = stream.Read(bytes, offset, count - offset);
                if (read == 0) throw new EndOfStreamException();
                offset += read;
            }
            return bytes;
        }

        void Handle(uint type, byte[] payload)
        {
            if (type == Capabilities)
            {
                if (payload.Length < 4 || payload.Length % 4 != 0) throw new IOException("Invalid SPICE display capabilities.");
                lock (writeGate)
                {
                    peerCapabilities = payload.Length >= 8 ? BitConverter.ToUInt32(payload, 4) : 0;
                    if (BitConverter.ToUInt32(payload, 0) != 0) Send(1, Capabilities, 0, DisplayCapabilities);
                }
            }
            else if (type == Monitors)
            {
                int width = 0, height = 0;
                bool valid = payload.Length >= 28 && BitConverter.ToUInt32(payload, 0) == 1;
                if (valid)
                {
                    uint flags = BitConverter.ToUInt32(payload, 4);
                    height = BitConverter.ToInt32(payload, 8);
                    width = BitConverter.ToInt32(payload, 12);
                    valid = (flags & ~3u) == 0 && payload.Length == ((flags & 2) != 0 ? 32 : 28)
                        && BitConverter.ToUInt32(payload, 16) == 32 && BitConverter.ToInt32(payload, 20) == 0
                        && BitConverter.ToInt32(payload, 24) == 0 && width >= 320 && width <= 16384
                        && height >= 200 && height <= 16384;
                }
                long epoch, request;
                lock (writeGate) { epoch = generation; request = ++latestResize; }
                // Keep receiving negotiation/disconnect messages while the session switches mode.
                // Skip queued obsolete sizes and never reply to a subsequent client.
                ThreadPool.QueueUserWorkItem(delegate(object state)
                {
                    lock (resizeGate)
                    {
                        lock (writeGate) { if (port == null || generation != epoch || latestResize != request) return; }
                        bool applied = false;
                        try { applied = valid && session.ResizeDisplay(width, height); }
                        catch (Exception error) { Log.Write("display resize: {0}", error.Message); }
                        lock (writeGate)
                        {
                            if (port == null || generation != epoch || latestResize != request) return;
                            try { if ((peerCapabilities & (1u << 2)) != 0) Send(1, Reply, Monitors, applied ? 1u : 2u); }
                            catch (IOException) { }
                            catch (ObjectDisposedException) { }
                        }
                    }
                });
            }
        }

        // These protocol messages all fit in one chunk. Call with writeGate held.
        void Send(uint destination, uint type, uint first, uint second)
        {
            using (var bytes = new MemoryStream())
            using (var writer = new BinaryWriter(bytes))
            {
                writer.Write(destination); writer.Write(28u);
                writer.Write(1u); writer.Write(type); writer.Write(0ul); writer.Write(8u);
                writer.Write(first); writer.Write(second);
                port.Write(bytes.GetBuffer(), 0, (int)bytes.Length);
            }
        }
    }

    // MARK: - The channel

    /// The serial port to the Mac, with the connections that share it.
    class Channel
    {
        const byte Hello = 0, Open = 1, Accept = 2, Refuse = 3, Data = 4, End = 5, Close = 6;
        static readonly byte[] HelloWords = Encoding.ASCII.GetBytes("swiftvm-agent-channel");
        const int MaximumPayload = 64 * 1024;

        readonly Dictionary<uint, Action<Connection>> listeners = new Dictionary<uint, Action<Connection>>();
        readonly Dictionary<uint, Connection> connections = new Dictionary<uint, Connection>();
        readonly object gate = new object();
        readonly object writeGate = new object();
        FileStream port;

        public void Listen(uint number, Action<Connection> handler)
        {
            listeners[number] = handler;
        }

        public void Start()
        {
            var thread = new Thread(Run);
            thread.IsBackground = true;
            thread.Start();
        }

        void Run()
        {
            while (true)
            {
                try
                {
                    port = OpenPort();
                    Log.Write("the line to the Mac is open");
                    DropEverything();
                    Send(Hello, 0, HelloWords);
                    ReadFrames();
                }
                catch (Exception error)
                {
                    Log.Write("the line to the Mac: {0}", error.Message);
                }
                DropEverything();
                if (port != null)
                {
                    try { port.Dispose(); } catch (Exception) { }
                    port = null;
                }
                Thread.Sleep(2000);
            }
        }

        static FileStream OpenPort()
        {
            while (true)
            {
                var handle = Native.CreateFile(Program.PortName, Native.GenericRead | Native.GenericWrite, 0, IntPtr.Zero,
                    Native.OpenExisting, Native.FileFlagOverlapped, IntPtr.Zero);
                if (!handle.IsInvalid)
                {
                    // Unbuffered: one thread reads while others write, and a buffer of the stream's
                    // would be theirs to share.
                    return new FileStream(handle, FileAccess.ReadWrite, 1, true);
                }
                // The driver isn't there yet, or the port is someone else's for a moment.
                Thread.Sleep(2000);
            }
        }

        void ReadFrames()
        {
            var header = new byte[9];
            while (true)
            {
                ReadExactly(header, 9);
                byte kind = header[0];
                uint id = BigEndian(header, 1);
                int length = (int)BigEndian(header, 5);
                if (kind > Close || length > MaximumPayload)
                {
                    throw new IOException("What came on the line isn't frames.");
                }
                var payload = new byte[length];
                ReadExactly(payload, length);
                Handle(kind, id, payload);
            }
        }

        void ReadExactly(byte[] buffer, int count)
        {
            int offset = 0;
            while (offset < count)
            {
                int read = port.Read(buffer, offset, count - offset);
                if (read <= 0) throw new IOException("The line to the Mac is gone.");
                offset += read;
            }
        }

        void Handle(byte kind, uint id, byte[] payload)
        {
            Connection connection;
            switch (kind)
            {
                case Hello:
                    // The Mac has opened its end anew: whatever was open before is gone.
                    DropEverything();
                    Send(Hello, 0, HelloWords);
                    break;
                case Open:
                    uint number = payload.Length == 4 ? BigEndian(payload, 0) : 0;
                    Action<Connection> handler;
                    if (!listeners.TryGetValue(number, out handler))
                    {
                        Send(Refuse, id, new byte[0]);
                        break;
                    }
                    connection = new Connection(this, id);
                    lock (gate) connections[id] = connection;
                    Send(Accept, id, new byte[0]);
                    var thread = new Thread(delegate()
                    {
                        try
                        {
                            handler(connection);
                        }
                        catch (Exception error)
                        {
                            Log.Write("connection {0}: {1}", id, error.Message);
                        }
                        connection.Close();
                    });
                    thread.IsBackground = true;
                    thread.Start();
                    break;
                case Data:
                    lock (gate) connections.TryGetValue(id, out connection);
                    if (connection != null) connection.Receive(payload);
                    break;
                case End:
                    lock (gate) connections.TryGetValue(id, out connection);
                    if (connection != null) connection.Receive(null);
                    break;
                case Close:
                    lock (gate)
                    {
                        connections.TryGetValue(id, out connection);
                        connections.Remove(id);
                    }
                    if (connection != null) connection.Dropped();
                    break;
            }
        }

        void DropEverything()
        {
            List<Connection> open;
            lock (gate)
            {
                open = connections.Values.ToList();
                connections.Clear();
            }
            foreach (var connection in open) connection.Dropped();
        }

        public bool Send(byte kind, uint id, byte[] payload)
        {
            var frame = new byte[9 + payload.Length];
            frame[0] = kind;
            PutBigEndian(frame, 1, id);
            PutBigEndian(frame, 5, (uint)payload.Length);
            Buffer.BlockCopy(payload, 0, frame, 9, payload.Length);
            lock (writeGate)
            {
                var stream = port;
                if (stream == null) return false;
                try
                {
                    stream.Write(frame, 0, frame.Length);
                    stream.Flush();
                    return true;
                }
                catch (Exception)
                {
                    return false;
                }
            }
        }

        public void SendData(uint id, byte[] bytes, int count)
        {
            int offset = 0;
            while (offset < count)
            {
                int piece = Math.Min(MaximumPayload, count - offset);
                var payload = new byte[piece];
                Buffer.BlockCopy(bytes, offset, payload, 0, piece);
                if (!Send(Data, id, payload)) throw new IOException("The line to the Mac is gone.");
                offset += piece;
            }
        }

        public void Forget(uint id)
        {
            lock (gate) connections.Remove(id);
        }

        public const byte EndKind = End, CloseKind = Close;

        static uint BigEndian(byte[] bytes, int offset)
        {
            return (uint)(bytes[offset] << 24 | bytes[offset + 1] << 16 | bytes[offset + 2] << 8 | bytes[offset + 3]);
        }

        static void PutBigEndian(byte[] bytes, int offset, uint value)
        {
            bytes[offset] = (byte)(value >> 24);
            bytes[offset + 1] = (byte)(value >> 16);
            bytes[offset + 2] = (byte)(value >> 8);
            bytes[offset + 3] = (byte)value;
        }
    }

    /// One connection on the channel, as a stream of bytes each way. Each way ends on its own.
    class Connection
    {
        readonly Channel channel;
        readonly uint id;
        readonly object gate = new object();
        readonly Queue<byte[]> arrived = new Queue<byte[]>();
        byte[] current;
        int currentOffset;
        bool hasEnded;
        bool isDropped;
        bool hasSentEnd;

        public Connection(Channel channel, uint id)
        {
            this.channel = channel;
            this.id = id;
        }

        /// What the Mac sent, or `null` for the end of it.
        public void Receive(byte[] payload)
        {
            lock (gate)
            {
                if (payload == null) hasEnded = true;
                else arrived.Enqueue(payload);
                Monitor.PulseAll(gate);
            }
        }

        public void Dropped()
        {
            lock (gate)
            {
                isDropped = true;
                hasEnded = true;
                Monitor.PulseAll(gate);
            }
        }

        public bool IsDropped
        {
            get { lock (gate) return isDropped; }
        }

        /// Reads what has arrived into `buffer`, waiting for some. Returns 0 at the end.
        public int Read(byte[] buffer, int offset, int count)
        {
            lock (gate)
            {
                while (true)
                {
                    if (current == null && arrived.Count > 0)
                    {
                        current = arrived.Dequeue();
                        currentOffset = 0;
                    }
                    if (current != null)
                    {
                        int piece = Math.Min(count, current.Length - currentOffset);
                        Buffer.BlockCopy(current, currentOffset, buffer, offset, piece);
                        currentOffset += piece;
                        if (currentOffset == current.Length) current = null;
                        return piece;
                    }
                    if (hasEnded) return 0;
                    Monitor.Wait(gate);
                }
            }
        }

        /// Reads one line, without its line break. `null` at the end.
        public string ReadLine(int limit)
        {
            var bytes = new List<byte>();
            var one = new byte[1];
            while (bytes.Count < limit)
            {
                if (Read(one, 0, 1) == 0) return bytes.Count > 0 ? Encoding.UTF8.GetString(bytes.ToArray()) : null;
                if (one[0] == (byte)'\n') return Encoding.UTF8.GetString(bytes.ToArray());
                bytes.Add(one[0]);
            }
            return null;
        }

        public void Write(byte[] bytes, int count)
        {
            if (IsDropped) throw new IOException("The connection is gone.");
            channel.SendData(id, bytes, count);
        }

        public void WriteLine(string text)
        {
            var bytes = Encoding.UTF8.GetBytes(text + "\n");
            Write(bytes, bytes.Length);
        }

        /// Says that nothing more is coming from this side. The Mac may still send.
        public void EndWriting()
        {
            lock (gate)
            {
                if (hasSentEnd || isDropped) return;
                hasSentEnd = true;
            }
            channel.Send(Channel.EndKind, id, new byte[0]);
        }

        /// Waits until the Mac has hung up, for `patience` at most.
        public void WaitForHangUp(TimeSpan patience)
        {
            var deadline = DateTime.UtcNow + patience;
            lock (gate)
            {
                while (!hasEnded)
                {
                    var left = deadline - DateTime.UtcNow;
                    if (left <= TimeSpan.Zero) return;
                    Monitor.Wait(gate, left);
                    // What still arrives is of no use any more.
                    arrived.Clear();
                    current = null;
                }
            }
        }

        public void Close()
        {
            lock (gate)
            {
                if (isDropped) return;
                isDropped = true;
                hasEnded = true;
                Monitor.PulseAll(gate);
            }
            channel.Send(Channel.CloseKind, id, new byte[0]);
            channel.Forget(id);
        }
    }

    // MARK: - The agent's line

    /// The conversation on port 717: a hello each way, then requests from the Mac and news from here.
    class AgentLine
    {
        const int LineLimit = 256 * 1024;
        readonly Connection connection;
        readonly Agent agent;
        readonly object writeGate = new object();
        bool sharesClipboard;
        bool showsWindows;
        string lastAddresses;
        string lastSetup;

        public AgentLine(Connection connection, Agent agent)
        {
            this.connection = connection;
            this.agent = agent;
        }

        public void Run()
        {
            Send(SystemInfo.Hello());
            var hello = Json.Read(connection.ReadLine(LineLimit));
            if (hello == null || Json.String(hello, "type") != "hello") return;
            sharesClipboard = true;
            SendAddressesIfChanged();
            SendSetupIfChanged();
            var watcher = new Thread(Watch);
            watcher.IsBackground = true;
            watcher.Start();
            if (agent.Session.HasClipboardToFill) SendClipboardRequest();

            while (true)
            {
                string line = connection.ReadLine(LineLimit);
                if (line == null) break;
                var message = Json.Read(line);
                if (message == null) continue;
                Handle(message);
            }
            sharesClipboard = false;
            // A Mac that is gone shows no windows: the taskbar is the guest's own again.
            if (showsWindows)
            {
                showsWindows = false;
                agent.SeamlessChanged();
            }
        }

        void Watch()
        {
            while (!connection.IsDropped)
            {
                Thread.Sleep(3000);
                try
                {
                    SendAddressesIfChanged();
                    SendSetupIfChanged();
                }
                catch (Exception)
                {
                    return;
                }
            }
        }

        void Handle(Dictionary<string, object> message)
        {
            string type = Json.String(message, "type");
            long id = Json.Number(message, "id") ?? 0;
            try
            {
                switch (type)
                {
                    case "set-clock":
                        SystemControl.SetClock(Json.Number(message, "nanoseconds") ?? 0);
                        Answer(id, null);
                        break;
                    case "shut-down":
                        Answer(id, null);
                        SystemControl.ShutDown();
                        break;
                    case "set-time-zone":
                        SystemControl.SetTimeZone(Json.String(message, "identifier"));
                        Answer(id, null);
                        break;
                    case "mount-shared-folders":
                        SharedFolders.Map(Json.String(message, "tag"), Json.String(message, "mountPoint"));
                        Answer(id, null);
                        break;
                    case "clipboard":
                        agent.Session.SetClipboard(Json.String(message, "text") ?? "");
                        break;
                    case "display-size":
                        agent.Session.SetDisplaySize(Json.Number(message, "width") ?? 0,
                            Json.Number(message, "height") ?? 0, Json.RealNumber(message, "scale") ?? 0);
                        break;
                    case "seamless":
                        showsWindows = Json.Flag(message, "enabled");
                        agent.SeamlessChanged();
                        break;
                    case "activate-window":
                    case "hit-test":
                    case "move-window":
                    case "resize-window":
                        agent.Session.PassOn(type, message);
                        break;
                    default:
                        if (id != 0) Answer(id, "The guest tools don't know “" + type + "”.");
                        break;
                }
            }
            catch (Exception error)
            {
                Log.Write("{0}: {1}", type, error.Message);
                if (id != 0) Answer(id, error.Message);
            }
        }

        void Answer(long id, string error)
        {
            var result = new Dictionary<string, object>();
            result["type"] = "result";
            result["id"] = id;
            result["ok"] = error == null;
            if (error != null) result["error"] = error;
            Send(result);
        }

        void SendAddressesIfChanged()
        {
            var interfaces = SystemInfo.Interfaces();
            string encoded = Json.Write(interfaces);
            if (encoded == lastAddresses) return;
            lastAddresses = encoded;
            var message = new Dictionary<string, object>();
            message["type"] = "addresses";
            message["interfaces"] = interfaces;
            Send(message);
        }

        void SendSetupIfChanged()
        {
            var status = Setup.Status();
            if (status == null) return;
            string encoded = Json.Write(status);
            if (encoded == lastSetup) return;
            lastSetup = encoded;
            status["type"] = "setup";
            Send(status);
        }

        public void SendClipboard(string text)
        {
            if (!sharesClipboard) return;
            var message = new Dictionary<string, object>();
            message["type"] = "clipboard";
            message["text"] = text;
            try { Send(message); } catch (Exception) { }
        }

        public bool ShowsWindows
        {
            get { return showsWindows; }
        }

        public void SendWindows(Dictionary<string, object> message)
        {
            if (!showsWindows) return;
            try { Send(message); } catch (Exception) { }
        }

        public void SendClipboardRequest()
        {
            if (!sharesClipboard) return;
            var message = new Dictionary<string, object>();
            message["type"] = "clipboard-request";
            try { Send(message); } catch (Exception) { }
        }

        void Send(Dictionary<string, object> message)
        {
            string line = Json.Write(message);
            // The Mac counts a line's bytes, not its characters.
            if (Encoding.UTF8.GetByteCount(line) >= LineLimit) return;
            lock (writeGate) connection.WriteLine(line);
        }
    }

    // MARK: - What the system is

    static class SystemInfo
    {
        public static Dictionary<string, object> Hello()
        {
            var system = new Dictionary<string, object>();
            system["id"] = "windows";
            system["name"] = "Windows";
            using (var key = Registry.LocalMachine.OpenSubKey(@"SOFTWARE\Microsoft\Windows NT\CurrentVersion"))
            {
                string product = key == null ? null : key.GetValue("ProductName") as string;
                string displayVersion = key == null ? null : key.GetValue("DisplayVersion") as string;
                string build = key == null ? null : key.GetValue("CurrentBuild") as string;
                object revision = key == null ? null : key.GetValue("UBR");
                int buildNumber;
                int.TryParse(build, out buildNumber);
                // Windows 11 still calls itself Windows 10 here. The build says which it is.
                if (product != null && buildNumber >= 22000 && product.StartsWith("Windows 10"))
                {
                    product = "Windows 11" + product.Substring("Windows 10".Length);
                }
                if (product != null) system["prettyName"] = product;
                if (displayVersion != null) system["version"] = displayVersion;
                if (build != null) system["build"] = revision != null ? build + "." + revision : build;
                // .NET says 6.2 to a program that doesn't name the Windows it was made for. The registry
                // says what it is.
                object major = key == null ? null : key.GetValue("CurrentMajorVersionNumber");
                object minor = key == null ? null : key.GetValue("CurrentMinorVersionNumber");
                if (major != null && minor != null && build != null) system["kernel"] = major + "." + minor + "." + build;
            }
            string architecture = Environment.GetEnvironmentVariable("PROCESSOR_ARCHITECTURE");
            if (architecture != null) system["architecture"] = architecture.ToLowerInvariant();

            var features = new List<object> { "clipboard", "time-zone", "exec", "display-size", "seamless" };
            if (HasResizableDisplayDriver()) features.Add("resizable-display");
            if (HasDisplayDriver("viogpu3d.inf_*")) features.Add("accelerated-display");

            var hello = new Dictionary<string, object>();
            hello["type"] = "hello";
            hello["protocol"] = Program.ProtocolVersion;
            hello["agent"] = Program.Version;
            hello["system"] = system;
            hello["hostName"] = Environment.MachineName;
            hello["features"] = features;
            return hello;
        }

        /// Whether the driver for QEMU's virtio GPU is in the driver store, which can make the display any
        /// size. A machine that sets itself up has no such GPU yet, so the driver is only in the store until
        /// it starts with one.
        static bool HasResizableDisplayDriver()
        {
            return HasDisplayDriver("viogpudo.inf_*") || HasDisplayDriver("viogpu3d.inf_*");
        }

        static bool HasDisplayDriver(string pattern)
        {
            try
            {
                string store = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), @"DriverStore\FileRepository");
                return Directory.GetDirectories(store, pattern).Length > 0;
            }
            catch (Exception)
            {
                return false;
            }
        }

        public static List<object> Interfaces()
        {
            var list = new List<object>();
            foreach (var adapter in NetworkInterface.GetAllNetworkInterfaces())
            {
                if (adapter.NetworkInterfaceType == NetworkInterfaceType.Loopback) continue;
                if (adapter.OperationalStatus != OperationalStatus.Up) continue;
                var bytes = adapter.GetPhysicalAddress().GetAddressBytes();
                if (bytes.Length != 6) continue;
                var addresses = new List<object>();
                foreach (var unicast in adapter.GetIPProperties().UnicastAddresses)
                {
                    var address = unicast.Address;
                    if (address.AddressFamily == AddressFamily.InterNetworkV6 && address.IsIPv6LinkLocal) continue;
                    if (address.AddressFamily == AddressFamily.InterNetwork && address.ToString().StartsWith("169.254.")) continue;
                    addresses.Add(address.ToString().Split('%')[0]);
                }
                if (addresses.Count == 0) continue;
                var entry = new Dictionary<string, object>();
                entry["name"] = adapter.Name;
                entry["mac"] = string.Join(":", bytes.Select(b => b.ToString("x2")));
                entry["addresses"] = addresses;
                list.Add(entry);
            }
            return list;
        }
    }

    // MARK: - Setup

    /// How SwiftVM's setup of the guest is doing, as its runner writes it down.
    static class Setup
    {
        public static Dictionary<string, object> Status()
        {
            string path = Path.Combine(Program.DataDirectory, "setup", "status.json");
            try
            {
                if (!File.Exists(path)) return null;
                var status = Json.Read(File.ReadAllText(path));
                if (status == null || Json.String(status, "state") == null) return null;
                var result = new Dictionary<string, object>();
                result["state"] = Json.String(status, "state");
                if (Json.String(status, "name") != null) result["name"] = Json.String(status, "name");
                if (Json.String(status, "step") != null) result["step"] = Json.String(status, "step");
                return result;
            }
            catch (Exception)
            {
                return null;
            }
        }
    }

    // MARK: - Power, clock and time zone

    static class SystemControl
    {
        public static void SetClock(long nanoseconds)
        {
            var time = new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc).AddTicks(nanoseconds / 100);
            var native = new Native.SystemTime
            {
                Year = (ushort)time.Year, Month = (ushort)time.Month, Day = (ushort)time.Day,
                DayOfWeek = (ushort)time.DayOfWeek, Hour = (ushort)time.Hour, Minute = (ushort)time.Minute,
                Second = (ushort)time.Second, Milliseconds = (ushort)time.Millisecond,
            };
            Privileges.Enable("SeSystemtimePrivilege");
            if (!Native.SetSystemTime(ref native)) throw new Win32Exception();
        }

        public static void ShutDown()
        {
            Privileges.Enable("SeShutdownPrivilege");
            // Give the answer a moment to get out first.
            var thread = new Thread(delegate()
            {
                Thread.Sleep(500);
                Native.InitiateShutdown(null, "SwiftVM", 0, Native.ShutdownForceOthers | Native.ShutdownPowerOff | Native.ShutdownGraceOverride, 0x80000000);
            });
            thread.Start();
        }

        /// Takes a time zone by its name in the time zone database (Europe/Berlin), which Windows' own copy of ICU
        /// translates to Windows' name for it.
        public static void SetTimeZone(string identifier)
        {
            if (string.IsNullOrEmpty(identifier)) throw new ArgumentException("No time zone was given.");
            var buffer = new StringBuilder(128);
            int status = 0;
            int length = Native.ucal_getWindowsTimeZoneID(identifier, identifier.Length, buffer, buffer.Capacity, ref status);
            if (status > 0 || length <= 0) throw new ArgumentException("Windows doesn't know the time zone " + identifier + ".");
            string windows = buffer.ToString(0, length);
            var tzutil = Process.Start(new ProcessStartInfo("tzutil.exe", "/s \"" + windows + "\"")
            {
                UseShellExecute = false, CreateNoWindow = true,
            });
            tzutil.WaitForExit();
            if (tzutil.ExitCode != 0) throw new InvalidOperationException("Windows didn't take the time zone " + windows + ".");
        }
    }

    static class Privileges
    {
        public static void Enable(string name)
        {
            IntPtr token;
            if (!Native.OpenProcessToken(Native.GetCurrentProcess(), Native.TokenAdjustPrivileges | Native.TokenQuery, out token)) return;
            try
            {
                Native.Luid luid;
                if (!Native.LookupPrivilegeValue(null, name, out luid)) return;
                var privileges = new Native.TokenPrivileges { Count = 1, Luid = luid, Attributes = Native.SePrivilegeEnabled };
                Native.AdjustTokenPrivileges(token, false, ref privileges, 0, IntPtr.Zero, IntPtr.Zero);
            }
            finally
            {
                Native.CloseHandle(token);
            }
        }
    }

    // MARK: - Shared folders

    /// The Mac's shared folders, which it serves over WebDAV on the virtual network, as a drive.
    static class SharedFolders
    {
        static readonly object Gate = new object();
        static string location;
        static string drive;

        /// `location` is the address the Mac serves them at, and `letter` the drive to map them to. The
        /// drive is mapped in the session of whoever is logged in, now if someone is and otherwise when
        /// someone logs in: a drive that SYSTEM maps is seen by nobody else.
        public static void Map(string address, string letter)
        {
            Uri uri;
            if (string.IsNullOrEmpty(address) || !Uri.TryCreate(address, UriKind.Absolute, out uri) || uri.Scheme != "http")
                throw new ArgumentException("The shared folders' address isn't one the guest tools take.");
            // The redirector that maps WebDAV to drives is a service of its own, off until it is needed.
            Run("sc.exe", "config WebClient start= auto");
            Run("net.exe", "start WebClient");
            lock (Gate)
            {
                // \\host@port\path, as Windows writes a WebDAV location that is a drive.
                location = @"\\" + uri.Host + "@" + uri.Port + uri.AbsolutePath.TrimEnd('/').Replace('/', '\\');
                drive = string.IsNullOrEmpty(letter) ? "Z:" : letter.TrimEnd('\\');
            }
            // Nobody logged in has it mapped when someone does.
            var session = SessionLink.Current;
            if (session != null && session.IsConnected && !session.MapDrive(location, drive))
                throw new IOException("Windows didn't map the shared folders as drive " + drive + ".");
        }

        /// The drive to map for someone who has just logged in, if the Mac shares folders.
        public static bool Pending(out string pendingLocation, out string pendingDrive)
        {
            lock (Gate)
            {
                pendingLocation = location;
                pendingDrive = drive;
                return location != null;
            }
        }

        static void Run(string program, string arguments)
        {
            var process = Process.Start(new ProcessStartInfo(program, arguments) { UseShellExecute = false, CreateNoWindow = true });
            process.WaitForExit();
        }
    }

    // MARK: - Jobs

    /// A job on port 718: its line, the answer, and then frames until it ends.
    class Job
    {
        const byte Input = 0, Output = 1, ErrorOutput = 2, EndFrame = 3;
        readonly Connection connection;
        readonly object writeGate = new object();

        public Job(Connection connection)
        {
            this.connection = connection;
        }

        public void Run()
        {
            var job = Json.Read(connection.ReadLine(256 * 1024));
            string type = Json.String(job, "type");
            if (type != "exec")
            {
                Answer("The guest tools in Windows don't do “" + (type ?? "nothing") + "” jobs.");
                return;
            }
            Commands.Running command;
            try
            {
                command = Commands.Start(job);
            }
            catch (Exception error)
            {
                Answer(error.Message);
                return;
            }
            Answer(null);
            using (command)
            {
                var output = Pump(command.Output, Output);
                var errors = Pump(command.Errors, ErrorOutput);
                var input = new Thread(delegate() { FeedInput(command); });
                input.IsBackground = true;
                input.Start();
                // The Mac hangs up to call the job off.
                var watcher = new Thread(delegate()
                {
                    while (!command.HasExited)
                    {
                        if (connection.IsDropped)
                        {
                            command.Kill();
                            return;
                        }
                        Thread.Sleep(200);
                    }
                });
                watcher.IsBackground = true;
                watcher.Start();
                command.WaitForExit();
                output.Join();
                errors.Join();
                var end = new Dictionary<string, object>();
                end["status"] = command.ExitCode;
                SendFrame(EndFrame, Encoding.UTF8.GetBytes(Json.Write(end)));
            }
            connection.EndWriting();
            connection.WaitForHangUp(TimeSpan.FromSeconds(5));
        }

        void Answer(string error)
        {
            var answer = new Dictionary<string, object>();
            answer["ok"] = error == null;
            if (error != null) answer["error"] = error;
            connection.WriteLine(Json.Write(answer));
            if (error != null)
            {
                connection.EndWriting();
                connection.WaitForHangUp(TimeSpan.FromSeconds(5));
            }
        }

        Thread Pump(Stream stream, byte kind)
        {
            var thread = new Thread(delegate()
            {
                var buffer = new byte[64 * 1024];
                try
                {
                    int read;
                    while ((read = stream.Read(buffer, 0, buffer.Length)) > 0)
                    {
                        var piece = new byte[read];
                        Buffer.BlockCopy(buffer, 0, piece, 0, read);
                        SendFrame(kind, piece);
                    }
                }
                catch (Exception)
                {
                }
            });
            thread.IsBackground = true;
            thread.Start();
            return thread;
        }

        void FeedInput(Commands.Running command)
        {
            var header = new byte[5];
            try
            {
                while (true)
                {
                    if (!ReadExactly(header, 5)) break;
                    int length = header[1] << 24 | header[2] << 16 | header[3] << 8 | header[4];
                    if (length < 0 || length > 1024 * 1024) break;
                    var payload = new byte[length];
                    if (!ReadExactly(payload, length)) break;
                    if (header[0] != Input) continue;
                    // An empty input frame says no more is coming.
                    if (length == 0) break;
                    command.Input.Write(payload, 0, length);
                    command.Input.Flush();
                }
            }
            catch (Exception)
            {
            }
            try { command.Input.Close(); } catch (Exception) { }
        }

        bool ReadExactly(byte[] buffer, int count)
        {
            int offset = 0;
            while (offset < count)
            {
                int read = connection.Read(buffer, offset, count - offset);
                if (read == 0) return false;
                offset += read;
            }
            return true;
        }

        void SendFrame(byte kind, byte[] payload)
        {
            var frame = new byte[5 + payload.Length];
            frame[0] = kind;
            frame[1] = (byte)(payload.Length >> 24);
            frame[2] = (byte)(payload.Length >> 16);
            frame[3] = (byte)(payload.Length >> 8);
            frame[4] = (byte)payload.Length;
            Buffer.BlockCopy(payload, 0, frame, 5, payload.Length);
            lock (writeGate) connection.Write(frame, frame.Length);
        }
    }

    /// Starting commands for jobs: as SYSTEM, or as whoever is logged in at the screen, in their session.
    static class Commands
    {
        public sealed class Running : IDisposable
        {
            public Stream Input;
            public Stream Output;
            public Stream Errors;
            public IntPtr Process;
            public IntPtr JobObject;

            public bool HasExited
            {
                get { return Native.WaitForSingleObject(Process, 0) == 0; }
            }

            public void WaitForExit()
            {
                Native.WaitForSingleObject(Process, 0xFFFFFFFF);
            }

            public int ExitCode
            {
                get
                {
                    uint code;
                    Native.GetExitCodeProcess(Process, out code);
                    return (int)code;
                }
            }

            /// Ends the command with everything it started.
            public void Kill()
            {
                Native.TerminateJobObject(JobObject, 1);
            }

            public void Dispose()
            {
                Native.CloseHandle(Process);
                Native.CloseHandle(JobObject);
            }
        }

        static readonly object LaunchGate = new object();

        public static Running Start(Dictionary<string, object> job)
        {
            object value;
            var arguments = job.TryGetValue("arguments", out value) && value is object[]
                ? ((object[])value).Select(argument => Convert.ToString(argument)).ToList()
                : new List<string>();
            if (arguments.Count == 0) throw new ArgumentException("The job doesn't say what to run.");
            string user = Json.String(job, "user");
            string directory = Json.String(job, "directory");
            var environment = job.TryGetValue("environment", out value) ? value as Dictionary<string, object> : null;

            IntPtr token = IntPtr.Zero;
            bool asSystem = string.IsNullOrEmpty(user) ? Sessions.ConsoleUser() == null : IsAdministrator(user);
            if (!asSystem)
            {
                string loggedIn = Sessions.ConsoleUser();
                if (loggedIn == null) throw new InvalidOperationException("Nobody is logged in at the screen to run the command as.");
                if (!string.IsNullOrEmpty(user) && !string.Equals(user, loggedIn, StringComparison.OrdinalIgnoreCase))
                    throw new InvalidOperationException(user + " isn't logged in at the screen. Commands run as whoever is, " + loggedIn + ", or as SYSTEM.");
                token = Sessions.ConsoleUserToken();
                if (directory == null) directory = Sessions.ProfileDirectory(token);
            }
            else if (directory == null)
            {
                // SYSTEM's own folder, as any account's command starts in its home.
                directory = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
            }
            try
            {
                // One at a time: a command started while another's pipes are being handed down would
                // take their ends along, and that one's output wouldn't end until this command does.
                lock (LaunchGate) return Launch(arguments, directory, environment, token);
            }
            finally
            {
                if (token != IntPtr.Zero) Native.CloseHandle(token);
            }
        }

        static bool IsAdministrator(string user)
        {
            var name = user.ToLowerInvariant();
            return name == "root" || name == "system" || name == "nt authority\\system";
        }

        static Running Launch(List<string> arguments, string directory, Dictionary<string, object> extra, IntPtr token)
        {
            SafeFileHandle inputRead, inputWrite, outputRead, outputWrite, errorRead, errorWrite;
            MakePipe(out inputRead, out inputWrite, true);
            MakePipe(out outputRead, out outputWrite, false);
            MakePipe(out errorRead, out errorWrite, false);

            var startup = new Native.StartupInfo();
            startup.Size = Marshal.SizeOf(startup);
            startup.Flags = Native.StartfUseStdHandles;
            startup.StdInput = inputRead.DangerousGetHandle();
            startup.StdOutput = outputWrite.DangerousGetHandle();
            startup.StdError = errorWrite.DangerousGetHandle();
            startup.Desktop = token != IntPtr.Zero ? @"winsta0\default" : null;

            IntPtr environmentBlock = IntPtr.Zero;
            if (token != IntPtr.Zero) Native.CreateEnvironmentBlock(out environmentBlock, token, false);
            string environment = BuildEnvironment(environmentBlock, extra);
            if (environmentBlock != IntPtr.Zero) Native.DestroyEnvironmentBlock(environmentBlock);

            Native.ProcessInformation information;
            string commandLine = string.Join(" ", arguments.Select(Quote));
            uint flags = Native.CreateUnicodeEnvironment | Native.CreateNoWindow | Native.CreateSuspended;
            bool started = token != IntPtr.Zero
                ? Native.CreateProcessAsUser(token, null, new StringBuilder(commandLine), IntPtr.Zero, IntPtr.Zero, true, flags, environment, directory, ref startup, out information)
                : Native.CreateProcess(null, new StringBuilder(commandLine), IntPtr.Zero, IntPtr.Zero, true, flags, environment, directory, ref startup, out information);
            int error = Marshal.GetLastWin32Error();
            inputRead.Dispose();
            outputWrite.Dispose();
            errorWrite.Dispose();
            if (!started)
            {
                inputWrite.Dispose();
                outputRead.Dispose();
                errorRead.Dispose();
                throw new InvalidOperationException("Couldn't run " + arguments[0] + ": " + new Win32Exception(error).Message);
            }
            // Everything the command starts is ended with it when the job is called off.
            IntPtr jobObject = Native.CreateJobObject(IntPtr.Zero, null);
            Native.AssignProcessToJobObject(jobObject, information.Process);
            Native.ResumeThread(information.Thread);
            Native.CloseHandle(information.Thread);
            return new Running
            {
                Input = new FileStream(inputWrite, FileAccess.Write, 4096, false),
                Output = new FileStream(outputRead, FileAccess.Read, 4096, false),
                Errors = new FileStream(errorRead, FileAccess.Read, 4096, false),
                Process = information.Process,
                JobObject = jobObject,
            };
        }

        /// A pipe whose one end the command gets: the reading end for its input, the writing end for
        /// its output.
        static void MakePipe(out SafeFileHandle read, out SafeFileHandle write, bool commandReads)
        {
            var attributes = new Native.SecurityAttributes();
            attributes.Length = Marshal.SizeOf(attributes);
            attributes.InheritHandle = true;
            if (!Native.CreatePipe(out read, out write, ref attributes, 0)) throw new Win32Exception();
            // Only the command's end is handed down.
            Native.SetHandleInformation(commandReads ? write : read, Native.HandleFlagInherit, 0);
        }

        /// The environment block for the command: the account's own, with what the job adds.
        static string BuildEnvironment(IntPtr block, Dictionary<string, object> extra)
        {
            var variables = new SortedDictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            if (block != IntPtr.Zero)
            {
                IntPtr cursor = block;
                while (true)
                {
                    string entry = Marshal.PtrToStringUni(cursor);
                    if (string.IsNullOrEmpty(entry)) break;
                    int equals = entry.IndexOf('=', 1);
                    if (equals > 0) variables[entry.Substring(0, equals)] = entry.Substring(equals + 1);
                    cursor = new IntPtr(cursor.ToInt64() + (entry.Length + 1) * 2);
                }
            }
            else
            {
                foreach (System.Collections.DictionaryEntry entry in Environment.GetEnvironmentVariables())
                    variables[(string)entry.Key] = (string)entry.Value;
            }
            if (extra != null)
            {
                foreach (var pair in extra) variables[pair.Key] = Convert.ToString(pair.Value);
            }
            var text = new StringBuilder();
            foreach (var pair in variables) text.Append(pair.Key).Append('=').Append(pair.Value).Append('\0');
            text.Append('\0');
            return text.ToString();
        }

        /// One argument as the C runtime reads a command line back into arguments.
        public static string Quote(string argument)
        {
            if (argument.Length > 0 && argument.IndexOfAny(new[] { ' ', '\t', '\n', '\v', '"' }) < 0) return argument;
            var quoted = new StringBuilder("\"");
            int backslashes = 0;
            foreach (char character in argument)
            {
                if (character == '\\')
                {
                    backslashes++;
                    continue;
                }
                if (character == '"')
                {
                    quoted.Append('\\', backslashes * 2 + 1);
                }
                else
                {
                    quoted.Append('\\', backslashes);
                }
                backslashes = 0;
                quoted.Append(character);
            }
            quoted.Append('\\', backslashes * 2);
            quoted.Append('"');
            return quoted.ToString();
        }
    }

    static class Sessions
    {
        /// The account logged in at the screen, or `null`.
        public static string ConsoleUser()
        {
            uint session = Native.WTSGetActiveConsoleSessionId();
            if (session == 0xFFFFFFFF) return null;
            IntPtr buffer;
            uint length;
            if (!Native.WTSQuerySessionInformation(IntPtr.Zero, session, 5, out buffer, out length)) return null;
            string name = Marshal.PtrToStringUni(buffer);
            Native.WTSFreeMemory(buffer);
            return string.IsNullOrEmpty(name) ? null : name;
        }

        public static IntPtr ConsoleUserToken()
        {
            IntPtr token;
            if (!Native.WTSQueryUserToken(Native.WTSGetActiveConsoleSessionId(), out token)) throw new Win32Exception();
            IntPtr primary;
            bool duplicated = Native.DuplicateTokenEx(token, 0x02000000, IntPtr.Zero, 2, 1, out primary);
            Native.CloseHandle(token);
            if (!duplicated) throw new Win32Exception();
            return primary;
        }

        public static string ProfileDirectory(IntPtr token)
        {
            var path = new StringBuilder(260);
            uint size = (uint)path.Capacity;
            return Native.GetUserProfileDirectory(token, path, ref size) ? path.ToString() : null;
        }
    }

    // MARK: - The session half

    /// Starts this program as the session half in a session that has none, as the account logged in
    /// there: only the service sees sessions come and go.
    static class SessionStarter
    {
        public static void Ensure(uint session)
        {
            try
            {
                int self = System.Diagnostics.Process.GetCurrentProcess().Id;
                foreach (var running in System.Diagnostics.Process.GetProcessesByName("swiftvm-agent"))
                {
                    if (running.Id != self && running.SessionId == session) return;
                }
                IntPtr token;
                if (!Native.WTSQueryUserToken(session, out token)) return;
                IntPtr primary;
                bool duplicated = Native.DuplicateTokenEx(token, 0x02000000, IntPtr.Zero, 2, 1, out primary);
                Native.CloseHandle(token);
                if (!duplicated) return;
                try
                {
                    IntPtr environment;
                    Native.CreateEnvironmentBlock(out environment, primary, false);
                    var startup = new Native.StartupInfo();
                    startup.Size = Marshal.SizeOf(startup);
                    startup.Desktop = @"winsta0\default";
                    string program = System.Reflection.Assembly.GetExecutingAssembly().Location;
                    Native.ProcessInformation information;
                    if (Native.CreateProcessAsUser(primary, null, new StringBuilder("\"" + program + "\" --session"), IntPtr.Zero, IntPtr.Zero, false,
                        Native.CreateUnicodeEnvironment | Native.CreateNoWindow, environment, null, ref startup, out information))
                    {
                        Native.CloseHandle(information.Thread);
                        Native.CloseHandle(information.Process);
                    }
                    else
                    {
                        Log.Write("couldn't start the session half in session {0}: {1}", session, new Win32Exception().Message);
                    }
                    if (environment != IntPtr.Zero) Native.DestroyEnvironmentBlock(environment);
                }
                finally
                {
                    Native.CloseHandle(primary);
                }
            }
            catch (Exception error)
            {
                Log.Write("session half: {0}", error.Message);
            }
        }
    }

    /// The service's end of the pipe to the session half, which owns the clipboard of whoever is
    /// logged in.
    class SessionLink
    {
        public static SessionLink Current;
        readonly Agent agent;
        readonly object gate = new object();
        StreamWriter writer;
        bool hasClipboardToFill;
        bool seamless;
        Dictionary<string, object> displaySize;
        readonly Dictionary<long, ManualResetEvent> waiting = new Dictionary<long, ManualResetEvent>();
        readonly Dictionary<long, bool> answers = new Dictionary<long, bool>();
        long nextRequest = 1;

        public SessionLink(Agent agent)
        {
            this.agent = agent;
            Current = this;
        }

        public bool HasClipboardToFill
        {
            get { lock (gate) return hasClipboardToFill; }
        }

        /// Whether the half in the session of whoever is logged in is there.
        public bool IsConnected
        {
            get { lock (gate) return writer != null; }
        }

        public void Start()
        {
            var thread = new Thread(Serve);
            thread.IsBackground = true;
            thread.Start();
        }

        void Serve()
        {
            while (true)
            {
                try
                {
                    // Only someone who is logged in may connect, and only SYSTEM serves.
                    var security = new PipeSecurity();
                    security.AddAccessRule(new PipeAccessRule(new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null), PipeAccessRights.FullControl, AccessControlType.Allow));
                    security.AddAccessRule(new PipeAccessRule(new SecurityIdentifier(WellKnownSidType.InteractiveSid, null), PipeAccessRights.ReadWrite, AccessControlType.Allow));
                    // Asynchronous at both ends: Windows has a write on a synchronous handle wait for the
                    // read that is pending on it, and the line to the Mac would wait with it until the
                    // session next says something.
                    using (var pipe = new NamedPipeServerStream(Program.SessionPipe, PipeDirection.InOut, 1, PipeTransmissionMode.Byte,
                        PipeOptions.Asynchronous, 64 * 1024, 64 * 1024, security))
                    {
                        pipe.WaitForConnection();
                        if (!IsOurs(pipe)) continue;
                        var reader = new StreamReader(pipe, new UTF8Encoding(false));
                        lock (gate)
                        {
                            writer = new StreamWriter(pipe, new UTF8Encoding(false));
                            writer.AutoFlush = true;
                            if (displaySize != null) Send(displaySize);
                            if (seamless) Send(SeamlessMessage(true));
                        }
                        // Someone who has just logged in gets the Mac's shared folders as a drive.
                        string share, letter;
                        if (SharedFolders.Pending(out share, out letter))
                        {
                            var map = new Dictionary<string, object>();
                            map["type"] = "map-drive";
                            map["location"] = share;
                            map["drive"] = letter;
                            Send(map);
                        }
                        string line;
                        while ((line = reader.ReadLine()) != null) Handle(Json.Read(line));
                    }
                }
                catch (Exception error)
                {
                    Log.Write("session link: {0}", error.Message);
                    Thread.Sleep(1000);
                }
                lock (gate) writer = null;
                // A session half that ended while its session goes on, as in a crash, starts again.
                ThreadPool.QueueUserWorkItem(delegate
                {
                    Thread.Sleep(3000);
                    uint console = Native.WTSGetActiveConsoleSessionId();
                    if (console != 0xFFFFFFFF) SessionStarter.Ensure(console);
                });
            }
        }

        /// Whether the program at the other end is this one, started for the session at the screen: the
        /// Mac's clipboard is for whoever sits there.
        static bool IsOurs(NamedPipeServerStream pipe)
        {
            uint pid, session;
            if (!Native.GetNamedPipeClientProcessId(pipe.SafePipeHandle, out pid)) return false;
            if (!Native.ProcessIdToSessionId(pid, out session) || session != Native.WTSGetActiveConsoleSessionId()) return false;
            try
            {
                string path = System.Diagnostics.Process.GetProcessById((int)pid).MainModule.FileName;
                return string.Equals(Path.GetFullPath(path), Path.GetFullPath(System.Reflection.Assembly.GetExecutingAssembly().Location), StringComparison.OrdinalIgnoreCase);
            }
            catch (Exception)
            {
                return false;
            }
        }

        void Handle(Dictionary<string, object> message)
        {
            switch (Json.String(message, "type"))
            {
                case "clipboard":
                    agent.GuestCopied(Json.String(message, "text") ?? "");
                    break;
                case "clipboard-request":
                    lock (gate) hasClipboardToFill = true;
                    agent.SessionWantsClipboard();
                    break;
                case "windows":
                case "hit":
                    agent.WindowsChanged(message);
                    break;
                case "result":
                    long id = Json.Number(message, "id") ?? 0;
                    lock (gate)
                    {
                        ManualResetEvent done;
                        if (waiting.TryGetValue(id, out done))
                        {
                            answers[id] = message.ContainsKey("ok") && Equals(message["ok"], true);
                            done.Set();
                        }
                    }
                    break;
            }
        }

        public void SetClipboard(string text)
        {
            var message = new Dictionary<string, object>();
            message["type"] = "clipboard";
            message["text"] = text;
            lock (gate) hasClipboardToFill = false;
            Send(message);
        }

        /// Has the session half map a WebDAV location to a drive, and says whether it did.
        public bool MapDrive(string location, string letter)
        {
            var message = new Dictionary<string, object>();
            message["type"] = "map-drive";
            message["location"] = location;
            message["drive"] = letter;
            return Ask(message, TimeSpan.FromSeconds(60));
        }

        public void SetDisplaySize(long width, long height, double scale)
        {
            if (!DisplayFollower.ValidRequest(width, height, scale)) return;
            var message = new Dictionary<string, object>();
            message["type"] = "display-size";
            message["width"] = width;
            message["height"] = height;
            message["scale"] = scale;
            // Keep the latest request across logon and session-pipe reconnection. No reply is
            // needed: a mode change must not hold up clipboard, commands or the host connection.
            lock (gate)
            {
                displaySize = message;
                Send(message);
            }
        }

        /// Has the session half report the windows on the screen, or stop. Kept across logon and
        /// session-pipe reconnection, like the display's size.
        public void SetSeamless(bool enabled)
        {
            lock (gate)
            {
                seamless = enabled;
                Send(SeamlessMessage(enabled));
            }
        }

        static Dictionary<string, object> SeamlessMessage(bool enabled)
        {
            var message = new Dictionary<string, object>();
            message["type"] = "seamless";
            message["enabled"] = enabled;
            return message;
        }

        /// Passes on what the Mac asks of a window: to bring it forward, to say what is at a point of it, or
        /// to move or resize it. Only the numbers these take go on.
        public void PassOn(string type, Dictionary<string, object> fromMac)
        {
            var message = new Dictionary<string, object>();
            message["type"] = type;
            foreach (string key in new[] { "window", "request", "x", "y", "width", "height" })
            {
                long? value = Json.Number(fromMac, key);
                if (value != null) message[key] = value.Value;
            }
            Send(message);
        }

        public bool ResizeDisplay(int width, int height)
        {
            var message = new Dictionary<string, object>();
            message["type"] = "resize-display";
            message["width"] = width;
            message["height"] = height;
            return Ask(message, TimeSpan.FromSeconds(5));
        }

        bool Ask(Dictionary<string, object> message, TimeSpan patience)
        {
            long id;
            using (var done = new ManualResetEvent(false))
            {
                lock (gate)
                {
                    id = nextRequest++;
                    waiting[id] = done;
                }
                try
                {
                    message["id"] = id;
                    if (!Send(message)) return false;
                    done.WaitOne(patience);
                    lock (gate)
                    {
                        bool ok;
                        return answers.TryGetValue(id, out ok) && ok;
                    }
                }
                finally
                {
                    lock (gate)
                    {
                        waiting.Remove(id);
                        answers.Remove(id);
                    }
                }
            }
        }

        bool Send(Dictionary<string, object> message)
        {
            lock (gate)
            {
                if (writer == null) return false;
                try
                {
                    writer.WriteLine(Json.Write(message));
                    return true;
                }
                catch (Exception)
                {
                    return false;
                }
            }
        }
    }

    /// Runs in the session of whoever is logged in: shares their clipboard, maps the shared folders as a
    /// drive of theirs, and has the display follow the Mac's window.
    static class SessionHalf
    {
        static StreamWriter writer;
        static readonly object writeGate = new object();
        static string lastFromMac;

        public static int Run()
        {
            bool isFirst;
            using (new Mutex(true, "Local\\SwiftVMAgentSession", out isFirst))
            {
                if (!isFirst) return 0;
                Native.SetProcessDpiAwarenessContext(new IntPtr(-4));
                // From a session half that ended in Seamless Mode.
                try { WindowWatcher.Restore(); } catch (Exception) { }
                var window = new ClipboardWindow();
                var thread = new Thread(delegate() { Talk(window); });
                thread.IsBackground = true;
                thread.Start();
                var display = new Thread(DisplayFollower.Run);
                display.IsBackground = true;
                display.Start();
                Application.Run();
            }
            return 0;
        }

        static void Talk(ClipboardWindow window)
        {
            bool askedForClipboard = false;
            while (true)
            {
                try
                {
                    using (var pipe = new NamedPipeClientStream(".", Program.SessionPipe, PipeDirection.InOut, PipeOptions.Asynchronous))
                    {
                        pipe.Connect(5000);
                        var reader = new StreamReader(pipe, new UTF8Encoding(false));
                        lock (writeGate)
                        {
                            writer = new StreamWriter(pipe, new UTF8Encoding(false));
                            writer.AutoFlush = true;
                        }
                        // Someone who has just logged in has nothing from the Mac yet.
                        if (!askedForClipboard)
                        {
                            askedForClipboard = true;
                            var request = new Dictionary<string, object>();
                            request["type"] = "clipboard-request";
                            Send(request);
                        }
                        string line;
                        while ((line = reader.ReadLine()) != null)
                        {
                            var message = Json.Read(line);
                            switch (Json.String(message, "type"))
                            {
                                case "clipboard":
                                    // Windows' own line breaks, which is what its clipboard hands back.
                                    string text = (Json.String(message, "text") ?? "").Replace("\r\n", "\n").Replace("\n", "\r\n");
                                    lastFromMac = text;
                                    window.Set(text);
                                    break;
                                case "map-drive":
                                    var answer = new Dictionary<string, object>();
                                    answer["type"] = "result";
                                    answer["id"] = Json.Number(message, "id") ?? 0;
                                    answer["ok"] = MapDrive(Json.String(message, "location"), Json.String(message, "drive"));
                                    Send(answer);
                                    break;
                                case "display-size":
                                    DisplayFollower.Request(Json.Number(message, "width") ?? 0,
                                        Json.Number(message, "height") ?? 0, Json.RealNumber(message, "scale") ?? 0);
                                    break;
                                case "seamless":
                                    WindowWatcher.SetEnabled(Json.Flag(message, "enabled"));
                                    break;
                                case "activate-window":
                                    WindowWatcher.Activate(Json.Number(message, "window") ?? 0);
                                    break;
                                case "hit-test":
                                    WindowWatcher.HitTest(Json.Number(message, "request") ?? 0, Json.Number(message, "window") ?? 0,
                                        (int)(Json.Number(message, "x") ?? 0), (int)(Json.Number(message, "y") ?? 0));
                                    break;
                                case "move-window":
                                    WindowWatcher.Move(Json.Number(message, "window") ?? 0,
                                        (int)(Json.Number(message, "x") ?? 0), (int)(Json.Number(message, "y") ?? 0));
                                    break;
                                case "resize-window":
                                    WindowWatcher.Resize(Json.Number(message, "window") ?? 0,
                                        (int)(Json.Number(message, "x") ?? 0), (int)(Json.Number(message, "y") ?? 0),
                                        (int)(Json.Number(message, "width") ?? 0), (int)(Json.Number(message, "height") ?? 0));
                                    break;
                                case "resize-display":
                                    var resized = new Dictionary<string, object>();
                                    resized["type"] = "result";
                                    resized["id"] = Json.Number(message, "id") ?? 0;
                                    resized["ok"] = DisplayFollower.Resize((int)(Json.Number(message, "width") ?? 0),
                                        (int)(Json.Number(message, "height") ?? 0));
                                    Send(resized);
                                    break;
                            }
                        }
                    }
                }
                catch (Exception)
                {
                }
                lock (writeGate) writer = null;
                // A service that comes back asks again if the Mac still wants the windows. One that
                // was updated or restarted meanwhile may never say that it doesn't.
                WindowWatcher.SetEnabled(false);
                Thread.Sleep(2000);
            }
        }

        static bool MapDrive(string location, string drive)
        {
            if (string.IsNullOrEmpty(location) || string.IsNullOrEmpty(drive)) return false;
            Run("net.exe", "use " + drive + " /delete /y");
            // Not persistent: the address is the Mac's for as long as the app runs, and the agent maps
            // it anew at every logon.
            int status = Run("net.exe", "use " + drive + " " + Commands.Quote(location) + " /persistent:no");
            return status == 0;
        }

        static int Run(string program, string arguments)
        {
            var process = System.Diagnostics.Process.Start(new ProcessStartInfo(program, arguments) { UseShellExecute = false, CreateNoWindow = true });
            process.WaitForExit();
            return process.ExitCode;
        }

        public static void Copied(string text)
        {
            // What the Mac just put there isn't news to the Mac.
            if (text == lastFromMac) return;
            var message = new Dictionary<string, object>();
            message["type"] = "clipboard";
            message["text"] = text.Replace("\r\n", "\n");
            Send(message);
        }

        public static void Send(Dictionary<string, object> message)
        {
            lock (writeGate)
            {
                if (writer == null) return;
                try { writer.WriteLine(Json.Write(message)); } catch (Exception) { }
            }
        }

        /// A window that is never shown, which Windows tells when the clipboard changes.
        class ClipboardWindow : NativeWindow
        {
            const int ClipboardUpdate = 0x031D;
            readonly SynchronizationContext context;

            public ClipboardWindow()
            {
                CreateHandle(new CreateParams { Parent = new IntPtr(-3) });
                Native.AddClipboardFormatListener(Handle);
                context = new WindowsFormsSynchronizationContext();
            }

            public void Set(string text)
            {
                context.Post(delegate
                {
                    try
                    {
                        if (string.IsNullOrEmpty(text)) Clipboard.Clear();
                        else Clipboard.SetText(text);
                    }
                    catch (Exception)
                    {
                    }
                }, null);
            }

            protected override void WndProc(ref Message message)
            {
                if (message.Msg == ClipboardUpdate)
                {
                    try
                    {
                        if (Clipboard.ContainsText()) Copied(Clipboard.GetText());
                    }
                    catch (Exception)
                    {
                    }
                }
                base.WndProc(ref message);
            }
        }
    }

    /// Reports the windows on the screen, front to back, while the Mac asks for them: it shows each in a
    /// window of its own. Meanwhile windows may take the whole screen, for the taskbar isn't shown there:
    /// it is set to hide itself, which gives windows its room, and is hidden besides, as it would
    /// otherwise come up over the part of a window that is behind it.
    ///
    /// Windows' animations are off meanwhile, as its own setting for them does: a window that slides or
    /// fades in or out does so where the Mac has no window for it, and the Mac follows a window once it
    /// has stopped.
    ///
    /// Nor is the desktop: behind every window there is a backdrop instead, of a black the Mac shows as
    /// nothing at all. What is uncovered before the Mac hears of it, as where a window has just closed,
    /// is see-through there rather than black. Windows' own panels, as Start, are larger than what they
    /// draw, for room to slide in or for a shadow, and what is behind them shows there. Where that is the
    /// backdrop, the panel's edges are where black ends, and the Mac is told of the panel alone.
    ///
    /// Windows says when a window opens, closes, moves, changes its title or comes to the front, and the
    /// list goes out at once, ahead of the picture it goes with, which the Mac waits for to show both.
    /// It is looked at now and then besides, for what Windows doesn't say, and often while a panel's
    /// edges move, which Windows doesn't say either.
    static class WindowWatcher
    {
        const int Interval = 500;
        const int SettlingInterval = 30;
        const int MostWindows = 64;
        const int MostTitle = 200;
        const int DwmExtendedFrameBounds = 9, DwmCloaked = 14;
        const long Caption = 0x00C00000, SizingBorder = 0x00040000, Transparent = 0x20, Layered = 0x80000, NoRedirectionBitmap = 0x200000;
        const uint GetTaskbarState = 0x4, SetTaskbarState = 0xA, AutoHide = 0x1;
        const int TitleBar = 2;
        const int NoRegion = 0, EmptyRegion = 1;
        /// The most room a panel leaves around itself, in pixels at 100%. More black than that is the
        /// panel's own, as a video's.
        const int MostMargin = 40;
        /// The window classes of the shell's own windows: Windows' Start menu, search and notifications
        /// are of the last, and so are the full-screen ones they put behind themselves, which only catch
        /// a click elsewhere to close them.
        const string ShellWindow = "Windows.UI.Core.CoreWindow";
        static readonly string[] Hidden = { "Progman", "WorkerW", "Shell_TrayWnd", "Shell_SecondaryTrayWnd" };
        static readonly object Gate = new object();
        static readonly AutoResetEvent changed = new AutoResetEvent(false);
        static bool enabled;
        static Thread thread;
        static Thread listener;
        /// Kept, as Windows calls it for as long as the hooks are there.
        static Native.WinEventCallback onEvent;
        static string last;
        /// Says that the taskbar was made to hide itself here, and is to stop once Seamless Mode is over:
        /// after a restart of the agent too, which may have ended in the middle of it.
        static readonly string AutoHideMark = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "SwiftVM", "taskbar-hidden-by-swiftvm");
        /// Says that animations were turned off here, and which were on before.
        static readonly string AnimationsMark = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "SwiftVM", "animations-off-by-swiftvm");
        const uint GetAnimation = 0x48, SetAnimation = 0x49, GetClientAreaAnimation = 0x1042, SetClientAreaAnimation = 0x1043;
        const uint SaveSetting = 0x1, SendChange = 0x2;
        /// The taskbar, and the desktop with its icons, which are hidden while the Mac shows the windows.
        static readonly string[] Shell = { "Shell_TrayWnd", "Shell_SecondaryTrayWnd", "Progman" };
        static readonly List<IntPtr> hiddenShell = new List<IntPtr>();
        static Backdrop backdrop;
        /// Put right behind a panel for a moment, to find its edges where a window is behind it.
        static Backdrop probe;
        /// How far in from each side panels draw, by their class and title, as found when nothing but the
        /// backdrop was behind them: left, top, right, bottom.
        static readonly Dictionary<string, int[]> margins = new Dictionary<string, int[]>();
        /// What was found of each panel on the screen the last time.
        static Dictionary<IntPtr, int[]> found = new Dictionary<IntPtr, int[]>();
        /// A panel's edges have just moved: the screen is looked at again soon.
        static bool settling;

        public static void SetEnabled(bool on)
        {
            lock (Gate)
            {
                enabled = on;
                // A Mac that asks again has forgotten what it was told.
                last = null;
                changed.Set();
                if (on && listener == null)
                {
                    var ready = new ManualResetEvent(false);
                    listener = new Thread(delegate() { Listen(ready); });
                    listener.IsBackground = true;
                    listener.Start();
                    ready.WaitOne();
                }
                // A watcher that isn't running has nothing to put back.
                if (thread != null || !on) return;
                thread = new Thread(Run);
                thread.IsBackground = true;
                thread.Start();
            }
        }

        static void Run()
        {
            while (true)
            {
                bool on;
                lock (Gate) on = enabled;
                try
                {
                    if (on)
                    {
                        HideShell();
                        AutoHideTaskbar();
                        TurnOffAnimations();
                        ShowBackdrop();
                        // At once, ahead of the picture with the change, which the Mac waits for to show
                        // the two together. QEMU sends a picture as soon as Windows has drawn it.
                        Report();
                        // Panels as drawn: their edges are found in the picture.
                        Native.DwmFlush();
                        Report();
                    }
                    else
                    {
                        HideBackdrop();
                        ShowShell();
                        RestoreTaskbar();
                        RestoreAnimations();
                        lock (Gate)
                        {
                            if (!enabled)
                            {
                                thread = null;
                                return;
                            }
                        }
                    }
                }
                catch (Exception error)
                {
                    Log.Write("windows: {0}", error.Message);
                }
                changed.WaitOne(settling ? SettlingInterval : Interval);
            }
        }

        /// Hears from Windows when a window changes, for as long as the session half runs. Windows tells
        /// the thread that asked, between the messages it waits for. The backdrop is that thread's too.
        static void Listen(ManualResetEvent ready)
        {
            try
            {
                backdrop = new Backdrop();
                probe = new Backdrop();
            }
            catch (Exception error)
            {
                Log.Write("backdrop: {0}", error.Message);
            }
            onEvent = delegate(IntPtr hook, uint kind, IntPtr window, int item, int child, uint eventThread, uint time)
            {
                // The windows themselves, not the parts of them, nor the pointer, which moves all along.
                if (item == 0 && child == 0 && enabled) changed.Set();
            };
            const uint OutOfContext = 0, SkipOwnProcess = 2;
            // From a window coming to the front to one being restored, and from one being made to its
            // being uncloaked: Start and the like are cloaked, not hidden, when they close.
            Native.SetWinEventHook(0x0003, 0x0017, IntPtr.Zero, onEvent, 0, 0, OutOfContext | SkipOwnProcess);
            Native.SetWinEventHook(0x8000, 0x8018, IntPtr.Zero, onEvent, 0, 0, OutOfContext | SkipOwnProcess);
            ready.Set();
            Native.Message message;
            while (Native.GetMessage(out message, IntPtr.Zero, 0, 0) > 0)
            {
                Native.TranslateMessage(ref message);
                Native.DispatchMessage(ref message);
            }
        }

        static void Report()
        {
            var windows = new List<Dictionary<string, object>>();
            IntPtr foreground = Native.GetForegroundWindow();
            int width = Native.GetSystemMetrics(0), height = Native.GetSystemMetrics(1);
            // Front to back. Unlike EnumWindows, this has the shell's own windows too, as Start.
            var order = new List<IntPtr>();
            IntPtr window = IntPtr.Zero;
            while ((window = Native.FindWindowEx(IntPtr.Zero, window, null, null)) != IntPtr.Zero) order.Add(window);
            var screen = new Screen(order);
            var panels = new Dictionary<IntPtr, int[]>();
            bool isSettling = false, isPastBackdrop = false;
            Native.Rect? focus = null;
            for (int index = 0; index < order.Count && windows.Count < MostWindows; index++)
            {
                window = order[index];
                if (IsOwn(window))
                {
                    isPastBackdrop = isPastBackdrop || (backdrop != null && window == backdrop.Handle);
                    continue;
                }
                Native.Rect seen;
                var described = Describe(window, foreground, width, height, out seen);
                if (described == null)
                {
                    // The keyboard's window shows nothing of itself, as Start's search box until something
                    // is typed in it: the window it is over has the keyboard, as far as the Mac can tell.
                    if (window == foreground && seen.Right > seen.Left) focus = seen;
                    continue;
                }
                if (IsPanel(window) && !isPastBackdrop)
                {
                    int[] inset = Panel(window, described, screen, index, ref seen);
                    panels[window] = inset;
                    int[] before;
                    if (!found.TryGetValue(window, out before) || !before.SequenceEqual(inset)) isSettling = true;
                }
                if (focus.HasValue && Contains(seen, (focus.Value.Left + focus.Value.Right) / 2, (focus.Value.Top + focus.Value.Bottom) / 2))
                {
                    described["focused"] = true;
                    focus = null;
                }
                // Someone put a window at the very back, where the backdrop hides it in Windows.
                if (isPastBackdrop)
                {
                    backdrop.Cover(0, 0, width, height, Backdrop.Bottom);
                    isPastBackdrop = false;
                    isSettling = true;
                }
                windows.Add(described);
            }
            found = panels;
            settling = isSettling;
            var message = new Dictionary<string, object>();
            message["type"] = "windows";
            message["width"] = width;
            message["height"] = height;
            message["windows"] = windows.Cast<object>().ToList();
            string encoded = Json.Write(message);
            lock (Gate)
            {
                if (!enabled || encoded == last) return;
                last = encoded;
            }
            SessionHalf.Send(message);
        }

        /// What the Mac is told of a window, or null for one that isn't to be seen: hidden, minimized,
        /// cloaked as the Start menu is while it is closed, or part of the desktop and the taskbar.
        /// `seen` is the part of the screen it takes, as far as it is known.
        static Dictionary<string, object> Describe(IntPtr window, IntPtr foreground, int screenWidth, int screenHeight, out Native.Rect seen)
        {
            seen = new Native.Rect();
            if (!Native.IsWindowVisible(window) || Native.IsIconic(window)) return null;
            int cloaked;
            if (Native.DwmGetWindowAttribute(window, DwmCloaked, out cloaked, sizeof(int)) == 0 && cloaked != 0) return null;
            string kind = ClassOf(window);
            if (Hidden.Contains(kind)) return null;
            long extended = Native.GetWindowLongPtr(window, -20).ToInt64();
            // Drawn over everything without taking a click: nothing to show in a window.
            if ((extended & (Transparent | Layered)) == (Transparent | Layered)) return null;
            // Without the shadow and the frame Windows 10 and 11 draw around it, which aren't its own.
            Native.Rect rect, outer;
            if (!Native.GetWindowRect(window, out outer)) return null;
            if (Native.DwmGetWindowAttribute(window, DwmExtendedFrameBounds, out rect, Marshal.SizeOf(typeof(Native.Rect))) != 0) rect = outer;
            // Only the part of it a region leaves, as Start's: the rest of it is as large as the screen.
            Native.Rect shape;
            int region = Native.GetWindowRgnBox(window, out shape);
            if (region == EmptyRegion)
            {
                seen = rect;
                return null;
            }
            if (region != NoRegion)
            {
                rect.Left = Math.Max(rect.Left, outer.Left + shape.Left);
                rect.Top = Math.Max(rect.Top, outer.Top + shape.Top);
                rect.Right = Math.Min(rect.Right, outer.Left + shape.Right);
                rect.Bottom = Math.Min(rect.Bottom, outer.Top + shape.Bottom);
            }
            int width = rect.Right - rect.Left, height = rect.Bottom - rect.Top;
            if (width < 2 || height < 2) return null;
            // A shell window as large as the screen, but for the taskbar's place, is all but see-through.
            if (kind == ShellWindow && width >= screenWidth * 9 / 10 && height >= screenHeight * 9 / 10) return null;
            seen = rect;
            long style = Native.GetWindowLongPtr(window, -16).ToInt64();
            var title = new StringBuilder(MostTitle + 1);
            Native.GetWindowText(window, title, title.Capacity);
            var described = new Dictionary<string, object>();
            described["id"] = window.ToInt64();
            described["title"] = title.ToString();
            described["x"] = rect.Left;
            described["y"] = rect.Top;
            described["width"] = width;
            described["height"] = height;
            described["popup"] = (style & Caption) != Caption;
            described["resizable"] = (style & Caption) == Caption && (style & SizingBorder) != 0;
            described["maximized"] = Native.IsZoomed(window);
            described["focused"] = window == foreground;
            return described;
        }

        /// A window without a frame that is drawn by composition, or with see-through pixels of its own:
        /// one that may leave room around what it draws.
        static bool IsPanel(IntPtr window)
        {
            long style = Native.GetWindowLongPtr(window, -16).ToInt64();
            long extended = Native.GetWindowLongPtr(window, -20).ToInt64();
            return (style & Caption) != Caption && (extended & (NoRedirectionBitmap | Layered)) != 0;
        }

        /// Narrows what the Mac is told of a panel to what it draws, and says how far in from each side
        /// that is. A side with another window behind it, rather than the backdrop, is as far in as it
        /// was found to be before. Failing that, black is put right behind it for a moment to find out.
        static int[] Panel(IntPtr window, Dictionary<string, object> described, Screen screen, int index, ref Native.Rect rect)
        {
            int most = MostMargin * (int)Native.GetDpiForWindow(window) / 96;
            int[] inset = screen.Margins(rect, index, most);
            string key = ClassOf(window) + "|" + described["title"];
            int[] known;
            bool isKnown = margins.TryGetValue(key, out known);
            if (inset.Contains(-1))
            {
                if (!isKnown && probe != null)
                {
                    known = Measure(window, rect, most);
                    margins[key] = known;
                    isKnown = true;
                }
                for (int side = 0; side < 4; side++)
                {
                    if (inset[side] == -1) inset[side] = isKnown ? known[side] : 0;
                }
            }
            else
            {
                int[] before;
                // The same twice over: it isn't sliding in, as it would if someone turned animations on.
                if (found.TryGetValue(window, out before) && before.SequenceEqual(inset)) margins[key] = inset;
            }
            if (inset[0] + inset[2] < rect.Right - rect.Left - 1 && inset[1] + inset[3] < rect.Bottom - rect.Top - 1)
            {
                rect.Left += inset[0];
                rect.Top += inset[1];
                rect.Right -= inset[2];
                rect.Bottom -= inset[3];
                described["x"] = rect.Left;
                described["y"] = rect.Top;
                described["width"] = rect.Right - rect.Left;
                described["height"] = rect.Bottom - rect.Top;
            }
            return inset;
        }

        static bool Contains(Native.Rect rect, int x, int y)
        {
            return x >= rect.Left && x < rect.Right && y >= rect.Top && y < rect.Bottom;
        }

        /// The screen as it is drawn, and the windows on it, to find where panels draw.
        class Screen
        {
            readonly List<Native.Rect> shown = new List<Native.Rect>();
            readonly List<int> places = new List<int>();

            public Screen(List<IntPtr> order)
            {
                for (int index = 0; index < order.Count; index++)
                {
                    IntPtr window = order[index];
                    // Nothing behind the backdrop is seen.
                    if (backdrop != null && window == backdrop.Handle) break;
                    if (IsOwn(window) || !Native.IsWindowVisible(window) || Native.IsIconic(window)) continue;
                    int cloaked;
                    if (Native.DwmGetWindowAttribute(window, DwmCloaked, out cloaked, sizeof(int)) == 0 && cloaked != 0) continue;
                    Native.Rect rect;
                    if (!Native.GetWindowRect(window, out rect) || rect.Right <= rect.Left || rect.Bottom <= rect.Top) continue;
                    shown.Add(rect);
                    places.Add(index);
                }
            }

            /// How far in from each side of a window black ends, along the middle of that side: left, top,
            /// right, bottom. -1 for a side where another window is behind, which hides the backdrop.
            public int[] Margins(Native.Rect rect, int index, int most)
            {
                int width = rect.Right - rect.Left, height = rect.Bottom - rect.Top;
                int middleX = rect.Left + width / 2, middleY = rect.Top + height / 2;
                int[] across = Pixels.Read(rect.Left, middleY, width, 1);
                int[] down = Pixels.Read(middleX, rect.Top, 1, height);
                return new[]
                {
                    Margin(across, 0, 1, most, rect.Left, middleY, index),
                    Margin(down, 0, 1, most, middleX, rect.Top, index),
                    Margin(across, width - 1, -1, most, rect.Right - 1, middleY, index),
                    Margin(down, height - 1, -1, most, middleX, rect.Bottom - 1, index),
                };
            }

            int Margin(int[] line, int from, int step, int most, int x, int y, int index)
            {
                if (line == null) return 0;
                if (!Pixels.IsBlack(line[from])) return IsBehind(x, y, index) ? -1 : 0;
                return Pixels.Margin(line, from, step, most);
            }

            /// Whether a window behind the one at `index` takes this point of the screen.
            bool IsBehind(int x, int y, int index)
            {
                for (int i = 0; i < shown.Count; i++)
                {
                    if (places[i] > index && Contains(shown[i], x, y)) return true;
                }
                return false;
            }
        }

        /// Reads what is drawn on the screen.
        static class Pixels
        {
            /// A part of the screen, row by row, as 0xRRGGBB. Null if it can't be read.
            public static int[] Read(int x, int y, int width, int height)
            {
                if (width <= 0 || height <= 0) return null;
                IntPtr screen = Native.GetDC(IntPtr.Zero);
                if (screen == IntPtr.Zero) return null;
                IntPtr memory = Native.CreateCompatibleDC(screen);
                var header = new Native.BitmapInfoHeader();
                header.Size = (uint)Marshal.SizeOf(typeof(Native.BitmapInfoHeader));
                header.Width = width;
                // From the top down.
                header.Height = -height;
                header.Planes = 1;
                header.BitCount = 32;
                IntPtr bits;
                IntPtr bitmap = Native.CreateDIBSection(screen, ref header, 0, out bits, IntPtr.Zero, 0);
                try
                {
                    if (memory == IntPtr.Zero || bitmap == IntPtr.Zero) return null;
                    IntPtr previous = Native.SelectObject(memory, bitmap);
                    const uint SourceCopy = 0x00CC0020;
                    bool copied = Native.BitBlt(memory, 0, 0, width, height, screen, x, y, SourceCopy);
                    Native.SelectObject(memory, previous);
                    if (!copied) return null;
                    var pixels = new int[width * height];
                    Marshal.Copy(bits, pixels, 0, pixels.Length);
                    return pixels;
                }
                finally
                {
                    if (bitmap != IntPtr.Zero) Native.DeleteObject(bitmap);
                    if (memory != IntPtr.Zero) Native.DeleteDC(memory);
                    Native.ReleaseDC(IntPtr.Zero, screen);
                }
            }

            /// The backdrop's black, and black, as a shadow's over it.
            public static bool IsBlack(int pixel)
            {
                return ((pixel >> 16) & 0xFF) <= 2 && ((pixel >> 8) & 0xFF) <= 2 && (pixel & 0xFF) <= 2;
            }

            /// How much black there is from one end of a line inward. None if there is more than `most`, or
            /// nothing but black: then it is what the window draws.
            public static int Margin(int[] line, int from, int step, int most)
            {
                int count = 0;
                for (int i = from; i >= 0 && i < line.Length && IsBlack(line[i]); i += step)
                {
                    if (++count > most) return 0;
                }
                return count;
            }
        }

        /// A window behind every other, in place of the desktop, of the black the Mac shows as nothing:
        /// red and blue 1, which pictures all but never have. Its picture is handed to Windows as it is
        /// shown, without waiting to be drawn.
        class Backdrop : NativeWindow
        {
            const int Popup = unchecked((int)0x80000000);
            const int ToolWindow = 0x80, LayeredWindow = 0x80000, NoActivate = 0x08000000;
            const uint NoSize = 0x1, NoMove = 0x2, NoActivateWindow = 0x10, ShowWindow = 0x40;
            public static readonly IntPtr Bottom = new IntPtr(1);
            /// Red 1, green 0, blue 1, as Windows writes a colour.
            const uint Clear = 0x010001;
            Native.Rect covered;

            public Backdrop()
            {
                var parameters = new CreateParams();
                parameters.Style = Popup;
                // Not in the taskbar, nor in Alt-Tab, and never given the keyboard.
                parameters.ExStyle = ToolWindow | LayeredWindow | NoActivate;
                CreateHandle(parameters);
            }

            public bool Covers(int width, int height)
            {
                return Native.IsWindowVisible(Handle) && covered.Left == 0 && covered.Top == 0
                    && covered.Right == width && covered.Bottom == height;
            }

            /// Shows it over a part of the screen, right behind a window, or behind every one.
            public void Cover(int x, int y, int width, int height, IntPtr behind)
            {
                var rect = new Native.Rect { Left = x, Top = y, Right = x + width, Bottom = y + height };
                if (!Native.IsWindowVisible(Handle) || covered.Left != rect.Left || covered.Top != rect.Top
                    || covered.Right != rect.Right || covered.Bottom != rect.Bottom)
                {
                    Fill(rect);
                }
                Native.SetWindowPos(Handle, behind, 0, 0, 0, 0, NoMove | NoSize | NoActivateWindow | ShowWindow);
            }

            public void Hide()
            {
                Native.ShowWindow(Handle, 0);
            }

            /// Gives Windows a black picture of the window, as large as it is to be, where it is to be.
            void Fill(Native.Rect rect)
            {
                int width = rect.Right - rect.Left, height = rect.Bottom - rect.Top;
                IntPtr screen = Native.GetDC(IntPtr.Zero);
                IntPtr memory = Native.CreateCompatibleDC(screen);
                var header = new Native.BitmapInfoHeader();
                header.Size = (uint)Marshal.SizeOf(typeof(Native.BitmapInfoHeader));
                header.Width = width;
                header.Height = -height;
                header.Planes = 1;
                header.BitCount = 32;
                IntPtr bits;
                IntPtr bitmap = Native.CreateDIBSection(screen, ref header, 0, out bits, IntPtr.Zero, 0);
                IntPtr brush = Native.CreateSolidBrush(Clear);
                try
                {
                    IntPtr previous = Native.SelectObject(memory, bitmap);
                    var all = new Native.Rect { Right = width, Bottom = height };
                    Native.FillRect(memory, ref all, brush);
                    var place = new Native.Point { X = rect.Left, Y = rect.Top };
                    var size = new Native.Size { Width = width, Height = height };
                    var origin = new Native.Point();
                    // Without the see-through its pixels' alpha, all nothing, would make it.
                    const uint Opaque = 0x4;
                    uint blend = 0x00FF0000;
                    if (Native.UpdateLayeredWindow(Handle, screen, ref place, ref size, memory, ref origin, 0, ref blend, Opaque)) covered = rect;
                    Native.SelectObject(memory, previous);
                }
                finally
                {
                    if (brush != IntPtr.Zero) Native.DeleteObject(brush);
                    if (bitmap != IntPtr.Zero) Native.DeleteObject(bitmap);
                    if (memory != IntPtr.Zero) Native.DeleteDC(memory);
                    Native.ReleaseDC(IntPtr.Zero, screen);
                }
            }

            protected override void WndProc(ref Message message)
            {
                const int MouseActivate = 0x21, NoActivateOnClick = 3;
                if (message.Msg == MouseActivate)
                {
                    message.Result = new IntPtr(NoActivateOnClick);
                    return;
                }
                base.WndProc(ref message);
            }
        }

        /// How far in from each side a panel draws, with black right behind it for a moment.
        static int[] Measure(IntPtr panel, Native.Rect rect, int most)
        {
            int width = rect.Right - rect.Left, height = rect.Bottom - rect.Top;
            try
            {
                probe.Cover(rect.Left, rect.Top, width, height, panel);
                Native.DwmFlush();
                int[] across = Pixels.Read(rect.Left, rect.Top + height / 2, width, 1);
                int[] down = Pixels.Read(rect.Left + width / 2, rect.Top, 1, height);
                if (across == null || down == null) return new int[4];
                return new[]
                {
                    Pixels.Margin(across, 0, 1, most), Pixels.Margin(down, 0, 1, most),
                    Pixels.Margin(across, width - 1, -1, most), Pixels.Margin(down, height - 1, -1, most),
                };
            }
            finally
            {
                probe.Hide();
            }
        }

        /// The backdrop, and what finds a panel's edges.
        static bool IsOwn(IntPtr window)
        {
            return (backdrop != null && window == backdrop.Handle) || (probe != null && window == probe.Handle);
        }

        static string ClassOf(IntPtr window)
        {
            var kind = new StringBuilder(256);
            Native.GetClassName(window, kind, kind.Capacity);
            return kind.ToString();
        }

        static void ShowBackdrop()
        {
            if (backdrop == null) return;
            int width = Native.GetSystemMetrics(0), height = Native.GetSystemMetrics(1);
            if (!backdrop.Covers(width, height)) backdrop.Cover(0, 0, width, height, Backdrop.Bottom);
        }

        static void HideBackdrop()
        {
            if (backdrop != null) backdrop.Hide();
            margins.Clear();
            found.Clear();
            settling = false;
        }

        /// Brings a window to the front, as clicking it would. Windows lets only the program that has
        /// the keyboard hand it on: this one borrows that program's input for the moment.
        public static void Activate(long id)
        {
            IntPtr window = new IntPtr(id);
            if (id == 0 || !Native.IsWindow(window)) return;
            IntPtr foreground = Native.GetForegroundWindow();
            if (window == foreground) return;
            uint current = Native.GetCurrentThreadId();
            uint owner = foreground == IntPtr.Zero ? 0 : Native.GetWindowThreadProcessId(foreground, IntPtr.Zero);
            bool attached = owner != 0 && owner != current && Native.AttachThreadInput(current, owner, true);
            try
            {
                if (Native.IsIconic(window)) Native.ShowWindow(window, 9);
                Native.BringWindowToTop(window);
                Native.SetForegroundWindow(window);
            }
            finally
            {
                if (attached) Native.AttachThreadInput(current, owner, false);
            }
        }

        /// Says whether a click at a point would take hold of the title bar of a window, which the Mac
        /// then moves itself. Windows asks the window under the point, as it does for a click, so that a
        /// title bar an app draws itself counts too.
        public static void HitTest(long request, long id, int x, int y)
        {
            string area = "other";
            try
            {
                var point = new Native.Point { X = x, Y = y };
                IntPtr target = Native.WindowFromPoint(point);
                if (target != IntPtr.Zero && Native.GetAncestor(target, 2) == new IntPtr(id))
                {
                    IntPtr hit;
                    var where = new IntPtr((y << 16) | (x & 0xFFFF));
                    // Not for long: a click waits on the answer, and an app that hangs gets the click as it is.
                    const uint AbortIfHung = 0x2;
                    if (Native.SendMessageTimeout(target, 0x84, IntPtr.Zero, where, AbortIfHung, 100, out hit) != IntPtr.Zero
                        && hit.ToInt64() == TitleBar)
                    {
                        area = "caption";
                    }
                }
            }
            catch (Exception error)
            {
                Log.Write("hit test: {0}", error.Message);
            }
            var message = new Dictionary<string, object>();
            message["type"] = "hit";
            message["request"] = request;
            message["area"] = area;
            SessionHalf.Send(message);
        }

        /// Moves a window so that its top left corner, without the frame Windows draws around it, is at a
        /// point of the screen: where it was dropped on the Mac.
        public static void Move(long id, int x, int y)
        {
            IntPtr window = new IntPtr(id);
            if (id == 0 || !Native.IsWindow(window) || Native.IsZoomed(window)) return;
            Native.Rect outer, frame;
            if (!Native.GetWindowRect(window, out outer)) return;
            if (Native.DwmGetWindowAttribute(window, DwmExtendedFrameBounds, out frame, Marshal.SizeOf(typeof(Native.Rect))) != 0) frame = outer;
            const uint NoSize = 0x1, NoZOrder = 0x4, NoActivate = 0x10;
            Native.SetWindowPos(window, IntPtr.Zero, outer.Left + x - frame.Left, outer.Top + y - frame.Top, 0, 0,
                NoSize | NoZOrder | NoActivate);
        }

        /// Moves a window and gives it a size, both without the frame Windows draws around it: as it was
        /// resized on the Mac. Windows keeps it as large as the window wants to be at the least.
        public static void Resize(long id, int x, int y, int width, int height)
        {
            IntPtr window = new IntPtr(id);
            if (id == 0 || width <= 0 || height <= 0 || !Native.IsWindow(window) || Native.IsZoomed(window)) return;
            Native.Rect outer, frame;
            if (!Native.GetWindowRect(window, out outer)) return;
            if (Native.DwmGetWindowAttribute(window, DwmExtendedFrameBounds, out frame, Marshal.SizeOf(typeof(Native.Rect))) != 0) frame = outer;
            int left = frame.Left - outer.Left, top = frame.Top - outer.Top;
            int right = outer.Right - frame.Right, bottom = outer.Bottom - frame.Bottom;
            const uint NoZOrder = 0x4, NoActivate = 0x10;
            Native.SetWindowPos(window, IntPtr.Zero, x - left, y - top, width + left + right, height + top + bottom, NoZOrder | NoActivate);
        }

        /// Hides the taskbar and the desktop, again whenever Explorer shows them anew: it starts again
        /// after a crash.
        static void HideShell()
        {
            foreach (string kind in Shell)
            {
                IntPtr window = Native.FindWindow(kind, null);
                if (window == IntPtr.Zero || !Native.IsWindowVisible(window)) continue;
                Native.ShowWindow(window, 0);
                if (!hiddenShell.Contains(window)) hiddenShell.Add(window);
            }
        }

        static void ShowShell()
        {
            foreach (IntPtr window in hiddenShell)
            {
                if (Native.IsWindow(window)) Native.ShowWindow(window, 5);
            }
            hiddenShell.Clear();
        }

        /// Has the taskbar hide itself, as Windows' own setting for it does, so that maximized windows
        /// take the whole screen. A taskbar that is merely hidden keeps its room on the screen.
        static void AutoHideTaskbar()
        {
            IntPtr state = TaskbarState(GetTaskbarState, 0);
            if ((state.ToInt64() & AutoHide) != 0) return;
            Directory.CreateDirectory(Path.GetDirectoryName(AutoHideMark));
            File.WriteAllText(AutoHideMark, "");
            TaskbarState(SetTaskbarState, state.ToInt64() | AutoHide);
        }

        /// Puts back the taskbar and the desktop, from a session half that ended in Seamless Mode: Windows
        /// hides neither itself.
        public static void Restore()
        {
            foreach (string kind in Shell)
            {
                IntPtr window = Native.FindWindow(kind, null);
                if (window != IntPtr.Zero && !Native.IsWindowVisible(window)) Native.ShowWindow(window, 5);
            }
            RestoreTaskbar();
            RestoreAnimations();
        }

        /// Turns off the animations of what windows draw, as Start sliding in, and of windows being
        /// minimized and maximized: the switch for animation effects in Windows' settings.
        static void TurnOffAnimations()
        {
            if (File.Exists(AnimationsMark)) return;
            int drawn = 0;
            Native.SystemParametersInfo(GetClientAreaAnimation, 0, ref drawn, 0);
            var windows = new Native.AnimationInfo { Size = (uint)Marshal.SizeOf(typeof(Native.AnimationInfo)) };
            Native.SystemParametersInfo(GetAnimation, windows.Size, ref windows, 0);
            if (drawn == 0 && windows.MinAnimate == 0) return;
            Directory.CreateDirectory(Path.GetDirectoryName(AnimationsMark));
            File.WriteAllText(AnimationsMark, drawn + " " + windows.MinAnimate);
            // Saved, as programs that hear of the change read it from there.
            if (drawn != 0) Native.SystemParametersInfo(SetClientAreaAnimation, 0, IntPtr.Zero, SaveSetting | SendChange);
            if (windows.MinAnimate != 0)
            {
                windows.MinAnimate = 0;
                Native.SystemParametersInfo(SetAnimation, windows.Size, ref windows, SaveSetting | SendChange);
            }
        }

        /// Turns the animations that were on back on, if it was this agent that turned them off.
        static void RestoreAnimations()
        {
            if (!File.Exists(AnimationsMark)) return;
            string[] were = File.ReadAllText(AnimationsMark).Split(' ');
            File.Delete(AnimationsMark);
            if (were.Length != 2) return;
            if (were[0] != "0") Native.SystemParametersInfo(SetClientAreaAnimation, 0, new IntPtr(1), SaveSetting | SendChange);
            if (were[1] != "0")
            {
                var windows = new Native.AnimationInfo { Size = (uint)Marshal.SizeOf(typeof(Native.AnimationInfo)), MinAnimate = 1 };
                Native.SystemParametersInfo(SetAnimation, windows.Size, ref windows, SaveSetting | SendChange);
            }
        }

        /// Has the taskbar stay again, if it was this agent that had it hide itself.
        static void RestoreTaskbar()
        {
            if (!File.Exists(AutoHideMark)) return;
            IntPtr state = TaskbarState(GetTaskbarState, 0);
            TaskbarState(SetTaskbarState, state.ToInt64() & ~AutoHide);
            File.Delete(AutoHideMark);
        }

        static IntPtr TaskbarState(uint message, long state)
        {
            var data = new Native.AppBarData();
            data.Size = (uint)Marshal.SizeOf(typeof(Native.AppBarData));
            data.Window = Native.FindWindow("Shell_TrayWnd", null);
            data.LParam = new IntPtr(state);
            return Native.SHAppBarMessage(message, ref data);
        }
    }

    /// Makes the display the size the Mac's window asks for. QEMU hands that size to the display driver,
    /// Red Hat's viogpudo, which offers it as a mode, but only a program in the session at the screen
    /// can have Windows switch to it. Red Hat's own helper for this looks at the first display device
    /// only, which here is Windows' basic one.
    static class DisplayFollower
    {
        const string VirtioGPU = "VEN_1AF4&DEV_1050";
        const ushort GetCustomResolution = 1;
        static readonly object ModeGate = new object();
        static readonly object RequestGate = new object();
        static readonly AutoResetEvent Changed = new AutoResetEvent(false);
        static int requestedWidth, requestedHeight;
        static double requestedScale;
        static long generation;

        public static bool ValidRequest(long width, long height, double scale)
        {
            return width >= 320 && width <= 16384 && height >= 200 && height <= 16384
                && !double.IsNaN(scale) && !double.IsInfinity(scale) && scale >= 1 && scale <= 5;
        }

        public static void Request(long width, long height, double scale)
        {
            if (!ValidRequest(width, height, scale)) return;
            lock (RequestGate)
            {
                requestedWidth = (int)width;
                requestedHeight = (int)height;
                requestedScale = scale;
                generation++;
            }
            Changed.Set();
        }

        public static bool Resize(int width, int height)
        {
            if (width < 320 || width > 16384 || height < 200 || height > 16384) return false;
            // The host updates the GPU's modes before forwarding the SPICE request. Windows may
            // still be handling that device notification when the request reaches the session.
            for (int attempt = 0; attempt < 10; attempt++)
            {
                // Once the host sends scale-aware requests, they take precedence over the
                // legacy SPICE channel, whose messages can arrive in a different order.
                lock (RequestGate)
                {
                    if (requestedWidth != 0 && (requestedWidth != width || requestedHeight != height)) return false;
                }
                string display = FindDisplay();
                var switched = display == null ? SwitchResult.Unavailable : Switch(display, width, height);
                if (switched == SwitchResult.Switched) return true;
                if (switched == SwitchResult.Substituted) return false;
                Thread.Sleep(100);
            }
            return false;
        }

        public static void Run()
        {
            int lastWidth = 0, lastHeight = 0, failures = 0;
            long handled = 0, sized = 0, attempted = 0;
            while (true)
            {
                try
                {
                    int width, height;
                    double scale;
                    long request;
                    lock (RequestGate)
                    {
                        width = requestedWidth;
                        height = requestedHeight;
                        scale = requestedScale;
                        request = generation;
                    }
                    if (attempted != request) { attempted = request; failures = 0; }
                    string display = FindDisplay();
                    if (width != 0)
                    {
                        if (request != handled)
                        {
                            bool applied = false, abandoned = false;
                            lock (ModeGate)
                            {
                                if (display != null)
                                {
                                    if (sized != request)
                                    {
                                        var switched = Switch(display, width, height);
                                        if (switched == SwitchResult.Switched) sized = request;
                                        // Windows put another raster in its place, and it was put back. Trying
                                        // again would only flip the mode back and forth until the host asks anew.
                                        else if (switched == SwitchResult.Substituted) abandoned = true;
                                    }
                                    // A DPI retry must not undo a size subsequently chosen in Windows.
                                    if (sized == request)
                                    {
                                        var scaled = SetScale(display, width, height, scale);
                                        applied = scaled != ScaleResult.Retry;
                                        if (applied) Log.Write("display {0}x{1} at {2}x: scale {3}", width, height, scale, scaled);
                                    }
                                }
                            }
                            if (abandoned) Log.Write("display {0}x{1}: Windows put another size in its place", width, height);
                            if (applied || abandoned) { handled = request; failures = 0; }
                            else failures++;
                        }
                    }
                    else if (display != null && AskedSize(display, out width, out height)
                        && (width != lastWidth || height != lastHeight))
                    {
                        // Older hosts send only the driver's custom mode. After a successful
                        // change, leave a size chosen in Windows alone until the host asks anew.
                        // A substituted size is let go of the same way, so the mode doesn't flip.
                        if (Switch(display, width, height) != SwitchResult.Unavailable)
                        {
                            lastWidth = width;
                            lastHeight = height;
                            failures = 0;
                        }
                        else failures++;
                    }
                }
                catch (Exception)
                {
                    failures++;
                }
                // Mode enumeration can lag the request by more than a few seconds. A size that isn't
                // on offer yet is never marked as handled; back off, and let a new request wake us.
                Changed.WaitOne(failures >= 10 ? 2000 : 500);
            }
        }

        /// The name of the display that viogpudo drives, such as \\.\DISPLAY2, if it is on.
        static string FindDisplay()
        {
            for (int index = 0; ; index++)
            {
                var device = new Native.DisplayDevice();
                device.Size = Marshal.SizeOf(typeof(Native.DisplayDevice));
                if (!Native.EnumDisplayDevices(null, index, ref device, 0)) return null;
                bool isOn = (device.StateFlags & Native.DisplayDeviceAttachedToDesktop) != 0;
                if (isOn && device.DeviceID != null && device.DeviceID.Contains(VirtioGPU)) return device.DeviceName;
            }
        }

        /// The size the driver was last asked for, which it says when asked through its private escape.
        static bool AskedSize(string display, out int width, out int height)
        {
            width = 0;
            height = 0;
            var adapter = new Native.OpenAdapterFromDisplayName { DeviceName = display };
            if (Native.D3DKMTOpenAdapterFromGdiDisplayName(ref adapter) != 0) return false;
            // The 3D driver validates the whole escape union, including its larger resource-info
            // requests, even when this request only uses the four-byte resolution member.
            const int escapeSize = 128;
            IntPtr data = Marshal.AllocHGlobal(escapeSize);
            try
            {
                for (int index = 0; index < escapeSize; index++) Marshal.WriteByte(data, index, 0);
                // VIOGPU_ESCAPE: its type, the length of what follows, and the width and height.
                Marshal.WriteInt16(data, 0, (short)GetCustomResolution);
                Marshal.WriteInt16(data, 2, 4);
                Marshal.WriteInt32(data, 4, 0);
                var escape = new Native.Escape { Adapter = adapter.Adapter, PrivateDriverData = data, PrivateDriverDataSize = escapeSize };
                if (Native.D3DKMTEscape(ref escape) != 0) return false;
                width = (ushort)Marshal.ReadInt16(data, 4);
                height = (ushort)Marshal.ReadInt16(data, 6);
                return width > 0 && height > 0;
            }
            finally
            {
                Marshal.FreeHGlobal(data);
                var closing = new Native.CloseAdapter { Adapter = adapter.Adapter };
                Native.D3DKMTCloseAdapter(ref closing);
            }
        }

        /// What became of a request for a size: Windows shows it, it isn't on offer (yet), or Windows
        /// applied another raster in its place, which was undone.
        enum SwitchResult { Switched, Unavailable, Substituted }

        static SwitchResult Switch(string display, int width, int height)
        {
            lock (ModeGate)
            {
                var adapter = new Native.OpenAdapterFromDisplayName { DeviceName = display };
                if (Native.D3DKMTOpenAdapterFromGdiDisplayName(ref adapter) != 0) return SwitchResult.Unavailable;
                var closing = new Native.CloseAdapter { Adapter = adapter.Adapter };
                Native.D3DKMTCloseAdapter(ref closing);
                Native.DisplayPath[] paths;
                Native.DisplayConfigMode[] modes;
                if (!Configuration(out paths, out modes)) return SwitchResult.Unavailable;
                int path = FindPath(paths, adapter);
                if (path < 0 || paths[path].Source.ModeIndex >= modes.Length) return SwitchResult.Unavailable;
                if (IsSize(paths[path], modes, width, height)) return SwitchResult.Switched;
                var previousPaths = (Native.DisplayPath[])paths.Clone();
                var previousModes = (Native.DisplayConfigMode[])modes.Clone();
                uint source = paths[path].Source.ModeIndex;
                if (modes[source].Type != 1) return SwitchResult.Unavailable;
                modes[source].Source.Width = (uint)width;
                modes[source].Source.Height = (uint)height;
                // A connected monitor's custom mode can change without a hotplug notification.
                // Refresh WDDM's mode list and select a matching target raster; keeping the old
                // target merely scales the desktop and loses Retina detail.
                paths[path].Target.ModeIndex = uint.MaxValue;
                uint flags = Native.DisplayApply | Native.DisplayUseSupplied | Native.DisplayForceEnumeration | Native.DisplaySave;
                int result = Native.SetDisplayConfig((uint)paths.Length, paths, (uint)modes.Length, modes, flags);
                int offeredWidth, offeredHeight;
                if (result == 1610 && AskedSize(display, out offeredWidth, out offeredHeight)
                    && offeredWidth == width && offeredHeight == height)
                {
                    // WDDM may need to reconcile timing with its cached monitor modes. Only allow
                    // this for the driver's current offer, and never accept a substituted raster.
                    result = Native.SetDisplayConfig((uint)paths.Length, paths, (uint)modes.Length, modes,
                        flags | Native.DisplayAllowChanges);
                }
                if (result != 0) return SwitchResult.Unavailable;
                if (Configuration(out paths, out modes))
                {
                    path = FindPath(paths, adapter);
                    if (path >= 0 && IsSize(paths[path], modes, width, height)) return SwitchResult.Switched;
                }
                Native.SetDisplayConfig((uint)previousPaths.Length, previousPaths, (uint)previousModes.Length, previousModes,
                    Native.DisplayApply | Native.DisplayUseSupplied | Native.DisplaySave);
                return SwitchResult.Substituted;
            }
        }

        enum ScaleResult { Applied, Unsupported, Retry }

        static ScaleResult ScaleFailure(int error)
        {
            return error == 50 || error == 87 ? ScaleResult.Unsupported : ScaleResult.Retry;
        }

        static ScaleResult SetScale(string display, int width, int height, double scale)
        {
            var adapter = new Native.OpenAdapterFromDisplayName { DeviceName = display };
            if (Native.D3DKMTOpenAdapterFromGdiDisplayName(ref adapter) != 0) return ScaleResult.Retry;
            var closing = new Native.CloseAdapter { Adapter = adapter.Adapter };
            Native.D3DKMTCloseAdapter(ref closing);
            Native.DisplayPath[] paths;
            Native.DisplayConfigMode[] modes;
            if (!Configuration(out paths, out modes)) return ScaleResult.Retry;
            int path = FindPath(paths, adapter);
            // The raster was applied already. A later choice in Windows is not ours to undo.
            if (path < 0 || !IsSize(paths[path], modes, width, height)) return ScaleResult.Unsupported;

            // Windows' per-monitor DPI requests use steps relative to the recommended scale,
            // not percentages. These native request types are not in the public SDK; if Windows
            // rejects them, leave the user's DPI alone rather than editing global registry values.
            var dpi = new Native.DisplayDpiScale();
            dpi.Header.Type = -3;
            dpi.Header.Size = (uint)Marshal.SizeOf(typeof(Native.DisplayDpiScale));
            dpi.Header.Adapter = paths[path].Source.Adapter;
            dpi.Header.Id = paths[path].Source.Id;
            int error = Native.DisplayConfigGetDeviceInfo(ref dpi);
            if (error != 0) return ScaleFailure(error);
            int[] scales = { 100, 125, 150, 175, 200, 225, 250, 300, 350, 400, 450, 500 };
            if (dpi.Minimum > 0 || dpi.Minimum <= -scales.Length) return ScaleResult.Unsupported;
            int recommended = -dpi.Minimum;
            int desired = 0;
            for (int index = 1; index < scales.Length; index++)
                if (Math.Abs(scales[index] - scale * 100) < Math.Abs(scales[desired] - scale * 100)) desired = index;
            int relative = desired - recommended;
            if (relative < dpi.Minimum || relative > dpi.Maximum) return ScaleResult.Unsupported;
            if (dpi.Current == relative) return ScaleResult.Applied;
            var setting = new Native.DisplayDpiScaleSet();
            setting.Header = dpi.Header;
            setting.Header.Type = -4;
            setting.Header.Size = (uint)Marshal.SizeOf(typeof(Native.DisplayDpiScaleSet));
            setting.Scale = relative;
            error = Native.DisplayConfigSetDeviceInfo(ref setting);
            if (error != 0) return ScaleFailure(error);
            error = Native.DisplayConfigGetDeviceInfo(ref dpi);
            if (error != 0) return ScaleFailure(error);
            return dpi.Current == relative ? ScaleResult.Applied : ScaleResult.Retry;
        }

        static int FindPath(Native.DisplayPath[] paths, Native.OpenAdapterFromDisplayName adapter)
        {
            return Array.FindIndex(paths, delegate(Native.DisplayPath path)
            {
                return path.Source.Id == adapter.VidPnSourceId && path.Source.Adapter.Low == adapter.AdapterLuid.Low
                    && path.Source.Adapter.High == adapter.AdapterLuid.High;
            });
        }

        static bool IsSize(Native.DisplayPath path, Native.DisplayConfigMode[] modes, int width, int height)
        {
            if (path.Source.ModeIndex >= modes.Length || path.Target.ModeIndex >= modes.Length) return false;
            var source = modes[path.Source.ModeIndex];
            var target = modes[path.Target.ModeIndex];
            // The display-only driver doesn't say what its target shows. The source's size is what is shown then.
            bool unspecified = target.Target.ActiveWidth == uint.MaxValue && target.Target.ActiveHeight == uint.MaxValue;
            return source.Type == 1 && target.Type == 2 && source.Source.Width == width && source.Source.Height == height
                && (unspecified || (target.Target.ActiveWidth == width && target.Target.ActiveHeight == height));
        }

        static bool Configuration(out Native.DisplayPath[] paths, out Native.DisplayConfigMode[] modes)
        {
            paths = null;
            modes = null;
            for (int attempt = 0; attempt < 3; attempt++)
            {
                uint pathCount, modeCount;
                if (Native.GetDisplayConfigBufferSizes(Native.DisplayActivePaths, out pathCount, out modeCount) != 0) return false;
                paths = new Native.DisplayPath[pathCount];
                modes = new Native.DisplayConfigMode[modeCount];
                int result = Native.QueryDisplayConfig(Native.DisplayActivePaths, ref pathCount, paths, ref modeCount, modes, IntPtr.Zero);
                if (result == 122) continue; // The topology changed between sizing and querying.
                if (result != 0) return false;
                Array.Resize(ref paths, (int)pathCount);
                Array.Resize(ref modes, (int)modeCount);
                return true;
            }
            return false;
        }
    }

    // MARK: - Windows

    static class Native
    {
        public const uint GenericRead = 0x80000000, GenericWrite = 0x40000000, OpenExisting = 3, FileFlagOverlapped = 0x40000000;
        public const uint TokenAdjustPrivileges = 0x20, TokenQuery = 0x8, SePrivilegeEnabled = 0x2;
        public const uint ShutdownForceOthers = 0x1, ShutdownPowerOff = 0x8, ShutdownGraceOverride = 0x20;
        public const int StartfUseStdHandles = 0x100;
        public const uint CreateUnicodeEnvironment = 0x400, CreateNoWindow = 0x08000000, CreateSuspended = 0x4;
        public const uint HandleFlagInherit = 1;
        public const int DisplayDeviceAttachedToDesktop = 0x1;
        public const uint DisplayActivePaths = 0x2, DisplayApply = 0x80, DisplayUseSupplied = 0x20;
        public const uint DisplaySave = 0x200, DisplayAllowChanges = 0x400, DisplayForceEnumeration = 0x1000;

        [StructLayout(LayoutKind.Sequential)]
        public struct Rect
        {
            public int Left, Top, Right, Bottom;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct AppBarData
        {
            public uint Size;
            public IntPtr Window;
            public uint CallbackMessage, Edge;
            public Rect Bounds;
            public IntPtr LParam;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct Point
        {
            public int X, Y;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct AnimationInfo
        {
            public uint Size;
            public int MinAnimate;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct Size
        {
            public int Width, Height;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct BitmapInfoHeader
        {
            public uint Size;
            public int Width, Height;
            public ushort Planes, BitCount;
            public uint Compression, SizeImage;
            public int XPelsPerMeter, YPelsPerMeter;
            public uint ClrUsed, ClrImportant;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct Message
        {
            public IntPtr Window;
            public uint Kind;
            public IntPtr WParam, LParam;
            public uint Time;
            public Point Where;
        }

        public delegate void WinEventCallback(IntPtr hook, uint kind, IntPtr window, int item, int child, uint thread, uint time);

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        public struct DisplayDevice
        {
            public int Size;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string DeviceName;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceString;
            public int StateFlags;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceID;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceKey;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct DisplayDeviceInfoHeader
        {
            public int Type;
            public uint Size;
            public Luid Adapter;
            public uint Id;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct DisplayDpiScale
        {
            public DisplayDeviceInfoHeader Header;
            public int Minimum, Current, Maximum;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct DisplayDpiScaleSet
        {
            public DisplayDeviceInfoHeader Header;
            public int Scale;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct DisplaySourcePath
        {
            public Luid Adapter;
            public uint Id, ModeIndex, Status;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct DisplayTargetPath
        {
            public Luid Adapter;
            public uint Id, ModeIndex, Technology, Rotation, Scaling, RefreshNumerator, RefreshDenominator;
            public uint ScanlineOrdering, Available, Status;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct DisplayPath
        {
            public DisplaySourcePath Source;
            public DisplayTargetPath Target;
            public uint Flags;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct DisplaySourceMode
        {
            public uint Width, Height, PixelFormat;
            public int X, Y;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct DisplayTargetMode
        {
            public ulong PixelRate;
            public uint HorizontalNumerator, HorizontalDenominator, VerticalNumerator, VerticalDenominator;
            public uint ActiveWidth, ActiveHeight, TotalWidth, TotalHeight, VideoStandard, ScanlineOrdering;
        }

        // DISPLAYCONFIG_MODE_INFO contains a 48-byte union. Preserve target timing fields while
        // changing a source mode; all members are blittable on both Windows ARM64 and x64.
        [StructLayout(LayoutKind.Explicit, Size = 64)]
        public struct DisplayConfigMode
        {
            [FieldOffset(0)] public uint Type;
            [FieldOffset(4)] public uint Id;
            [FieldOffset(8)] public Luid Adapter;
            [FieldOffset(16)] public DisplaySourceMode Source;
            [FieldOffset(16)] public DisplayTargetMode Target;
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        public struct OpenAdapterFromDisplayName
        {
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string DeviceName;
            public uint Adapter;
            public Luid AdapterLuid;
            public uint VidPnSourceId;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct Escape
        {
            public uint Adapter, Device;
            /// D3DKMT_ESCAPE_DRIVERPRIVATE is 0.
            public int Type;
            public uint Flags;
            public IntPtr PrivateDriverData;
            public uint PrivateDriverDataSize;
            public uint Context;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct CloseAdapter
        {
            public uint Adapter;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct SystemTime
        {
            public ushort Year, Month, DayOfWeek, Day, Hour, Minute, Second, Milliseconds;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct Luid
        {
            public uint Low;
            public int High;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct TokenPrivileges
        {
            public uint Count;
            public Luid Luid;
            public uint Attributes;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct SecurityAttributes
        {
            public int Length;
            public IntPtr Descriptor;
            public bool InheritHandle;
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        public struct StartupInfo
        {
            public int Size;
            public string Reserved;
            public string Desktop;
            public string Title;
            public int X, Y, Width, Height, CountX, CountY, FillAttribute, Flags;
            public short ShowWindow, Reserved2;
            public IntPtr Reserved3, StdInput, StdOutput, StdError;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct ProcessInformation
        {
            public IntPtr Process, Thread;
            public int ProcessId, ThreadId;
        }

        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        public static extern SafeFileHandle CreateFile(string name, uint access, uint share, IntPtr security, uint disposition, uint flags, IntPtr template);

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool SetSystemTime(ref SystemTime time);

        [DllImport("kernel32.dll")]
        public static extern IntPtr GetCurrentProcess();

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool CloseHandle(IntPtr handle);

        [DllImport("advapi32.dll", SetLastError = true)]
        public static extern bool OpenProcessToken(IntPtr process, uint access, out IntPtr token);

        [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        public static extern bool LookupPrivilegeValue(string system, string name, out Luid luid);

        [DllImport("advapi32.dll", SetLastError = true)]
        public static extern bool AdjustTokenPrivileges(IntPtr token, bool disableAll, ref TokenPrivileges state, uint length, IntPtr previous, IntPtr returnLength);

        [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        public static extern uint InitiateShutdown(string machine, string message, uint grace, uint flags, uint reason);

        [DllImport("icu.dll", CharSet = CharSet.Unicode)]
        public static extern int ucal_getWindowsTimeZoneID(string id, int length, StringBuilder windowsID, int capacity, ref int status);

        [DllImport("kernel32.dll")]
        public static extern uint WTSGetActiveConsoleSessionId();

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool ProcessIdToSessionId(uint process, out uint session);

        [DllImport("wtsapi32.dll", SetLastError = true)]
        public static extern bool WTSQueryUserToken(uint session, out IntPtr token);

        [DllImport("wtsapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        public static extern bool WTSQuerySessionInformation(IntPtr server, uint session, int infoClass, out IntPtr buffer, out uint length);

        [DllImport("wtsapi32.dll")]
        public static extern void WTSFreeMemory(IntPtr memory);

        [DllImport("advapi32.dll", SetLastError = true)]
        public static extern bool DuplicateTokenEx(IntPtr token, uint access, IntPtr attributes, int impersonation, int type, out IntPtr duplicate);

        [DllImport("userenv.dll", SetLastError = true)]
        public static extern bool CreateEnvironmentBlock(out IntPtr environment, IntPtr token, bool inherit);

        [DllImport("userenv.dll", SetLastError = true)]
        public static extern bool DestroyEnvironmentBlock(IntPtr environment);

        [DllImport("userenv.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        public static extern bool GetUserProfileDirectory(IntPtr token, StringBuilder path, ref uint size);

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool CreatePipe(out SafeFileHandle read, out SafeFileHandle write, ref SecurityAttributes attributes, uint size);

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool SetHandleInformation(SafeFileHandle handle, uint mask, uint flags);

        [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        public static extern bool CreateProcessAsUser(IntPtr token, string application, StringBuilder commandLine, IntPtr processAttributes, IntPtr threadAttributes, bool inherit, uint flags, string environment, string directory, ref StartupInfo startup, out ProcessInformation information);

        [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        public static extern bool CreateProcessAsUser(IntPtr token, string application, StringBuilder commandLine, IntPtr processAttributes, IntPtr threadAttributes, bool inherit, uint flags, IntPtr environment, string directory, ref StartupInfo startup, out ProcessInformation information);

        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        public static extern bool CreateProcess(string application, StringBuilder commandLine, IntPtr processAttributes, IntPtr threadAttributes, bool inherit, uint flags, string environment, string directory, ref StartupInfo startup, out ProcessInformation information);

        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        public static extern IntPtr CreateJobObject(IntPtr attributes, string name);

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool TerminateJobObject(IntPtr job, uint code);

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern uint ResumeThread(IntPtr thread);

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool GetExitCodeProcess(IntPtr process, out uint code);

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool GetNamedPipeClientProcessId(SafePipeHandle pipe, out uint pid);

        [DllImport("user32.dll", SetLastError = true)]
        public static extern bool AddClipboardFormatListener(IntPtr window);

        [DllImport("user32.dll", CharSet = CharSet.Unicode, EntryPoint = "FindWindowExW")]
        public static extern IntPtr FindWindowEx(IntPtr parent, IntPtr after, string className, string title);

        [DllImport("user32.dll")]
        public static extern IntPtr SetWinEventHook(uint first, uint last, IntPtr module, WinEventCallback callback,
            uint process, uint thread, uint flags);

        [DllImport("user32.dll", EntryPoint = "GetMessageW")]
        public static extern int GetMessage(out Message message, IntPtr window, uint first, uint last);

        [DllImport("user32.dll")]
        public static extern bool TranslateMessage(ref Message message);

        [DllImport("user32.dll", EntryPoint = "DispatchMessageW")]
        public static extern IntPtr DispatchMessage(ref Message message);

        [DllImport("user32.dll")]
        public static extern IntPtr WindowFromPoint(Point point);

        [DllImport("user32.dll")]
        public static extern IntPtr GetAncestor(IntPtr window, uint kind);

        [DllImport("user32.dll", EntryPoint = "SendMessageTimeoutW")]
        public static extern IntPtr SendMessageTimeout(IntPtr window, uint message, IntPtr wParam, IntPtr lParam,
            uint flags, uint timeout, out IntPtr result);

        [DllImport("user32.dll")]
        public static extern bool SetWindowPos(IntPtr window, IntPtr after, int x, int y, int width, int height, uint flags);

        [DllImport("dwmapi.dll")]
        public static extern int DwmFlush();

        [DllImport("user32.dll")]
        public static extern bool IsWindow(IntPtr window);

        [DllImport("user32.dll")]
        public static extern bool IsWindowVisible(IntPtr window);

        [DllImport("user32.dll")]
        public static extern bool IsIconic(IntPtr window);

        [DllImport("user32.dll")]
        public static extern bool IsZoomed(IntPtr window);

        [DllImport("user32.dll", CharSet = CharSet.Unicode, EntryPoint = "GetClassNameW")]
        public static extern int GetClassName(IntPtr window, StringBuilder name, int capacity);

        [DllImport("user32.dll", CharSet = CharSet.Unicode, EntryPoint = "GetWindowTextW")]
        public static extern int GetWindowText(IntPtr window, StringBuilder text, int capacity);

        [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")]
        public static extern IntPtr GetWindowLongPtr(IntPtr window, int index);

        [DllImport("user32.dll")]
        public static extern bool GetWindowRect(IntPtr window, out Rect rect);

        [DllImport("user32.dll")]
        public static extern int GetWindowRgnBox(IntPtr window, out Rect rect);

        [DllImport("user32.dll", EntryPoint = "SystemParametersInfoW")]
        public static extern bool SystemParametersInfo(uint action, uint size, ref int value, uint flags);

        [DllImport("user32.dll", EntryPoint = "SystemParametersInfoW")]
        public static extern bool SystemParametersInfo(uint action, uint size, IntPtr value, uint flags);

        [DllImport("user32.dll", EntryPoint = "SystemParametersInfoW")]
        public static extern bool SystemParametersInfo(uint action, uint size, ref AnimationInfo value, uint flags);

        [DllImport("user32.dll")]
        public static extern uint GetDpiForWindow(IntPtr window);

        [DllImport("user32.dll")]
        public static extern bool UpdateLayeredWindow(IntPtr window, IntPtr screen, ref Point place, ref Size size,
            IntPtr source, ref Point origin, uint key, ref uint blend, uint flags);

        [DllImport("user32.dll")]
        public static extern IntPtr GetDC(IntPtr window);

        [DllImport("user32.dll")]
        public static extern int ReleaseDC(IntPtr window, IntPtr context);

        [DllImport("gdi32.dll")]
        public static extern IntPtr CreateCompatibleDC(IntPtr context);

        [DllImport("gdi32.dll")]
        public static extern bool DeleteDC(IntPtr context);

        [DllImport("gdi32.dll")]
        public static extern IntPtr CreateDIBSection(IntPtr context, ref BitmapInfoHeader header, uint usage, out IntPtr bits,
            IntPtr section, uint offset);

        [DllImport("gdi32.dll")]
        public static extern IntPtr SelectObject(IntPtr context, IntPtr item);

        [DllImport("gdi32.dll")]
        public static extern bool DeleteObject(IntPtr item);

        [DllImport("gdi32.dll")]
        public static extern IntPtr CreateSolidBrush(uint color);

        [DllImport("user32.dll")]
        public static extern int FillRect(IntPtr context, ref Rect rect, IntPtr brush);

        [DllImport("gdi32.dll")]
        public static extern bool BitBlt(IntPtr target, int x, int y, int width, int height, IntPtr source, int sourceX, int sourceY, uint operation);

        [DllImport("user32.dll", CharSet = CharSet.Unicode, EntryPoint = "FindWindowW")]
        public static extern IntPtr FindWindow(string className, string title);

        [DllImport("user32.dll")]
        public static extern IntPtr GetForegroundWindow();

        [DllImport("user32.dll")]
        public static extern bool SetForegroundWindow(IntPtr window);

        [DllImport("user32.dll")]
        public static extern bool BringWindowToTop(IntPtr window);

        [DllImport("user32.dll")]
        public static extern bool ShowWindow(IntPtr window, int command);

        [DllImport("user32.dll")]
        public static extern uint GetWindowThreadProcessId(IntPtr window, IntPtr process);

        [DllImport("user32.dll")]
        public static extern bool AttachThreadInput(uint attaching, uint attachedTo, bool attach);

        [DllImport("kernel32.dll")]
        public static extern uint GetCurrentThreadId();

        [DllImport("user32.dll")]
        public static extern int GetSystemMetrics(int index);

        [DllImport("shell32.dll")]
        public static extern IntPtr SHAppBarMessage(uint message, ref AppBarData data);

        [DllImport("dwmapi.dll")]
        public static extern int DwmGetWindowAttribute(IntPtr window, int attribute, out int value, int size);

        [DllImport("dwmapi.dll")]
        public static extern int DwmGetWindowAttribute(IntPtr window, int attribute, out Rect value, int size);

        [DllImport("user32.dll", CharSet = CharSet.Unicode, EntryPoint = "EnumDisplayDevicesW")]
        public static extern bool EnumDisplayDevices(string device, int index, ref DisplayDevice information, int flags);

        [DllImport("user32.dll")]
        public static extern bool SetProcessDpiAwarenessContext(IntPtr context);

        [DllImport("user32.dll")]
        public static extern int DisplayConfigGetDeviceInfo(ref DisplayDpiScale scale);

        [DllImport("user32.dll")]
        public static extern int DisplayConfigSetDeviceInfo(ref DisplayDpiScaleSet scale);

        [DllImport("user32.dll")]
        public static extern int GetDisplayConfigBufferSizes(uint flags, out uint pathCount, out uint modeCount);

        [DllImport("user32.dll")]
        public static extern int QueryDisplayConfig(uint flags, ref uint pathCount, [Out] DisplayPath[] paths,
            ref uint modeCount, [Out] DisplayConfigMode[] modes, IntPtr topology);

        [DllImport("user32.dll")]
        public static extern int SetDisplayConfig(uint pathCount, [In] DisplayPath[] paths,
            uint modeCount, [In] DisplayConfigMode[] modes, uint flags);

        [DllImport("gdi32.dll")]
        public static extern int D3DKMTOpenAdapterFromGdiDisplayName(ref OpenAdapterFromDisplayName adapter);

        [DllImport("gdi32.dll")]
        public static extern int D3DKMTEscape(ref Escape escape);

        [DllImport("gdi32.dll")]
        public static extern int D3DKMTCloseAdapter(ref CloseAdapter adapter);
    }
}
