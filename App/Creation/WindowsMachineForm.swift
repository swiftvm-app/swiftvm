import Installers
import SwiftUI
import UniformTypeIdentifiers
import VMCore

/// Editable Windows settings, independent of which controls are expanded.
struct WindowsMachineSettings {
    var cpuCount = HostResources.recommendedCPUCount(for: .windows)
    var memoryGigabytes = Double(HostResources.recommendedMemorySize(for: .windows) / HostResources.gibibyte)
    var diskGigabytes = Int(HostResources.recommendedDiskCapacity(for: .windows) / HostResources.gibibyte)
    var fullName: String
    var userName: String
    var password = ""
    var installsSSHKey = true
    var compressesDisk = false
    var acceleratesGraphics = true
    var location: URL?

    init(hostUserName: String = NSUserName(), hostFullName: String = NSFullUserName()) {
        userName = WindowsSetup.problem(withUserName: hostUserName) == nil ? hostUserName : "user"
        fullName = hostFullName
    }

    /// Expanding or collapsing Advanced cannot change what will be installed.
    func request(name: String, media: WindowsInstallRequest.Media) -> WindowsInstallRequest {
        WindowsInstallRequest(
            name: name, media: media,
            cpuCount: cpuCount,
            memorySize: UInt64(max(memoryGigabytes, 0)) * HostResources.gibibyte,
            diskCapacity: UInt64(max(diskGigabytes, 0)) * HostResources.gibibyte,
            userName: userName.trimmingCharacters(in: .whitespaces),
            fullName: fullName,
            password: password,
            installsSSHKey: installsSSHKey,
            compressesDisk: compressesDisk,
            acceleratesGraphics: acceleratesGraphics,
            location: location
        )
    }
}

/// The form for a Windows machine: Windows 11 from Microsoft or a disc of the user's, installed without
/// anyone sitting through its setup.
struct WindowsMachineForm: View {
    @Binding var source: NewMachineSource
    @Binding var mode: NewMachineMode
    /// An installer disc to start with, instead of Microsoft's download.
    var initialDisc: URL?
    let onReady: (VirtualMachine, Bool) -> Void

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var localDisc: URL?
    @State private var localDiscProblem: String?
    @State private var usesLocalDisc = false
    @State private var name = ""
    @State private var hasEditedName = false
    @State private var settings = WindowsMachineSettings()
    @State private var startsWhenReady = true

    /// Windows 11 doesn't install on less, and wants room for its updates.
    private static let diskRange = 64...HostResources.maximumDiskGigabytes
    private static let minimumMemoryGigabytes = 4.0

    var body: some View {
        VStack(spacing: 0) {
            Form {
                sourceSection
                accountSection
                if canAccelerateGraphics {
                    graphicsSection
                }
                NewMachineAdvancedToggle(selection: $mode, summary: hardwareSummary)
                if mode == .advanced {
                    hardwareSection
                    optionsSection
                }
            }
            .formStyle(.grouped)
            .scrollBounceBehavior(.basedOnSize)

            Divider()
            FormButtons(problem: nameProblem ?? diskProblem, canCreate: canCreate, create: create)
        }
        .frame(height: mode.formHeight)
        .onAppear {
            if let initialDisc {
                useLocalDisc(at: initialDisc)
            }
            suggestName()
        }
    }

    private var sourceSection: some View {
        Section {
            NewMachineSourcePicker(selection: $source)
            Picker("Version", selection: $usesLocalDisc) {
                Text("Windows 11 for Arm, from Microsoft").tag(false)
                if let localDisc {
                    Text(localDisc.lastPathComponent).tag(true)
                }
            }
            // A disc that was turned down is of no concern once another version is chosen.
            .onChange(of: usesLocalDisc) { localDiscProblem = nil }
            LabeledContent("") {
                Button("Choose ISO…") { chooseDisc() }
            }
            TextField("Name", text: nameBinding)
        } footer: {
            if !isEngineAvailable {
                Text("This copy of SwiftVM was built without QEMU, which runs Windows.").foregroundStyle(.red)
            } else if let localDiscProblem {
                Text(localDiscProblem).foregroundStyle(.red)
            } else {
                Text(sourceNote)
            }
        }
    }

    private var accountSection: some View {
        Section {
            SecureField("Password", text: $settings.password, prompt: Text("Required"))
        } header: {
            Text("Account")
        } footer: {
            if let problem = accountProblem {
                Text(problem).foregroundStyle(.red)
            } else {
                Text("Windows creates the account “\(settings.userName)” and logs in to it by itself. Expand Advanced to change the account.")
            }
        }
    }

    /// Whether this copy of the app can give a Windows machine the Mac's GPU to draw with.
    private var canAccelerateGraphics: Bool {
        model.qemuProvider?.canAccelerateWindowsGraphics == true
    }

    private var graphicsSection: some View {
        Section {
            Toggle("Graphics acceleration (experimental)", isOn: $settings.acceleratesGraphics)
        } footer: {
            Text(settings.acceleratesGraphics
                ? "Draws with your Mac's GPU, for smooth 3D and video. Windows is sharp at the size its window opens at; after you resize the window, restart Windows to make it sharp at the new size."
                : "Windows is sharp at any window size, and follows the window as you resize it. Graphics are drawn by the processors, so 3D apps and video are slower.")
        }
    }

    private var hardwareSection: some View {
        Section {
            Stepper(value: $settings.cpuCount, in: 2...max(HostResources.cpuCount, 2)) {
                LabeledContent("Processors", value: "\(settings.cpuCount)")
            }
            LabeledContent("Memory") {
                HStack {
                    if maximumMemoryGigabytes > Self.minimumMemoryGigabytes {
                        Slider(value: $settings.memoryGigabytes, in: Self.minimumMemoryGigabytes...maximumMemoryGigabytes, step: 1)
                            .accessibilityLabel("Memory")
                            .accessibilityValue("\(Int(settings.memoryGigabytes)) GB")
                    }
                    Text("\(Int(settings.memoryGigabytes)) GB")
                        .monospacedDigit()
                        .frame(width: 56, alignment: .trailing)
                }
            }
            DiskSizeRow(gigabytes: $settings.diskGigabytes, range: Self.diskRange)
            Toggle("Keep the disk compressed", isOn: $settings.compressesDisk)
            LocationRow(location: $settings.location)
        } header: {
            Text("Hardware")
        } footer: {
            if let diskProblem {
                Text(diskProblem).foregroundStyle(.red)
            }
        }
    }

    private var optionsSection: some View {
        Section("Account Options") {
            TextField("Full Name", text: $settings.fullName)
            TextField("Account Name", text: $settings.userName)
            Toggle("Sign in over SSH with my key", isOn: $settings.installsSSHKey)
            Toggle("Start when ready", isOn: $startsWhenReady)
        }
    }

    private var hardwareSummary: String {
        "\(settings.cpuCount) processors · \(Int(settings.memoryGigabytes)) GB memory · \(settings.diskGigabytes) GB disk"
    }

    private var sourceNote: String {
        if usesLocalDisc, let localDisc {
            return "Installs Windows from “\(localDisc.lastPathComponent)”, with the drivers for virtual machines, and sets it up by itself. This takes about half an hour."
        }
        return "Downloads Windows 11 from Microsoft (about 9 GB) and the drivers for virtual machines, installs Windows and sets it up by itself. This takes a while; you can keep using your Mac."
    }

    // MARK: The installer

    private func chooseDisc() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "iso") ?? .diskImage]
        panel.message = "Choose a Windows 11 installer disc image (ISO) for Arm."
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        useLocalDisc(at: url)
    }

    private func useLocalDisc(at url: URL) {
        Task {
            do {
                _ = try await Task.detached(priority: .userInitiated) { try WindowsInstaller.inspect(url) }.value
                localDisc = url
                localDiscProblem = nil
                usesLocalDisc = true
            } catch {
                localDiscProblem = error.localizedDescription
            }
        }
    }

    // MARK: Validation

    private var isEngineAvailable: Bool {
        model.qemuProvider?.isAvailable == true
    }

    private var maximumMemoryGigabytes: Double {
        max(Double(HostResources.maximumGuestMemorySize / HostResources.gibibyte), Self.minimumMemoryGigabytes)
    }

    private var nameBinding: Binding<String> {
        Binding(get: { name }, set: { newValue in
            name = newValue
            hasEditedName = true
        })
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var nameProblem: String? {
        if trimmedName.isEmpty { return nil }
        return model.isNameTaken(trimmedName) ? "That name is already in use." : nil
    }

    private var accountProblem: String? {
        WindowsSetup.problem(withUserName: settings.userName.trimmingCharacters(in: .whitespaces))
    }

    private var diskProblem: String? {
        DiskSizeRow.problem(with: settings.diskGigabytes, in: Self.diskRange)
    }

    private var canCreate: Bool {
        isEngineAvailable && !trimmedName.isEmpty && nameProblem == nil && diskProblem == nil && accountProblem == nil
            && WindowsSetup.problem(withPassword: settings.password) == nil && (!usesLocalDisc || localDisc != nil)
    }

    private func suggestName() {
        guard !hasEditedName else { return }
        var candidate = "Windows 11"
        var counter = 2
        while model.isNameTaken(candidate) {
            candidate = "Windows 11 \(counter)"
            counter += 1
        }
        name = candidate
    }

    // MARK: Create

    private func create() {
        guard canCreate else { return }
        let media: WindowsInstallRequest.Media = usesLocalDisc ? localDisc.map(WindowsInstallRequest.Media.localFile) ?? .download : .download
        let startsWhenReady = startsWhenReady
        model.create(settings.request(name: trimmedName, media: media), onReady: { machine in
            onReady(machine, startsWhenReady)
        })
        dismiss()
    }
}
