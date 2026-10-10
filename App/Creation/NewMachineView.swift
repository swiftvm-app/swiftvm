import Installers
import SwiftUI
import UniformTypeIdentifiers
import VMCore
import Virtualization

/// The sheet that creates a new virtual machine.
struct NewMachineView: View {
    /// Called when the new machine is in the library; the flag says whether to start it right away.
    let onReady: (VirtualMachine, Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var family: GuestFamily?

    var body: some View {
        VStack(spacing: 0) {
            switch family {
            case nil:
                SystemChooser(selection: $family)
            case .linux:
                LinuxMachineForm(onBack: { family = nil }, onReady: onReady)
            case .macOS, .windows:
                // Not reachable yet: the chooser only offers systems that can be created.
                SystemChooser(selection: $family)
            }
        }
        .frame(width: 600)
    }
}

// MARK: - Choosing a system

private struct SystemChooser: View {
    @Binding var selection: GuestFamily?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 22) {
            VStack(spacing: 6) {
                Text("New Virtual Machine")
                    .font(.title2.weight(.semibold))
                Text("Choose the operating system to install.")
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 26)

            HStack(spacing: 14) {
                card(.macOS, detail: "Coming soon", isAvailable: false)
                card(.linux, detail: "Ubuntu, Debian and more", isAvailable: true)
                card(.windows, detail: "Coming soon", isAvailable: false)
            }
            .padding(.horizontal, 26)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(16)
        }
    }

    private func card(_ family: GuestFamily, detail: String, isAvailable: Bool) -> some View {
        Button {
            selection = family
        } label: {
            VStack(spacing: 10) {
                OSGlyph(os: GuestOS(family: family, distribution: family == .linux ? "ubuntu" : nil), size: 44)
                Text(family.displayName)
                    .font(.headline)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 22)
            .contentShape(.rect(cornerRadius: 20))
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(isAvailable), in: .rect(cornerRadius: 20))
        .opacity(isAvailable ? 1 : 0.5)
        .disabled(!isAvailable)
    }
}

// MARK: - Linux

private struct LinuxMachineForm: View {
    enum Method: String, CaseIterable, Identifiable {
        case quickCreate = "Quick Create"
        case installer = "Installer Disc"

        var id: Self { self }
    }

    let onBack: () -> Void
    let onReady: (VirtualMachine, Bool) -> Void

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var method = Method.quickCreate
    @State private var distributionID = DistributionCatalog.quickCreate.first?.id ?? ""
    @State private var installerURL: URL?
    @State private var localISO: URL?
    @State private var name = ""
    @State private var hasEditedName = false
    @State private var cpuCount = HostResources.recommendedCPUCount(for: .linux)
    @State private var memoryGigabytes = Double(HostResources.recommendedMemorySize(for: .linux) / HostResources.gibibyte)
    @State private var diskGigabytes = Int(HostResources.recommendedDiskCapacity(for: .linux) / HostResources.gibibyte)
    @State private var userName = NSUserName()
    @State private var password = ""
    @State private var installsSSHKey = true
    @State private var usesRosetta = false
    @State private var startsWhenReady = true

    private static let diskSizes = [16, 32, 64, 128, 256, 512, 1024]

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Picker("Setup", selection: $method) {
                        ForEach(Method.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)

                    switch method {
                    case .quickCreate:
                        Picker("Distribution", selection: $distributionID) {
                            ForEach(DistributionCatalog.quickCreate) { distribution in
                                Text(distribution.name).tag(distribution.id)
                            }
                        }
                    case .installer:
                        installerPicker
                    }
                    TextField("Name", text: nameBinding)
                } footer: {
                    Text(method == .quickCreate
                        ? "Downloads a ready-made server image and sets it up on first start. No installer to click through."
                        : "Starts the installer from a disc image. Use this for desktop editions or other distributions.")
                }

                Section("Hardware") {
                    Stepper(value: $cpuCount, in: 1...HostResources.cpuCount) {
                        LabeledContent("Processors", value: "\(cpuCount)")
                    }
                    LabeledContent("Memory") {
                        HStack {
                            Slider(value: $memoryGigabytes, in: 1...Double(HostResources.maximumGuestMemorySize / HostResources.gibibyte), step: 1)
                            Text("\(Int(memoryGigabytes)) GB")
                                .monospacedDigit()
                                .frame(width: 56, alignment: .trailing)
                        }
                    }
                    Picker("Disk Size", selection: $diskGigabytes) {
                        ForEach(Self.diskSizes, id: \.self) { size in
                            Text(size >= 1024 ? "\(size / 1024) TB" : "\(size) GB").tag(size)
                        }
                    }
                }

                if method == .quickCreate {
                    Section {
                        TextField("User Name", text: $userName)
                        SecureField("Password", text: $password, prompt: Text(installsSSHKey ? "Optional" : "Required"))
                        Toggle("Sign in over SSH with my key", isOn: $installsSSHKey)
                        if VZLinuxRosettaDirectoryShare.availability == .installed {
                            Toggle("Run x86-64 programs with Rosetta", isOn: $usesRosetta)
                        }
                    } header: {
                        Text("Account")
                    } footer: {
                        if let problem = accountProblem {
                            Text(problem).foregroundStyle(.red)
                        } else {
                            Text("The password is used to sign in on the console. The account can use sudo without it.")
                        }
                    }
                }

                Section {
                    Toggle("Start when ready", isOn: $startsWhenReady)
                }
            }
            .formStyle(.grouped)
            .scrollBounceBehavior(.basedOnSize)

            Divider()
            HStack {
                Button("Back", action: onBack)
                Spacer()
                if let problem = nameProblem {
                    Text(problem)
                        .font(.callout)
                        .foregroundStyle(.red)
                }
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create", action: create)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canCreate)
            }
            .padding(16)
        }
        .frame(height: 620)
        .onAppear { suggestName() }
        .onChange(of: distributionID) { suggestName() }
        .onChange(of: method) { suggestName() }
        .onChange(of: installerURL) { suggestName() }
    }

    // MARK: Installer source

    @ViewBuilder
    private var installerPicker: some View {
        Picker("Disc Image", selection: $installerURL) {
            if let localISO {
                Text(localISO.lastPathComponent).tag(URL?.some(localISO))
            }
            ForEach(catalogInstallers, id: \.installer.url) { entry in
                Text("\(entry.distribution.name) \(entry.installer.name) (download)").tag(URL?.some(entry.installer.url))
            }
            if localISO == nil, catalogInstallers.isEmpty {
                Text("None").tag(URL?.none)
            }
        }
        LabeledContent("") {
            Button("Choose ISO File…") { chooseISO() }
        }
        .onAppear {
            if installerURL == nil {
                installerURL = catalogInstallers.first?.installer.url
            }
        }
    }

    private var catalogInstallers: [(distribution: LinuxDistribution, installer: LinuxDistribution.Installer)] {
        DistributionCatalog.builtIn.flatMap { distribution in
            distribution.installers.map { (distribution, $0) }
        }
    }

    private func chooseISO() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "iso") ?? .diskImage, .diskImage]
        panel.message = "Choose an ARM64 Linux installer image."
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        localISO = url
        installerURL = url
    }

    // MARK: Validation

    private var selectedDistribution: LinuxDistribution? {
        DistributionCatalog.quickCreate.first { $0.id == distributionID }
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
        let user = userName.trimmingCharacters(in: .whitespaces)
        if user.isEmpty { return nil }
        let isValid = user.first!.isLowercase && user.first!.isASCII
            && user.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "-" || $0 == "_") }
            && user.count <= 32
        if !isValid {
            return "Use lowercase letters, digits, “-” and “_”, starting with a letter."
        }
        if user == "root" {
            return "Choose a user name other than root."
        }
        if password.isEmpty, !installsSSHKey {
            return "Set a password or turn on SSH key sign-in, otherwise nobody can sign in."
        }
        return nil
    }

    private var canCreate: Bool {
        guard !trimmedName.isEmpty, nameProblem == nil else { return false }
        switch method {
        case .quickCreate:
            return selectedDistribution != nil && !userName.trimmingCharacters(in: .whitespaces).isEmpty && accountProblem == nil
        case .installer:
            return installerURL != nil
        }
    }

    /// Fills in a name based on the chosen system until the user types their own.
    private func suggestName() {
        guard !hasEditedName else { return }
        var base = "Linux"
        switch method {
        case .quickCreate:
            if let distribution = selectedDistribution {
                base = distribution.name.replacingOccurrences(of: " LTS", with: "")
            }
        case .installer:
            if let entry = catalogInstallers.first(where: { $0.installer.url == installerURL }) {
                base = entry.distribution.name.replacingOccurrences(of: " LTS", with: "")
            } else if let localISO, installerURL == localISO {
                base = localISO.deletingPathExtension().lastPathComponent
            }
        }
        var candidate = base
        var counter = 2
        while model.isNameTaken(candidate) {
            candidate = "\(base) \(counter)"
            counter += 1
        }
        name = candidate
    }

    // MARK: Create

    private func create() {
        let memorySize = UInt64(memoryGigabytes) * HostResources.gibibyte
        let diskCapacity = UInt64(diskGigabytes) * HostResources.gibibyte
        let starts = startsWhenReady
        let ready: (VirtualMachine) -> Void = { machine in onReady(machine, starts) }

        switch method {
        case .quickCreate:
            guard let distribution = selectedDistribution else { return }
            model.create(LinuxQuickCreateRequest(
                name: trimmedName,
                distribution: distribution,
                cpuCount: cpuCount,
                memorySize: memorySize,
                diskCapacity: diskCapacity,
                userName: userName.trimmingCharacters(in: .whitespaces),
                fullName: NSFullUserName(),
                password: password,
                installsSSHKey: installsSSHKey,
                rosetta: usesRosetta
            ), onReady: ready)
        case .installer:
            guard let installerURL else { return }
            let media: LinuxInstallerRequest.Media
            if let entry = catalogInstallers.first(where: { $0.installer.url == installerURL }) {
                media = .download(entry.distribution, entry.installer)
            } else {
                media = .localFile(installerURL)
            }
            model.create(LinuxInstallerRequest(
                name: trimmedName,
                media: media,
                cpuCount: cpuCount,
                memorySize: memorySize,
                diskCapacity: diskCapacity
            ), onReady: ready)
        }
        dismiss()
    }
}
