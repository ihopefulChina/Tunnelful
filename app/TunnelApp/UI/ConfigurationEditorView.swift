import SwiftUI

struct ConfigurationEditorView: View {
    @EnvironmentObject private var model: AppModel

    private var draftDocument: CloudflaredConfigDocument? {
        get { model.configurationDraft }
        nonmutating set { model.configurationDraft = newValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: AppMetrics.sectionSpacing) {
                    if let document = draftDocument {
                        configurationSummary(document)
                        rulesSection(document)
                        yamlSection(document)
                        advancedFieldsNotice
                    } else {
                        emptyState
                    }
                }
                .frame(maxWidth: AppMetrics.maxContentWidth, alignment: .leading)
                .padding(.horizontal, AppMetrics.pagePadding)
                .padding(.top, AppMetrics.pageTopPadding)
                .padding(.bottom, AppMetrics.pageBottomPadding)
                .frame(maxWidth: .infinity, alignment: .top)
            }

            if draftDocument != nil {
                saveBar
            }
        }
        .appPageBackground()
        .onAppear {
            if model.configurationDraft == nil {
                synchronizeDraft(with: model.configDocument)
            }
        }
    }

    private func configurationSummary(_ document: CloudflaredConfigDocument) -> some View {
        panel {
            HStack(spacing: 14) {
                Image(systemName: "doc.text")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    Text("当前配置")
                        .font(.headline)
                    Text(document.sourceURL?.path ?? "未关联配置文件")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }

                Spacer(minLength: 12)

                Button("导入其他配置…") {
                    model.chooseConfiguration()
                }
                .disabled(model.isApplyingConfiguration || model.isRoutingDNS)
            }
        }
    }

    private func rulesSection(_ document: CloudflaredConfigDocument) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                SectionHeader(title: "结构化规则")
                Text("\(document.ingress.count) 条")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)

                Spacer()

                Button {
                    addRule()
                } label: {
                    Label("新增规则", systemImage: "plus")
                }
                .disabled(editingIsDisabled)
            }

            if document.ingress.isEmpty {
                NoticeView(
                    kind: .warning,
                    title: "至少需要一条规则",
                    message: "新增规则时会同时补上一条 http_status:404 兜底规则。"
                )
            } else {
                VStack(spacing: 10) {
                    ForEach(document.ingress) { rule in
                        ruleEditor(rule, in: document)
                    }
                }
            }

            if !globalIssues.isEmpty {
                NoticeView(
                    kind: .warning,
                    title: "配置结构需要修正",
                    message: globalIssues.map(\.message).joined(separator: " ")
                )
            }
        }
    }

    private func ruleEditor(
        _ rule: IngressRule,
        in document: CloudflaredConfigDocument
    ) -> some View {
        let index = document.ingress.firstIndex(where: { $0.id == rule.id }) ?? 0
        let issues = issues(for: rule.id)
        let lastIndex = document.ingress.index(before: document.ingress.endIndex)
        let isProtectedFallback = rule.isCatchAll && index == lastIndex

        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text("\(index + 1)")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: AppMetrics.accessoryColumnWidth, height: AppMetrics.accessoryColumnWidth)
                    .background(.primary.opacity(0.06), in: Circle())

                Label(
                    isProtectedFallback ? "兜底规则" : "匹配规则",
                    systemImage: isProtectedFallback ? "arrow.down.to.line" : "arrow.triangle.branch"
                )
                .font(.headline)

                Spacer()

                IconToolButton(
                    systemImage: "arrow.up",
                    accessibilityLabel: "上移第 \(index + 1) 条规则",
                    helpText: "上移规则",
                    disabled: editingIsDisabled || !canMoveRule(rule.id, by: -1)
                ) {
                    moveRule(rule.id, by: -1)
                }

                IconToolButton(
                    systemImage: "arrow.down",
                    accessibilityLabel: "下移第 \(index + 1) 条规则",
                    helpText: "下移规则",
                    disabled: editingIsDisabled || !canMoveRule(rule.id, by: 1)
                ) {
                    moveRule(rule.id, by: 1)
                }

                IconToolButton(
                    systemImage: "trash",
                    accessibilityLabel: "删除第 \(index + 1) 条规则",
                    helpText: isProtectedFallback ? "兜底规则不能删除" : "删除规则",
                    role: .destructive,
                    disabled: editingIsDisabled || isProtectedFallback
                ) {
                    removeRule(rule.id)
                }
            }

            HStack(alignment: .top, spacing: AppMetrics.rowSpacing) {
                ruleFields(for: rule)
            }

            if isProtectedFallback {
                Text("hostname 与 path 均留空时，此规则匹配所有未命中的请求。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(issues) { issue in
                Label(issue.message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(AppPalette.statusOrange)
                    .accessibilityLabel("错误：\(issue.message)")
            }
        }
        .appSurface(
            padding: AppMetrics.stackSpacing,
            tint: issues.isEmpty ? .clear : AppPalette.statusOrange.opacity(0.06),
            borderColor: issues.isEmpty
                ? AppPalette.hairline.opacity(AppMetrics.hairlineOpacity)
                : AppPalette.statusOrange.opacity(0.45)
        )
    }

    @ViewBuilder
    private func ruleFields(for rule: IngressRule) -> some View {
        ruleField(
            title: "hostname",
            prompt: "app.example.com",
            text: optionalBinding(for: rule.id, keyPath: \.hostname)
        )
        .frame(maxWidth: .infinity)

        ruleField(
            title: "path（可选）",
            prompt: "^/api/.*",
            text: optionalBinding(for: rule.id, keyPath: \.path)
        )
        .frame(maxWidth: .infinity)

        ruleField(
            title: "service",
            prompt: "http://127.0.0.1:3000",
            text: serviceBinding(for: rule.id)
        )
        .frame(maxWidth: .infinity)
    }

    private func ruleField(
        title: String,
        prompt: String,
        text: Binding<String>
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)

            TextField(title, text: text, prompt: Text(prompt))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .disabled(editingIsDisabled)
                .accessibilityLabel(title)
        }
    }

    private func yamlSection(_ document: CloudflaredConfigDocument) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                SectionHeader(title: "YAML 预览")
                Spacer()
            }

            ScrollView {
                Text(CloudflaredConfigSerializer().serialize(document))
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(AppMetrics.stackSpacing)
            }
            .frame(minHeight: 160, maxHeight: 240)
            .appSurface(padding: 0, fill: AppPalette.workspace)
            .accessibilityLabel("YAML 预览")
        }
    }

    private var advancedFieldsNotice: some View {
        NoticeView(
            kind: .info,
            title: "高级字段会保留",
            message: "此页面只修改 ingress 中的 hostname、path 与 service；其他配置段、注释和规则内高级字段不会在这里展开编辑，保存时仍会写回。"
        )
    }

    private var emptyState: some View {
        panel {
            VStack(alignment: .leading, spacing: 14) {
                Label("尚未导入配置", systemImage: "doc.badge.plus")
                    .font(.title3.weight(.semibold))
                Text("请选择 config.yml 或 config.yaml。导入只会读取文件，确认保存后才会写入。")
                    .foregroundStyle(.secondary)
                Button("导入配置…") {
                    model.chooseConfiguration()
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isApplyingConfiguration || model.isRoutingDNS)
            }
            .frame(maxWidth: .infinity, minHeight: 150, alignment: .leading)
        }
    }

    private var saveBar: some View {
        HStack(spacing: 12) {
            Image(systemName: saveStatusSymbol)
                .foregroundStyle(saveStatusColor)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(saveStatusTitle)
                    .font(.callout.weight(.medium))
                Text(saveStatusDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if hasUnsavedChanges {
                Button("放弃更改") {
                    model.discardConfigurationDraft()
                }
                .disabled(model.isApplyingConfiguration || model.isRoutingDNS)
            }

            Button {
                saveDraft()
            } label: {
                if model.isApplyingConfiguration {
                    ProgressView()
                        .controlSize(.small)
                        .frame(minWidth: 122)
                } else {
                    Label("保存并官方校验", systemImage: "checkmark.shield")
                }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut("s", modifiers: .command)
            .disabled(!canSave)
            .help(saveButtonHelp)
            .accessibilityLabel("保存并使用官方 cloudflared 校验")
            .accessibilityValue(model.isApplyingConfiguration ? "正在保存" : "")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .appChromeBackground()
    }

    private var validationIssues: [ConfigValidationIssue] {
        draftDocument?.validationIssues() ?? []
    }

    private var globalIssues: [ConfigValidationIssue] {
        validationIssues.filter { $0.ruleID == nil }
    }

    private var localErrors: [ConfigValidationIssue] {
        validationIssues.filter { $0.severity == .error }
    }

    private var editingIsDisabled: Bool {
        model.isApplyingConfiguration || model.isRoutingDNS
    }

    private var hasUnsavedChanges: Bool {
        guard let draftDocument else { return false }
        return draftDocument != model.configDocument
    }

    private var canSave: Bool {
        guard let draftDocument,
              draftDocument.sourceURL != nil,
              model.installation != nil else {
            return false
        }
        return !model.isApplyingConfiguration &&
            !model.isRoutingDNS &&
            localErrors.isEmpty &&
            hasUnsavedChanges
    }

    private var saveStatusTitle: String {
        if !localErrors.isEmpty { return "有 \(localErrors.count) 个问题需要修正" }
        if hasUnsavedChanges { return "有尚未保存的更改" }
        if model.lastValidationMessage != nil { return "配置已保存" }
        return "当前没有未保存的更改"
    }

    private var saveStatusDetail: String {
        if let firstError = localErrors.first { return firstError.message }
        if hasUnsavedChanges { return "保存时会先运行官方校验，并自动备份原文件。" }
        if let message = model.lastValidationMessage { return message }
        if model.installation == nil { return "检测到 cloudflared 后才能运行官方校验。" }
        return "修改规则后即可保存。"
    }

    private var saveStatusSymbol: String {
        if !localErrors.isEmpty { return "exclamationmark.triangle.fill" }
        if hasUnsavedChanges { return "pencil.circle.fill" }
        if model.lastValidationMessage != nil { return "checkmark.circle.fill" }
        return "checkmark.circle"
    }

    private var saveStatusColor: Color {
        if !localErrors.isEmpty { return AppPalette.statusOrange }
        if !hasUnsavedChanges, model.lastValidationMessage != nil { return AppPalette.statusGreen }
        return .secondary
    }

    private var saveButtonHelp: String {
        if model.installation == nil { return "未检测到 cloudflared，无法运行官方校验" }
        if !localErrors.isEmpty { return "请先修正本地结构问题" }
        if !hasUnsavedChanges { return "没有需要保存的更改" }
        return "运行 cloudflared 官方校验，通过后备份并保存"
    }

    private func issues(for ruleID: UUID) -> [ConfigValidationIssue] {
        validationIssues.filter { $0.ruleID == ruleID }
    }

    private func optionalBinding(
        for ruleID: UUID,
        keyPath: WritableKeyPath<IngressRule, String?>
    ) -> Binding<String> {
        Binding(
            get: {
                draftDocument?.ingress.first(where: { $0.id == ruleID })?[keyPath: keyPath] ?? ""
            },
            set: { value in
                updateRule(ruleID) { rule in
                    rule[keyPath: keyPath] = value
                }
            }
        )
    }

    private func serviceBinding(for ruleID: UUID) -> Binding<String> {
        Binding(
            get: {
                draftDocument?.ingress.first(where: { $0.id == ruleID })?.service ?? ""
            },
            set: { value in
                updateRule(ruleID) { rule in
                    rule.service = value
                }
            }
        )
    }

    private func updateRule(_ ruleID: UUID, update: (inout IngressRule) -> Void) {
        guard var document = draftDocument,
              let index = document.ingress.firstIndex(where: { $0.id == ruleID }) else {
            return
        }
        update(&document.ingress[index])
        draftDocument = document
    }

    private func addRule() {
        guard var document = draftDocument else { return }

        let routeNumber = document.ingress.filter { !$0.isCatchAll }.count + 1
        let rule = IngressRule(
            hostname: "service-\(routeNumber).example.com",
            service: "http://127.0.0.1:3000"
        )

        if let fallbackIndex = document.ingress.firstIndex(where: \.isCatchAll) {
            document.ingress.insert(rule, at: fallbackIndex)
        } else {
            document.ingress.append(rule)
            document.ingress.append(IngressRule(service: "http_status:404"))
        }
        draftDocument = document
    }

    private func removeRule(_ ruleID: UUID) {
        guard var document = draftDocument,
              let index = document.ingress.firstIndex(where: { $0.id == ruleID }) else {
            return
        }
        document.ingress.remove(at: index)
        draftDocument = document
    }

    private func canMoveRule(_ ruleID: UUID, by offset: Int) -> Bool {
        guard let document = draftDocument,
              let index = document.ingress.firstIndex(where: { $0.id == ruleID }) else {
            return false
        }

        let destination = index + offset
        guard document.ingress.indices.contains(destination) else { return false }

        let lastIndex = document.ingress.index(before: document.ingress.endIndex)
        let rule = document.ingress[index]
        let destinationRule = document.ingress[destination]
        let ruleIsProtectedFallback = rule.isCatchAll && index == lastIndex
        let destinationIsProtectedFallback = destinationRule.isCatchAll && destination == lastIndex
        return !ruleIsProtectedFallback && !destinationIsProtectedFallback
    }

    private func moveRule(_ ruleID: UUID, by offset: Int) {
        guard canMoveRule(ruleID, by: offset),
              var document = draftDocument,
              let index = document.ingress.firstIndex(where: { $0.id == ruleID }) else {
            return
        }
        document.ingress.swapAt(index, index + offset)
        draftDocument = document
    }

    private func saveDraft() {
        guard var document = draftDocument, canSave else { return }

        for index in document.ingress.indices {
            document.ingress[index].hostname = normalized(document.ingress[index].hostname)
            document.ingress[index].path = normalized(document.ingress[index].path)
            document.ingress[index].service = document.ingress[index].service
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        draftDocument = document

        Task {
            await model.saveStructuredConfiguration(document)
        }
    }

    private func normalized(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }

    private func synchronizeDraft(with document: CloudflaredConfigDocument?) {
        draftDocument = document
    }

    private func panel<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .appSurface(padding: AppMetrics.stackSpacing)
    }
}
