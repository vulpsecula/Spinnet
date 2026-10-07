import Foundation

/// Plugin API Level 2 addition (#81): how a page looks, beyond what it
/// holds. Structured Component Styles (colours, font size and weight,
/// backgrounds) on the components that draw content; a `column` beside
/// Level 2's `row`; `icon` components and item icons drawn from system
/// symbols; `image` components the Host loads from an Image Source (a
/// resource in the Plugin's package, or an HTTPS address the Plugin may
/// contact); and `progress`, a task's stages and status with no percentage
/// the Plugin does not know, and a cancel View Action.
///
/// These were appended to Level 2 while it is still open (PluginAPI
/// README), so a Plugin pinned to an earlier commit of Level 2 lacks them.
/// No Component Style is inherited, and none reaches the Host's fields,
/// buttons, Collections or chrome.
public enum PagePresentation {
    /// A component may carry a `style`.
    public static let componentStyle = PluginInterfaceMember.behaviour("component_style")
    /// A Collection's item may carry an `icon`, a system symbol.
    public static let itemIcons = PluginInterfaceMember.behaviour("item_icons")
    /// The Host loads an `image` component's Image Source with the authority
    /// of the session's handler.
    public static let hostLoadedImages = PluginInterfaceMember.behaviour("host_loaded_images")

    public static let componentKinds = ["column", "icon", "image", "progress"]
    public static let behaviours = ["component_style", "item_icons", "host_loaded_images"]

    /// What this addition appends to Level 2.
    public static let members: [PluginInterfaceMember] =
        componentKinds.map(PluginInterfaceMember.viewComponent) + behaviours.map(PluginInterfaceMember.behaviour)

    // MARK: Limits

    /// Components a `column` holds.
    public static let maximumColumnChildren = 8
    /// Rows and columns nest at most this deep: a row in a column in a row.
    public static let maximumContainerDepth = 3
    public static let fontSizes: ClosedRange<Double> = 9...40
    public static let paddings: ClosedRange<Double> = 0...24
    public static let cornerRadii: ClosedRange<Double> = 0...16
    public static let iconSizes: ClosedRange<Double> = 10...64
    public static let defaultIconSize: Double = 16
    /// An image's frame, in points: up to the page's content width.
    public static let imageSides: ClosedRange<Double> = 16...412
    public static let maximumSymbolNameLength = 64
    public static let maximumResourcePathLength = 256
    public static let maximumImageURLLength = 2_048
    public static let maximumStatusLength = 256
    public static let stages = 2...8
}

// MARK: - Component Styles

/// A colour a Component Style gives: a fixed sRGB value, one of the Host's
/// named colours, which follow light and dark appearance and Increase
/// Contrast, or one value for each appearance.
public indirect enum PluginPageColor: Equatable {
    public enum Name: String, CaseIterable, Equatable {
        case primary, secondary, tertiary, accent
        case blue, indigo, purple, pink, red, orange, yellow, green, teal, gray
    }

    /// Components from 0 to 1.
    case rgb(red: Double, green: Double, blue: Double, alpha: Double)
    case named(Name)
    case appearance(light: PluginPageColor, dark: PluginPageColor)

    init(parsing value: JSONValue, _ name: String) throws {
        switch value {
        case .string(let text):
            self = try Self.single(text, name)
        case .object:
            let members = try PluginPage.object(value, name, allowed: ["light", "dark"])
            guard case .string(let light)? = members["light"], case .string(let dark)? = members["dark"] else {
                throw PluginPage.violation("\(name) gives both light and dark as colours")
            }
            self = .appearance(light: try Self.single(light, "\(name)'s light"), dark: try Self.single(dark, "\(name)'s dark"))
        default:
            throw PluginPage.violation("\(name) is not a colour")
        }
    }

    private static func single(_ text: String, _ name: String) throws -> PluginPageColor {
        if let named = Name(rawValue: text) { return .named(named) }
        let hex = text.hasPrefix("#") ? String(text.dropFirst()) : ""
        guard hex.count == 6 || hex.count == 8, hex.allSatisfy(\.isHexDigit), let value = UInt64(hex, radix: 16) else {
            throw PluginPage.violation("\(name) must be #RRGGBB, #RRGGBBAA or one of "
                + Name.allCases.map(\.rawValue).joined(separator: ", "))
        }
        let full = hex.count == 6 ? value << 8 | 0xFF : value
        func channel(_ shift: UInt64) -> Double { Double((full >> shift) & 0xFF) / 255 }
        return .rgb(red: channel(24), green: channel(16), blue: channel(8), alpha: channel(0))
    }
}

/// The weights a Component Style may give text.
public enum PluginPageFontWeight: String, CaseIterable, Equatable {
    case regular, medium, semibold, bold
}

/// A component's own visual attributes. Each kind takes only the members
/// that mean something for it; a container's style is its own background,
/// never its children's.
public struct PluginPageStyle: Equatable {
    public enum Member: String, CaseIterable {
        case color, background
        case fontSize = "font_size"
        case fontWeight = "font_weight"
        case monospacedDigits = "monospaced_digits"
        case padding
        case cornerRadius = "corner_radius"
    }

    public var color: PluginPageColor?
    public var background: PluginPageColor?
    /// Points at the Host's default text size, scaled with it.
    public var fontSize: Double?
    public var fontWeight: PluginPageFontWeight?
    public var monospacedDigits = false
    public var padding: Double?
    public var cornerRadius: Double?

    public init() {}

    /// The members each kind takes.
    public static func members(of kind: String) -> [Member] {
        switch kind {
        case "text": return [.color, .background, .fontSize, .fontWeight, .monospacedDigits, .padding, .cornerRadius]
        case "row", "column": return [.background, .padding, .cornerRadius]
        case "image": return [.background, .cornerRadius]
        case "icon", "progress": return [.color]
        default: return []
        }
    }

    /// Reads `members["style"]` of a component of `kind`, or nil when it has
    /// none; refuses it from a Plugin the addition is not offered to.
    static func parse(_ members: [String: JSONValue], kind: String, id: String,
                      permits: (PluginInterfaceMember) -> Bool) throws -> PluginPageStyle? {
        guard let value = members["style"] else { return nil }
        guard permits(PagePresentation.componentStyle) else {
            throw PluginPage.violation("The \(kind) \(id) has unknown member style")
        }
        let name = "The \(kind) \(id)'s style"
        let fields = try PluginPage.object(value, name, allowed: Set(Self.members(of: kind).map(\.rawValue)))
        var style = PluginPageStyle()
        style.color = try fields["color"].map { try PluginPageColor(parsing: $0, "\(name)'s color") }
        style.background = try fields["background"].map { try PluginPageColor(parsing: $0, "\(name)'s background") }
        style.fontSize = try fields["font_size"].map { try number($0, "\(name)'s font_size", in: PagePresentation.fontSizes) }
        if let weight = fields["font_weight"] {
            guard case .string(let text) = weight, let parsed = PluginPageFontWeight(rawValue: text) else {
                throw PluginPage.violation("\(name)'s font_weight must be one of "
                    + PluginPageFontWeight.allCases.map(\.rawValue).joined(separator: ", "))
            }
            style.fontWeight = parsed
        }
        style.monospacedDigits = try PluginPage.flag(fields["monospaced_digits"], "\(name)'s monospaced_digits")
        style.padding = try fields["padding"].map { try number($0, "\(name)'s padding", in: PagePresentation.paddings) }
        style.cornerRadius = try fields["corner_radius"].map {
            try number($0, "\(name)'s corner_radius", in: PagePresentation.cornerRadii)
        }
        return style
    }

    static func number(_ value: JSONValue, _ name: String, in range: ClosedRange<Double>) throws -> Double {
        guard case .number(let number) = value, range.contains(number) else {
            throw PluginPage.violation("\(name) is not a number from \(format(range.lowerBound)) to \(format(range.upperBound))")
        }
        return number
    }

    static func format(_ number: Double) -> String {
        number.rounded() == number ? String(Int(number)) : String(number)
    }
}

// MARK: - Containers

/// A `row`, side by side, or a `column`, top to bottom: layout containers
/// that hold other components and draw nothing of their own but their
/// style's background.
public struct PluginPageStack: Equatable {
    public enum Axis: Equatable { case horizontal, vertical }

    public let id: String
    public let axis: Axis
    public let content: [PluginPageComponent]
    public let style: PluginPageStyle?

    public init(id: String, axis: Axis, content: [PluginPageComponent], style: PluginPageStyle? = nil) {
        self.id = id
        self.axis = axis
        self.content = content
        self.style = style
    }
}

/// A `text` component: text in the Markdown subset, with an optional
/// title and Component Style.
public struct PluginPageText: Equatable {
    public let id: String
    public let title: String?
    public let text: String
    public let style: PluginPageStyle?

    public init(id: String, title: String? = nil, text: String, style: PluginPageStyle? = nil) {
        self.id = id
        self.title = title
        self.text = text
        self.style = style
    }
}

// MARK: - Icons and images

/// A system symbol, as an `icon` component or an item's `icon` names it: a
/// lower-case SF Symbols name such as `cpu` or `memorychip`. A name the
/// running macOS lacks draws nothing in its place.
public struct PluginPageSymbol: Equatable, Hashable {
    public let name: String

    init(parsing value: JSONValue?, _ name: String) throws {
        let fields = try PluginPage.object(value ?? .null, name, allowed: ["symbol"])
        guard case .string(let symbol)? = fields["symbol"], Self.isValid(symbol) else {
            throw PluginPage.violation("\(name) names a system symbol such as cpu or memorychip, "
                + "in lower-case letters, digits and dots, at most \(PagePresentation.maximumSymbolNameLength) characters")
        }
        self.name = symbol
    }

    public init(name: String) { self.name = name }

    static func isValid(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= PagePresentation.maximumSymbolNameLength,
              !name.hasPrefix("."), !name.hasSuffix("."), !name.contains("..") else { return false }
        return name.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "." }
    }
}

/// Where an `image` component's picture comes from. Reading it checks only
/// its shape; the Host checks the authority to load it each time it loads.
public enum PluginImageSource: Equatable, Hashable {
    /// A PNG or JPEG file inside the Plugin's package, by its path from
    /// the package's root.
    case resource(String)
    /// A PNG or JPEG at an `https` address the session's handler may contact.
    case url(URL)

    init(parsing value: JSONValue?, _ name: String) throws {
        let fields = try PluginPage.object(value ?? .null, name, allowed: ["resource", "url"])
        switch (fields["resource"], fields["url"]) {
        case (.string(let path)?, nil):
            guard Self.isValidResourcePath(path) else {
                throw PluginPage.violation("\(name)'s resource must be a relative path inside the package to a "
                    + ".png, .jpg or .jpeg file, without . or .. parts, at most \(PagePresentation.maximumResourcePathLength) characters")
            }
            self = .resource(path)
        case (nil, .string(let address)?):
            guard address.count <= PagePresentation.maximumImageURLLength, let url = URL(string: address),
                  HTTPSDestination.host(of: url) != nil, url.fragment == nil else {
                throw PluginPage.violation("\(name)'s url must be an https address without a user, password, port or "
                    + "fragment, at most \(PagePresentation.maximumImageURLLength) characters")
            }
            self = .url(url)
        default:
            throw PluginPage.violation("\(name) gives either a resource or a url")
        }
    }

    /// A relative path of plain components naming a PNG or JPEG.
    static func isValidResourcePath(_ path: String) -> Bool {
        guard !path.isEmpty, path.count <= PagePresentation.maximumResourcePathLength, !path.hasPrefix("/"),
              !path.contains("\\"), !path.contains("\0") else { return false }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.hasPrefix(".") }) else { return false }
        let ext = (path as NSString).pathExtension.lowercased()
        return ["png", "jpg", "jpeg"].contains(ext)
    }

    /// The host an HTTPS source contacts.
    public var host: String? {
        if case .url(let url) = self { return HTTPSDestination.host(of: url) }
        return nil
    }

    public var json: JSONValue {
        switch self {
        case .resource(let path): return .object(["resource": .string(path)])
        case .url(let url): return .object(["url": .string(url.absoluteString)])
        }
    }
}

/// An `icon` component: a system symbol at a size, tinted by its style's
/// colour. With a `label` VoiceOver reads it; without one it is decoration.
public struct PluginPageIcon: Equatable {
    public let id: String
    public let symbol: PluginPageSymbol
    public let label: String?
    public let size: Double
    public let style: PluginPageStyle?

    init(parsing value: JSONValue, permits: (PluginInterfaceMember) -> Bool) throws {
        let members = try PluginPage.object(value, "An icon", allowed: ["kind", "id", "source", "label", "size", "style"])
        let id = try PluginPage.identifier(members["id"], "An icon's id")
        self.id = id
        symbol = try PluginPageSymbol(parsing: members["source"], "The icon \(id)'s source")
        label = try members["label"].map { try PluginPage.text($0, "The icon \(id)'s label", maximum: CollectionsContract.maximumTitleLength) }
        size = try members["size"].map { try PluginPageStyle.number($0, "The icon \(id)'s size", in: PagePresentation.iconSizes) }
            ?? PagePresentation.defaultIconSize
        style = try PluginPageStyle.parse(members, kind: "icon", id: id, permits: permits)
    }
}

/// An `image` component: a picture the Host loads from its Image Source
/// into a frame of the given size, which it keeps while loading and when
/// the load fails, so the page does not move. `label` is what VoiceOver
/// reads.
public struct PluginPageImage: Equatable {
    public enum Fit: String, CaseIterable, Equatable {
        /// The whole picture, within the frame.
        case fit
        /// The frame filled, the picture's overflow cropped.
        case fill
    }

    public let id: String
    public let source: PluginImageSource
    public let label: String
    public let width: Double
    public let height: Double
    public let fit: Fit
    public let style: PluginPageStyle?

    init(parsing value: JSONValue, permits: (PluginInterfaceMember) -> Bool) throws {
        let members = try PluginPage.object(value, "An image", allowed: [
            "kind", "id", "source", "label", "width", "height", "fit", "style"
        ])
        let id = try PluginPage.identifier(members["id"], "An image's id")
        self.id = id
        source = try PluginImageSource(parsing: members["source"], "The image \(id)'s source")
        label = try PluginPage.text(members["label"], "The image \(id)'s label", maximum: CollectionsContract.maximumTitleLength)
        guard let width = members["width"], let height = members["height"] else {
            throw PluginPage.violation("The image \(id) gives its width and height, so the page does not move as it loads")
        }
        self.width = try PluginPageStyle.number(width, "The image \(id)'s width", in: PagePresentation.imageSides)
        self.height = try PluginPageStyle.number(height, "The image \(id)'s height", in: PagePresentation.imageSides)
        if let declared = members["fit"] {
            guard case .string(let name) = declared, let fit = Fit(rawValue: name) else {
                throw PluginPage.violation("The image \(id)'s fit must be fit or fill")
            }
            self.fit = fit
        } else {
            fit = .fit
        }
        style = try PluginPageStyle.parse(members, kind: "image", id: id, permits: permits)
    }

    /// What the Host loads for it: its source, decoded to its frame at
    /// twice its size in points, for a Retina screen.
    public var request: PageImageRequest {
        PageImageRequest(source: source, maximumPixelSize: Int((max(width, height) * 2).rounded(.up)))
    }
}

/// One picture the Host loads for a page: its source, decoded so its
/// longer edge is at most `maximumPixelSize`.
public struct PageImageRequest: Equatable, Hashable {
    public let source: PluginImageSource
    public let maximumPixelSize: Int

    public init(source: PluginImageSource, maximumPixelSize: Int) {
        self.source = source
        self.maximumPixelSize = maximumPixelSize
    }
}

// MARK: - Progress

/// A `progress` component: how a task the Plugin describes is going. It is
/// indeterminate unless the Plugin gives the `value` it knows; the Host
/// never derives one from the stages. `stages` name the steps, the
/// current one `stage`; `state` says whether it still runs; and `cancel`
/// is a View Action the Host draws while it runs, which sends
/// `action_chosen` so the Plugin can attempt to cancel. Cancelling never
/// means anything is undone.
public struct PluginPageProgress: Equatable {
    public enum State: String, CaseIterable, Equatable {
        case running, cancelling, succeeded, failed, cancelled
    }

    public struct Stage: Equatable {
        public let id: String
        public let title: String
    }

    public let id: String
    public let title: String?
    /// The fraction done, from 0 to 1, only when the Plugin knows it.
    public let value: Double?
    public let status: String?
    public let stages: [Stage]
    /// The stage under way: those before it are done.
    public let stage: String?
    public let state: State
    /// The cancel View Action: its event ID and title.
    public let cancel: (id: String, title: String)?
    public let style: PluginPageStyle?

    public static func == (lhs: PluginPageProgress, rhs: PluginPageProgress) -> Bool {
        lhs.id == rhs.id && lhs.title == rhs.title && lhs.value == rhs.value && lhs.status == rhs.status
            && lhs.stages == rhs.stages && lhs.stage == rhs.stage && lhs.state == rhs.state
            && lhs.cancel?.id == rhs.cancel?.id && lhs.cancel?.title == rhs.cancel?.title && lhs.style == rhs.style
    }

    init(parsing value: JSONValue, permits: (PluginInterfaceMember) -> Bool) throws {
        let members = try PluginPage.object(value, "A progress component", allowed: [
            "kind", "id", "title", "value", "status", "stages", "stage", "state", "cancel", "style"
        ])
        let id = try PluginPage.identifier(members["id"], "A progress component's id")
        self.id = id
        title = try members["title"].map { try PluginPage.text($0, "The progress \(id)'s title", maximum: CollectionsContract.maximumTitleLength) }
        self.value = try members["value"].map { try PluginPageStyle.number($0, "The progress \(id)'s value", in: 0...1) }
        status = try members["status"].map {
            try PluginPage.text($0, "The progress \(id)'s status", allowsBlank: true, maximum: PagePresentation.maximumStatusLength)
        }
        if let declared = members["stages"] {
            let parsed = try PluginPage.array(declared, "The progress \(id)'s stages", minimum: PagePresentation.stages.lowerBound,
                                              maximum: PagePresentation.stages.upperBound).map { value -> Stage in
                let fields = try PluginPage.object(value, "A stage of \(id)", allowed: ["id", "title"])
                let stage = try PluginPage.identifier(fields["id"], "A stage of \(id)'s id")
                return Stage(id: stage, title: try PluginPage.text(fields["title"], "The stage \(stage)'s title",
                                                                  maximum: CollectionsContract.maximumTitleLength))
            }
            guard Set(parsed.map(\.id)).count == parsed.count else {
                throw PluginPage.violation("The progress \(id) has two stages with one ID")
            }
            stages = parsed
        } else {
            stages = []
        }
        stage = try members["stage"].map { try PluginPage.identifier($0, "The progress \(id)'s stage") }
        if let stage, !stages.contains(where: { $0.id == stage }) {
            throw PluginPage.violation("The progress \(id)'s stage names \(stage), which is not one of its stages")
        }
        if let declared = members["state"] {
            guard case .string(let name) = declared, let state = State(rawValue: name) else {
                throw PluginPage.violation("The progress \(id)'s state must be one of "
                    + State.allCases.map(\.rawValue).joined(separator: ", "))
            }
            self.state = state
        } else {
            state = .running
        }
        if let declared = members["cancel"] {
            let fields = try PluginPage.object(declared, "The progress \(id)'s cancel", allowed: ["id", "title"])
            let action = try PluginPage.identifier(fields["id"], "The progress \(id)'s cancel id")
            cancel = (action, try fields["title"].map { try PluginPage.text($0, "The progress \(id)'s cancel title") } ?? "Cancel")
        } else {
            cancel = nil
        }
        style = try PluginPageStyle.parse(members, kind: "progress", id: id, permits: permits)
    }

    /// Whether the Host draws its cancel View Action now.
    public var offersCancel: Bool { cancel != nil && state == .running }

    /// Where each stage is: done, under way, or still to come. A failed or
    /// cancelled task stops at its stage; a succeeded one is done
    /// throughout.
    public enum StageState: Equatable { case done, current, failed, pending }

    public func state(of stage: Stage) -> StageState {
        guard let index = stages.firstIndex(of: stage) else { return .pending }
        if state == .succeeded { return .done }
        guard let current = self.stage.flatMap({ id in stages.firstIndex { $0.id == id } }) else { return .pending }
        if index < current { return .done }
        if index > current { return .pending }
        return state == .failed || state == .cancelled ? .failed : .current
    }

    /// What VoiceOver reads: its title, the stage under way, its status
    /// and its state, and the value only when the Plugin gave one.
    public var accessibilityValue: String {
        var parts: [String] = []
        if let stage, let found = stages.first(where: { $0.id == stage }),
           let index = stages.firstIndex(of: found) {
            parts.append("\(found.title), stage \(index + 1) of \(stages.count)")
        }
        if let status, !status.isEmpty { parts.append(status) }
        switch state {
        case .running: if let value { parts.append("\(Int((value * 100).rounded())) percent") } else { parts.append("In progress") }
        case .cancelling: parts.append("Cancelling")
        case .succeeded: parts.append("Done")
        case .failed: parts.append("Failed")
        case .cancelled: parts.append("Cancelled")
        }
        return parts.joined(separator: ", ")
    }
}
