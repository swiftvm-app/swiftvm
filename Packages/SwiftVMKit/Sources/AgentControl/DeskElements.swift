import CoreGraphics
import Foundation
import GuestChannel

/// One thing on the screen, as far as the app knows it between looks.
struct DeskEntry: Sendable, Equatable {
    var application: String
    /// The same on every system: see ``DeskRoles``.
    var role: String
    var name: String?
    var value: String?
    var states: [String] = []
    /// In the display's own pixels.
    var frame: CGRect?
    /// What the guest's agent knows it by. `nil` for what was read off the screen's pixels.
    var elementID: String?
    var depth = 0
    /// What the nearest named thing that holds it calls itself, other than its window, whose title
    /// comes and goes: it tells apart the Delete buttons of two rows.
    var holder: String?

    /// What says that an element in one look is the same one in the next: what it is and what it is
    /// called, and not what it holds or where it is.
    var identity: String { "\(application)\u{1F}\(holder ?? "")\u{1F}\(role)\u{1F}\(name ?? "")" }

    /// Whether `text` is what it says, or at least in it. Goes by letters and digits, as reading
    /// pixels gets those right, unless the text has none of those.
    func says(_ text: String, exactly: Bool) -> Bool {
        let wanted = text.lowercased()
        let wantedLetters = ScreenText.letters(of: text)
        for said in [name, value].compactMap({ $0 }) {
            let lowered = said.lowercased()
            let letters = ScreenText.letters(of: said)
            if exactly {
                if lowered == wanted || (!wantedLetters.isEmpty && letters == wantedLetters) { return true }
            } else if lowered.contains(wanted) || (!wantedLetters.isEmpty && letters.contains(wantedLetters)) {
                return true
            }
        }
        return false
    }

    var isInteractive: Bool { DeskRoles.interactive.contains(role) }

    /// Whether it shows as `other` does. What the guest's agent knows it by changes with every reading.
    func looksLike(_ other: DeskEntry) -> Bool {
        role == other.role && name == other.name && value == other.value && states == other.states && frame == other.frame
    }
}

/// What the guests' systems call the parts of a screen, in the few words a look uses on every system.
enum DeskRoles {
    private static let names: [String: String] = [
        // Text
        "statictext": "text", "label": "text", "text": "text", "paragraph": "text", "heading": "heading", "caption": "text",
        "description": "text", "headeritem": "text",
        // Fields
        "textfield": "textfield", "textarea": "textfield", "entry": "textfield", "edit": "textfield", "passwordtext": "textfield",
        "searchfield": "textfield", "terminal": "textfield", "securetextfield": "textfield", "spinbutton": "textfield", "document": "textfield",
        // Buttons and their like
        "button": "button", "pushbutton": "button", "splitbutton": "button", "togglebutton": "toggle", "toggle": "toggle",
        "checkbox": "checkbox", "checkmenuitem": "menuitem", "radiobutton": "radio", "radiomenuitem": "menuitem", "switch": "toggle",
        "link": "link", "hyperlink": "link", "combobox": "combobox", "popupbutton": "combobox", "menubutton": "button",
        "slider": "slider", "incrementor": "slider", "colorwell": "button", "disclosuretriangle": "button",
        // Menus and lists
        "menuitem": "menuitem", "menubaritem": "menu", "pagetab": "tab", "tabitem": "tab", "dockitem": "dockitem",
        "listitem": "item", "row": "item", "treeitem": "item", "tablerow": "item", "cell": "item", "tablecell": "item", "dataitem": "item",
        "icon": "image", "image": "image", "progressbar": "progress", "progressindicator": "progress",
        // Windows
        "window": "window", "frame": "window", "dialog": "dialog", "alert": "dialog", "sheet": "dialog", "filechooser": "dialog",
    ]

    /// What only holds other things. It shows if it has a name, as a `group`.
    private static let containers: Set<String> = [
        "application", "group", "panel", "pane", "filler", "scrollarea", "scrollpane", "viewport", "layeredpane", "splitgroup",
        "splitpane", "splitter", "toolbar", "custom", "section", "htmlcontainer", "documentweb", "documentframe", "list", "listbox", "outline",
        "tree", "treetable", "table", "datagrid", "pagetablist", "tabgroup", "tab", "menubar", "menu", "statusbar", "unknown", "titlebar", "webarea",
        "rootpane", "glasspane", "internalframe", "desktopframe", "desktoppane", "autocomplete", "form", "landmark", "article", "browser", "header",
    ]

    /// What is left out with all it holds: nothing in there is for anyone to read.
    private static let skipped: Set<String> = ["scrollbar", "ruler", "separator", "grip", "thumb", "valueindicator", "growarea", "matte", "layoutarea", "layoutitem"]

    /// What takes a click or the keyboard, and is worth showing even if it has no name.
    static let interactive: Set<String> = ["button", "toggle", "checkbox", "radio", "link", "textfield", "combobox", "slider", "tab", "menuitem", "menu"]

    private static func folded(_ role: String) -> String {
        role.lowercased().filter { $0.isLetter }
    }

    static func isSkipped(_ role: String) -> Bool {
        skipped.contains(folded(role))
    }

    /// The word for `role`, and `nil` for what only holds other things.
    static func shown(_ role: String) -> String? {
        let role = folded(role)
        if let name = names[role] { return name }
        return containers.contains(role) ? nil : role
    }
}

/// A tree of what is on the screen, as the guest's agent tells it (``GuestJob/tree(_:)``), made into the
/// short list that a look is.
struct DeskTree {
    struct Part: Decodable {
        var id: String
        var role: String
        var name: String?
        var description: String?
        var value: String?
        var states: [String]?
        var actions: [String]?
        var bounds: [Int]?
        var children: [Part]?

        private enum CodingKeys: String, CodingKey {
            case id, role, name, description, value, states, actions, bounds, children
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            role = try container.decode(String.self, forKey: .role)
            name = try? container.decodeIfPresent(String.self, forKey: .name)
            description = try? container.decodeIfPresent(String.self, forKey: .description)
            // Text, or the number that a slider or a switch is at.
            if let text = try? container.decodeIfPresent(String.self, forKey: .value) {
                value = text
            } else if let number = try? container.decodeIfPresent(Double.self, forKey: .value) {
                value = number == number.rounded() && abs(number) < 1e15 ? String(Int(number)) : String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), number)
            }
            states = try? container.decodeIfPresent([String].self, forKey: .states)
            actions = try? container.decodeIfPresent([String].self, forKey: .actions)
            bounds = try? container.decodeIfPresent([Int].self, forKey: .bounds)
            children = try? container.decodeIfPresent([Part].self, forKey: .children)
        }

        /// The place the guest says it is at. The guest can say anything: what no display could have is
        /// taken for no place, or counting with it could bring this Mac's app down.
        var frame: CGRect? {
            guard let bounds, bounds.count == 4,
                  bounds.allSatisfy({ abs($0) <= DeskTree.largestCoordinate }), bounds[2] >= 0, bounds[3] >= 0
            else { return nil }
            return CGRect(x: bounds[0], y: bounds[1], width: bounds[2], height: bounds[3])
        }

        var isActive: Bool {
            states?.contains("active") == true || children?.contains { $0.states?.contains("active") == true } == true
        }

        var hasPlaces: Bool {
            (children ?? []).contains { child in
                !DeskRoles.isWindow(child.role) && child.frame != nil || child.hasPlaces
            }
        }
    }

    struct Contents: Decodable {
        var applications: [Part]
        var truncated: Bool?
    }

    /// More than any display has, and little enough to count with.
    static let largestCoordinate = 1 << 20

    let applications: [Part]
    let isTruncated: Bool

    /// The desktop's own: they are always there, and not what anyone is working in.
    private static let shells: Set<String> = ["dock", "gnome-shell", "gjs", "plasmashell", "xfce4-panel", "xfdesktop", "cinnamon", "taskbar", "desktop"]
    /// What is behind every window. It may say it is the one in front, while nothing else is.
    private static let backdrops: Set<String> = ["gjs", "xfdesktop", "desktop"]

    init?(json: Data) {
        guard let contents = try? JSONDecoder().decode(Contents.self, from: json) else { return nil }
        applications = contents.applications
        isTruncated = contents.truncated == true
    }

    /// The names of the applications, the one in front first.
    var applicationNames: [String] {
        let names = applications.compactMap { Self.shownName($0.name) }
        guard let front = frontName else { return names }
        return [front] + names.filter { $0 != front }
    }

    /// What the application in front is called, fit to show.
    var frontName: String? {
        Self.shownName(frontApplication?.name)
    }

    /// A guest can call an application anything, control characters too, and it goes to a terminal.
    private static func shownName(_ name: String?) -> String? {
        name.map { ShownText.line($0, limit: 80) }.flatMap { $0.isEmpty ? nil : $0 }
    }

    var frontApplication: Part? {
        applications.first { $0.isActive && !Self.backdrops.contains(($0.name ?? "").lowercased()) }
            ?? applications.first { !Self.shells.contains(($0.name ?? "").lowercased()) }
            ?? applications.first
    }

    /// What to show: every application, those with `named` in their name, or the one in front.
    func entries(screen: CGRect, all: Bool = false, named: String? = nil) -> [DeskEntry] {
        let chosen: [Part]
        if let named {
            chosen = applications.filter { ($0.name ?? "").localizedCaseInsensitiveContains(named) }
        } else if all {
            chosen = applications
        } else {
            chosen = frontApplication.map { [$0] } ?? []
        }
        var entries: [DeskEntry] = []
        for application in chosen {
            let name = Self.shownName(application.name) ?? ""
            // Under Wayland an application isn't told where its parts are. Where it is told, a part that
            // has no place isn't on the screen: a menu that is closed.
            let requiresPlace = application.hasPlaces
            for child in application.children ?? [] {
                add(child, of: name, holder: nil, depth: 0, requiresPlace: requiresPlace, screen: screen, to: &entries)
            }
        }
        return entries
    }

    private func add(_ part: Part, of application: String, holder: String?, depth: Int, requiresPlace: Bool, screen: CGRect, to entries: inout [DeskEntry]) {
        guard !DeskRoles.isSkipped(part.role) else { return }
        let frame = part.frame
        // A closed menu has no place, and neither has anything in it.
        if requiresPlace, frame == nil, !DeskRoles.isWindow(part.role), part.role.lowercased().contains("menu") { return }
        var childDepth = depth
        var childHolder = holder
        let isOnScreen = frame.map { $0.width >= 4 && $0.height >= 4 && $0.intersects(screen) } ?? !requiresPlace
        if isOnScreen, var entry = entry(for: part, of: application, frame: frame, depth: depth) {
            entry.holder = holder
            // What a button says is often said a second time by the text inside it.
            let repeatsHolder = entries.last.map { holder in
                holder.depth < depth && entry.role == "text" && holder.name == entry.name && holder.frame?.intersects(frame ?? .zero) != false
            } ?? false
            // Windows tells a dialog twice: by itself, and in the window it belongs to.
            let isTold = frame != nil && entries.contains { $0.role == entry.role && $0.name == entry.name && $0.frame == entry.frame && $0.value == entry.value }
            if !repeatsHolder, !isTold {
                entries.append(entry)
                childDepth = depth + 1
                if entry.name != nil, !DeskRoles.isWindow(part.role) { childHolder = entry.name }
            }
        }
        for child in part.children ?? [] {
            add(child, of: application, holder: childHolder, depth: childDepth, requiresPlace: requiresPlace, screen: screen, to: &entries)
        }
    }

    private static let shownStates: Set<String> = ["focused", "selected", "checked", "disabled", "expanded", "pressed"]

    private func entry(for part: Part, of application: String, frame: CGRect?, depth: Int) -> DeskEntry? {
        let name = (part.name ?? part.description).map { ShownText.line($0, limit: 120) }.flatMap { $0.isEmpty ? nil : $0 }
        var value = part.value.map { ShownText.line($0, limit: 240) }.flatMap { $0.isEmpty || $0 == name ? nil : $0 }
        var states = (part.states ?? []).filter(Self.shownStates.contains)
        let shown = DeskRoles.shown(part.role)
        // A Linux text box is called text like any label, and only says that it can be written in.
        let isEditable = part.states?.contains("editable") == true
        let role: String
        if let shown {
            role = shown == "text" && isEditable ? "textfield" : shown
            // macOS says how a box or a radio button stands as a number.
            if role == "checkbox" || role == "radio" || role == "toggle", value == "0" || value == "1" {
                if value == "1", !states.contains("checked") { states.append("checked") }
                value = nil
            }
        } else if name != nil {
            role = "group"
        } else {
            return nil
        }
        // Nameless parts are only worth a line if they can be used, or have the keyboard.
        guard name != nil || value != nil || DeskRoles.interactive.contains(role) || states.contains("focused") else { return nil }
        return DeskEntry(application: application, role: role, name: name, value: value, states: states, frame: frame, elementID: part.id, depth: depth)
    }
}

extension DeskRoles {
    static func isWindow(_ role: String) -> Bool {
        let name = shown(role)
        return name == "window" || name == "dialog"
    }
}

/// Puts what was read off a screen's pixels together with what its accessibility said: what only the
/// pixels know is added, and what has no place of its own gets the one the pixels show.
enum DeskOCR {
    static func merged(_ lines: [ScreenText.Line], into entries: [DeskEntry]) -> [DeskEntry] {
        var result = entries
        for line in lines {
            let text = ShownText.line(line.text, limit: 200)
            let letters = ScreenText.letters(of: text)
            guard !letters.isEmpty else { continue }
            let middle = CGPoint(x: line.frame.midX, y: line.frame.midY)
            let isKnown = result.contains { entry in
                guard let frame = entry.frame, frame.contains(middle) else { return false }
                return [entry.name, entry.value].compactMap { $0 }.contains { said in
                    let saidLetters = ScreenText.letters(of: said)
                    return saidLetters.contains(letters) || letters.contains(saidLetters) && !saidLetters.isEmpty
                }
            }
            if isKnown { continue }
            if let placeless = result.firstIndex(where: { $0.frame == nil && ScreenText.letters(of: $0.name ?? "") == letters }) {
                result[placeless].frame = line.frame
                continue
            }
            result.append(DeskEntry(application: "", role: "ocr", name: text, frame: line.frame, depth: 0))
        }
        return result
    }
}

/// Gives what is on the screen its numbers, which stay with an element from look to look.
struct DeskNumbering {
    private var numbers: [String: Int] = [:]
    private var next = 1

    /// Numbers `entries`, and returns them with their numbers. Two with the same name are told apart by
    /// their order, top to bottom.
    mutating func number(_ entries: [DeskEntry]) -> [(number: Int, entry: DeskEntry)] {
        var seen: [String: Int] = [:]
        return entries.map { entry in
            let ordinal = seen[entry.identity, default: 0]
            seen[entry.identity] = ordinal + 1
            let key = "\(entry.identity)\u{1F}\(ordinal)"
            if let number = numbers[key] { return (number, entry) }
            let number = next
            next += 1
            numbers[key] = number
            return (number, entry)
        }
    }
}
