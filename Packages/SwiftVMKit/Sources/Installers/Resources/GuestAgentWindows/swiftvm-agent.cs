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
// Mac's window, and talks to the service over a named pipe.

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
        public const string Version = "1.3";
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

            var features = new List<object> { "clipboard", "time-zone", "exec", "display-size" };
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

        static void Send(Dictionary<string, object> message)
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
