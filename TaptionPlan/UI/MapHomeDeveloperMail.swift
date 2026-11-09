import Compression
import MessageUI
import SwiftUI

/// 로그·원본을 개발자에게 메일로 보낸다(MAL1103A01). 보내기는 사용자가 메일 화면에서 직접 누른다.
enum MapHomeDeveloperMail {
    static let recipient = "support@bokkiyaw.com"
}

/// 파일 하나를 담는 zip. 표준 해제 도구로 열리고 CRC로 검증된다.
enum MapHomeZipArchive {
    private static let crcTable: [UInt32] = (0..<256).map { index -> UInt32 in
        (0..<8).reduce(UInt32(index)) { value, _ in value & 1 == 1 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1 }
    }

    static func crc32(_ data: Data) -> UInt32 {
        ~data.reduce(UInt32.max) { crcTable[Int(($0 ^ UInt32($1)) & 0xFF)] ^ ($0 >> 8) }
    }

    /// 압축이 도움이 안 되면 그대로 담는다.
    static func zip(_ data: Data, named name: String) throws -> Data {
        let deflated = try (data as NSData).compressed(using: .zlib) as Data
        let usesDeflate = deflated.count < data.count
        let body = usesDeflate ? deflated : data
        let nameBytes = Data(name.utf8)
        let crc = crc32(data)
        var header = Data()
        func put16(_ value: Int, _ out: inout Data) { withUnsafeBytes(of: UInt16(value).littleEndian) { out.append(contentsOf: $0) } }
        func put32(_ value: UInt32, _ out: inout Data) { withUnsafeBytes(of: value.littleEndian) { out.append(contentsOf: $0) } }
        func common(_ out: inout Data) {
            put16(20, &out); put16(0x0800, &out); put16(usesDeflate ? 8 : 0, &out)
            put16(0, &out); put16(0x21, &out)
            put32(crc, &out); put32(UInt32(body.count), &out); put32(UInt32(data.count), &out)
            put16(nameBytes.count, &out); put16(0, &out)
        }
        put32(0x0403_4B50, &header)
        common(&header)
        header.append(nameBytes)
        var central = Data()
        put32(0x0201_4B50, &central)
        put16(20, &central)
        common(&central)
        put16(0, &central); put16(0, &central); put16(0, &central); put32(0, &central); put32(0, &central)
        central.append(nameBytes)
        var end = Data()
        put32(0x0605_4B50, &end)
        put16(0, &end); put16(0, &end); put16(1, &end); put16(1, &end)
        put32(UInt32(central.count), &end); put32(UInt32(header.count + body.count), &end); put16(0, &end)
        return header + body + central + end
    }

    static func write(_ source: URL) throws -> URL {
        let data = try Data(contentsOf: source)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TaptionPlanDeveloperMail", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(source.deletingPathExtension().lastPathComponent + ".zip")
        try zip(data, named: source.lastPathComponent).write(to: url, options: [.atomic, .completeFileProtection])
        return url
    }
}

struct MapHomeDeveloperAttachment: Identifiable {
    let id = UUID()
    let url: URL
    let subject: String
    var mimeType = "application/zip"
}

struct MapHomeDeveloperMailSheet: UIViewControllerRepresentable {
    let attachment: MapHomeDeveloperAttachment
    @Environment(\.dismiss) private var dismiss

    func makeCoordinator() -> Coordinator { Coordinator { dismiss() } }

    func makeUIViewController(context: Context) -> UIViewController {
        guard MFMailComposeViewController.canSendMail(), let data = try? Data(contentsOf: attachment.url) else {
            // 메일 계정이 없으면 공유 시트로 다른 앱에 넘긴다.
            return UIActivityViewController(activityItems: [attachment.url], applicationActivities: nil)
        }
        let mail = MFMailComposeViewController()
        mail.mailComposeDelegate = context.coordinator
        mail.setToRecipients([MapHomeDeveloperMail.recipient])
        mail.setSubject(attachment.subject)
        mail.addAttachmentData(data, mimeType: attachment.mimeType, fileName: attachment.url.lastPathComponent)
        return mail
    }

    func updateUIViewController(_ controller: UIViewController, context: Context) {}

    final class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        let onFinish: () -> Void
        init(onFinish: @escaping () -> Void) { self.onFinish = onFinish }

        func mailComposeController(_ controller: MFMailComposeViewController, didFinishWith result: MFMailComposeResult, error: Error?) {
            onFinish()
        }
    }
}
