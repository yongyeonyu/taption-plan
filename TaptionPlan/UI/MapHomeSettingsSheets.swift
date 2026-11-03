import CoreLocation
import MapKit
import Observation
import OSLog
import SwiftUI
import UIKit
import TaptionPlanCore

struct MapHomeCategoryAddSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: AppModel
    let language: MapHomeLanguage
    @State private var title = ""
    @State private var systemImage = "tag.fill"
    @State private var color = Color.tpReferenceMint
    @State private var animation: MapUserActivityAnimation?
    @FocusState private var isFocused: Bool

    private var iconNames: [String] {
        MapUserActivityIconCatalog.available(
            for: model.settings.mapUserActivityCategories
        )
    }

    private var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text(language.text("행동분류 추가", "Add activity category"))
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(21)), weight: .bold))
                Spacer()
                Button(language.text("닫기", "Close")) { dismiss() }
            }

            TextField(
                language.text("행동분류 이름", "Category name"),
                text: $title
            )
            .focused($isFocused)
            .textInputAutocapitalization(.words)
            .submitLabel(.done)
            .onSubmit(save)
            .padding(.horizontal, 14)
            .frame(height: 48)
            .background(Color.tpSurface, in: RoundedRectangle(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .stroke(Color.tpLine.opacity(0.7), lineWidth: 1)
            }

            HStack(spacing: 12) {
                Picker(language.text("아이콘", "Icon"), selection: $systemImage) {
                    ForEach(iconNames, id: \.self) { name in
                        Image(systemName: name).tag(name)
                    }
                }
                .pickerStyle(.menu)
                .disabled(iconNames.isEmpty)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background(Color.tpSurface, in: Capsule())

                ColorPicker(
                    language.text("색상", "Color"),
                    selection: $color,
                    supportsOpacity: false
                )
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background(Color.tpSurface, in: Capsule())
            }

            Picker(language.text("화랑이 동작", "Cat animation"), selection: $animation) {
                Text(language.text("기본 동작", "Default")).tag(MapUserActivityAnimation?.none)
                ForEach(MapUserActivityAnimation.allCases) { Text($0.title).tag(MapUserActivityAnimation?.some($0)) }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .background(Color.tpSurface, in: Capsule())

            Button(action: save) {
                Text(language.text("추가", "Add"))
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(16)), weight: .bold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
            }
            .buttonStyle(.borderedProminent)
            .disabled(trimmedTitle.isEmpty || systemImage.isEmpty)

            if iconNames.isEmpty {
                Text(
                    language.text(
                        "사용할 수 있는 새 아이콘이 없습니다.",
                        "No unused icons are available."
                    )
                )
                .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(12)), weight: .medium))
                .foregroundStyle(Color.tpSecondary)
            }
        }
        .padding(20)
        .background(Color.tpBackground)
        .task {
            if !iconNames.contains(systemImage) {
                systemImage = iconNames.first ?? ""
            }
            isFocused = true
        }
    }

    private func save() {
        guard !trimmedTitle.isEmpty, !systemImage.isEmpty else { return }
        guard model.addMapUserActivityCategory(
            title: trimmedTitle,
            systemImage: systemImage,
            hex: color.hexRGBString ?? "#29A383",
            animation: animation
        ) else { return }
        dismiss()
    }
}

struct MapHomeSecuritySheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: AppModel
    let language: MapHomeLanguage
    @State private var pin = ""
    @State private var confirmation = ""
    @State private var backupPassword = ""
    /// 복원 카드에서 넣는 비밀번호. 앱 비밀번호가 없는 기기나 다른 비밀번호로 만든 백업을 열 때 쓴다.
    @State private var restorePassword = ""
    @State private var remembered: String?
    @State private var message: String?
    @State private var restoreTarget: PlanBackupListingRow?
    @State private var isOffloadConfirmationPresented = false
    @State private var rawExportStatus = ""
    @State var developerAttachment: MapHomeDeveloperAttachment?
    @State var developerMailStatus = ""
    @FocusState private var focusedField: PINField?

    private enum PINField { case pin, confirmation, backup, restore }
    /// 등록된 비밀번호는 다시 보여줄 수 없으므로, 등록돼 있으면 빈 칸 대신 점 6개로 표시한다.
    private var registeredPINDots: String { String(repeating: "●", count: securityPINDigits) }

    private var security: PlanSecurityStatus { model.securityStatus }
    private var hasPIN: Bool { security.hasPIN }
    private var securityPINDigits: Int { security.pinDigits }
    private var appLockEnabled: Bool {
        security.settings.lockOnLaunch && security.settings.lockOnForeground
    }
    private var activity: PlanBackupActivity { model.backupActivity }
    private var isBusy: Bool { activity.isBusy }
    /// 기기에 보관된 비밀번호가 있으면 그것을, 없으면(기존 사용자 첫 1회) 입력한 값을 쓴다.
    private var password: String { remembered ?? backupPassword }
    private var needsPasswordEntry: Bool { hasPIN && remembered == nil }
    /// 목록·복원에 쓸 비밀번호. 복원 카드에 넣은 값이 먼저다.
    private var listingPassword: String? {
        [restorePassword, password].first { $0.count == securityPINDigits }
    }
    private var showsRestorePasswordField: Bool {
        !needsPasswordEntry && (remembered == nil || model.backupListings.contains(where: \.needsAnotherPassword))
    }
    private var hasDownloadingBackups: Bool { model.backupListings.contains(where: \.isDownloading) }
    private var canUseBackupPassword: Bool {
        hasPIN && password.count == securityPINDigits && !isBusy
    }

    private func refreshRemembered() {
        let value = model.rememberedBackupPassword
        guard value != remembered else { return }
        remembered = value
        if let value { Task { await model.refreshBackupListings(password: value) } }
    }

    /// 백업 버튼이 꺼져 있을 때 이유를 알려 준다. 켜져 있으면 nil.
    private var backupDisabledReason: String? {
        if !model.backupDestinationAvailable {
            return language.text("백업 저장소를 열지 못했습니다. 앱을 다시 실행해 주세요.", "The backup store could not be opened. Relaunch the app.")
        }
        if !hasPIN {
            return language.text("먼저 위에서 앱 비밀번호(6자리)를 등록해야 백업할 수 있습니다.", "Register an app password (6 digits) above first to back up.")
        }
        if isBusy { return nil }
        if password.count != securityPINDigits {
            return language.text("비밀번호 \(securityPINDigits)자리를 입력하면 버튼이 켜집니다.", "Enter your \(securityPINDigits)-digit password to enable the button.")
        }
        return nil
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    Image(systemName: "lock.shield.fill")
                        .font(.system(size: TaptionType.scaled(TaptionType.snapped(22)), weight: .bold))
                        .foregroundStyle(Color.tpReferenceRose)
                        .frame(width: 46, height: 46)
                        .background(
                            Color.tpReferenceRose.opacity(0.12),
                            in: RoundedRectangle(cornerRadius: 14)
                        )
                    VStack(alignment: .leading, spacing: 3) {
                        Text(language.text("데이터 보호", "Data Protection"))
                            .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(21)), weight: .bold))
                        Text(hasPIN
                            ? language.text("\(securityPINDigits)자리 비밀번호 등록됨", "\(securityPINDigits)-digit password registered")
                            : language.text("백업 전 비밀번호 등록 필요", "Set a password before backup")
                        )
                        .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(11.5)), weight: .medium))
                        .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(language.text("닫기", "Close")) { dismiss() }
                        .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(14)), weight: .semibold))
                }

                card(language.text("iCloud 로그 업로드", "iCloud Log Upload")) {
                    Text(language.text(
                        "iPhone·Apple Watch 진단 로그와 직전 비정상 종료 상태를 iCloud Drive의 TaptionLogs에 저장합니다.",
                        "Saves iPhone and Apple Watch diagnostics plus the previous unfinished session to TaptionLogs in iCloud Drive."
                    ))
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(11)), weight: .medium))
                    .foregroundStyle(.secondary)

                    HStack(spacing: 10) {
                        Button {
                            Task { await model.exportDiagnosticsToICloud() }
                        } label: {
                            Label(
                                language.text("로그 업로드", "Upload logs"),
                                systemImage: "icloud.and.arrow.up"
                            )
                            .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(13)), weight: .semibold))
                            .lineLimit(1)
                        }
                        .fixedSize()
                        .buttonStyle(.bordered)
                        .tint(Color.tpReferenceBlue)
                        .disabled(model.isExportingDiagnostics)

                        Text(model.diagnosticsExportStatus)
                            .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(11)), weight: .semibold))
                            .foregroundStyle(Color.tpReferenceBlue)
                    }

                    Text(model.diagnosticsLatestLogSummary)
                        .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(10.5)), weight: .medium))
                        .foregroundStyle(.secondary)
                    // 어제·오늘 센서 원본(GPS·모션·기압)을 같은 TaptionLogs 폴더에 바로 저장한다(SUB1029A01).
                    HStack(spacing: 10) {
                        Button {
                            rawExportStatus = language.text("저장 중…", "Saving…")
                            Task { rawExportStatus = await model.exportSensorRawToICloud() }
                        } label: {
                            Label(language.text("어제·오늘 원본 업로드", "Upload raw (2 days)"), systemImage: "location.square")
                                .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(13)), weight: .semibold))
                                .lineLimit(1)
                        }
                        .fixedSize()
                        .buttonStyle(.bordered)
                        .tint(Color.tpReferenceBlue)
                        Text(rawExportStatus)
                            .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(10.5)), weight: .semibold))
                            .foregroundStyle(Color.tpReferenceBlue)
                            .lineLimit(2)
                    }
                    developerMailButtons
                }

                card(language.text("\(PlanPINVerifier.currentDigits)자리 비밀번호", "\(PlanPINVerifier.currentDigits)-digit password")) {
                    SecureField(hasPIN ? registeredPINDots : language.text("비밀번호", "Password"), text: $pin)
                        .keyboardType(.numberPad)
                        .textContentType(.newPassword)
                        .focused($focusedField, equals: .pin)
                        .onChange(of: pin) { _, value in pin = numericPIN(value) }
                    SecureField(hasPIN ? registeredPINDots : language.text("비밀번호 확인", "Confirm password"), text: $confirmation)
                        .keyboardType(.numberPad)
                        .textContentType(.newPassword)
                        .focused($focusedField, equals: .confirmation)
                        .onChange(of: confirmation) { _, value in confirmation = numericPIN(value) }
                    Button(language.text("비밀번호 저장", "Save password")) {
                        savePIN()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.tpReferenceRose)
                    .disabled(pin.count != PlanPINVerifier.currentDigits
                        || confirmation.count != PlanPINVerifier.currentDigits)
                    Text(language.text(
                        "비밀번호를 바꾸면 그 뒤에 만드는 백업부터 새 비밀번호를 씁니다. 바꾸기 전에 만든 백업 파일은 그때의 비밀번호로 열립니다.",
                        "After you change the password, new backups use it. Backup files made earlier still open with the password used at that time."
                    ))
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(11)), weight: .medium))
                    .foregroundStyle(.secondary)
                }

                card(language.text("앱 잠금", "App lock")) {
                    Toggle(
                        language.text("앱을 열 때마다 잠금", "Lock whenever the app opens"),
                        isOn: Binding(
                            get: { appLockEnabled },
                            set: { setAppLock($0) }
                        )
                    )
                    .tint(Color.tpReferenceRose)
                    Toggle(
                        language.text("Face ID / Touch ID 사용", "Use Face ID / Touch ID"),
                        isOn: Binding(
                            get: { security.settings.biometricUnlockEnabled },
                            set: { setBiometricUnlock($0) }
                        )
                    )
                    .tint(Color.tpReferenceMint)
                    Text(language.text(
                        "생체 인증은 빠른 잠금 해제용이며, 생체 정보는 앱이나 백업에 저장되지 않습니다.",
                        "Biometrics are only a fast local unlock; biometric data is never stored."
                    ))
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(11)), weight: .medium))
                    .foregroundStyle(.secondary)
                }

                backupCard
                offloadCard
                restoreCard

                if let message {
                    Text(message)
                        .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(12)), weight: .semibold))
                        .foregroundStyle(Color.tpReferenceBlue)
                }
            }
            .padding(22)
            // 비밀번호 칸 밖의 빈 곳을 누르면 숫자 키패드를 내린다.
            .background(
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { focusedField = nil }
            )
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Color.tpSurface)
        .task { await model.refreshBackupListings(password: listingPassword) }
        .task(id: hasDownloadingBackups) {
            guard hasDownloadingBackups else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                guard !Task.isCancelled, !isBusy else { continue }
                await model.refreshBackupListings(password: listingPassword)
            }
        }
        .onAppear { refreshRemembered() }
        .onChange(of: isBusy) { _, _ in refreshRemembered() }
        .onChange(of: hasPIN) { _, _ in refreshRemembered() }
        .alert(
            language.text("이 달을 불러올까요?", "Restore this month?"),
            isPresented: Binding(
                get: { restoreTarget != nil },
                set: { if !$0 { restoreTarget = nil } }
            )
        ) {
            Button(language.text("취소", "Cancel"), role: .cancel) { restoreTarget = nil }
            Button(language.text("불러오기", "Restore")) { restoreConfirmed() }
        } message: {
            Text(language.text(
                "\(restoreTarget.map(title(of:)) ?? "")의 백업을 이 기기로 가져옵니다. 이 기기에 더 새로운 기록이 있으면 그대로 유지됩니다. 위 입력란의 비밀번호는 그 백업을 만들 때 쓴 비밀번호여야 합니다.",
                "Brings the backup for \(restoreTarget.map(title(of:)) ?? "") onto this device. Newer records already on this device are kept. The password above must be the one used when that backup was made."
            ))
        }
        .alert(
            language.text("로컬 정리", "Clear from this device"),
            isPresented: $isOffloadConfirmationPresented
        ) {
            Button(language.text("취소", "Cancel"), role: .cancel) {}
            Button(language.text("정리", "Clear"), role: .destructive) { offload() }
        } message: {
            Text(language.text(
                "최근 \(security.localMonthsToKeep)개 달을 뺀 지난 달 중 백업을 다시 읽어 확인된 달만 이 기기에서 지웁니다. 지운 달은 백업 목록에서 다시 불러올 수 있습니다.",
                "Past months older than the latest \(security.localMonthsToKeep) are removed from this device only after their backup is read back and verified. You can restore them from the backup list."
            ))
        }
    }

    // MARK: 카드

    private var backupCard: some View {
        card(language.text("iCloud 백업", "iCloud Backup")) {
            Text(language.text(
                "iCloud Drive/TaptionBackup에 달마다 파일 하나로 압축·암호화해 저장합니다. 자동으로 올리지 않으며, ‘지금 백업’을 누를 때만 올립니다.",
                "Saved to iCloud Drive/TaptionBackup as one compressed, encrypted file per month. Nothing is uploaded automatically; it runs only when you tap Back up now."
            ))
            .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(11)), weight: .medium))
            .foregroundStyle(.secondary)
            if needsPasswordEntry {
                SecureField(language.text("비밀번호", "Password"), text: $backupPassword)
                    .keyboardType(.numberPad)
                    .focused($focusedField, equals: .backup)
                    .textContentType(.password)
                    .onChange(of: backupPassword) { _, value in
                        backupPassword = numericPIN(value)
                        let shown = backupPassword.count == securityPINDigits ? backupPassword : nil
                        Task { await model.refreshBackupListings(password: shown) }
                    }
            }
            if let latestBackupText {
                Text(language.text(
                    "마지막 백업: \(latestBackupText)",
                    "Last backup: \(latestBackupText)"
                ))
                .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(11)), weight: .semibold))
                .foregroundStyle(Color.tpReferenceBlue)
            }
            if case .backingUp(let completed, let total) = activity {
                ProgressView(value: Double(completed), total: Double(max(total, 1)))
                Text(language.text("백업 중 \(completed)/\(total)", "Backing up \(completed)/\(total)"))
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(11)), weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            Button(language.text(isBusy ? "작업 중입니다" : "지금 백업", isBusy ? "Working" : "Back up now")) {
                let password = self.password
                Task { await model.backUpNow(password: password) }
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.tpReferenceBlue)
            .disabled(!canUseBackupPassword || !model.backupDestinationAvailable)
            if let reason = backupDisabledReason {
                Text(reason)
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(11)), weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            if let report = model.lastBackupReport, report.operation == .backup {
                reportView(report)
            }
        }
    }

    private var offloadCard: some View {
        card(language.text("백업 후 로컬 정리", "Clear from device after backup")) {
            Stepper(
                value: Binding(
                    get: { security.localMonthsToKeep },
                    set: { model.setLocalMonthsToKeep($0) }
                ),
                in: PlanSecurityService.localMonthsToKeepRange
            ) {
                Text(language.text(
                    "이 기기에 남길 최근 \(security.localMonthsToKeep)개 달(이번 달 포함)",
                    "Keep the latest \(security.localMonthsToKeep) months on this device (this month included)"
                ))
                .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(13)), weight: .semibold))
            }
            Text(language.text(
                "백업을 다시 읽어 확인된 지난 달만 이 기기에서 지웁니다. 먼저 ‘지금 백업’을 해야 하며, 설정은 지우지 않습니다.",
                "Only past months whose backup was read back and verified are removed from this device. Run ‘Back up now’ first; settings are never removed."
            ))
            .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(11)), weight: .medium))
            .foregroundStyle(.secondary)
            if case .offloading = activity {
                ProgressView().controlSize(.small)
            }
            Button(language.text("백업 후 로컬 정리", "Clear after backup")) {
                isOffloadConfirmationPresented = true
            }
            .buttonStyle(.bordered)
            .disabled(!canUseBackupPassword || !model.backupDestinationAvailable)
            if let report = model.lastBackupReport, report.operation == .offload {
                reportView(report)
            }
        }
    }

    private var restoreCard: some View {
        card(language.text("백업 목록과 복원", "Backups and restore")) {
            Text(language.text(
                "비밀번호를 넣으면 같은 iCloud의 다른 기기에서 만든 백업까지 보입니다. 백업을 만들 때 쓴 비밀번호로 열립니다.",
                "Enter the password to see backups from every device on this iCloud account. They open with the password used when they were made."
            ))
            .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(11)), weight: .medium))
            .foregroundStyle(.secondary)
            if showsRestorePasswordField {
                SecureField(language.text("백업 비밀번호", "Backup password"), text: $restorePassword)
                    .keyboardType(.numberPad)
                    .focused($focusedField, equals: .restore)
                    .textContentType(.password)
                    .onChange(of: restorePassword) { _, value in
                        let digits = numericPIN(value)
                        if digits != value { restorePassword = digits }
                        guard digits.count == securityPINDigits || digits.isEmpty else { return }
                        Task { await model.refreshBackupListings(password: listingPassword) }
                    }
            }
            if case .restoring(let name) = activity {
                ProgressView(language.text("\(name) 불러오는 중", "Restoring \(name)"))
                    .controlSize(.small)
            }
            if model.backupListings.isEmpty {
                if model.isRefreshingBackupListings {
                    ProgressView(language.text("iCloud에서 목록을 읽는 중", "Reading the list from iCloud"))
                        .controlSize(.small)
                } else {
                    Text(emptyListingText)
                        .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(12)), weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(model.backupListings) { row in
                listingRow(row)
            }
            if model.backupUnsupportedFileCount > 0 {
                Text(language.text(
                    "이전 버전에서 만든 백업 \(model.backupUnsupportedFileCount)개는 이 버전에서 열 수 없어 목록에서 뺐습니다. 파일은 그대로 있습니다.",
                    "\(model.backupUnsupportedFileCount) backups from an earlier version cannot be opened here and are not listed. The files are untouched."
                ))
                .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(11)), weight: .medium))
                .foregroundStyle(.secondary)
            }
            Button {
                Task { await model.refreshBackupListings(password: listingPassword) }
            } label: {
                Label(language.text("목록 새로고침", "Refresh list"), systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .disabled(isBusy)
            if let report = model.lastBackupReport, report.operation == .restore {
                reportView(report)
            }
        }
    }

    private func listingRow(_ row: PlanBackupListingRow) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title(of: row))
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(13)), weight: .bold))
                Text(listingDetail(row))
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(11)), weight: .medium))
                    .foregroundStyle(.secondary)
                if row.isOffloaded {
                    Text(language.text("이 기기에서는 정리됨 · 불러올 수 있음", "Cleared from this device · can be restored"))
                        .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(11)), weight: .semibold))
                        .foregroundStyle(Color.tpReferenceBlue)
                }
            }
            Spacer(minLength: 8)
            Button(language.text("불러오기", "Restore")) {
                guard listingPassword != nil else {
                    message = language.text(
                        "비밀번호를 먼저 입력해 주세요.",
                        "Enter your password first."
                    )
                    return
                }
                restoreTarget = row
            }
            .buttonStyle(.bordered)
            .disabled(isBusy || !row.isReadable)
        }
    }

    private func reportView(_ report: PlanBackupReport) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(report.summary)
                .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(12)), weight: .bold))
                .foregroundStyle(report.succeeded ? Color.tpReferenceBlue : Color.tpReferenceRose)
            ForEach(report.items) { item in
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: icon(for: item.kind))
                        .font(.system(size: TaptionType.scaled(TaptionType.snapped(11)), weight: .bold))
                        .foregroundStyle(item.kind == .rejected ? Color.tpReferenceRose : Color.tpReferenceBlue)
                    Text("\(item.name == "settings" ? language.text("설정", "Settings") : item.name) · \(item.detail)")
                        .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(11)), weight: .medium))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func icon(for kind: PlanBackupItem.Kind) -> String {
        switch kind {
        case .done: "checkmark.circle.fill"
        case .unchanged: "equal.circle.fill"
        case .rejected: "exclamationmark.triangle.fill"
        case .skipped: "minus.circle.fill"
        }
    }

    @ViewBuilder
    private func card<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(15)), weight: .bold))
            content()
        }
        .padding(13)
        .background(
            Color.tpSurfaceBlue.opacity(0.72),
            in: RoundedRectangle(cornerRadius: 14)
        )
    }

    // MARK: 동작

    private func numericPIN(_ value: String) -> String {
        String(value.filter(\.isNumber).prefix(PlanPINVerifier.currentDigits))
    }

    private func savePIN() {
        guard pin == confirmation else {
            message = language.text("비밀번호 확인이 일치하지 않습니다.", "Passwords do not match.")
            return
        }
        perform {
            try model.configureBackupPIN(pin)
            refreshRemembered()
            focusedField = nil
            message = language.text("비밀번호를 저장했습니다.", "Password saved.")
        }
    }

    private func setAppLock(_ enabled: Bool) {
        var value = security.settings
        value.lockOnLaunch = enabled
        value.lockOnForeground = enabled
        configure(value)
    }

    private func setBiometricUnlock(_ enabled: Bool) {
        var value = security.settings
        value.biometricUnlockEnabled = enabled
        configure(value)
    }

    private func configure(_ value: PlanAppLockSettings) {
        perform {
            try model.configureAppLock(value)
            message = language.text("보안 설정을 저장했습니다.", "Security settings saved.")
        }
    }

    private func offload() {
        let password = self.password
        Task { await model.offloadLocalMonths(password: password) }
    }

    private func restoreConfirmed() {
        guard let target = restoreTarget else { return }
        restoreTarget = nil
        guard let password = listingPassword else { return }
        Task { await model.restoreBackup(target.scope, password: password) }
    }

    private func perform(_ action: () throws -> Void) {
        do {
            try action()
        } catch {
            message = error.localizedDescription
        }
    }

    // MARK: 표시 문구

    private func title(of row: PlanBackupListingRow) -> String {
        switch row.scope {
        case .settings:
            return language.text("설정", "Settings")
        case .month(let month):
            return language.text("\(month.year)년 \(month.month)월", "\(month.month)/\(month.year)")
        }
    }

    private var emptyListingText: String {
        if let error = model.backupListingError { return error }
        if listingPassword == nil {
            return language.text("비밀번호 \(securityPINDigits)자리를 넣으면 iCloud 백업이 보입니다.", "Enter your \(securityPINDigits)-digit password to see iCloud backups.")
        }
        return language.text("iCloud에 백업 파일이 없습니다.", "No backup files in iCloud.")
    }

    private func listingDetail(_ row: PlanBackupListingRow) -> String {
        let size = ByteCountFormatter.string(fromByteCount: Int64(row.size), countStyle: .file)
        switch row.state {
        case .notDownloaded:
            let status = language.text("iCloud에서 내려받는 중 · 불러오기를 눌러도 됩니다", "Downloading from iCloud · you can tap Restore")
            return row.size > 0 ? "\(size) · \(status)" : status
        case .wrongPassword:
            return language.text("\(size) · 다른 비밀번호로 만든 백업입니다. 위에 그 비밀번호를 넣어 주세요", "\(size) · made with another password. Enter that password above")
        case .locked, .unreadable:
            return language.text("\(size) · 열 수 없음(손상되었거나 충돌 버전이 있음)", "\(size) · unreadable (damaged or has conflicting versions)")
        case .ok:
            break
        }
        guard let rows = row.rowCount else { return size }
        var parts = [size, language.text("\(rows)행", "\(rows) rows")]
        if let last = row.lastDataAt {
            parts.append(language.text("마지막 기록 \(formatted(last))", "last record \(formatted(last))"))
        }
        if let created = row.createdAt {
            parts.append(language.text("백업 \(formatted(created))", "backed up \(formatted(created))"))
        }
        return parts.joined(separator: " · ")
    }

    private func formatted(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = language.locale
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private var latestBackupText: String? {
        security.latestSuccessfulBackupDate.map(formatted)
    }
}

extension MapHomeSecuritySheet {
    /// 압축해 메일 작성 화면에 첨부한다. 보내기는 사용자가 누른다(MAL1103A01).
    @ViewBuilder
    var developerMailButtons: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(language.text("개발자에게 보내기", "Send to developer"))
                .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(11)), weight: .semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                developerMailButton(language.text("로그 보내기", "Logs"), subject: "BOKKI Plan 로그") {
                    try await model.diagnosticsPackageURL()
                }
                developerMailButton(language.text("어제·오늘 데이터", "2 days data"), subject: "BOKKI Plan 어제·오늘 데이터") {
                    try await model.exportTodaySensorRawURL()
                }
            }
            Text(language.text(
                "위치 기록이 포함될 수 있어요. 메일 화면에서 보내기를 눌러야 전송됩니다.",
                "May include location history. Nothing is sent until you tap Send in Mail."
            ))
            .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(10.5)), weight: .medium))
            .foregroundStyle(.secondary)
            if !developerMailStatus.isEmpty {
                Text(developerMailStatus)
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(10.5)), weight: .medium))
                    .foregroundStyle(Color.tpReferenceBlue)
            }
        }
        .sheet(item: $developerAttachment) { MapHomeDeveloperMailSheet(attachment: $0) }
    }

    private func developerMailButton(_ title: String, subject: String, source: @escaping () async throws -> URL) -> some View {
        Button {
            developerMailStatus = language.text("압축 중…", "Compressing…")
            Task {
                do {
                    let file = try await source()
                    let zipped = try await Task.detached(priority: .utility) { try MapHomeZipArchive.write(file) }.value
                    developerMailStatus = ""
                    developerAttachment = MapHomeDeveloperAttachment(url: zipped, subject: subject)
                } catch {
                    developerMailStatus = language.text("실패 · \(error.localizedDescription)", "Failed · \(error.localizedDescription)")
                }
            }
        } label: {
            Label(title, systemImage: "envelope")
                .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(13)), weight: .semibold))
                .lineLimit(1)
        }
        .fixedSize()
        .buttonStyle(.bordered)
        .tint(Color.tpReferenceBlue)
    }
}

struct MapHomeLocationSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: AppModel
    let destination: MapHomeLocationDestination
    let language: MapHomeLanguage
    let onSaved: () -> Void
    @State private var showsDeleteConfirmation = false
    @State private var floor = 1

    private var place: FrequentPlace? {
        guard let kind = destination.placeKind else { return nil }
        return model.settings.frequentPlaces.first { $0.kind == kind }
    }

    private var hasCurrentLocation: Bool {
        model.latestSensorReading?.point != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                MapHomeLocationThumbnail(destination: destination)
                VStack(alignment: .leading, spacing: 3) {
                    Text(
                        language.text(destination.koreanName, destination.englishName)
                            + language.text(" 위치 설정", " location")
                    )
                        .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(20)), weight: .bold))
                    if let place, place.point != nil {
                        Text(
                            language.text("현재 저장 상태", "Saved")
                                + " · "
                                + language.text(FloorLabel.korean(place.floor ?? 1), FloorLabel.english(place.floor ?? 1))
                        )
                            .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(12)), weight: .medium))
                            .foregroundStyle(.secondary)
                    } else {
                        Text(
                            language.text(
                                "현재 위치를 기준으로 저장할 수 있습니다",
                                "Save this place from your current location"
                            )
                        )
                            .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(12)), weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }

            Text(
                hasCurrentLocation
                    ? language.text(
                        "현재 위치를 이 장소의 기준 위치로 저장합니다. 좌표는 화면에 표시하지 않습니다.",
                        "Save the current location as this place. Coordinates are not shown."
                    )
                    : language.text(
                        "현재 위치를 받는 중입니다. 위치 기록이 잡히면 저장할 수 있습니다.",
                        "Waiting for location. Save becomes available when a location is recorded."
                    )
            )
                .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(13)), weight: .medium))
                .foregroundStyle(.secondary)

            Stepper(value: $floor, in: FloorCalibrationPrompt.range) {
                HStack {
                    Text(language.text("저장할 층수", "Floor to save"))
                    Spacer()
                    Text(language.text(FloorLabel.korean(floor), FloorLabel.english(floor)))
                        .fontWeight(.bold)
                        .foregroundStyle(destination.tint)
                }
            }
            .tint(destination.tint)

            // 위치는 그대로 두고 층수만 저장한다. 시트 밖을 누르면 바꾼 층수는 저장되지 않는다.
            Button {
                guard let place else { return }
                model.saveFrequentPlaceFloorAndHeight(place.id, floor: floor)
                onSaved()
                dismiss()
            } label: {
                Text(language.text("층수 저장", "Save floor"))
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(15)), weight: .bold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .foregroundStyle(destination.tint)
                    .background(destination.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 13))
            }
            .buttonStyle(.plain)
            // 같은 층이어도 그 자리에 있으면 높이를 다시 잴 수 있다.
            .disabled(place?.point == nil || (floor == place?.floor && !(place.map { PlaceHeightCapture.isInside($0, reading: model.latestSensorReading) } ?? false)))
            .opacity(place?.point == nil || (floor == place?.floor && !(place.map { PlaceHeightCapture.isInside($0, reading: model.latestSensorReading) } ?? false)) ? 0.46 : 1)

            Button {
                guard let place else { return }
                model.setFrequentPlaceToCurrentLocation(place.id, floor: floor)
                onSaved()
                dismiss()
            } label: {
                Label(
                    place?.point == nil
                        ? language.text("현재 위치로 저장", "Save current location")
                        : language.text("현재 위치로 다시 저장", "Update current location"),
                    systemImage: "location.fill"
                )
                .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(15)), weight: .bold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .foregroundStyle(.white)
                .background(destination.tint, in: RoundedRectangle(cornerRadius: 13))
            }
            .buttonStyle(.plain)
            .disabled(place == nil || !hasCurrentLocation)
            .opacity(place == nil || !hasCurrentLocation ? 0.46 : 1)

            Button(role: .destructive) {
                showsDeleteConfirmation = true
            } label: {
                Label(
                    language.text("저장된 위치 삭제", "Delete saved location"),
                    systemImage: "trash"
                )
                .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(14)), weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .foregroundStyle(Color.red)
                .background(
                    Color.red.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 13)
                )
            }
            .buttonStyle(.plain)
            .disabled(place?.point == nil)
            .opacity(place?.point == nil ? 0.38 : 1)
        }
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .presentationBackground(Color.tpSurface)
        .onAppear {
            floor = place?.floor ?? 1
        }
        .confirmationDialog(
            language.text(
                "저장된 위치를 삭제할까요?",
                "Delete the saved location?"
            ),
            isPresented: $showsDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button(
                language.text("저장된 위치 삭제", "Delete saved location"),
                role: .destructive
            ) {
                guard let place else { return }
                model.clearFrequentPlaceLocation(place.id)
                onSaved()
                dismiss()
            }
            Button(language.text("취소", "Cancel"), role: .cancel) {}
        }
    }
}
