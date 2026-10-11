import Installers
import SwiftUI
import UniformTypeIdentifiers
import VMCore
import VZEngine
import Virtualization

/// What the New Virtual Machine form starts with.
struct NewMachineRequest: Identifiable {
    enum Source {
        /// Ask which system to install.
        case chooser
        /// A Linux installer disc image, for example one that was dropped on the window.
        case installerDisc(URL)
        /// A macOS restore image (IPSW).
        case restoreImage(URL)
    }

    let id = UUID()
    var source = Source.chooser

    /// The request for a file dropped on the window, or `nil` if a machine can't be made from it.
    init?(droppedFile url: URL) {
        switch url.pathExtension.lowercased() {
        case "iso": source = .installerDisc(url)
        case "ipsw": source = .restoreImage(url)
        default: return nil
        }
    }

    init() {}
}

/// The form that creates a new virtual machine, shown in the New Virtual Machine window.
struct NewMachineView: View {
    /// Called when the new machine is in the library; the flag says whether to start it right away.
    let onReady: (VirtualMachine, Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var family: GuestFamily?
    /// The file the form was opened for. Going back to the chooser forgets it.
    @State private var source: NewMachineRequest.Source

    init(request: NewMachineRequest = NewMachineRequest(), onReady: @escaping (VirtualMachine, Bool) -> Void) {
        self.onReady = onReady
        _source = State(initialValue: request.source)
        switch request.source {
        case .chooser: _family = State(initialValue: nil)
        case .installerDisc: _family = State(initialValue: .linux)
        case .restoreImage: _family = State(initialValue: .macOS)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            switch family {
            case nil:
                SystemChooser(selection: $family)
            case .linux:
                LinuxMachineForm(initialDisc: initialDisc, onBack: goBack, onReady: onReady)
            case .macOS:
                MacMachineForm(initialImage: initialImage, onBack: goBack, onReady: onReady)
            case .windows:
                // Not reachable yet: the chooser only offers systems that can be created.
                SystemChooser(selection: $family)
            }
        }
        .frame(width: 600)
    }

    private var initialDisc: URL? {
        if case .installerDisc(let url) = source { return url }
        return nil
    }

    private var initialImage: URL? {
        if case .restoreImage(let url) = source { return url }
        return nil
    }

    private func goBack() {
        source = .chooser
        family = nil
    }
}

// MARK: - Choosing a system

private struct SystemChooser: View {
    @Binding var selection: GuestFamily?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 22) {
            // The window's title bar says what this is.
            Text("Choose the operating system to install.")
                .font(.title3.weight(.medium))
                .padding(.top, 22)

            HStack(spacing: 14) {
                card(.macOS, detail: "The latest version, or your own restore image", isAvailable: true)
                card(.linux, detail: "Ubuntu, Debian and more", isAvailable: true)
                card(.windows, detail: "Coming soon", isAvailable: false)
            }
            .padding(.horizontal, 26)

            HStack {
                Text("Or drop an installer disc (ISO), a macOS restore image (IPSW) or a virtual machine here.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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
                OSGlyph(os: GuestOS(family: family, distribution: family == .linux ? "ubuntu" : nil), size: 54)
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

    @State private var method: Method
    @State private var distributionID = DistributionCatalog.quickCreate.first?.id ?? ""
    @State private var installerURL: URL?
    @State private var localISO: URL?

    /// - Parameter initialDisc: An installer disc image to start with, instead of Quick Create.
    init(initialDisc: URL? = nil, onBack: @escaping () -> Void, onReady: @escaping (VirtualMachine, Bool) -> Void) {
        self.onBack = onBack
        self.onReady = onReady
        _method = State(initialValue: initialDisc == nil ? .quickCreate : .installer)
        _installerURL = State(initialValue: initialDisc)
        _localISO = State(initialValue: initialDisc)
    }
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
                                .accessibilityLabel("Memory")
                                .accessibilityValue("\(Int(memoryGigabytes)) GB")
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

// MARK: - macOS

private struct MacMachineForm: View {
    /// What is known about the newest macOS this Mac can run.
    enum LatestImage {
        case loading
        case available(MacRestoreImage)
        case unavailable(String)
    }

    /// A restore image to start with, instead of the latest macOS.
    var initialImage: URL?
    let onBack: () -> Void
    let onReady: (VirtualMachine, Bool) -> Void

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var latest = LatestImage.loading
    /// Size of the download for the latest image, when it isn't in the cache yet.
    @State private var latestDownloadSize: Int64?
    @State private var lookupAttempt = 0
    @State private var localImage: MacRestoreImage?
    @State private var localImageProblem: String?
    @State private var usesLocalImage = false
    @State private var name = ""
    @State private var hasEditedName = false
    @State private var cpuCount = HostResources.recommendedCPUCount(for: .macOS)
    @State private var memoryGigabytes = Double(HostResources.recommendedMemorySize(for: .macOS) / HostResources.gibibyte)
    @State private var diskGigabytes = Int(HostResources.recommendedDiskCapacity(for: .macOS) / HostResources.gibibyte)
    @State private var fullName = NSFullUserName()
    @State private var userName = NSUserName()
    @State private var password = ""
    @State private var logsInAutomatically = true
    @State private var installsSSHKey = true

    private static let diskSizes = [64, 128, 256, 512, 1024]

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Picker("Version", selection: versionBinding) {
                        Text(latestTitle).tag(false)
                        if let localImage {
                            Text("\(localImage.productName) (\(localImage.url.lastPathComponent))").tag(true)
                        }
                    }
                    LabeledContent("") {
                        HStack {
                            if case .unavailable = latest {
                                Button("Try Again") { lookupAttempt += 1 }
                            }
                            Button("Choose Restore Image…") { chooseImage() }
                        }
                    }
                    TextField("Name", text: nameBinding)
                } footer: {
                    if let problem = sourceProblem {
                        Text(problem).foregroundStyle(.red)
                    } else {
                        Text(sourceNote)
                    }
                }

                Section("Hardware") {
                    Stepper(value: $cpuCount, in: minimumCPUCount...max(HostResources.cpuCount, minimumCPUCount)) {
                        LabeledContent("Processors", value: "\(cpuCount)")
                    }
                    LabeledContent("Memory") {
                        HStack {
                            // A slider needs room to move; on a small Mac the minimum is all there is.
                            if maximumMemoryGigabytes > minimumMemoryGigabytes {
                                Slider(value: $memoryGigabytes, in: minimumMemoryGigabytes...maximumMemoryGigabytes, step: 1)
                                    .accessibilityLabel("Memory")
                                    .accessibilityValue("\(Int(memoryGigabytes)) GB")
                            }
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

                if setsUpAccount {
                    Section {
                        TextField("Full Name", text: $fullName)
                        TextField("Account Name", text: $userName)
                        SecureField("Password", text: $password, prompt: Text("Required"))
                        Toggle("Log in automatically", isOn: $logsInAutomatically)
                        Toggle("Sign in over SSH with my key", isOn: $installsSSHKey)
                    } header: {
                        Text("Account")
                    } footer: {
                        if let problem = accountProblem {
                            Text(problem).foregroundStyle(.red)
                        } else {
                            Text("macOS creates this account the first time it starts, so there is no setup assistant to click through. The virtual machine starts as soon as it is installed.")
                        }
                    }
                } else {
                    Section("Account") {
                        Text("Versions before macOS \(GuestProvisioning.minimumMacOSMajorVersion) can't be set up automatically. Create the account in the setup assistant when the virtual machine first starts.")
                            .foregroundStyle(.secondary)
                    }
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
        .task(id: lookupAttempt) { await lookUpLatest() }
        .task {
            if let initialImage {
                await useLocalImage(at: initialImage)
            }
        }
        .onAppear { suggestName() }
        .onChange(of: selectedImage) {
            suggestName()
            // A newer system can ask for more than the defaults.
            cpuCount = max(cpuCount, minimumCPUCount)
            memoryGigabytes = min(max(memoryGigabytes, minimumMemoryGigabytes), maximumMemoryGigabytes)
        }
    }

    // MARK: Restore image

    private var selectedImage: MacRestoreImage? {
        if usesLocalImage {
            return localImage
        }
        if case .available(let image) = latest {
            return image
        }
        return nil
    }

    /// Switching versions by hand puts an earlier complaint about a file out of date.
    private var versionBinding: Binding<Bool> {
        Binding(get: { usesLocalImage }, set: { newValue in
            usesLocalImage = newValue
            localImageProblem = nil
        })
    }

    private var latestTitle: String {
        switch latest {
        case .loading: "Latest macOS"
        case .available(let image): "Latest (\(image.productName))"
        case .unavailable: "Latest macOS (unavailable)"
        }
    }

    /// Why the chosen version can't be installed, if it can't.
    private var sourceProblem: String? {
        // A file that was just turned down is what the user is looking at, whatever is still selected.
        if let localImageProblem {
            return localImageProblem
        }
        if usesLocalImage {
            if let localImage, localImage.requirements == nil {
                return "This Mac can't run \(localImage.productName) in a virtual machine."
            }
            return nil
        }
        if case .unavailable(let reason) = latest {
            return "Couldn't look up the latest macOS: \(reason) You can still install from a restore image file."
        }
        return nil
    }

    private var sourceNote: String {
        guard let image = selectedImage else { return "Checking for the latest macOS…" }
        if usesLocalImage {
            return "Installs \(image.guestOS.summary) from the chosen file. This takes several minutes."
        }
        if model.downloader.isCached(RemoteImage(url: image.url)) {
            return "\(image.guestOS.summary) is already downloaded. Installing it takes several minutes."
        }
        if let latestDownloadSize {
            return "Downloads \(image.guestOS.summary) from Apple (\(Formatting.bytes(UInt64(latestDownloadSize)))) and installs it. This takes a while; you can keep using your Mac."
        }
        return "Downloads \(image.guestOS.summary) from Apple and installs it. This takes a while; you can keep using your Mac."
    }

    private func lookUpLatest() async {
        latest = .loading
        do {
            let image = try await MacRestoreImage.latestSupported()
            latest = .available(image)
            let remote = RemoteImage(url: image.url)
            if image.isRemote, !model.downloader.isCached(remote) {
                latestDownloadSize = await model.downloader.remoteSize(of: remote)
            }
        } catch {
            guard !Task.isCancelled else { return }
            latest = .unavailable(error.localizedDescription)
        }
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "ipsw") ?? .data]
        panel.message = "Choose a macOS restore image (IPSW) for Apple silicon."
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await useLocalImage(at: url) }
    }

    private func useLocalImage(at url: URL) async {
        do {
            localImage = try await MacRestoreImage.load(from: url)
            localImageProblem = nil
            usesLocalImage = true
        } catch {
            localImageProblem = "“\(url.lastPathComponent)” isn't a usable restore image: \(error.localizedDescription)"
        }
    }

    // MARK: Limits

    private var minimumCPUCount: Int {
        selectedImage?.requirements?.minimumCPUCount ?? 2
    }

    private var minimumMemoryGigabytes: Double {
        let bytes = selectedImage?.requirements?.minimumMemorySize ?? 4 * HostResources.gibibyte
        return Double((bytes + HostResources.gibibyte - 1) / HostResources.gibibyte)
    }

    private var maximumMemoryGigabytes: Double {
        max(Double(HostResources.maximumGuestMemorySize / HostResources.gibibyte), minimumMemoryGigabytes)
    }

    // MARK: Validation

    private var setsUpAccount: Bool {
        selectedImage?.supportsProvisioning ?? true
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

    private var account: GuestProvisioning {
        let user = userName.trimmingCharacters(in: .whitespaces)
        let full = fullName.trimmingCharacters(in: .whitespaces)
        return GuestProvisioning(
            fullName: full.isEmpty ? user : full,
            userName: user,
            password: password,
            logsInAutomatically: logsInAutomatically,
            enablesRemoteLogin: installsSSHKey
        )
    }

    /// What is wrong with the account, once the user has started filling it in.
    private var accountProblem: String? {
        let account = account
        if account.userName.isEmpty { return nil }
        if let problem = GuestProvisioning.problem(withUserName: account.userName) {
            return problem
        }
        if password.isEmpty { return nil }
        do {
            try account.validateForMacOS()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private var canCreate: Bool {
        guard !trimmedName.isEmpty, nameProblem == nil, selectedImage?.requirements != nil else { return false }
        guard setsUpAccount else { return true }
        return !account.userName.isEmpty && !password.isEmpty && accountProblem == nil
    }

    /// Fills in a name based on the chosen version until the user types their own.
    private func suggestName() {
        guard !hasEditedName else { return }
        let base = selectedImage.map { "macOS \($0.majorVersion)" } ?? "macOS"
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
        guard let image = selectedImage else { return }
        model.create(MacInstallRequest(
            name: trimmedName,
            image: image,
            cpuCount: cpuCount,
            memorySize: UInt64(memoryGigabytes) * HostResources.gibibyte,
            diskCapacity: UInt64(diskGigabytes) * HostResources.gibibyte,
            account: setsUpAccount ? account : nil,
            installsSSHKey: installsSSHKey
        ), onReady: { machine in
            // The account is set up on the first start, which has to happen while the app still knows it.
            onReady(machine, true)
        })
        dismiss()
    }
}
