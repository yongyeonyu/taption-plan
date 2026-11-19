import UIKit
import UniformTypeIdentifiers

/// 공유 시트 「BOKKI Plan에 넣기」(FLT1119A01). 항공사 문자·알림톡 글, 링크, 탑승권(.pkpass)을 받아 App Group 보관함에 두고 끝낸다.
/// 읽기와 일정 반영은 앱이 열릴 때 한다. 이 확장은 네트워크를 쓰지 않고, 받은 글을 화면에 그대로 보이지 않는다(이름·예약번호가 들 수 있다).
final class ShareViewController: UIViewController {
    private let titleLabel = UILabel()
    private let messageLabel = UILabel()
    private let button = UIButton(type: .system)
    private var isKorean: Bool { Locale.preferredLanguages.first?.hasPrefix("ko") == true }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        titleLabel.text = "BOKKI Plan"
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        messageLabel.text = isKorean ? "받은 항공 알림을 BOKKI Plan에 넣을까요? 앱을 열면 여행의 항공편 카드에 붙여요." : "Add this flight notice to BOKKI Plan? It attaches to the trip's flight card when you open the app."
        messageLabel.font = .preferredFont(forTextStyle: .body)
        messageLabel.numberOfLines = 0
        messageLabel.textAlignment = .center
        var configuration = UIButton.Configuration.filled()
        configuration.title = isKorean ? "BOKKI Plan에 넣기" : "Add to BOKKI Plan"
        button.configuration = configuration
        button.addTarget(self, action: #selector(add), for: .touchUpInside)
        let cancel = UIButton(type: .system)
        cancel.setTitle(isKorean ? "취소" : "Cancel", for: .normal)
        cancel.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)
        let stack = UIStackView(arrangedSubviews: [titleLabel, messageLabel, button, cancel])
        stack.axis = .vertical
        stack.spacing = 16
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor, constant: -8),
        ])
    }

    @objc private func cancelTapped() {
        extensionContext?.cancelRequest(withError: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
    }

    @objc private func add() {
        button.isEnabled = false
        Task { @MainActor in
            let stored = await collect()
            messageLabel.text = stored
                ? (isKorean ? "넣었어요. BOKKI Plan을 열면 붙여요." : "Added. It will attach when you open BOKKI Plan.")
                : (isKorean ? "읽을 수 있는 글이나 탑승권이 없어요." : "Nothing readable to add.")
            try? await Task.sleep(nanoseconds: 900_000_000)
            extensionContext?.completeRequest(returningItems: nil)
        }
    }

    /// 공유된 글·링크·탑승권을 보관함에 둔다. 하나라도 두었으면 true.
    private func collect() async -> Bool {
        var stored = false
        for item in (extensionContext?.inputItems as? [NSExtensionItem]) ?? [] {
            if let attributed = item.attributedContentText?.string, FlightShareStore.enqueue(text: attributed) { stored = true }
            for provider in item.attachments ?? [] {
                if provider.hasItemConformingToTypeIdentifier("com.apple.pkpass"), let data = await loadData(provider, type: "com.apple.pkpass"), FlightShareStore.enqueue(passData: data) {
                    stored = true
                } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier), let text = await loadString(provider, type: UTType.plainText.identifier), FlightShareStore.enqueue(text: text) {
                    stored = true
                } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier), let text = await loadString(provider, type: UTType.url.identifier), FlightShareStore.enqueue(text: text) {
                    stored = true
                }
            }
        }
        return stored
    }

    private func loadString(_ provider: NSItemProvider, type: String) async -> String? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: type, options: nil) { value, _ in
                if let string = value as? String { continuation.resume(returning: string) }
                else if let url = value as? URL { continuation.resume(returning: url.absoluteString) }
                else { continuation.resume(returning: nil) }
            }
        }
    }

    private func loadData(_ provider: NSItemProvider, type: String) async -> Data? {
        await withCheckedContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: type) { data, _ in continuation.resume(returning: data) }
        }
    }
}
