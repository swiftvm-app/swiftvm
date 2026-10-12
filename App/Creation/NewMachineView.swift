import Installers
import SwiftUI
import UniformTypeIdentifiers
import VMCore
import VZEngine
import Virtualization

/// What the New Virtual Machine form starts with.
struct NewMachineRequest: Identifiable {
    enum Source {
        /// No file. The form opens for the kind of system that was made last.
        case unspecified
        /// A Linux installer disc image, for example one that was dropped on the window.
        case installerDisc(URL)
        /// A macOS restore image (IPSW).
        case restoreImage(URL)
    }

    let id = UUID()
    var source = Source.unspecified

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

    /// The kinds of system a machine can be made for, in the order they are offered.
    static let families: [GuestFamily] = [.macOS, .linux]
    private static let familyKey = "newMachineFamily"

    /// The kind of system that was picked here last, which the window opens on the next time.
    @AppStorage(Self.familyKey) private var preferredFamily = GuestFamily.linux
    @State private var family: GuestFamily
    /// The file the form was opened for.
    private let source: NewMachineRequest.Source

    init(request: NewMachineRequest = NewMachineRequest(), onReady: @escaping (VirtualMachine, Bool) -> Void) {
        self.onReady = onReady
        source = request.source
        switch request.source {
        case .unspecified:
            // What is remembered may be from a build that could make what this one can't.
            let remembered = UserDefaults.standard.string(forKey: Self.familyKey).flatMap(GuestFamily.init(rawValue:))
            _family = State(initialValue: remembered.flatMap { Self.families.contains($0) ? $0 : nil } ?? .linux)
        case .installerDisc: _family = State(initialValue: .linux)
        case .restoreImage: _family = State(initialValue: .macOS)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            switch family {
            case .macOS:
                MacMachineForm(family: familyBinding, initialImage: initialImage, onReady: onReady)
            case .linux, .windows:
                // Windows can't be picked yet.
                LinuxMachineForm(family: familyBinding, initialDisc: initialDisc, onReady: onReady)
            }
        }
        .frame(width: 600)
    }

    /// A file the form was opened for doesn't change what the window opens on the next time. Picking
    /// a system by hand does.
    private var familyBinding: Binding<GuestFamily> {
        Binding(get: { family }, set: { newValue in
            guard Self.families.contains(newValue) else { return }
            family = newValue
            preferredFamily = newValue
        })
    }

    private var initialDisc: URL? {
        if case .installerDisc(let url) = source { return url }
        return nil
    }

    private var initialImage: URL? {
        if case .restoreImage(let url) = source { return url }
        return nil
    }
}

// MARK: - What both forms share

/// The first row of a form: the kind of system the machine is for. Picking another one puts that
/// system's form in the place of this one.
private struct OperatingSystemPicker: View {
    @Binding var selection: GuestFamily

    var body: some View {
        Picker("Operating System", selection: $selection) {
            ForEach(NewMachineView.families, id: \.self) { family in
                Text(family.displayName).tag(family)
            }
            Divider()
            Text("\(GuestFamily.windows.displayName) (coming soon)")
                .tag(GuestFamily.windows)
                .disabled(true)
        }
    }
}

/// The foot of a form: what is wrong with the name, or what else the window takes, and the buttons.
private struct FormButtons: View {
    var problem: String?
    var canCreate: Bool
    let create: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        HStack {
            if let problem {
                Text(problem)
                    .font(.callout)
                    .foregroundStyle(.red)
            } else {
                Text("Or drop an ISO, an IPSW or a virtual machine on this window.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Create", action: create)
                .keyboardShortcut(.defaultAction)
                .disabled(!canCreate)
        }
        .padding(16)
    }
}

// MARK: - Linux

private struct LinuxMachineForm: View {
    /// How much of the machine the form asks about.
    enum Mode: String, CaseIterable, Identifiable {
        /// A distribution, setup scripts and a password. Everything else is decided.
        case simple = "Simple"
        case advanced = "Advanced"

        var id: Self { self }
    }

    enum Method: String, CaseIterable, Identifiable {
        case quickCreate = "Quick Create"
        case installer = "Installer Disc"

        var id: Self { self }
    }

    @Binding var family: GuestFamily
    let onReady: (VirtualMachine, Bool) -> Void

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    /// The side of the form that was used last.
    @AppStorage("newLinuxMachineMode") private var preferredMode = Mode.simple
    /// The form was opened for an installer disc, which only Advanced has a place for.
    @State private var isOpenedForDisc: Bool
    @State private var method: Method
    @State private var distributionID = DistributionCatalog.quickCreate.first?.id ?? ""
    /// What a Quick Create machine is set up with on its first start: the setup scripts that were
    /// added, in the order they run.
    @State private var scripts: [SetupScript] = []
    /// Which of them were taken out because they are no longer in the user's folder as scripts.
    @State private var missingScriptsNote: String?
    @State private var isAddingScripts = false
    @State private var installerURL: URL?
    @State private var localISO: URL?

    /// - Parameter initialDisc: An installer disc image to start with, instead of Quick Create.
    init(family: Binding<GuestFamily>, initialDisc: URL? = nil, onReady: @escaping (VirtualMachine, Bool) -> Void) {
        _family = family
        self.onReady = onReady
        _isOpenedForDisc = State(initialValue: initialDisc != nil)
        _method = State(initialValue: initialDisc == nil ? .quickCreate : .installer)
        _installerURL = State(initialValue: initialDisc)
        _localISO = State(initialValue: initialDisc)
    }
    @State private var name = ""
    @State private var hasEditedName = false
    @State private var cpuCount = HostResources.recommendedCPUCount(for: .linux)
    @State private var memoryGigabytes = Double(HostResources.recommendedMemorySize(for: .linux) / HostResources.gibibyte)
    @State private var diskGigabytes = Int(HostResources.recommendedDiskCapacity(for: .linux) / HostResources.gibibyte)
    // Simple has no field to correct a name in that Linux won't take, such as a Mac's "Jane.Doe".
    @State private var userName = CloudInitSeed.userName(from: NSUserName())
    @State private var password = ""
    @State private var installsSSHKey = true
    @State private var usesRosetta = false
    @State private var startsWhenReady = true

    private static let diskSizes = [16, 32, 64, 128, 256, 512, 1024]
    private static let maximumMemoryGigabytes = Double(HostResources.maximumGuestMemorySize / HostResources.gibibyte)

    var body: some View {
        VStack(spacing: 0) {
            Picker("How much to set up", selection: modeBinding) {
                ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .padding(.top, 14)

            Form {
                switch mode {
                case .simple: simpleSections
                case .advanced: advancedSections
                }
            }
            .formStyle(.grouped)
            .scrollBounceBehavior(.basedOnSize)

            Divider()
            FormButtons(problem: nameProblem, canCreate: canCreate, create: create)
        }
        .frame(height: (mode == .simple ? 410 : 664) + scriptRowsHeight)
        .sheet(isPresented: $isAddingScripts) {
            if let distribution = selectedDistribution {
                SetupScriptChooser(distribution: distribution, scripts: $scripts)
            }
        }
        .onAppear { suggestName() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshScripts()
        }
        .onChange(of: distributionID) {
            // A script that isn't written for the system that is now chosen isn't offered for it.
            // One from a file stays, and is said not to fit.
            if let distribution = selectedDistribution {
                scripts.removeAll { $0.origin != .file && !$0.supports(distribution) }
            }
            fitHardware()
            suggestName()
        }
        .onChange(of: scripts) {
            fitHardware()
            suggestName()
        }
        .onChange(of: method) { suggestName() }
        .onChange(of: mode) {
            // Simple has no field for the name. One that was emptied in Advanced is suggested anew.
            if mode == .simple, trimmedName.isEmpty {
                hasEditedName = false
            }
            suggestName()
        }
        .onChange(of: installerURL) { suggestName() }
    }

    // MARK: Simple and Advanced

    private var mode: Mode {
        isOpenedForDisc ? .advanced : preferredMode
    }

    private var modeBinding: Binding<Mode> {
        Binding(get: { mode }, set: { newValue in
            isOpenedForDisc = false
            preferredMode = newValue
        })
    }

    /// Whether the machine is made from a ready-made image. Simple knows no other way.
    private var isQuickCreate: Bool {
        mode == .simple || method == .quickCreate
    }

    @ViewBuilder
    private var simpleSections: some View {
        Section {
            OperatingSystemPicker(selection: $family)
            distributionPicker
            scriptRows
            SecureField("Password", text: $password, prompt: Text(isPasswordRequired ? "Required" : "Optional"))
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text(simpleSummary)
                if let missingScriptsNote {
                    Text(missingScriptsNote).foregroundStyle(.orange)
                }
                if let problem = setupProblem {
                    Text(problem).foregroundStyle(.red)
                } else {
                    Text(setupNote ?? "A server with nothing added. Setup scripts add a desktop or other software. You sign in over SSH with your key, or on the console with the password.")
                }
            }
        }
    }

    /// What Simple decides without asking, for the user to see before it is created.
    private var simpleSummary: String {
        let disk = chosenDiskGigabytes >= 1024 ? "\(chosenDiskGigabytes / 1024) TB" : "\(chosenDiskGigabytes) GB"
        return "Creates “\(trimmedName)” with \(chosenCPUCount) processors, \(chosenMemoryGigabytes) GB of memory, a \(disk) disk and the user “\(chosenUserName)”. Advanced changes any of it."
    }

    // MARK: What the machine is made with

    // In Simple, SwiftVM decides whatever the form doesn't ask. What was set in Advanced and can't
    // be seen in Simple isn't used there: it would be made with settings nobody is looking at.

    private var chosenCPUCount: Int {
        mode == .simple ? HostResources.recommendedCPUCount(for: .linux) : cpuCount
    }

    private var chosenMemoryGigabytes: Int {
        guard mode == .simple else { return Int(memoryGigabytes) }
        let recommended = Int(HostResources.recommendedMemorySize(for: .linux) / HostResources.gibibyte)
        return min(max(recommended, selectedScripts.minimumMemoryGigabytes ?? 0), Int(Self.maximumMemoryGigabytes))
    }

    private var chosenDiskGigabytes: Int {
        guard mode == .simple else { return diskGigabytes }
        let needed = max(Int(HostResources.recommendedDiskCapacity(for: .linux) / HostResources.gibibyte), selectedScripts.minimumDiskGigabytes ?? 0)
        return Self.diskSizes.first { $0 >= needed } ?? needed
    }

    private var chosenUserName: String {
        mode == .simple ? CloudInitSeed.userName(from: NSUserName()) : userName.trimmingCharacters(in: .whitespaces)
    }

    private var chosenInstallsSSHKey: Bool {
        mode == .simple || installsSSHKey
    }

    @ViewBuilder
    private var advancedSections: some View {
        Section {
            OperatingSystemPicker(selection: $family)
            Picker("Setup", selection: $method) {
                ForEach(Method.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            switch method {
            case .quickCreate:
                distributionPicker
                scriptRows
            case .installer:
                installerPicker
            }
            TextField("Name", text: nameBinding)
        } footer: {
            if method == .installer {
                Text("Starts the installer from a disc image. Use this for other distributions.")
            } else if let problem = setupProblem {
                Text(problem).foregroundStyle(.red)
            } else if let missingScriptsNote {
                Text(missingScriptsNote).foregroundStyle(.orange)
            } else {
                Text(setupNote ?? "Downloads a ready-made server image and sets it up on first start. No installer to click through. Setup scripts add a desktop or other software.")
            }
        }

        Section("Hardware") {
            Stepper(value: $cpuCount, in: 1...HostResources.cpuCount) {
                LabeledContent("Processors", value: "\(cpuCount)")
            }
            LabeledContent("Memory") {
                HStack {
                    Slider(value: $memoryGigabytes, in: 1...Self.maximumMemoryGigabytes, step: 1)
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
                SecureField("Password", text: $password, prompt: Text(isPasswordRequired ? "Required" : "Optional"))
                Toggle("Sign in over SSH with my key", isOn: $installsSSHKey)
                if VZLinuxRosettaDirectoryShare.availability == .installed {
                    Toggle("Run x86-64 programs with Rosetta", isOn: $usesRosetta)
                }
            } header: {
                Text("Account")
            } footer: {
                if let problem = accountProblem {
                    Text(problem).foregroundStyle(.red)
                } else if selectedScripts.requiresPassword {
                    Text("A desktop asks for the password at its login screen. The account can use sudo without it.")
                } else {
                    Text("The password is used to sign in on the console. The account can use sudo without it.")
                }
            }
        }

        Section {
            Toggle("Start when ready", isOn: $startsWhenReady)
        }
    }

    // MARK: Distribution and setup scripts

    private var distributionPicker: some View {
        Picker("Distribution", selection: $distributionID) {
            ForEach(DistributionCatalog.quickCreate) { distribution in
                Text(distribution.name).tag(distribution.id)
            }
        }
    }

    /// The scripts that were added, each on a row of its own, under the button that adds more.
    @ViewBuilder
    private var scriptRows: some View {
        LabeledContent("Setup Scripts") {
            HStack {
                if scripts.isEmpty {
                    Text("None")
                }
                Button("Add…") {
                    missingScriptsNote = nil
                    isAddingScripts = true
                }
            }
        }
        ForEach(Array(scripts.enumerated()), id: \.offset) { index, script in
            LabeledContent {
                Button {
                    scripts.remove(at: index)
                } label: {
                    Image(systemName: "minus.circle.fill")
                }
                .buttonStyle(.borderless)
                .help("Don't run “\(script.name)”")
                .accessibilityLabel("Remove \(script.name)")
            } label: {
                // With more than one, the number says when its turn is.
                Text(scripts.count > 1 ? "\(index + 1). \(script.name)" : script.name)
                Text(script.summary ?? (script.origin == .file ? "From a file" : "A script of yours"))
            }
            .padding(.leading, 12)
        }
    }

    /// The room the rows of added scripts take, up to where the form scrolls instead of growing:
    /// Advanced is tall as it is.
    private var scriptRowsHeight: CGFloat {
        isQuickCreate ? CGFloat(min(scripts.count, mode == .simple ? 4 : 2)) * 57 : 0
    }

    /// What the machine is set up with on its first start, in the order it runs.
    private var selectedScripts: [SetupScript] {
        isQuickCreate ? scripts : []
    }

    /// Reads what was added from the catalog again. A script in the user's folder may have been changed
    /// or taken away since, and the machine is made with what is there now.
    private func refreshScripts() {
        guard scripts.contains(where: { $0.origin != .file }) else { return }
        let catalog = SetupScriptCatalog.all()
        let refreshed = scripts.compactMap { script in
            script.origin == .file ? script : catalog.first { $0.id == script.id }
        }
        // What is gone is said to be gone: a machine without something that was picked is no surprise
        // to anyone who was told.
        let missing = scripts.filter { script in script.origin != .file && !catalog.contains { $0.id == script.id } }
        if !missing.isEmpty {
            missingScriptsNote = "\(missing.setupName) \(missing.count == 1 ? "is no longer a script in your folder, and was" : "are no longer scripts in your folder, and were") taken out. Add… lists the files that can't be read as scripts, and why."
        }
        if refreshed != scripts {
            scripts = refreshed
        }
    }

    /// Why the machine can't be set up with what is chosen, if it can't.
    private var setupProblem: String? {
        guard let distribution = selectedDistribution else { return nil }
        return selectedScripts.problem(
            for: distribution, memorySize: UInt64(chosenMemoryGigabytes) * HostResources.gibibyte,
            diskCapacity: UInt64(chosenDiskGigabytes) * HostResources.gibibyte
        )
    }

    /// What the chosen scripts mean for the machine's first start.
    private var setupNote: String? {
        let scripts = selectedScripts
        guard let first = scripts.first else { return nil }
        var sentences: [String] = []
        if scripts.count == 1 {
            sentences.append(first.isDesktop
                ? "\(first.name) is installed the first time the machine starts, which takes about ten minutes and needs the internet."
                : "“\(first.name)” runs the first time the machine starts.")
        } else {
            sentences.append("The scripts run in this order the first time the machine starts.")
            if scripts.contains(where: \.isDesktop) {
                sentences.append("A desktop takes about ten minutes and needs the internet.")
            }
        }
        if scripts.restartsWhenDone {
            sentences.append(scripts.count == 1 ? "The machine restarts when it is done." : "The machine restarts when they are done.")
        }
        return sentences.joined(separator: " ")
    }

    /// Raises memory and disk to what the chosen scripts need. Nothing is lowered again: what was
    /// there before may have been chosen.
    private func fitHardware() {
        let scripts = selectedScripts
        if let minimum = scripts.minimumMemoryGigabytes {
            memoryGigabytes = min(max(memoryGigabytes, Double(minimum)), Self.maximumMemoryGigabytes)
        }
        if let minimum = scripts.minimumDiskGigabytes, diskGigabytes < minimum {
            diskGigabytes = Self.diskSizes.first { $0 >= minimum } ?? diskGigabytes
        }
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

    /// Whether the account can't do without a password: a desktop asks for it at its login screen,
    /// and without the SSH key it is the only way in.
    private var isPasswordRequired: Bool {
        !chosenInstallsSSHKey || selectedScripts.requiresPassword
    }

    private var accountProblem: String? {
        let user = chosenUserName
        if user.isEmpty { return nil }
        if let problem = CloudInitSeed.problem(withUserName: user) {
            return problem
        }
        if password.isEmpty, !chosenInstallsSSHKey {
            return "Set a password or turn on SSH key sign-in, otherwise nobody can sign in."
        }
        return nil
    }

    private var canCreate: Bool {
        guard !trimmedName.isEmpty, nameProblem == nil else { return false }
        guard isQuickCreate else { return installerURL != nil }
        return selectedDistribution != nil && !chosenUserName.isEmpty
            && accountProblem == nil && setupProblem == nil && !(isPasswordRequired && password.isEmpty)
    }

    /// Fills in a name based on the chosen system until the user types their own.
    private func suggestName() {
        guard !hasEditedName else { return }
        var base = "Linux"
        if isQuickCreate {
            if let distribution = selectedDistribution {
                base = distribution.name.replacingOccurrences(of: " LTS", with: "")
                if let desktop = selectedScripts.first(where: \.isDesktop) {
                    base += " \(desktop.name)"
                }
            }
        } else if let entry = catalogInstallers.first(where: { $0.installer.url == installerURL }) {
            base = entry.distribution.name.replacingOccurrences(of: " LTS", with: "")
        } else if let localISO, installerURL == localISO {
            base = localISO.deletingPathExtension().lastPathComponent
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
        let memorySize = UInt64(chosenMemoryGigabytes) * HostResources.gibibyte
        let diskCapacity = UInt64(chosenDiskGigabytes) * HostResources.gibibyte
        let starts = mode == .simple || startsWhenReady
        let ready: (VirtualMachine) -> Void = { machine in onReady(machine, starts) }

        if isQuickCreate {
            guard let distribution = selectedDistribution else { return }
            model.create(LinuxQuickCreateRequest(
                name: trimmedName,
                distribution: distribution,
                cpuCount: chosenCPUCount,
                memorySize: memorySize,
                diskCapacity: diskCapacity,
                userName: chosenUserName,
                fullName: NSFullUserName(),
                password: password,
                installsSSHKey: chosenInstallsSSHKey,
                rosetta: mode == .advanced && usesRosetta,
                setupScripts: selectedScripts
            ), onReady: ready)
        } else {
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

// MARK: - Adding setup scripts

/// The sheet that adds setup scripts to the machine that is being created: the templates the app
/// brings and the scripts in the user's folder, a file, or one written on the spot. A list fetched
/// from elsewhere would be one more thing to pick from here.
private struct SetupScriptChooser: View {
    let distribution: LinuxDistribution
    /// The machine's scripts, in the order they run.
    @Binding var scripts: [SetupScript]

    @Environment(\.dismiss) private var dismiss
    /// Every script there is for the distribution. The user's folder is read when the sheet opens and
    /// when the app comes to the front, which is when a file may have been put there.
    @State private var catalog: [SetupScript] = []
    /// The files in the user's folder that can't be scripts, and why.
    @State private var skipped: [SetupScriptCatalog.Skipped] = []
    @State private var problem: String?
    /// What was typed to narrow the list.
    @State private var filter = ""
    /// The script that is being written, while it is.
    @State private var isWriting = false
    @State private var draftName = ""
    @State private var draftSource = SetupScriptCatalog.newScriptTemplate

    var body: some View {
        VStack(spacing: 0) {
            if isWriting {
                editor
            } else {
                list
            }
        }
        .frame(width: 540, height: 540)
        .onAppear { loadCatalog() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            loadCatalog()
        }
    }

    // MARK: Picking

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Add Setup Scripts")
                        .font(.headline)
                    Text("For \(distribution.name). They run in the order you add them.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                FilterField(text: $filter)
            }
            .padding(16)

            Divider()
            if shownGroups.isEmpty, shownFiles.isEmpty, shownSkipped.isEmpty {
                ContentUnavailableView.search(text: filter)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        ForEach(shownGroups) { group in
                            card(group.title, rows: group.scripts, id: \.id) { script in
                                SetupScriptRow(script: script, turn: turn(of: script)) { toggle(script) }
                            }
                        }
                        if !shownFiles.isEmpty {
                            // Two files may go by one name, so they are told apart by what is in them.
                            card("From a File", rows: shownFiles, id: \.self) { script in
                                SetupScriptRow(script: script, turn: turn(of: script)) { toggle(script) }
                            }
                        }
                        if !shownSkipped.isEmpty {
                            // A file that was meant to be here and isn't: better said than left to wonder about.
                            card("In Your Folder, but Not a Script", rows: shownSkipped, id: \.self) { file in
                                SkippedFileRow(file: file)
                            }
                        }
                    }
                    .padding(16)
                }
            }

            Divider()
            if let problem {
                Text(problem)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding([.horizontal, .top], 16)
            }
            HStack {
                Button("New Script…") {
                    problem = nil
                    isWriting = true
                }
                Button("Choose File…") { chooseFile() }
                Button("Open Scripts Folder") { openFolder() }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        // The search field takes Escape first, to empty itself. With nothing in it the sheet goes,
        // and keeps what was added: there is nothing here to cancel.
        .onExitCommand { dismiss() }
    }

    /// The rows under one heading, on a card of their own as the sections of the form are.
    private func card<Row>(
        _ title: String, rows: [Row], id: KeyPath<Row, some Hashable>, @ViewBuilder content: @escaping (Row) -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 12)
                .accessibilityAddTraits(.isHeader)
            VStack(spacing: 0) {
                ForEach(rows, id: id) { row in
                    if row[keyPath: id] != rows.first?[keyPath: id] {
                        // From where the text starts, as the lines between the rows of a list are.
                        Divider()
                            .padding(.leading, SetupScriptRow.textInset)
                    }
                    content(row)
                }
            }
            .background(.fill.quaternary)
            .clipShape(.rect(cornerRadius: 10))
        }
    }

    /// What is listed of the catalog with the filter as it is.
    private var shownGroups: [SetupScriptCatalog.Group] {
        SetupScriptCatalog.groups(of: catalog, matching: filter)
    }

    private var shownFiles: [SetupScript] {
        files.filter { $0.matches(filter: filter) }
    }

    private var shownSkipped: [SetupScriptCatalog.Skipped] {
        let typed = filter.trimmingCharacters(in: .whitespaces)
        return typed.isEmpty ? skipped : skipped.filter { $0.fileName.localizedCaseInsensitiveContains(typed) }
    }

    /// The scripts that were added from a file, which the catalog doesn't list.
    private var files: [SetupScript] {
        scripts.filter { $0.origin == .file }
    }

    /// Whether `added`, one of the machine's scripts, is `script` from the list. One from a file is
    /// known by what is in it, and the others by their name: the folder may have been read again since.
    private func isSame(_ added: SetupScript, as script: SetupScript) -> Bool {
        script.origin == .file ? added == script : added.origin != .file && added.id == script.id
    }

    /// When `script`'s turn is among those that are added, counting from 1, or `nil` if it isn't added.
    private func turn(of script: SetupScript) -> Int? {
        scripts.firstIndex { isSame($0, as: script) }.map { $0 + 1 }
    }

    /// Adds `script`, or takes it out if it is added.
    private func toggle(_ script: SetupScript) {
        problem = nil
        if turn(of: script) == nil {
            add(script)
        } else {
            scripts.removeAll { isSame($0, as: script) }
        }
    }

    /// Adds a script to the end of the machine's, unless the machine can take no more.
    private func add(_ script: SetupScript) {
        guard scripts.count < SetupScript.maximumPerMachine else {
            problem = "A machine is set up with \(SetupScript.maximumPerMachine) scripts at most."
            return
        }
        scripts.append(script)
    }

    private func loadCatalog() {
        let listing = SetupScriptCatalog.listing()
        catalog = listing.scripts.filter { $0.supports(distribution) }
        skipped = listing.skipped
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.message = "Choose a script to run in the new virtual machine the first time it starts."
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let script = try SetupScript(contentsOf: url)
            guard script.supports(distribution) else {
                problem = "\(script.name) isn't written for \(distribution.name). It is for: \(script.systems.joined(separator: ", "))."
                return
            }
            guard !scripts.contains(where: { $0.source == script.source }) else {
                problem = "\(script.name) is added already."
                return
            }
            problem = nil
            add(script)
        } catch {
            problem = error.localizedDescription
        }
    }

    /// Shows the folder that scripts of the user's own are kept in, which is made if it isn't there.
    private func openFolder() {
        do {
            NSWorkspace.shared.open(try SetupScriptCatalog.makeUserDirectory())
            problem = nil
        } catch {
            problem = "The folder for your setup scripts couldn't be made: \(error.localizedDescription)"
        }
    }

    // MARK: Writing one

    private var editor: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Setup Script")
                .font(.headline)
            LabeledContent("Name") {
                TextField("Name", text: $draftName, prompt: Text("my-tools"))
                    .labelsHidden()
            }
            ScriptTextEditor(text: $draftSource)
                .clipShape(.rect(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
            if let problem {
                Text(problem)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Runs as root. A line it prints that starts with “==> ” is the step SwiftVM shows. It is saved under this name in your scripts folder, where you can change it later.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    problem = nil
                    isWriting = false
                }
                .keyboardShortcut(.cancelAction)
                Button("Save and Add") { saveDraft() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(draftName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16)
    }

    private func saveDraft() {
        do {
            let script = try SetupScriptCatalog.save(source: draftSource, fileName: draftName)
            loadCatalog()
            isWriting = false
            draftName = ""
            draftSource = SetupScriptCatalog.newScriptTemplate
            // Saved either way. Only what is written for this system is run on it.
            if script.supports(distribution) {
                problem = nil
                add(script)
            } else {
                problem = "\(script.name) is saved, but it isn't written for \(distribution.name), so it isn't added."
            }
        } catch {
            problem = error.localizedDescription
        }
    }
}

/// One script in the list of those to add. The whole row is its checkbox: a click anywhere on it adds
/// the script or takes it out.
private struct SetupScriptRow: View {
    let script: SetupScript
    /// When the script's turn is among those that are added, counting from 1, or `nil` if it isn't added.
    let turn: Int?
    let toggle: () -> Void

    static let markSize: CGFloat = 18
    static let spacing: CGFloat = 10
    static let padding: CGFloat = 12
    /// How far from the edge of a row its text starts.
    static let textInset = padding + markSize + spacing

    var body: some View {
        Button(action: toggle) {
            HStack(alignment: .top, spacing: Self.spacing) {
                mark
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(script.name)
                            .fontWeight(.medium)
                        if script.origin == .library {
                            Text("From your folder")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(.fill.tertiary, in: .capsule)
                        }
                        Spacer(minLength: 12)
                        needs
                    }
                    // Under the name and what the script needs, so that it has the row's whole width.
                    if let summary = script.summary {
                        Text(summary)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .buttonStyle(SetupScriptRowStyle())
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(turn.map { "Added, number \($0)" } ?? "Not added")
    }

    /// The checkbox. Ticked, it says when the script's turn is: they run in the order they are added.
    private var mark: some View {
        ZStack {
            if let turn {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.accentColor)
                Text("\(turn)")
                    .font(.caption.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(.white)
            } else {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(.fill.secondary)
            }
        }
        .frame(width: Self.markSize, height: Self.markSize)
        .accessibilityHidden(true)
    }

    /// The least memory and disk the script asks for, kept short: it is the same two things on every row.
    @ViewBuilder
    private var needs: some View {
        let memory = script.minimumMemoryGigabytes
        let disk = script.minimumDiskGigabytes
        if memory != nil || disk != nil {
            let inWords = [memory.map { "\($0) GB of memory" }, disk.map { "a disk of \($0) GB" }]
                .compactMap { $0 }
                .joined(separator: " and ")
            HStack(spacing: 4) {
                need(memory, symbol: "memorychip")
                need(disk, symbol: "internaldrive")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .help("Needs at least \(inWords)")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Needs at least \(inWords)")
        }
    }

    /// One of the two things a script can need. It keeps its place when the script doesn't say, so that
    /// memory is under memory and disk under disk all the way down the list.
    private func need(_ gigabytes: Int?, symbol: String) -> some View {
        HStack(spacing: 3) {
            if let gigabytes {
                Image(systemName: symbol)
                Text("\(gigabytes) GB")
                    .monospacedDigit()
            }
        }
        // Wider for the rare disk of three digits, and never on two lines.
        .fixedSize()
        .frame(minWidth: 52, alignment: .trailing)
    }
}

/// How a row of the list answers the pointer: lit up under it, as something that takes a click.
private struct SetupScriptRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Appearance(configuration: configuration)
    }

    /// A view of its own, because only a view can keep track of the pointer.
    private struct Appearance: View {
        let configuration: Configuration
        @State private var isHovering = false

        var body: some View {
            configuration.label
                .padding(.horizontal, SetupScriptRow.padding)
                .padding(.vertical, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.primary.opacity(configuration.isPressed ? 0.1 : isHovering ? 0.05 : 0))
                // The room around the text takes the click too.
                .contentShape(.rect)
                .onHover { isHovering = $0 }
        }
    }
}

/// A file in the user's folder that can't be a script, with why. There is nothing to click.
private struct SkippedFileRow: View {
    let file: SetupScriptCatalog.Skipped

    var body: some View {
        HStack(alignment: .top, spacing: SetupScriptRow.spacing) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .frame(width: SetupScriptRow.markSize, height: SetupScriptRow.markSize)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(file.fileName)
                    .fontWeight(.medium)
                Text(file.reason)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, SetupScriptRow.padding)
        .padding(.vertical, 9)
        .accessibilityElement(children: .combine)
    }
}

/// The field that narrows the list of scripts: the system's own search field, with the button that
/// empties it and Escape doing the same.
private struct FilterField: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = "Filter"
        field.delegate = context.coordinator
        field.setAccessibilityLabel("Filter scripts")
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        guard field.stringValue != text else { return }
        field.stringValue = text
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        private let text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            text.wrappedValue = field.stringValue
        }

        /// The button that empties the field doesn't count as typing, so it is heard of here.
        func searchFieldDidEndSearching(_ sender: NSSearchField) {
            text.wrappedValue = ""
        }
    }
}

/// A plain text editor for a script. What macOS does to prose would break a program: quotes that are
/// made to curl and two hyphens that are made a dash.
private struct ScriptTextEditor: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        textView.delegate = context.coordinator
        textView.string = text
        textView.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize + 1, weight: .regular)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.textContainerInset = NSSize(width: 4, height: 6)
        textView.setAccessibilityLabel("Script")
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView, textView.string != text else { return }
        textView.string = text
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        private let text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
        }
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

    @Binding var family: GuestFamily
    /// A restore image to start with, instead of the latest macOS.
    var initialImage: URL?
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
                    OperatingSystemPicker(selection: $family)
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
            FormButtons(problem: nameProblem, canCreate: canCreate, create: create)
        }
        .frame(height: 658)
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
