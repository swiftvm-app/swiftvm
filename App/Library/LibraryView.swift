import SwiftUI
import VMCore

/// The main window: every virtual machine, with its state and quick actions.
struct LibraryView: View {
    enum SortOrder: String, CaseIterable, Identifiable {
        case created = "Date Created"
        case name = "Name"
        case status = "Status"

        var id: Self { self }
    }

    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    @State private var selection: UUID?
    @State private var creationRequest: NewMachineRequest?
    @State private var isDropTargeted = false
    @State private var machineBeingEdited: VirtualMachine?
    @State private var machineShowingSnapshots: VirtualMachine?
    @State private var machinePendingDeletion: VirtualMachine?
    @AppStorage("library.sortOrder") private var sortOrder = SortOrder.created
    @State private var familyFilter: GuestFamily?
    @FocusState private var isListFocused: Bool

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(machines) { machine in
                        row(for: machine)
                            .id(machine.id)
                    }
                    ForEach(model.creations) { creation in
                        CreationRow(creation: creation) { model.dismiss(creation) }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 4)
                .padding(.bottom, 14)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Virtual Machines")
            }
            .onChange(of: selection) { _, newValue in
                if let newValue {
                    proxy.scrollTo(newValue)
                }
            }
        }
        .overlay {
            if model.library.machines.isEmpty, model.creations.isEmpty {
                emptyState
            } else if machines.isEmpty, model.creations.isEmpty {
                ContentUnavailableView("No Matching Machines", systemImage: "line.3.horizontal.decrease", description: Text("No virtual machine matches the current filter."))
            }
        }
        .overlay {
            if isDropTargeted {
                dropHighlight
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            handleDrop(of: urls)
        } isTargeted: { isTargeted in
            withAnimation(.easeOut(duration: 0.15)) { isDropTargeted = isTargeted }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($isListFocused)
        .onKeyPress(.upArrow) { moveSelection(by: -1) }
        .onKeyPress(.downArrow) { moveSelection(by: 1) }
        .onKeyPress(.return) { openSelection() }
        .onAppear {
            isListFocused = true
            model.showMachineWindow = { id in openWindow(id: WindowID.machine, value: id) }
        }
        .frame(minWidth: 560, minHeight: 300)
        .containerBackground(.ultraThinMaterial, for: .window)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .toolbar {
            // With the title bar hidden nothing else pushes the controls to the trailing edge.
            ToolbarSpacer(.flexible, placement: .primaryAction)
            ToolbarItemGroup(placement: .primaryAction) {
                filterMenu
                Button("New Virtual Machine", systemImage: "plus") { creationRequest = NewMachineRequest() }
                    .help("Create a virtual machine")
            }
        }
        .sheet(item: $creationRequest) { request in
            NewMachineView(request: request) { machine, startsImmediately in
                selection = machine.id
                if startsImmediately {
                    start(machine)
                }
            }
        }
        .sheet(item: $machineBeingEdited) { machine in
            MachineSettingsView(machine: machine)
        }
        .sheet(item: $machineShowingSnapshots) { machine in
            SnapshotsView(machine: machine)
        }
        .focusedSceneValue(\.machine, selectedMachine)
        .focusedSceneValue(\.machineActions, selectedMachine.map { machine in
            MachineActions(
                showSettings: { machineBeingEdited = machine },
                showSnapshots: { machineShowingSnapshots = machine }
            )
        })
        .confirmationDialog(
            "Delete “\(machinePendingDeletion?.name ?? "")”?",
            isPresented: Binding(get: { machinePendingDeletion != nil }, set: { if !$0 { machinePendingDeletion = nil } }),
            presenting: machinePendingDeletion
        ) { machine in
            Button("Move to Trash", role: .destructive) {
                if selection == machine.id {
                    selection = nil
                }
                model.delete(machine)
            }
        } message: { _ in
            Text("The virtual machine and its disks are moved to the Trash.")
        }
        .alert(
            presentedError?.title ?? "",
            isPresented: Binding(get: { presentedError != nil }, set: { if !$0 { dismissError() } }),
            presenting: presentedError
        ) { error in
            MessageButtons(message: error, dismiss: dismissError)
        } message: { error in
            Text(error.message)
        }
        .onReceive(NotificationCenter.default.publisher(for: .newMachineRequested)) { _ in
            creationRequest = NewMachineRequest()
        }
    }

    // MARK: Rows

    private var machines: [VirtualMachine] {
        let filtered = model.library.machines.filter { familyFilter == nil || $0.configuration.os.family == familyFilter }
        switch sortOrder {
        case .created:
            return filtered
        case .name:
            return filtered.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .status:
            // Stable: active machines first, otherwise library order.
            return filtered.filter(\.state.isActive) + filtered.filter { !$0.state.isActive }
        }
    }

    private var selectedMachine: VirtualMachine? {
        selection.flatMap { model.library.machine(id: $0) }
    }

    private func row(for machine: VirtualMachine) -> some View {
        let menu = MachineMenu(
            machine: machine,
            onStart: { start(machine) },
            onOpen: { open(machine) },
            onSettings: { machineBeingEdited = machine },
            onSnapshots: { machineShowingSnapshots = machine },
            onDelete: { machinePendingDeletion = machine }
        )
        return MachineRow(machine: machine, isSelected: selection == machine.id, onStart: { start(machine) }, menu: menu)
            .onTapGesture {
                selection = machine.id
                isListFocused = true
            }
            .simultaneousGesture(TapGesture(count: 2).onEnded { open(machine) })
            .contextMenu { menu }
            // What a double-click does, for someone who doesn't use the pointer.
            .accessibilityAction(named: "Open Window") { open(machine) }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Virtual Machines", systemImage: "macwindow.on.rectangle")
        } description: {
            Text("Create a virtual machine to run macOS, Linux or Windows on this Mac.")
        } actions: {
            Button("New Virtual Machine") { creationRequest = NewMachineRequest() }
                .buttonStyle(.glassProminent)
        }
    }

    private var filterMenu: some View {
        Menu("Sort and Filter", systemImage: "slider.horizontal.3") {
            Picker("Sort By", selection: $sortOrder) {
                ForEach(SortOrder.allCases) { order in
                    Text(order.rawValue).tag(order)
                }
            }
            .pickerStyle(.inline)

            Picker("Show", selection: $familyFilter) {
                Text("All Systems").tag(GuestFamily?.none)
                ForEach(GuestFamily.allCases, id: \.self) { family in
                    Text(family.displayName).tag(GuestFamily?.some(family))
                }
            }
            .pickerStyle(.inline)
        }
        .menuIndicator(.hidden)
        .help("Sort and filter")
    }

    // MARK: Dropped files

    private var dropHighlight: some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .strokeBorder(.tint, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
            .background(.tint.opacity(0.08), in: .rect(cornerRadius: 22))
            .overlay {
                Label("Drop an installer disc or restore image to create a virtual machine", systemImage: "plus.square.dashed")
                    .font(.headline)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .glassEffect(.regular, in: .capsule)
            }
            .padding(10)
            .allowsHitTesting(false)
    }

    /// Takes what was dropped on the window: machines join the library, and an installer disc (ISO) or a
    /// macOS restore image (IPSW) opens the New Virtual Machine sheet with that file chosen.
    private func handleDrop(of urls: [URL]) -> Bool {
        var didAccept = false
        for url in urls where url.pathExtension == VMBundle.pathExtension {
            do {
                selection = try model.library.add(VMBundle(url: url)).id
                didAccept = true
            } catch {
                model.generalError = VMErrorInfo(title: "Couldn't open “\(url.lastPathComponent)”", message: error.localizedDescription)
            }
        }
        // One sheet at a time: the first file a machine can be made from.
        if let request = urls.lazy.compactMap(NewMachineRequest.init(droppedFile:)).first {
            creationRequest = request
            didAccept = true
        }
        return didAccept
    }

    // MARK: Actions

    private func open(_ machine: VirtualMachine) {
        selection = machine.id
        openWindow(id: WindowID.machine, value: machine.id)
    }

    private func start(_ machine: VirtualMachine) {
        open(machine)
        Task { await machine.start() }
    }

    private func moveSelection(by offset: Int) -> KeyPress.Result {
        let list = machines
        guard !list.isEmpty else { return .ignored }
        guard let selection, let index = list.firstIndex(where: { $0.id == selection }) else {
            self.selection = (offset > 0 ? list.first : list.last)?.id
            return .handled
        }
        self.selection = list[min(max(index + offset, 0), list.count - 1)].id
        return .handled
    }

    private func openSelection() -> KeyPress.Result {
        guard let machine = machines.first(where: { $0.id == selection }) else { return .ignored }
        open(machine)
        return .handled
    }

    // MARK: Errors

    /// What to show here: app-wide problems first, then what machines whose own window isn't open have
    /// to say, errors and notices alike.
    private var presentedError: VMErrorInfo? {
        if let error = model.generalError {
            return error
        }
        return model.library.machines.first { $0.message != nil && !model.openMachineWindows.contains($0.id) }?.message
    }

    private func dismissError() {
        if model.generalError != nil {
            model.generalError = nil
        } else if let machine = model.library.machines.first(where: { $0.message != nil && !model.openMachineWindows.contains($0.id) }) {
            machine.dismissMessage()
        }
    }
}

enum WindowID {
    static let library = "library"
    static let machine = "machine"
}

extension Notification.Name {
    /// Posted by the File › New Virtual Machine command.
    static let newMachineRequested = Notification.Name("SwiftVM.newMachineRequested")
}
