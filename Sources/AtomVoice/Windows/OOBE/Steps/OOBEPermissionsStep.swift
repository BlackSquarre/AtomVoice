import Cocoa

final class OOBEPermissionsStep: OOBEStep {
    private let permissionService: PermissionService
    private var permissionCards: [OOBEPermissionCardView] = []
    private var permissionRefreshTimer: Timer?

    init(permissionService: PermissionService) {
        self.permissionService = permissionService
    }

    func makeView() -> NSView {
        let v = NSStackView()
        v.orientation = .vertical
        v.alignment = .leading
        v.spacing = 0

        let heading = NSTextField(labelWithString: loc("oobe.perm.heading"))
        heading.font = .systemFont(ofSize: 22, weight: .semibold)
        v.addArrangedSubview(heading)
        v.setCustomSpacing(6, after: heading)

        let sub = NSTextField(labelWithString: loc("oobe.perm.subtitle"))
        sub.font = .systemFont(ofSize: 12.5)
        sub.textColor = .secondaryLabelColor
        sub.lineBreakMode = .byWordWrapping
        sub.maximumNumberOfLines = 0
        sub.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        v.addArrangedSubview(sub)
        sub.widthAnchor.constraint(equalTo: v.widthAnchor).isActive = true
        v.setCustomSpacing(18, after: sub)

        // 三张横排竖版卡片（Three vertical cards arranged horizontally）
        let cards = NSStackView()
        cards.orientation = .horizontal
        cards.distribution = .fillEqually
        cards.spacing = 12
        cards.translatesAutoresizingMaskIntoConstraints = false

        permissionCards = []
        let perms: [(String, String, String, NSColor, Int)] = [
            (loc("permission.accessibility.title"), loc("permission.accessibility.desc"),
             "accessibility", NSColor.systemBlue, 0),
            (loc("permission.microphone.title"),    loc("permission.microphone.desc"),
             "mic.fill", NSColor.systemPink, 1),
            (loc("permission.speech.title"),         loc("permission.speech.desc"),
             "waveform", NSColor.systemPurple, 2),
        ]
        for p in perms {
            let card = OOBEPermissionCardView(title: p.0, desc: p.1, iconName: p.2,
                                              iconColor: p.3, tag: p.4,
                                              target: self, action: #selector(permTapped(_:)))
            cards.addArrangedSubview(card)
            permissionCards.append(card)
        }
        v.addArrangedSubview(cards)
        cards.widthAnchor.constraint(equalTo: v.widthAnchor).isActive = true

        refreshPermissions()
        return v
    }

    func willAppear() {
        startPermissionRefresh()
    }

    func willDisappear() {
        stopPermissionRefresh()
    }

    private func startPermissionRefresh() {
        permissionRefreshTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.refreshPermissions()
        }
    }
    private func stopPermissionRefresh() {
        permissionRefreshTimer?.invalidate()
        permissionRefreshTimer = nil
    }
    private func refreshPermissions() {
        guard permissionCards.count >= 3 else { return }
        permissionCards[0].update(status: permissionService.status(for: .accessibility))
        permissionCards[1].update(status: permissionService.status(for: .microphone))
        permissionCards[2].update(status: permissionService.status(for: .speechRecognition))
    }

    @objc private func permTapped(_ sender: NSButton) {
        guard let kind = PermissionKind(permissionCardTag: sender.tag) else { return }
        permissionService.requestOrOpenSettings(for: kind) { [weak self] in
            self?.refreshPermissions()
        }
    }

}
