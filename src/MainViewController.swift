import AppKit

enum Mode { case none, compress, extract }
enum Phase { case idle, working, done, failed }

final class MainViewController: NSViewController {

    // MARK: 状态

    private var items: [URL] = []
    private var mode: Mode = .none
    private var phase: Phase = .idle
    private var level = 5
    private var strongEncryption = false
    private var passwordPlain = false
    private var reencryptMode = false
    private var autoNested = false
    /// 重新加密默认覆盖原文件：保留无密码副本等于没加密
    private var keepOriginal = false

    private let runner = BatchRunner()
    private var jobs: [Job] = []
    private var rows: [UUID: JobRowView] = [:]
    private var lastSucceeded = 0
    private var lastFailed = 0

    // MARK: UI

    /// 统一尺寸，避免各处散落魔法数字
    private enum Metrics {
        static let width: CGFloat = 440      // 480 窗口 − 左右各 20
        static let radius: CGFloat = 10
        static let rowHeight: CGFloat = 34
        static let footerHeight: CGFloat = 56
    }

    private let stack = NSStackView()
    private var dropZone: DropZoneView!
    private var headerMode: NSTextField!

    private var fileCard: NSView!
    private var fileIconView: NSImageView!
    private var fileNameLabel: NSTextField!
    private var fileMetaLabel: NSTextField!

    private var jobBox: NSView!
    private var jobScroll: NSScrollView!
    private var jobList: NSStackView!
    private var jobHeight: NSLayoutConstraint!

    private var compressSettings: NSStackView!
    private var levelSegment: NSSegmentedControl!
    private var encryptionSegment: NSSegmentedControl!
    private var encryptionHint: NSTextField!
    private var nameWarning: NSTextField!

    private var optionsArea: NSStackView!
    private var reencryptOption: NSView!
    private var nestedOption: NSView!
    private var reencryptCheck: NSButton!
    private var nestedCheck: NSButton!

    private var passwordArea: NSStackView!
    private var passwordTitle: NSTextField!
    private var passwordPlainField: NSTextField!
    private var passwordSecureField: NSSecureTextField!
    private var revealButton: NSButton!
    private var strengthBar: StrengthBar!
    private var strengthLabel: NSTextField!
    private var strengthRow: NSStackView!

    private var progressArea: NSStackView!
    private var progressIndicator: NSProgressIndicator!
    private var progressLabel: NSTextField!

    private var resultArea: NSStackView!
    private var resultIcon: NSImageView!
    private var resultLabel: NSTextField!
    private var resultDetail: NSTextField!
    private var errorArea: NSStackView!
    private var errorIcon: NSImageView!
    private var errorLabel: NSTextField!

    private var footer: NSView!
    private var footerHeight: NSLayoutConstraint!
    private var footerSummary: NSTextField!
    private var actionButton: NSButton!
    private var secondaryButton: NSButton!

    // MARK: 生命周期

    override func loadView() {
        let root = DragReceiverView(frame: NSRect(x: 0, y: 0, width: 480, height: 520))
        root.wantsLayer = true
        root.handler = self
        root.onHoverChange = { [weak self] hover in self?.dropZone.isHover = hover }
        root.registerForDraggedTypes([.fileURL])
        view = root
        buildUI()
        wireRunner()
        refresh()
    }

    /// loadView 阶段窗口还不存在，高度自适应要等真正上屏后再做一次
    override func viewDidAppear() {
        super.viewDidAppear()
        fitWindowHeight()
    }

    // MARK: 构建 UI

    private func buildUI() {
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        // 顶部留出交通灯的高度（窗口用了 fullSizeContentView）
        stack.edgeInsets = NSEdgeInsets(top: 36, left: 20, bottom: 18, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        buildFooter()
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: footer.topAnchor),
        ])

        buildHeader()
        buildDropZone()
        buildFileCard()
        buildJobList()
        buildCompressSettings()
        buildOptions()
        buildPasswordArea()
        buildProgress()
        buildResult()
        buildError()
        buildSpacer()
    }

    // MARK: 标题栏

    private func buildHeader() {
        let badge = CardView()
        badge.fill = NSColor.controlAccentColor.withAlphaComponent(0.15)
        badge.borderColor = nil
        badge.cornerRadius = 9
        badge.translatesAutoresizingMaskIntoConstraints = false
        badge.widthAnchor.constraint(equalToConstant: 32).isActive = true
        badge.heightAnchor.constraint(equalToConstant: 32).isActive = true

        let icon = NSImageView(image: NSImage(systemSymbolName: "shippingbox.fill",
                                              accessibilityDescription: nil)!)
        icon.contentTintColor = .controlAccentColor
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 16, weight: .semibold)
        icon.translatesAutoresizingMaskIntoConstraints = false
        badge.addSubview(icon)
        NSLayoutConstraint.activate([
            icon.centerXAnchor.constraint(equalTo: badge.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: badge.centerYAnchor),
        ])

        let title = NSTextField(labelWithString: "Squash")
        title.font = .systemFont(ofSize: 16, weight: .semibold)
        title.setContentHuggingPriority(.defaultLow, for: .horizontal)

        headerMode = NSTextField(labelWithString: "")
        headerMode.font = .systemFont(ofSize: 11, weight: .medium)
        headerMode.textColor = .tertiaryLabelColor
        headerMode.alignment = .right

        let row = NSStackView(views: [badge, title, NSView(), headerMode])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.widthAnchor.constraint(equalToConstant: Metrics.width).isActive = true
        stack.addArrangedSubview(row)
    }

    // MARK: 拖放区

    private func buildDropZone() {
        dropZone = DropZoneView()
        dropZone.widthAnchor.constraint(equalToConstant: Metrics.width).isActive = true
        // 优先级低于 required：NSStackView 靠 1000 优先级的零高度约束隐藏子视图，
        // 这里若也用 required 会打架，导致隐藏后仍占着位置留一片空白
        let h = dropZone.heightAnchor.constraint(equalToConstant: 200)
        h.priority = .defaultHigh
        h.isActive = true
        dropZone.onTap = { [weak self] in self?.openPanel() }
        stack.addArrangedSubview(dropZone)
    }

    /// 统一卡片容器：系统控件底色 + 细边框 + 圆角
    private func card(_ inner: NSView, insets: NSEdgeInsets) -> CardView {
        let box = CardView()
        box.cornerRadius = Metrics.radius
        inner.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(inner)
        NSLayoutConstraint.activate([
            inner.topAnchor.constraint(equalTo: box.topAnchor, constant: insets.top),
            inner.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -insets.bottom),
            inner.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: insets.left),
            inner.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -insets.right),
        ])
        return box
    }

    private func buildFileCard() {
        fileIconView = NSImageView()
        fileIconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 24, weight: .regular)
        fileIconView.contentTintColor = .controlAccentColor
        fileIconView.imageScaling = .scaleProportionallyUpOrDown
        fileIconView.widthAnchor.constraint(equalToConstant: 32).isActive = true

        fileNameLabel = NSTextField(labelWithString: "")
        fileNameLabel.font = .systemFont(ofSize: 13.5, weight: .medium)
        fileNameLabel.lineBreakMode = .byTruncatingMiddle

        fileMetaLabel = NSTextField(labelWithString: "")
        fileMetaLabel.font = .systemFont(ofSize: 11)
        fileMetaLabel.textColor = .secondaryLabelColor
        fileMetaLabel.lineBreakMode = .byTruncatingTail

        let col = NSStackView(views: [fileNameLabel, fileMetaLabel])
        col.orientation = .vertical
        col.alignment = .leading
        col.spacing = 2

        let inner = NSStackView(views: [fileIconView, col])
        inner.orientation = .horizontal
        inner.alignment = .centerY
        inner.spacing = 12

        fileCard = card(inner, insets: NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14))
        fileCard.widthAnchor.constraint(equalToConstant: Metrics.width).isActive = true
        stack.addArrangedSubview(fileCard)
    }

    /// 多文件时的任务列表
    private func buildJobList() {
        jobList = NSStackView()
        jobList.orientation = .vertical
        jobList.alignment = .leading
        jobList.spacing = 0
        jobList.translatesAutoresizingMaskIntoConstraints = false

        let box = CardView()
        box.cornerRadius = Metrics.radius
        box.translatesAutoresizingMaskIntoConstraints = false

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = jobList
        scroll.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: box.topAnchor, constant: 6),
            scroll.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -6),
            scroll.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: box.trailingAnchor),
        ])
        jobHeight = box.heightAnchor.constraint(equalToConstant: Metrics.rowHeight + 12)
        jobHeight.priority = .defaultHigh
        jobHeight.isActive = true
        jobScroll = scroll
        jobBox = box
        box.widthAnchor.constraint(equalToConstant: Metrics.width).isActive = true
        stack.addArrangedSubview(box)

        NSLayoutConstraint.activate([
            jobList.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            jobList.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            jobList.widthAnchor.constraint(equalToConstant: Metrics.width),
        ])
    }

    /// 「压缩比  [标准|更小]」这类设置行，标签定宽保证纵向对齐
    private func settingRow(_ title: String, _ control: NSView) -> NSStackView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 11.5)
        label.textColor = .secondaryLabelColor
        label.widthAnchor.constraint(equalToConstant: 60).isActive = true
        label.setContentHuggingPriority(.required, for: .horizontal)

        let row = NSStackView(views: [label, control, NSView()])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 6
        row.widthAnchor.constraint(equalToConstant: Metrics.width).isActive = true
        return row
    }

    private func buildCompressSettings() {
        levelSegment = NSSegmentedControl(labels: ["标准", "更小"],
                                          trackingMode: .selectOne,
                                          target: self, action: #selector(levelChanged))
        levelSegment.selectedSegment = 0
        levelSegment.setWidth(88, forSegment: 0)
        levelSegment.setWidth(88, forSegment: 1)

        encryptionSegment = NSSegmentedControl(labels: ["通用 ZIP", "强加密 AES-256"],
                                               trackingMode: .selectOne,
                                               target: self, action: #selector(encryptionChanged))
        encryptionSegment.selectedSegment = 0
        encryptionSegment.setWidth(116, forSegment: 0)
        encryptionSegment.setWidth(150, forSegment: 1)

        compressSettings = NSStackView(views: [
            settingRow("压缩比", levelSegment),
            settingRow("加密方式", encryptionSegment),
        ])
        compressSettings.orientation = .vertical
        compressSettings.alignment = .leading
        compressSettings.spacing = 8
        compressSettings.widthAnchor.constraint(equalToConstant: Metrics.width).isActive = true
        stack.addArrangedSubview(compressSettings)
    }

    /// 解压模式下的两个行为选项
    private func buildOptions() {
        reencryptCheck = NSButton(checkboxWithTitle: "给这个压缩包设置密码",
                                  target: self, action: #selector(reencryptChanged))
        reencryptCheck.font = .systemFont(ofSize: 12.5)
        reencryptCheck.state = .off

        nestedCheck = NSButton(checkboxWithTitle: "自动继续解压内部的压缩包",
                               target: self, action: #selector(nestedChanged))
        nestedCheck.font = .systemFont(ofSize: 12.5)
        nestedCheck.state = .off

        reencryptOption = optionRow(reencryptCheck,
                                    detail: "解包后重新打包并覆盖原文件，原包会被替换")
        nestedOption = optionRow(nestedCheck,
                                 detail: "最多向下解压 3 层嵌套压缩包")

        optionsArea = NSStackView(views: [reencryptOption, nestedOption])
        optionsArea.orientation = .vertical
        optionsArea.alignment = .leading
        optionsArea.spacing = 10
        optionsArea.widthAnchor.constraint(equalToConstant: Metrics.width).isActive = true
        stack.addArrangedSubview(optionsArea)
    }

    /// 复选框 + 说明行，说明缩进到标题起始位置
    private func optionRow(_ check: NSButton, detail: String) -> NSView {
        let note = NSTextField(wrappingLabelWithString: detail)
        note.font = .systemFont(ofSize: 10.5)
        note.textColor = .tertiaryLabelColor

        let box = NSView()
        check.translatesAutoresizingMaskIntoConstraints = false
        note.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(check)
        box.addSubview(note)
        NSLayoutConstraint.activate([
            box.widthAnchor.constraint(equalToConstant: Metrics.width),
            check.topAnchor.constraint(equalTo: box.topAnchor),
            check.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            check.trailingAnchor.constraint(lessThanOrEqualTo: box.trailingAnchor),
            note.topAnchor.constraint(equalTo: check.bottomAnchor, constant: 1),
            note.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 20),
            note.trailingAnchor.constraint(lessThanOrEqualTo: box.trailingAnchor, constant: -4),
            note.bottomAnchor.constraint(equalTo: box.bottomAnchor),
        ])
        return box
    }

    private func buildPasswordArea() {
        passwordTitle = NSTextField(labelWithString: "解压密码")
        passwordTitle.font = .systemFont(ofSize: 11.5)
        passwordTitle.textColor = .secondaryLabelColor

        strengthLabel = NSTextField(labelWithString: "")
        strengthLabel.font = .systemFont(ofSize: 10.5)
        strengthLabel.textColor = .secondaryLabelColor
        strengthBar = StrengthBar()
        strengthBar.heightAnchor.constraint(equalToConstant: 4).isActive = true
        strengthBar.widthAnchor.constraint(equalToConstant: 64).isActive = true
        strengthRow = NSStackView(views: [strengthBar, strengthLabel])
        strengthRow.orientation = .horizontal
        strengthRow.alignment = .centerY
        strengthRow.spacing = 6

        let titleRow = NSStackView(views: [passwordTitle, NSView(), strengthRow])
        titleRow.orientation = .horizontal
        titleRow.alignment = .centerY
        titleRow.widthAnchor.constraint(equalToConstant: Metrics.width).isActive = true

        passwordSecureField = NSSecureTextField()
        passwordSecureField.placeholderString = "输入密码"
        passwordSecureField.font = .systemFont(ofSize: 13)
        passwordSecureField.target = self
        passwordSecureField.action = #selector(passwordEdited)
        passwordSecureField.delegate = self
        passwordSecureField.heightAnchor.constraint(equalToConstant: 30).isActive = true
        passwordSecureField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        passwordPlainField = NSTextField()
        passwordPlainField.placeholderString = "输入密码"
        passwordPlainField.font = .systemFont(ofSize: 13)
        passwordPlainField.target = self
        passwordPlainField.action = #selector(passwordEdited)
        passwordPlainField.delegate = self
        passwordPlainField.heightAnchor.constraint(equalToConstant: 30).isActive = true
        passwordPlainField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        passwordPlainField.isHidden = true

        revealButton = NSButton(image: NSImage(systemSymbolName: "eye",
                                               accessibilityDescription: "显示密码")!,
                                target: self, action: #selector(toggleReveal))
        revealButton.bezelStyle = .inline
        revealButton.isBordered = false
        revealButton.toolTip = "显示 / 隐藏密码"
        revealButton.widthAnchor.constraint(equalToConstant: 28).isActive = true
        revealButton.heightAnchor.constraint(equalToConstant: 30).isActive = true

        let pwdRow = NSStackView(views: [passwordSecureField, passwordPlainField, revealButton])
        pwdRow.orientation = .horizontal
        pwdRow.alignment = .centerY
        pwdRow.spacing = 6
        pwdRow.widthAnchor.constraint(equalToConstant: Metrics.width).isActive = true

        encryptionHint = NSTextField(wrappingLabelWithString: "")
        encryptionHint.font = .systemFont(ofSize: 10.5)
        encryptionHint.textColor = .secondaryLabelColor
        encryptionHint.preferredMaxLayoutWidth = Metrics.width

        nameWarning = NSTextField(wrappingLabelWithString:
            "ZIP 格式无法隐藏文件名：加密后仍能看到包内有哪些文件")
        nameWarning.font = .systemFont(ofSize: 10.5)
        nameWarning.textColor = .tertiaryLabelColor
        nameWarning.preferredMaxLayoutWidth = Metrics.width
        nameWarning.isHidden = true

        passwordArea = NSStackView(views: [titleRow, pwdRow, encryptionHint, nameWarning])
        passwordArea.orientation = .vertical
        passwordArea.alignment = .leading
        passwordArea.spacing = 6
        passwordArea.setCustomSpacing(8, after: pwdRow)
        passwordArea.widthAnchor.constraint(equalToConstant: Metrics.width).isActive = true
        stack.addArrangedSubview(passwordArea)
    }

    // MARK: 底部操作栏

    /// 操作按钮统一收到窗口底栏：左边是结果摘要，右边是主/次按钮。
    /// 好处是主按钮不再是一条横贯整窗的色块，窗口高度变化时按钮也不会跳来跳去。
    private func buildFooter() {
        footer = NSView()
        footer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(footer)

        let line = Hairline()
        line.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(line)

        footerSummary = NSTextField(labelWithString: "")
        footerSummary.font = .systemFont(ofSize: 11.5)
        footerSummary.textColor = .secondaryLabelColor
        footerSummary.lineBreakMode = .byTruncatingTail
        footerSummary.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        secondaryButton = NSButton(title: "再处理一批", target: self, action: #selector(secondaryTapped))
        secondaryButton.bezelStyle = .rounded
        secondaryButton.controlSize = .large
        secondaryButton.font = .systemFont(ofSize: 13)
        secondaryButton.heightAnchor.constraint(equalToConstant: 32).isActive = true
        secondaryButton.setContentHuggingPriority(.required, for: .horizontal)
        secondaryButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        secondaryButton.isHidden = true

        actionButton = NSButton(title: "解压", target: self, action: #selector(primaryTapped))
        actionButton.bezelStyle = .rounded
        actionButton.controlSize = .large
        actionButton.keyEquivalent = "\r"
        actionButton.font = .systemFont(ofSize: 13, weight: .semibold)
        actionButton.heightAnchor.constraint(equalToConstant: 32).isActive = true
        actionButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 104).isActive = true
        // 主按钮固定用强调色，不依赖「窗口是否为 key」来决定颜色
        actionButton.bezelColor = .controlAccentColor
        actionButton.contentTintColor = .white
        // 底栏是 fill 分布，必须让按钮按自身内容宽度，否则会被拉满整行
        actionButton.setContentHuggingPriority(.required, for: .horizontal)
        actionButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        let row = NSStackView(views: [footerSummary, secondaryButton, actionButton])
        row.orientation = .horizontal
        row.alignment = .centerY
        // 必须 fill，否则按钮会紧贴摘要而不是靠到窗口右侧
        row.distribution = .fill
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(row)

        footerHeight = footer.heightAnchor.constraint(equalToConstant: Metrics.footerHeight)
        NSLayoutConstraint.activate([
            footer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            footerHeight,
            line.topAnchor.constraint(equalTo: footer.topAnchor),
            line.leadingAnchor.constraint(equalTo: footer.leadingAnchor),
            line.trailingAnchor.constraint(equalTo: footer.trailingAnchor),
            line.heightAnchor.constraint(equalToConstant: 1),
            row.topAnchor.constraint(equalTo: footer.topAnchor, constant: 12),
            row.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: 20),
            row.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -20),
        ])
    }

    private func setFooterVisible(_ visible: Bool) {
        footer.isHidden = !visible
        footerHeight.constant = visible ? Metrics.footerHeight : 0
    }

    private func buildProgress() {
        progressIndicator = NSProgressIndicator()
        progressIndicator.isIndeterminate = false
        progressIndicator.minValue = 0
        progressIndicator.maxValue = 100
        progressIndicator.doubleValue = 0
        progressIndicator.controlSize = .regular
        progressIndicator.widthAnchor.constraint(equalToConstant: Metrics.width).isActive = true

        progressLabel = NSTextField(labelWithString: "")
        progressLabel.font = .monospacedDigitSystemFont(ofSize: 11.5, weight: .regular)
        progressLabel.textColor = .secondaryLabelColor
        progressLabel.lineBreakMode = .byTruncatingMiddle

        progressArea = NSStackView(views: [progressIndicator, progressLabel])
        progressArea.orientation = .vertical
        progressArea.alignment = .leading
        progressArea.spacing = 8
        progressArea.widthAnchor.constraint(equalToConstant: Metrics.width).isActive = true
        stack.addArrangedSubview(progressArea)
    }

    private func buildResult() {
        resultIcon = NSImageView()
        resultIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 34, weight: .regular)
        resultIcon.contentTintColor = .systemGreen

        resultLabel = NSTextField(labelWithString: "")
        resultLabel.font = .systemFont(ofSize: 13, weight: .medium)
        resultLabel.alignment = .center
        resultLabel.lineBreakMode = .byTruncatingMiddle
        resultLabel.maximumNumberOfLines = 3
        resultLabel.preferredMaxLayoutWidth = Metrics.width

        resultDetail = NSTextField(labelWithString: "")
        resultDetail.font = .systemFont(ofSize: 11)
        resultDetail.textColor = .tertiaryLabelColor
        resultDetail.alignment = .center
        resultDetail.lineBreakMode = .byTruncatingMiddle
        resultDetail.maximumNumberOfLines = 2
        resultDetail.preferredMaxLayoutWidth = Metrics.width

        resultArea = NSStackView(views: [resultIcon, resultLabel, resultDetail])
        resultArea.orientation = .vertical
        resultArea.alignment = .centerX
        resultArea.spacing = 10
        resultArea.setCustomSpacing(14, after: resultIcon)
        resultArea.edgeInsets = NSEdgeInsets(top: 40, left: 0, bottom: 20, right: 0)
        resultArea.widthAnchor.constraint(equalToConstant: Metrics.width).isActive = true
        stack.addArrangedSubview(resultArea)
    }

    private func buildError() {
        errorIcon = NSImageView()
        errorIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 34, weight: .regular)
        errorIcon.contentTintColor = .systemRed

        errorLabel = NSTextField(wrappingLabelWithString: "")
        errorLabel.font = .systemFont(ofSize: 12.5)
        errorLabel.textColor = .labelColor
        errorLabel.alignment = .center
        errorLabel.preferredMaxLayoutWidth = Metrics.width

        errorArea = NSStackView(views: [errorIcon, errorLabel])
        errorArea.orientation = .vertical
        errorArea.alignment = .centerX
        errorArea.spacing = 12
        errorArea.edgeInsets = NSEdgeInsets(top: 40, left: 0, bottom: 20, right: 0)
        errorArea.widthAnchor.constraint(equalToConstant: Metrics.width).isActive = true
        stack.addArrangedSubview(errorArea)
    }

    private func buildSpacer() {
        let s = NSView()
        s.setContentHuggingPriority(.init(1), for: .vertical)
        s.setContentCompressionResistancePriority(.init(1), for: .vertical)
        stack.addArrangedSubview(s)
    }

    // MARK: 执行器回调

    private func wireRunner() {
        runner.onJobUpdate = { [weak self] job in
            guard let self else { return }
            if let row = self.rows[job.id] {
                row.update()
            } else {
                self.rebuildRows()
            }
        }
        // 嵌套解压会往队列里追加任务，必须把内部数组同步回来
        runner.onJobsChanged = { [weak self] jobs in
            guard let self else { return }
            self.jobs = jobs
            self.rebuildRows()
        }
        runner.onProgress = { [weak self] value, label in
            guard let self else { return }
            self.progressIndicator.doubleValue = value
            self.progressLabel.stringValue = "\(Int(value))%  \(label)"
        }
        runner.onComplete = { [weak self] ok, failed in
            guard let self else { return }
            self.lastSucceeded = ok
            self.lastFailed = failed
            self.phase = failed > 0 && ok == 0 ? .failed : .done
            self.finishUI()
        }
    }

    private func finishUI() {
        progressIndicator.doubleValue = 100

        let firstError = jobs.first { $0.state == .failed }?.message ?? ""
        let fixedNames = jobs.filter { $0.state == .done && $0.message.contains("文件名编码") }.count
        let encodingNote = fixedNames > 0 ? "已自动修正 \(fixedNames) 个包的文件名编码" : ""
        let outputDir = jobs.compactMap { $0.output }.first?
            .deletingLastPathComponent().path ?? ""

        if lastFailed == 0 {
            resultIcon.image = NSImage(systemSymbolName: "checkmark.circle.fill",
                                       accessibilityDescription: nil)
            resultIcon.contentTintColor = .systemGreen
            if jobs.count == 1 {
                resultLabel.stringValue = jobs[0].output.map {
                    "已完成 \($0.lastPathComponent)"
                } ?? "已完成"
            } else {
                resultLabel.stringValue = "\(lastSucceeded) 个任务全部完成"
            }
            // 补一行「落在哪」，比单放一个对勾更能说明结果
            resultDetail.stringValue = [encodingNote, outputDir.isEmpty ? "" : prettyPath(outputDir)]
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
        } else if lastSucceeded == 0 {
            resultIcon.image = NSImage(systemSymbolName: "xmark.circle.fill",
                                       accessibilityDescription: nil)
            resultIcon.contentTintColor = .systemRed
            // 全部失败时界面走 errorArea，这里必须一并填上，否则会是一片空白
            errorIcon.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill",
                                      accessibilityDescription: nil)
            errorLabel.stringValue = lastFailed == 1
                ? (firstError.isEmpty ? "没能完成" : firstError)
                : "\(lastFailed) 个任务都没能完成\n\(firstError)"
            resultLabel.stringValue = "失败：\(firstError)"
            resultDetail.stringValue = ""
        } else {
            resultIcon.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill",
                                       accessibilityDescription: nil)
            resultIcon.contentTintColor = .systemOrange
            resultLabel.stringValue = "\(lastSucceeded) 个完成，\(lastFailed) 个失败"
            resultDetail.stringValue = firstError
        }
        refresh()
    }

    /// 路径里把家目录缩成 ~，避免一行被撑爆
    private func prettyPath(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    // MARK: 刷新

    private func refresh() {
        let multi = items.count > 1
        dropZone.isHidden   = !(phase == .idle && mode == .none)
        // 结束时由结果区接管，不再重复显示文件卡片；进行中保留卡片，画面不会空掉
        fileCard.isHidden   = multi || mode == .none || phase == .done || phase == .failed
        jobBox.isHidden     = !multi || phase == .done || phase == .failed
        compressSettings.isHidden = !(phase == .idle && (mode == .compress || reencryptMode))
        optionsArea.isHidden      = !(phase == .idle && mode == .extract)
        passwordArea.isHidden     = !(phase == .idle && mode != .none)
        progressArea.isHidden     = phase != .working
        resultArea.isHidden       = phase != .done
        errorArea.isHidden        = phase != .failed

        reencryptOption.isHidden = !(phase == .idle && mode == .extract
                                     && items.count == 1 && canReencrypt)
        nestedOption.isHidden = reencryptMode

        headerMode.stringValue = headerModeText
        passwordTitle.stringValue = mode == .extract && !reencryptMode
            ? "解压密码"
            : (reencryptMode ? "新密码" : "压缩密码")
        strengthRow.isHidden = mode == .extract && !reencryptMode

        if !items.isEmpty && !multi {
            fileIconView.image = NSImage(systemSymbolName:
                mode == .extract ? "doc.zipper" : "doc",
                accessibilityDescription: nil)
            fileNameLabel.stringValue = items[0].lastPathComponent
            fileMetaLabel.stringValue = fileMetaText()
        }
        if multi {
            rebuildRows()
        }

        updatePasswordFeedback()
        configureFooter()
        fitWindowHeight()
    }

    /// 右上角的一句话状态，替代原来空白的标题栏右侧
    private var headerModeText: String {
        switch phase {
        case .working: return "处理中"
        case .done:    return "已完成"
        case .failed:  return "有任务失败"
        case .idle:
            if mode == .none { return "拖入或点选文件" }
            if reencryptMode { return "加密码" }
            return mode == .extract ? "解压" : "压缩"
        }
    }

    /// 单文件卡片第二行：大小 · 类型
    private func fileMetaText() -> String {
        let size = totalSizeText()
        if mode == .compress && items.count > 1 {
            return "\(size) · \(items.count) 个项目"
        }
        let ext = items[0].pathExtension.uppercased()
        guard !ext.isEmpty else { return size }
        return mode == .extract ? "\(size) · \(ext) 压缩包" : "\(size) · \(ext) 文件"
    }

    /// 底栏：左侧摘要 + 右侧主/次按钮，随阶段切换
    private func configureFooter() {
        let hasAction = !(phase == .idle && mode == .none)
        setFooterVisible(hasAction)
        guard hasAction else { return }

        switch phase {
        case .idle:
            footerSummary.stringValue = idleSummary
            secondaryButton.isHidden = true
            actionButton.isHidden = false
            actionButton.title = actionTitle
            actionButton.isEnabled = !(reencryptMode && currentPassword().isEmpty)
        case .working:
            footerSummary.stringValue = "正在处理…"
            secondaryButton.isHidden = false
            secondaryButton.title = "取消"
            actionButton.isHidden = true
        case .done:
            footerSummary.stringValue = ""
            secondaryButton.isHidden = false
            secondaryButton.title = "再处理一批"
            actionButton.isHidden = false
            actionButton.title = "在 Finder 中显示"
            actionButton.isEnabled = !jobs.compactMap { $0.output }.isEmpty
        case .failed:
            footerSummary.stringValue = ""
            secondaryButton.isHidden = false
            secondaryButton.title = "换一批文件"
            actionButton.isHidden = false
            actionButton.title = "重试"
            actionButton.isEnabled = true
        }
    }

    private var idleSummary: String {
        let size = totalSizeText()
        if reencryptMode { return "将覆盖原压缩包 · \(size)" }
        if mode == .compress { return "\(items.count) 个文件 · \(size)" }
        let archives = items.filter { ArchiveScan.isArchive($0) }.count
        return "\(archives) 个压缩包 · \(size)"
    }

    /// 让窗口高度贴着内容走，别在按钮下面留一大片空白
    private func fitWindowHeight() {
        guard phase != .working, let window = view.window else { return }
        view.layoutSubtreeIfNeeded()
        let footerH = footer.isHidden ? 0 : footerHeight.constant
        let target = max(stack.fittingSize.height + footerH, 300)
        let current = view.bounds.height
        guard abs(target - current) > 4 else { return }
        let delta = target - current
        var f = window.frame
        f.size.height += delta
        f.origin.y -= delta                // 顶边保持不动
        window.setFrame(f, display: true, animate: false)
    }

    private var actionTitle: String {
        if reencryptMode { return "加密这个压缩包" }
        if mode == .extract {
            return items.count > 1 ? "解压 \(items.count) 个压缩包" : "解压"
        }
        return items.count > 1 ? "打包成一个 ZIP" : "压缩为 ZIP"
    }

    private var canReencrypt: Bool {
        guard let f = items.first else { return false }
        return f.pathExtension.lowercased() == "zip"
    }

    /// 密码相关的可视反馈：强度、加密方式说明、文件名暴露警告
    private func updatePasswordFeedback() {
        let pwd = currentPassword()
        let hasPwd = !pwd.isEmpty
        let needsPwdFields = (mode == .compress) || reencryptMode

        if needsPwdFields {
            nameWarning.isHidden = !hasPwd
            if hasPwd {
                encryptionHint.stringValue = strongEncryption
                    ? "AES-256 加密。对方需安装 7-Zip / WinRAR / Bandizip 才能打开，Windows 资源管理器会报错。"
                    : "ZipCrypto 加密。Windows 资源管理器、Mac 归档工具双击输密码即可打开，但强度较弱，仅能防随手翻看。"
            } else {
                encryptionHint.stringValue = reencryptMode
                    ? "必须填写新密码，否则重新加密没有意义。"
                    : "留空则直接打包为通用 ZIP，不加密。"
            }
            let score = Self.passwordScore(pwd)
            strengthBar.score = score
            switch score {
            case 0: strengthLabel.stringValue = ""
            case 1...2: strengthLabel.stringValue = "弱"
            case 3...4: strengthLabel.stringValue = "中"
            default: strengthLabel.stringValue = "强"
            }
            strengthRow.isHidden = !hasPwd
        } else {
            nameWarning.isHidden = true
            encryptionHint.stringValue = "仅加密的压缩包需要密码；留空会自动跳过已加密的包。"
            strengthRow.isHidden = true
        }
        if phase == .idle { configureFooter() }
    }

    static func passwordScore(_ s: String) -> Int {
        guard !s.isEmpty else { return 0 }
        var score = 0
        if s.count >= 8 { score += 1 }
        if s.count >= 12 { score += 1 }
        if s.count >= 16 { score += 1 }
        if s.rangeOfCharacter(from: .lowercaseLetters) != nil,
           s.rangeOfCharacter(from: .uppercaseLetters) != nil { score += 1 }
        if s.rangeOfCharacter(from: .decimalDigits) != nil { score += 1 }
        if s.rangeOfCharacter(from: .punctuationCharacters) != nil ||
           s.rangeOfCharacter(from: .symbols) != nil { score += 1 }
        return score
    }

    private func currentPassword() -> String {
        passwordPlain ? passwordPlainField.stringValue : passwordSecureField.stringValue
    }

    private func totalSizeText() -> String {
        var total: Int64 = 0
        for url in items {
            if let v = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64 {
                total += v
            }
        }
        return humanSize(total)
    }

    // MARK: 任务行

    private func rebuildRows() {
        for v in jobList.arrangedSubviews { jobList.removeArrangedSubview(v); v.removeFromSuperview() }
        rows.removeAll()
        for (index, job) in jobs.enumerated() {
            let row = JobRowView(job: job, showsSeparator: index < jobs.count - 1)
            jobList.addArrangedSubview(row)
            row.widthAnchor.constraint(equalToConstant: Metrics.width).isActive = true
            rows[job.id] = row
        }
        // 高度跟着行数走，避免 3 行撑出空白
        if jobHeight != nil {
            let needed = CGFloat(jobs.count) * Metrics.rowHeight + 12
            jobHeight.constant = min(max(needed, Metrics.rowHeight + 12),
                                     Metrics.rowHeight * 5 + 12)
        }
        jobList.layoutSubtreeIfNeeded()
    }

    // MARK: 输入

    func setItems(_ urls: [URL]) {
        guard phase != .working else { return }
        items = Array(urls.prefix(64))
        rows.removeAll()
        reencryptMode = false
        reencryptCheck.state = .off
        passwordSecureField.stringValue = ""
        passwordPlainField.stringValue = ""
        phase = .idle

        if items.isEmpty {
            mode = .none
        } else if items.allSatisfy({ ArchiveScan.isArchive($0) }) {
            mode = .extract
        } else if items.allSatisfy({ !ArchiveScan.isArchive($0) }) {
            mode = .compress
        } else {
            // 混合：压缩包各自解压，普通文件不参与（避免继承解压密码去压缩）
            mode = .extract
        }
        // 先把待执行队列建出来，这样还没点按钮就能看到要做什么
        jobs = buildJobs()
        refresh()
    }

    private func openPanel() {
        let p = NSOpenPanel()
        p.canChooseFiles = true
        p.canChooseDirectories = true
        p.allowsMultipleSelection = true
        p.message = "选择要压缩或解压的文件（可多选）"
        p.beginSheetModal(for: view.window!) { [weak self] resp in
            guard resp == .OK, !p.urls.isEmpty else { return }
            self?.setItems(p.urls)
        }
    }

    // MARK: 动作

    /// 底栏主按钮：同一颗按钮按阶段承担不同职责
    @objc private func primaryTapped() {
        switch phase {
        case .idle:    startTapped()
        case .done:    revealTapped()
        case .failed:  retryTapped()
        case .working: break
        }
    }

    @objc private func secondaryTapped() {
        switch phase {
        case .working: cancelTapped()
        case .done, .failed, .idle: resetTapped()
        }
    }

    @objc private func levelChanged() {
        level = [5, 9][levelSegment.selectedSegment]
    }

    @objc private func encryptionChanged() {
        strongEncryption = encryptionSegment.selectedSegment == 1
        updatePasswordFeedback()
    }

    @objc private func passwordEdited() {
        updatePasswordFeedback()
    }

    @objc private func nestedChanged() {
        autoNested = nestedCheck.state == .on
    }

    @objc private func reencryptChanged() {
        reencryptMode = reencryptCheck.state == .on
        jobs = buildJobs()
        refresh()
    }

    /// 在密文 / 明文两个字段之间切换，值保持同步
    @objc private func toggleReveal() {
        let value = currentPassword()
        passwordPlain.toggle()
        if passwordPlain {
            passwordPlainField.stringValue = value
            passwordSecureField.isHidden = true
            passwordPlainField.isHidden = false
            view.window?.makeFirstResponder(passwordPlainField)
            revealButton.image = NSImage(systemSymbolName: "eye.slash",
                                         accessibilityDescription: "隐藏密码")
        } else {
            passwordSecureField.stringValue = value
            passwordPlainField.isHidden = true
            passwordSecureField.isHidden = false
            view.window?.makeFirstResponder(passwordSecureField)
            revealButton.image = NSImage(systemSymbolName: "eye",
                                         accessibilityDescription: "显示密码")
        }
        updatePasswordFeedback()
    }

    @objc private func startTapped() {
        jobs = buildJobs()
        guard !jobs.isEmpty else { return }

        var settings = BatchSettings()
        settings.level = level
        settings.password = currentPassword()
        settings.strongEncryption = strongEncryption
        settings.autoNested = autoNested
        settings.keepOriginal = keepOriginal

        phase = .working
        progressIndicator.doubleValue = 0
        progressLabel.stringValue = "准备中…"
        refresh()
        rebuildRows()
        runner.run(jobs, settings: settings)
    }

    private func buildJobs() -> [Job] {
        if reencryptMode {
            guard let f = items.first else { return [] }
            return [Job(sources: [f], kind: .reencrypt)]
        }
        switch mode {
        case .extract:
            // 混合拖入时只处理压缩包：把解压密码顺带当成压缩密码会出事
            return items.filter { ArchiveScan.isArchive($0) }
                .map { Job(sources: [$0], kind: .extract) }
        case .compress:
            guard !items.isEmpty else { return [] }
            return [Job(sources: items, kind: .compress)]
        case .none:
            return []
        }
    }

    @objc private func cancelTapped() {
        runner.cancel()
    }

    @objc private func resetTapped() {
        setItems([])
    }

    @objc private func retryTapped() {
        phase = .idle
        refresh()
    }

    @objc private func revealTapped() {
        let outputs = jobs.compactMap { $0.output }
        guard !outputs.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(outputs)
    }

    // MARK: 外部入口

    /// 供 --snapshot 自检使用：直接触发主按钮，方便截到「进行中 / 完成」两种界面
    func startForSnapshot() {
        guard phase == .idle, mode != .none else { return }
        startTapped()
    }

    /// Finder 右键「添加密码」进来时直接进入重新加密模式并聚焦密码框
    func activateEncryptMode() {
        guard canReencrypt else { return }
        reencryptCheck.state = .on
        reencryptMode = true
        refresh()
        let field: NSTextField = passwordPlain ? passwordPlainField : passwordSecureField
        view.window?.makeFirstResponder(field)
    }

    /// 右键「用 Squash 解压」：强制走解压，不受自动判断影响
    func activateExtractMode() {
        force(mode: .extract)
    }

    /// 右键「用 Squash 压缩」：强制走压缩
    func activateCompressMode() {
        force(mode: .compress)
    }

    private func force(mode target: Mode) {
        guard phase != .working, !items.isEmpty else { return }
        reencryptMode = false
        reencryptCheck.state = .off
        mode = target
        jobs = buildJobs()
        refresh()
    }

    // MARK: 拖放（由 DragReceiverView 转发）

    func dragEntered() -> Bool { phase != .working }

    func dragExited() {
        dropZone.isHover = false
    }

    func dropped(_ urls: [URL]) -> Bool {
        dropZone.isHover = false
        guard !urls.isEmpty else { return false }
        setItems(urls)
        return true
    }
}

extension MainViewController: DragHandler {}

extension MainViewController: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        updatePasswordFeedback()
    }
}

// MARK: - 基础绘制组件

/// 简洁的体积文案：229 B / 12.4 KB / 1.2 MB。
/// 系统的 ByteCountFormatter 会跟随系统语言输出「229 bytes」，和中文界面不搭。
func humanSize(_ bytes: Int64) -> String {
    let units = ["B", "KB", "MB", "GB", "TB"]
    guard bytes >= 1024 else { return "\(bytes) B" }
    var value = Double(bytes)
    var index = 0
    while value >= 1024 && index < units.count - 1 {
        value /= 1024
        index += 1
    }
    return String(format: value >= 100 ? "%.0f %@" : "%.1f %@", value, units[index])
}

extension NSColor {
    private static func dynamic(_ name: String,
                                light: CGFloat,
                                dark: CGFloat) -> NSColor {
        NSColor(name: name) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(calibratedWhite: dark, alpha: 1)
                : NSColor(calibratedWhite: light, alpha: 1)
        }
    }

    /// 窗口画布：比卡片略深/略浅一点，让卡片能立起来
    static var squashCanvas: NSColor { dynamic("squashCanvas", light: 0.960, dark: 0.105) }

    /// 卡片底色：深色下要比画布亮一档，否则只剩描边能看出边界
    static var squashCard: NSColor { dynamic("squashCard", light: 1.0, dark: 0.158) }

    /// 拖放区虚线：深色下要收一点，否则白花花一圈太抢眼
    static var squashDash: NSColor { dynamic("squashDash", light: 0.60, dark: 0.40) }
}

/// 卡片容器：底色与描边跟随系统外观刷新，避免到处手撸 cgColor 在切换深浅色时失效
final class CardView: NSView {
    var fill: NSColor = .squashCard { didSet { needsDisplay = true } }
    var borderColor: NSColor? = NSColor.separatorColor { didSet { needsDisplay = true } }
    var cornerRadius: CGFloat = 10 { didSet { needsDisplay = true } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = fill.cgColor
        layer?.cornerRadius = cornerRadius
        layer?.borderWidth = borderColor == nil ? 0 : 1
        layer?.borderColor = borderColor?.cgColor
        layer?.masksToBounds = true
    }
}

/// 1pt 分隔线
final class Hairline: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.separatorColor.cgColor
    }
}

// MARK: - 任务行视图

final class JobRowView: NSView {
    private let job: Job
    private let icon = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let size = NSTextField(labelWithString: "")
    private let status = NSTextField(labelWithString: "")
    private let bar = NSProgressIndicator()
    private let separator = Hairline()

    init(job: Job, showsSeparator: Bool) {
        self.job = job
        super.init(frame: .zero)

        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        icon.widthAnchor.constraint(equalToConstant: 17).isActive = true

        name.font = .systemFont(ofSize: 12.5)
        name.lineBreakMode = .byTruncatingMiddle
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        size.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        size.textColor = .tertiaryLabelColor
        size.alignment = .right
        size.setContentHuggingPriority(.required, for: .horizontal)
        size.setContentCompressionResistancePriority(.required, for: .horizontal)

        status.font = .systemFont(ofSize: 11, weight: .medium)
        status.alignment = .right
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        status.setContentHuggingPriority(.required, for: .horizontal)

        bar.style = .bar
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 100
        bar.controlSize = .small
        bar.isHidden = true
        bar.widthAnchor.constraint(equalToConstant: 48).isActive = true
        bar.setContentHuggingPriority(.required, for: .horizontal)

        let row = NSStackView(views: [icon, name, bar, size, status])
        row.orientation = .horizontal
        row.alignment = .centerY
        // 默认的 gravityAreas 不会把剩余宽度分出去，名字后面的内容会挤在中间
        row.distribution = .fill
        row.spacing = 8
        row.edgeInsets = NSEdgeInsets(top: 0, left: 14, bottom: 0, right: 14)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.isHidden = !showsSeparator
        addSubview(separator)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 34),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1),
        ])
        update()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// 嵌套解压出来的条目用缩进箭头标出层级
    private var displayName: String {
        (job.depth > 0 ? "↳ " : "") + job.displayName
    }

    private var sizeText: String {
        var isDir: ObjCBool = false
        guard let first = job.sources.first,
              FileManager.default.fileExists(atPath: first.path, isDirectory: &isDir),
              !isDir.boolValue else { return "—" }
        var total: Int64 = 0
        for url in job.sources {
            if let v = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64 {
                total += v
            }
        }
        return humanSize(total)
    }

    func update() {
        name.stringValue = displayName
        size.stringValue = sizeText
        icon.contentTintColor = .secondaryLabelColor
        switch job.state {
        case .pending:
            icon.image = NSImage(systemSymbolName: "circle.dotted", accessibilityDescription: nil)
            status.stringValue = "等待"
            status.textColor = .tertiaryLabelColor
            bar.isHidden = true
        case .running:
            icon.image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath",
                                 accessibilityDescription: nil)
            icon.contentTintColor = .controlAccentColor
            status.stringValue = "\(job.progress)%"
            status.textColor = .controlAccentColor
            bar.isHidden = false
            bar.doubleValue = Double(job.progress)
        case .done:
            icon.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)
            icon.contentTintColor = .systemGreen
            // 有补充说明就显示（例如「已加密」「已修正文件名编码」），否则就是「完成」
            status.stringValue = job.message.isEmpty ? "完成" : job.message
            status.textColor = .systemGreen
            bar.isHidden = true
        case .failed:
            icon.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: nil)
            icon.contentTintColor = .systemRed
            status.stringValue = job.message.isEmpty ? "失败" : job.message
            status.textColor = .systemRed
            bar.isHidden = true
        case .skipped:
            icon.image = NSImage(systemSymbolName: "minus.circle", accessibilityDescription: nil)
            status.stringValue = "跳过"
            bar.isHidden = true
        }
    }
}

// MARK: - 拖放根视图

protocol DragHandler: AnyObject {
    /// 返回 false 表示当前状态不接受拖放
    func dragEntered() -> Bool
    func dragExited()
    func dropped(_ urls: [URL]) -> Bool
}

final class DragReceiverView: NSView {
    weak var handler: DragHandler?
    var onHoverChange: ((Bool) -> Void)?

    /// 窗口底色交给根视图画，深浅色切换时跟着刷新
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.squashCanvas.cgColor
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let handler,
              sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self],
                                                      options: [.urlReadingFileURLsOnly: true]),
              handler.dragEntered() else { return [] }
        onHoverChange?(true)
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onHoverChange?(false)
        handler?.dragExited()
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        onHoverChange?(false)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onHoverChange?(false)
        guard let urls = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]) as? [URL] else { return false }
        return handler?.dropped(urls) ?? false
    }
}

extension MainViewController {
    static let archiveExts: Set<String> = ArchiveScan.extractable
}

/// 密码强度条：4pt 高的圆角条，颜色随强度变化
final class StrengthBar: NSView {
    var score: Int = 0 { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let track = NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2,
                                 yRadius: bounds.height / 2)
        NSColor.quaternaryLabelColor.withAlphaComponent(0.5).setFill()
        track.fill()
        guard score > 0 else { return }

        let ratio: CGFloat = min(CGFloat(score) / 6.0, 1)
        var r = bounds
        r.size.width = max(bounds.height, bounds.width * ratio)
        let fill = NSBezierPath(roundedRect: r, xRadius: bounds.height / 2,
                                yRadius: bounds.height / 2)
        let color: NSColor
        switch score {
        case 1...2: color = .systemRed
        case 3...4: color = .systemOrange
        default: color = .systemGreen
        }
        color.setFill()
        fill.fill()
    }
}

/// 拖放区：虚线圆角卡片，中间是引导文案，悬停高亮
final class DropZoneView: NSView {
    var isHover = false {
        didSet {
            needsDisplay = true
            titleLabel.textColor = isHover ? .controlAccentColor : .labelColor
        }
    }
    var onTap: (() -> Void)?

    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "拖入文件开始")
    private let hintLabel = NSTextField(labelWithString: "ZIP · RAR · 7z · TAR · GZ 等格式，也可以点这里选择")

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)

        iconView.image = NSImage(systemSymbolName: "arrow.down.doc",
                                 accessibilityDescription: nil)
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 28, weight: .light)
        iconView.contentTintColor = .controlAccentColor

        titleLabel.font = .systemFont(ofSize: 14, weight: .medium)
        hintLabel.font = .systemFont(ofSize: 11.5)
        hintLabel.textColor = .tertiaryLabelColor
        hintLabel.alignment = .center
        hintLabel.lineBreakMode = .byTruncatingTail

        let col = NSStackView(views: [iconView, titleLabel, hintLabel])
        col.orientation = .vertical
        col.alignment = .centerX
        col.spacing = 6
        col.setCustomSpacing(12, after: iconView)
        col.translatesAutoresizingMaskIntoConstraints = false
        addSubview(col)
        NSLayoutConstraint.activate([
            col.centerXAnchor.constraint(equalTo: centerXAnchor),
            col.centerYAnchor.constraint(equalTo: centerYAnchor),
            col.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -32),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: rect, xRadius: 12, yRadius: 12)
        let fill = isHover
            ? NSColor.controlAccentColor.withAlphaComponent(0.10)
            : NSColor.squashCard
        fill.setFill()
        path.fill()

        let stroke = isHover
            ? NSColor.controlAccentColor.withAlphaComponent(0.85)
            : NSColor.squashDash
        stroke.setStroke()
        path.setLineDash([7, 5], count: 2, phase: 0)
        path.lineWidth = 1.5
        path.stroke()
    }

    /// 让整块区域都能响应点击，避免点到文字时穿透
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return bounds.contains(local) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        onTap?()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}
