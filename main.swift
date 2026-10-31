import SwiftUI

struct Zone: Identifiable {
    let id: String
    let city: String
    let actionTitle: String

    static let losAngeles = Zone(id: "America/Los_Angeles", city: "美国洛杉矶", actionTitle: "切换到洛杉矶")
    static let beijing = Zone(id: "Asia/Shanghai", city: "中国北京", actionTitle: "切换回北京")
    static let all = [losAngeles, beijing]

    var timeZone: TimeZone { TimeZone(identifier: id)! }
}

enum SystemZone {
    static let linkPath = "/etc/localtime"
    static let zoneInfoDir = "/var/db/timezone/zoneinfo"

    // 直接读 /etc/localtime，避免 TimeZone.current 的缓存。
    static func currentID() -> String? {
        guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: linkPath),
              let range = target.range(of: "zoneinfo/") else { return nil }
        return String(target[range.upperBound...])
    }

    // 关闭“自动设置时区”，否则系统会按定位把时区改回去。
    // systemsetup 在部分系统版本上会失败，所以设置后再检查一次，没生效就直接改链接。
    // 这段脚本要嵌进 AppleScript 字符串，因此不能出现双引号。
    static func shellCommand(for zone: Zone) -> String {
        let target = "\(zoneInfoDir)/\(zone.id)"
        return [
            "/usr/bin/defaults write /Library/Preferences/com.apple.timezone.auto Active -bool false",
            "/usr/sbin/systemsetup -settimezone \(zone.id) >/dev/null 2>&1",
            "case $(/usr/bin/readlink \(linkPath)) in \(target)) ;; *) /bin/ln -sf \(target) \(linkPath) && /usr/bin/notifyutil -p com.apple.system.timezone ;; esac",
        ].joined(separator: "; ")
    }

    static func appleScript(for zone: Zone) -> String {
        "do shell script \"\(shellCommand(for: zone))\" with prompt \"切换系统时区需要管理员权限。\" with administrator privileges"
    }

    enum Outcome {
        case success
        case cancelled
        case failure(String)
    }

    static func apply(_ zone: Zone) -> Outcome {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", appleScript(for: zone)]
        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return .failure(error.localizedDescription)
        }
        let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        if process.terminationStatus == 0 { return .success }
        let message = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return message.contains("-128") ? .cancelled : .failure(message)
    }
}

@MainActor
final class ZoneModel: ObservableObject {
    @Published var now = Date()
    @Published var currentID = SystemZone.currentID()
    @Published var isSwitching = false
    @Published var errorMessage: String?

    private var timer: Timer?

    init() {
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    var currentZone: Zone? { Zone.all.first { $0.id == currentID } }

    private func tick() {
        now = Date()
        currentID = SystemZone.currentID()
    }

    func switchTo(_ zone: Zone) {
        isSwitching = true
        errorMessage = nil
        Task {
            let outcome = await Task.detached { SystemZone.apply(zone) }.value
            NSTimeZone.resetSystemTimeZone()
            tick()
            isSwitching = false
            switch outcome {
            case .success:
                if currentID != zone.id { errorMessage = "切换后系统时区仍是 \(currentID ?? "未知")。" }
            case .cancelled:
                break
            case .failure(let message):
                errorMessage = "切换失败：\(message)"
            }
        }
    }
}

func timeText(_ date: Date, in zone: TimeZone, format: String) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.timeZone = zone
    formatter.dateFormat = format
    return formatter.string(from: date)
}

func offsetText(_ date: Date, in zone: TimeZone) -> String {
    let hours = zone.secondsFromGMT(for: date) / 3600
    return "UTC" + (hours >= 0 ? "+" : "") + String(hours)
}

struct ZoneCard: View {
    let zone: Zone
    @ObservedObject var model: ZoneModel

    private var isCurrent: Bool { model.currentID == zone.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(zone.city).font(.headline)
            Text(timeText(model.now, in: zone.timeZone, format: "HH:mm"))
                .font(.system(size: 30, weight: .medium, design: .rounded))
                .monospacedDigit()
            Text(timeText(model.now, in: zone.timeZone, format: "M月d日 EEE") + " · " + offsetText(model.now, in: zone.timeZone))
                .font(.caption)
                .foregroundStyle(.secondary)
            Button {
                model.switchTo(zone)
            } label: {
                Text(isCurrent ? "正在使用" : zone.actionTitle).frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .disabled(isCurrent || model.isSwitching)
            .padding(.top, 6)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct ContentView: View {
    @StateObject private var model = ZoneModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 6) {
                Text("当前系统时区：").foregroundStyle(.secondary)
                Text(model.currentZone?.city ?? model.currentID ?? "未知").fontWeight(.semibold)
                Spacer()
                if model.isSwitching { ProgressView().controlSize(.small) }
            }
            HStack(spacing: 12) {
                ForEach(Zone.all) { ZoneCard(zone: $0, model: model) }
            }
            if let message = model.errorMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(18)
        .frame(width: 420)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct TimeZoneSwitcherApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("时区切换", id: "main") {
            ContentView()
        }
        .windowResizability(.contentSize)
    }
}
