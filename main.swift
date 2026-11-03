import SwiftUI

struct Zone: Identifiable {
    let id: String
    let city: String
    let actionTitle: String

    static let losAngeles = Zone(id: "America/Los_Angeles", city: "美国洛杉矶", actionTitle: "切换到洛杉矶")
    static let newYork = Zone(id: "America/New_York", city: "美国纽约", actionTitle: "切换到纽约")
    static let beijing = Zone(id: "Asia/Shanghai", city: "中国北京", actionTitle: "切换回北京")
    static let all = [losAngeles, newYork, beijing]

    var timeZone: TimeZone { TimeZone(identifier: id)! }
}

enum AutoTimeZone {
    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.Date-Time-Settings.extension")!
    private static let coreTime = dlopen("/System/Library/PrivateFrameworks/CoreTime.framework/CoreTime", RTLD_NOW)

    // 向系统时间服务 timed 询问真实状态。CoreTime 是私有框架，读不到时返回 nil。
    static func isEnabled() -> Bool? {
        guard let coreTime, let symbol = dlsym(coreTime, "TMIsAutomaticTimeZoneEnabled") else { return nil }
        typealias Getter = @convention(c) () -> Bool
        return unsafeBitCast(symbol, to: Getter.self)()
    }

    // timed 以 _timed 用户运行，开关存在它自己的偏好设置里，改完要重启它才会生效。
    // com.apple.timezone.auto 只是旧开关，单独改它拦不住 timed。
    static let disableCommands: [String] = {
        let key = "TMAutomaticTimeZoneEnabled"
        return [
            "/usr/bin/defaults write /Library/Preferences/com.apple.timezone.auto Active -bool false",
            "/usr/bin/sudo -H -u _timed /usr/bin/defaults write com.apple.timed \(key) -bool false",
            "for f in /var/db/timed/com.apple.timed.plist /var/db/timed/Library/Preferences/com.apple.timed.plist; do [ -f $f ] && /usr/bin/plutil -replace \(key) -bool NO $f && /usr/sbin/chown _timed:_timed $f; done",
            "/bin/launchctl kickstart -k system/com.apple.timed",
            "/bin/sleep 1",
        ]
    }()
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

    // 自动设置时区开着时要先关掉，否则系统会按定位把时区改回去。
    // systemsetup 在部分系统版本上会失败，所以设置后再检查一次，没生效就直接改链接。
    // 这段脚本要嵌进 AppleScript 字符串，因此不能出现双引号。
    static func shellCommand(for zone: Zone, disableAuto: Bool) -> String {
        let target = "\(zoneInfoDir)/\(zone.id)"
        let setZone = [
            "/usr/sbin/systemsetup -settimezone \(zone.id) >/dev/null 2>&1",
            "case $(/usr/bin/readlink \(linkPath)) in \(target)) ;; *) /bin/ln -sf \(target) \(linkPath) && /usr/bin/notifyutil -p com.apple.system.timezone ;; esac",
        ]
        return ((disableAuto ? AutoTimeZone.disableCommands : []) + setZone).joined(separator: "; ")
    }

    static func appleScript(for zone: Zone, disableAuto: Bool) -> String {
        "do shell script \"\(shellCommand(for: zone, disableAuto: disableAuto))\" with prompt \"切换系统时区需要管理员权限。\" with administrator privileges"
    }

    enum Outcome {
        case success
        case cancelled
        case failure(String)
    }

    static func apply(_ zone: Zone) -> Outcome {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", appleScript(for: zone, disableAuto: AutoTimeZone.isEnabled() != false)]
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
    @Published var autoEnabled: Bool?

    // 软件最后一次设置成功的时区，用来发现时区被别的程序改掉。
    var expectedID: String?

    private var timer: Timer?
    private var ticksSinceAutoCheck = 0

    init() {
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        Task { await refreshAuto() }
    }

    var currentZone: Zone? { Zone.all.first { $0.id == currentID } }

    func tick() {
        now = Date()
        currentID = SystemZone.currentID()
        if let expected = expectedID, !isSwitching, currentID != expected {
            expectedID = nil
            errorMessage = "系统时区被改成了 \(currentZone?.city ?? currentID ?? "未知")，这不是本软件操作的。"
        }
        ticksSinceAutoCheck += 1
        if ticksSinceAutoCheck >= 10 {
            ticksSinceAutoCheck = 0
            Task { await refreshAuto() }
        }
    }

    private func refreshAuto() async {
        autoEnabled = await Task.detached { AutoTimeZone.isEnabled() }.value
    }

    func switchTo(_ zone: Zone) {
        isSwitching = true
        errorMessage = nil
        Task {
            let outcome = await Task.detached { SystemZone.apply(zone) }.value
            NSTimeZone.resetSystemTimeZone()
            await refreshAuto()
            isSwitching = false
            switch outcome {
            case .success:
                expectedID = zone.id
                tick()
                if currentID != zone.id {
                    errorMessage = "切换后系统时区仍是 \(currentID ?? "未知")。"
                } else if autoEnabled == true {
                    errorMessage = "时区已切换，但没能关闭“自动设置时区”，系统可能按定位把时区改回去。请点下方按钮手动关闭。"
                }
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

struct AutoStatusRow: View {
    let enabled: Bool?

    var body: some View {
        switch enabled {
        case .some(true):
            HStack(spacing: 8) {
                Text("“自动设置时区”仍开启，系统可能按定位把时区改回去。切换时软件会尝试关闭它。")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("打开系统设置") { NSWorkspace.shared.open(AutoTimeZone.settingsURL) }
            }
            .font(.caption)
        case .some(false):
            Text("“自动设置时区”已关闭，系统不会按定位改时区。")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .none:
            Text("无法读取“自动设置时区”的状态。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
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
            AutoStatusRow(enabled: model.autoEnabled)
            if let message = model.errorMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(18)
        .frame(width: 620)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // 1.2 的窗口比 1.0 宽了 200pt，系统恢复的旧位置有可能让它越过屏幕右缘，
    // 最右边那张卡片就看不见了。这里只在窗口越界时把它推回来，正常位置不动。
    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            AppDelegate.clampToVisibleScreen()
        }
    }

    static func clampToVisibleScreen() {
        for window in NSApp.windows where window.isVisible {
            guard let screen = window.screen ?? NSScreen.main else { continue }
            let visible = screen.visibleFrame
            var frame = window.frame
            var changed = false
            if frame.maxX > visible.maxX { frame.origin.x = visible.maxX - frame.width; changed = true }
            if frame.minX < visible.minX { frame.origin.x = visible.minX; changed = true }
            if frame.maxY > visible.maxY { frame.origin.y = visible.maxY - frame.height; changed = true }
            if frame.minY < visible.minY { frame.origin.y = visible.minY; changed = true }
            if changed { window.setFrame(frame, display: true) }
        }
    }
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
