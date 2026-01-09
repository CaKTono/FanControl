import SwiftUI
import Foundation
import ServiceManagement
import AppKit

let HELPER_PATH = "/Library/PrivilegedHelperTools/com.fancontrol.smc"

enum MenuBarDisplayMode: String, CaseIterable {
    case cpuTemp = "CPU Temperature"
    case gpuTemp = "GPU Temperature"
    case fanRPM = "Fan RPM"
    case fanPercent = "Fan Percentage"
    case cpuAndRPM = "CPU Temp + RPM"
    case cpuAndPercent = "CPU Temp + Fan %"
}

enum FanProfile: String, CaseIterable {
    case auto = "Auto"
    case silent = "Silent"
    case fifty = "50%"
    case seventyFive = "75%"
    case max = "Max"
    case custom = "Custom"
    
    var icon: String {
        switch self {
        case .auto: return "a.circle.fill"
        case .silent: return "speaker.slash.fill"
        case .fifty: return "gauge.with.dots.needle.33percent"
        case .seventyFive: return "gauge.with.dots.needle.67percent"
        case .max: return "flame.fill"
        case .custom: return "slider.horizontal.3"
        }
    }
    
    var color: Color {
        switch self {
        case .auto: return .blue
        case .silent: return .green
        case .fifty: return .yellow
        case .seventyFive: return .orange
        case .max: return .red
        case .custom: return .purple
        }
    }
    
    func rpmForFan(min: Double, max: Double) -> Double? {
        switch self {
        case .auto: return nil
        case .silent: return min
        case .fifty: return min + (max - min) * 0.5
        case .seventyFive: return min + (max - min) * 0.75
        case .max: return max
        case .custom: return nil
        }
    }
}

struct Fan: Identifiable {
    let id: Int
    var rpm: Double
    var minRpm: Double
    var maxRpm: Double
    var isAuto: Bool = true
    var targetRpm: Double = 0
    var percentage: Int { guard maxRpm > 0 else { return 0 }; return Int((rpm / maxRpm) * 100) }
    func rpmForPercentage(_ pct: Double) -> Double { maxRpm * (pct / 100.0) }
}

struct Sensor: Identifiable, Equatable {
    var id: String { key }
    let key: String
    let name: String
    var temperature: Double
}

class SMCManager: ObservableObject {
    static let shared = SMCManager()
    
    @Published var fans: [Fan] = []
    @Published var sensors: [Sensor] = []
    @Published var statusMessage: String = ""
    @Published var currentProfile: FanProfile = .auto
    @Published var helperInstalled: Bool = false
    @Published var allFansPercentage: Double = 50
    
    private var sensorCache: [String: (name: String, temp: Double)] = [:]
    
    private var smcPath: String {
        if FileManager.default.fileExists(atPath: HELPER_PATH) { return HELPER_PATH }
        return Bundle.main.resourcePath! + "/smc_util"
    }
    
    init() { checkHelperInstalled() }
    
    func checkHelperInstalled() { helperInstalled = FileManager.default.fileExists(atPath: HELPER_PATH) }
    
    func installHelper() {
        let smcUtil = Bundle.main.resourcePath! + "/smc_util"
        let script = "do shell script \"mkdir -p /Library/PrivilegedHelperTools && cp '\(smcUtil)' '\(HELPER_PATH)' && chown root:wheel '\(HELPER_PATH)' && chmod u+s '\(HELPER_PATH)'\" with administrator privileges"
        var error: NSDictionary?
        if let appleScript = NSAppleScript(source: script) {
            appleScript.executeAndReturnError(&error)
            DispatchQueue.main.async { self.checkHelperInstalled(); self.statusMessage = error == nil ? "Helper installed!" : "Cancelled" }
        }
    }
    
    func uninstallHelper() {
        let script = "do shell script \"rm -f '\(HELPER_PATH)'\" with administrator privileges"
        var error: NSDictionary?
        if let appleScript = NSAppleScript(source: script) {
            appleScript.executeAndReturnError(&error)
            DispatchQueue.main.async { self.checkHelperInstalled(); self.statusMessage = error == nil ? "Helper removed" : "Cancelled" }
        }
    }
    
    func refresh() { loadFans(); loadSensors() }
    
    func loadFans() {
        guard let output = runSMC(["-l"]) else { return }
        var newFans: [Fan] = []
        for line in output.split(separator: "\n") {
            if line.hasPrefix("FAN:") {
                let parts = line.split(separator: ":")
                if parts.count >= 5 {
                    let fanId = Int(parts[1]) ?? 0
                    var fan = Fan(id: fanId, rpm: Double(parts[2]) ?? 0, minRpm: Double(parts[3]) ?? 0, maxRpm: Double(parts[4]) ?? 0)
                    if let existing = fans.first(where: { $0.id == fanId }) { fan.isAuto = existing.isAuto; fan.targetRpm = existing.targetRpm }
                    newFans.append(fan)
                }
            }
        }
        DispatchQueue.main.async { self.fans = newFans }
    }
    
    func loadSensors() {
        guard let output = runSMC(["-s"]) else { return }
        for line in output.split(separator: "\n") {
            if line.hasPrefix("TEMP:") {
                let parts = line.split(separator: ":")
                if parts.count >= 4 {
                    let key = String(parts[1]), name = String(parts[2]), temp = Double(parts[3]) ?? 0
                    if temp > 0 || sensorCache[key] == nil { sensorCache[key] = (name, temp) }
                }
            }
        }
        let sorted = sensorCache.map { Sensor(key: $0.key, name: $0.value.name, temperature: $0.value.temp) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        DispatchQueue.main.async { self.sensors = sorted }
    }
    
    var hottestCPU: Double { sensors.first { $0.key == "_MAX" }?.temperature ?? sensors.filter { $0.name.contains("CPU") }.map { $0.temperature }.max() ?? 0 }
    var hottestGPU: Double { sensors.filter { $0.name.contains("GPU") }.map { $0.temperature }.max() ?? 0 }
    var avgFanRPM: Int { fans.isEmpty ? 0 : Int(fans.map { $0.rpm }.reduce(0, +) / Double(fans.count)) }
    var avgFanPercent: Int { fans.isEmpty ? 0 : fans.map { $0.percentage }.reduce(0, +) / fans.count }
    
    func applyProfile(_ profile: FanProfile) {
        currentProfile = profile
        if profile == .custom { statusMessage = "Custom mode"; return }
        for fan in fans {
            if profile == .auto { setFanAuto(fanIndex: fan.id) }
            else if let rpm = profile.rpmForFan(min: fan.minRpm, max: fan.maxRpm) { setFanSpeed(fanIndex: fan.id, rpm: rpm, silent: true) }
        }
        statusMessage = "\(profile.rawValue) applied"
    }
    
    func setAllFansPercentage(_ pct: Double) {
        allFansPercentage = pct
        for fan in fans { setFanSpeed(fanIndex: fan.id, rpm: fan.rpmForPercentage(pct), silent: true) }
        statusMessage = "All fans: \(Int(pct))%"
    }
    
    func setFanPercentage(fanIndex: Int, pct: Double) {
        guard let fan = fans.first(where: { $0.id == fanIndex }) else { return }
        setFanSpeed(fanIndex: fanIndex, rpm: fan.rpmForPercentage(pct), silent: false)
    }
    
    func setFanSpeed(fanIndex: Int, rpm: Double, silent: Bool = false) {
        let output = helperInstalled ? runSMC(["-f", String(fanIndex), String(Int(rpm))]) : runSMCWithPriv(["-f", String(fanIndex), String(Int(rpm))])
        if output != nil {
            DispatchQueue.main.async {
                if !silent { self.statusMessage = "Fan \(fanIndex + 1): \(Int(rpm)) RPM" }
                if let idx = self.fans.firstIndex(where: { $0.id == fanIndex }) { self.fans[idx].isAuto = false; self.fans[idx].targetRpm = rpm }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.loadFans() }
    }
    
    func setFanAuto(fanIndex: Int) {
        let output = helperInstalled ? runSMC(["-f", String(fanIndex), "-1"]) : runSMCWithPriv(["-f", String(fanIndex), "-1"])
        if output != nil {
            DispatchQueue.main.async { if let idx = self.fans.firstIndex(where: { $0.id == fanIndex }) { self.fans[idx].isAuto = true } }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.loadFans() }
    }
    
    private func runSMC(_ args: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: smcPath)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe; process.standardError = pipe
        do { try process.run(); process.waitUntilExit(); return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) }
        catch { return nil }
    }
    
    private func runSMCWithPriv(_ args: [String]) -> String? {
        let argsStr = args.joined(separator: " ")
        let bundledSmc = Bundle.main.resourcePath! + "/smc_util"
        let script = "do shell script \"\(bundledSmc) \(argsStr)\" with administrator privileges"
        var error: NSDictionary?
        if let appleScript = NSAppleScript(source: script) {
            let result = appleScript.executeAndReturnError(&error)
            if error == nil { return result.stringValue ?? "OK:" }
        }
        return nil
    }
}

class AppSettings: ObservableObject {
    @Published var launchAtLogin: Bool { didSet { setLaunchAtLogin(launchAtLogin) } }
    @Published var showInMenuBar: Bool { didSet { UserDefaults.standard.set(showInMenuBar, forKey: "showInMenuBar"); updateMenuBar() } }
    @Published var menuBarDisplayMode: MenuBarDisplayMode {
        didSet { UserDefaults.standard.set(menuBarDisplayMode.rawValue, forKey: "menuBarDisplayMode"); updateMenuBar() }
    }
    
    init() {
        self.launchAtLogin = SMAppService.mainApp.status == .enabled
        self.showInMenuBar = UserDefaults.standard.bool(forKey: "showInMenuBar")
        if let modeStr = UserDefaults.standard.string(forKey: "menuBarDisplayMode"),
           let mode = MenuBarDisplayMode(rawValue: modeStr) {
            self.menuBarDisplayMode = mode
        } else {
            self.menuBarDisplayMode = .cpuAndRPM
        }
    }
    
    private func setLaunchAtLogin(_ enabled: Bool) {
        do { if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } } catch {}
    }
    
    func updateMenuBar() {
        NotificationCenter.default.post(name: Notification.Name("UpdateMenuBar"), object: nil)
    }
}

class MenuBarController: NSObject, ObservableObject {
    private var statusItem: NSStatusItem?
    private var timer: Timer?
    private let smc = SMCManager.shared
    
    override init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(handleMenuBarUpdate), name: Notification.Name("UpdateMenuBar"), object: nil)
        if UserDefaults.standard.bool(forKey: "showInMenuBar") { setupMenuBar() }
    }
    
    @objc func handleMenuBarUpdate(_ notification: Notification) {
        let show = UserDefaults.standard.bool(forKey: "showInMenuBar")
        if show { setupMenuBar(); updateMenuBarTitle() } else { removeMenuBar() }
    }
    
    func setupMenuBar() {
        guard statusItem == nil else { updateMenuBarTitle(); return }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateMenuBarTitle()
        setupMenu()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.updateMenuBarTitle() }
    }
    
    func removeMenuBar() {
        timer?.invalidate()
        if let item = statusItem { NSStatusBar.system.removeStatusItem(item) }
        statusItem = nil
    }
    
    func updateMenuBarTitle() {
        smc.refresh()
        
        let modeStr = UserDefaults.standard.string(forKey: "menuBarDisplayMode") ?? MenuBarDisplayMode.cpuAndRPM.rawValue
        let mode = MenuBarDisplayMode(rawValue: modeStr) ?? .cpuAndRPM
        
        var title = ""
        switch mode {
        case .cpuTemp:
            title = "\(Int(smc.hottestCPU))°C"
        case .gpuTemp:
            title = "\(Int(smc.hottestGPU))°C"
        case .fanRPM:
            title = "\(smc.avgFanRPM) RPM"
        case .fanPercent:
            title = "\(smc.avgFanPercent)%"
        case .cpuAndRPM:
            title = "\(Int(smc.hottestCPU))° \(smc.avgFanRPM)rpm"
        case .cpuAndPercent:
            title = "\(Int(smc.hottestCPU))° \(smc.avgFanPercent)%"
        }
        
        DispatchQueue.main.async {
            self.statusItem?.button?.title = title
            self.statusItem?.button?.image = NSImage(systemSymbolName: "fan.fill", accessibilityDescription: nil)
        }
    }
    
    func setupMenu() {
        let menu = NSMenu()
        
        let headerItem = NSMenuItem(title: "Fan Control", action: nil, keyEquivalent: "")
        headerItem.isEnabled = false
        menu.addItem(headerItem)
        menu.addItem(NSMenuItem.separator())
        
        let profileMenu = NSMenu()
        for profile in FanProfile.allCases {
            let item = NSMenuItem(title: profile.rawValue, action: #selector(selectProfile(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = profile
            if smc.currentProfile == profile { item.state = .on }
            profileMenu.addItem(item)
        }
        let profileItem = NSMenuItem(title: "Profile", action: nil, keyEquivalent: "")
        profileItem.submenu = profileMenu
        menu.addItem(profileItem)
        
        menu.addItem(NSMenuItem.separator())
        
        let openItem = NSMenuItem(title: "Open Fan Control", action: #selector(openMainWindow), keyEquivalent: "o")
        openItem.target = self
        menu.addItem(openItem)
        
        menu.addItem(NSMenuItem.separator())
        
        let quitItem = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        
        statusItem?.menu = menu
    }
    
    @objc func selectProfile(_ sender: NSMenuItem) {
        if let profile = sender.representedObject as? FanProfile {
            smc.applyProfile(profile)
            setupMenu()
        }
    }
    
    @objc func openMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first { window.makeKeyAndOrderFront(nil) }
    }
    
    @objc func quitApp() { NSApplication.shared.terminate(nil) }
}

struct SettingsView: View {
    @ObservedObject var smc: SMCManager
    @ObservedObject var settings: AppSettings
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Settings").font(.title2).fontWeight(.semibold)
            Divider()
            
            // Helper section
            VStack(alignment: .leading, spacing: 8) {
                Text("PRIVILEGED HELPER").font(.caption).foregroundColor(.secondary)
                HStack {
                    if smc.helperInstalled { Image(systemName: "checkmark.circle.fill").foregroundColor(.green); Text("Installed") }
                    else { Image(systemName: "xmark.circle.fill").foregroundColor(.orange); Text("Not installed") }
                    Spacer()
                }
                HStack(spacing: 8) {
                    Button(smc.helperInstalled ? "Reinstall" : "Install") { smc.installHelper() }.buttonStyle(.borderedProminent)
                    if smc.helperInstalled { Button("Uninstall") { smc.uninstallHelper() }.buttonStyle(.bordered) }
                }
            }.padding().background(Color(NSColor.controlBackgroundColor)).cornerRadius(8)
            
            // Menu Bar section
            VStack(alignment: .leading, spacing: 8) {
                Text("MENU BAR").font(.caption).foregroundColor(.secondary)
                Toggle("Show in Menu Bar", isOn: $settings.showInMenuBar)
                
                if settings.showInMenuBar {
                    Picker("Display", selection: $settings.menuBarDisplayMode) {
                        ForEach(MenuBarDisplayMode.allCases, id: \.self) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.menu)
                }
            }.padding().background(Color(NSColor.controlBackgroundColor)).cornerRadius(8)
            
            // Startup section
            VStack(alignment: .leading, spacing: 8) {
                Text("STARTUP").font(.caption).foregroundColor(.secondary)
                Toggle("Launch at Login", isOn: $settings.launchAtLogin)
            }.padding().background(Color(NSColor.controlBackgroundColor)).cornerRadius(8)
            
            Spacer()
            HStack { Spacer(); Button("Done") { dismiss() }.buttonStyle(.borderedProminent) }
        }.padding(20).frame(width: 350, height: 420)
    }
}

struct ProfileButton: View {
    let profile: FanProfile; let isSelected: Bool; let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) { Image(systemName: profile.icon).font(.title3); Text(profile.rawValue).font(.caption2) }
            .frame(width: 55, height: 50)
            .background(isSelected ? profile.color.opacity(0.3) : Color(NSColor.controlBackgroundColor))
            .foregroundColor(isSelected ? profile.color : .secondary)
            .cornerRadius(10)
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(isSelected ? profile.color : Color.clear, lineWidth: 2))
        }.buttonStyle(.plain)
    }
}

struct FanSliderView: View {
    let fan: Fan; @Binding var percentage: Double
    let onPercentageChange: (Double) -> Void; let onAutoTap: () -> Void
    var fanName: String { fan.id == 0 ? "Left" : "Right" }
    var body: some View {
        VStack(spacing: 8) {
            HStack { Text(fanName).font(.headline); Spacer(); Text("\(fan.percentage)%").font(.headline).foregroundColor(.blue) }
            HStack(spacing: 8) {
                Button("Auto") { onAutoTap() }.buttonStyle(.bordered).tint(fan.isAuto ? .blue : .gray).controlSize(.small)
                Button("Manual") {}.buttonStyle(.bordered).tint(fan.isAuto ? .gray : .blue).controlSize(.small).disabled(true)
            }
            Slider(value: $percentage, in: 0...100, step: 1) { editing in if !editing { onPercentageChange(percentage) } }.tint(.blue)
            HStack {
                Text("\(Int(fan.minRpm))").font(.caption).padding(4).background(Color(NSColor.controlBackgroundColor)).cornerRadius(4)
                Spacer(); Text("\(Int(fan.rpm)) RPM").font(.caption).foregroundColor(.secondary); Spacer()
                Text("\(Int(fan.maxRpm))").font(.caption).padding(4).background(Color(NSColor.controlBackgroundColor)).cornerRadius(4)
            }
        }.padding().background(Color(NSColor.controlBackgroundColor).opacity(0.5)).cornerRadius(10)
    }
}

struct AllFansSliderView: View {
    @Binding var percentage: Double; let minRpm: Double; let maxRpm: Double; let onPercentageChange: (Double) -> Void
    var currentRpm: Double { minRpm + (maxRpm - minRpm) * (percentage / 100.0) }
    var body: some View {
        VStack(spacing: 8) {
            HStack { Image(systemName: "link").foregroundColor(.purple); Text("All Fans").font(.headline); Spacer(); Text("\(Int(percentage))%").font(.headline).foregroundColor(.purple) }
            Slider(value: $percentage, in: 0...100, step: 1) { editing in if !editing { onPercentageChange(percentage) } }.tint(.purple)
            HStack { Text("0%").font(.caption); Spacer(); Text("\(Int(currentRpm)) RPM").font(.caption).foregroundColor(.secondary); Spacer(); Text("100%").font(.caption) }
        }.padding().background(Color.purple.opacity(0.1)).cornerRadius(10)
    }
}

struct FanCardView: View {
    let fan: Fan
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(fan.id == 0 ? "Left" : "Right").font(.subheadline).fontWeight(.medium)
                Spacer()
                Text(fan.isAuto ? "Auto" : "Manual").font(.caption2).padding(.horizontal, 6).padding(.vertical, 2)
                    .background(fan.isAuto ? Color.blue.opacity(0.2) : Color.orange.opacity(0.2))
                    .foregroundColor(fan.isAuto ? .blue : .orange).cornerRadius(4)
            }
            HStack(alignment: .lastTextBaseline) {
                Text("\(Int(fan.rpm))").font(.system(size: 24, weight: .bold))
                Text("RPM").font(.caption).foregroundColor(.secondary); Spacer()
                Text("\(fan.percentage)%").font(.title3).fontWeight(.semibold).foregroundColor(.blue)
            }
            ProgressView(value: Double(fan.percentage) / 100.0).tint(fan.percentage > 80 ? .orange : .blue)
        }.padding(10).background(Color(NSColor.controlBackgroundColor)).cornerRadius(8)
    }
}

struct SensorRowView: View {
    let sensor: Sensor
    var tempColor: Color { sensor.temperature > 90 ? .red : (sensor.temperature > 70 ? .orange : .primary) }
    var body: some View {
        HStack {
            Text(sensor.name).font(.system(size: 11))
            Spacer()
            Text(String(format: "%.1f°", sensor.temperature)).font(.system(size: 11, weight: .semibold)).foregroundColor(tempColor)
        }.padding(.vertical, 1)
    }
}

struct ContentView: View {
    @ObservedObject private var smc = SMCManager.shared
    @StateObject private var settings = AppSettings()
    @State private var timer: Timer?
    @State private var showSettings = false
    @State private var fanPercentages: [Int: Double] = [:]
    
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "fan.fill").font(.title3).foregroundColor(.blue)
                Text("Fan Control").font(.title3).fontWeight(.semibold)
                Spacer()
                Text(smc.statusMessage).font(.caption).foregroundColor(.secondary).frame(width: 100, alignment: .trailing)
                Button { showSettings = true } label: { Image(systemName: "gearshape.fill").font(.title3) }.buttonStyle(.plain).foregroundColor(.secondary)
            }.padding(.horizontal).padding(.vertical, 8)
            
            HStack(spacing: 8) {
                ForEach(FanProfile.allCases, id: \.self) { profile in
                    ProfileButton(profile: profile, isSelected: smc.currentProfile == profile) { smc.applyProfile(profile) }
                }
            }.padding(.horizontal).padding(.bottom, 8)
            Divider()
            HSplitView {
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(smc.fans) { fan in FanCardView(fan: fan) }
                        if smc.currentProfile == .custom {
                            Divider().padding(.vertical, 4)
                            AllFansSliderView(percentage: $smc.allFansPercentage, minRpm: smc.fans.first?.minRpm ?? 0, maxRpm: smc.fans.first?.maxRpm ?? 100, onPercentageChange: { smc.setAllFansPercentage($0) })
                            ForEach(smc.fans) { fan in
                                FanSliderView(fan: fan, percentage: Binding(get: { fanPercentages[fan.id] ?? Double(fan.percentage) }, set: { fanPercentages[fan.id] = $0 }), onPercentageChange: { smc.setFanPercentage(fanIndex: fan.id, pct: $0) }, onAutoTap: { smc.setFanAuto(fanIndex: fan.id) })
                            }
                        }
                    }.padding(10)
                }.frame(minWidth: 280)
                VStack(alignment: .leading, spacing: 0) {
                    Text("SENSORS").font(.caption).foregroundColor(.secondary).padding(.horizontal).padding(.top, 8)
                    List(smc.sensors) { sensor in SensorRowView(sensor: sensor) }.listStyle(.inset)
                }.frame(minWidth: 180)
            }
        }.frame(minWidth: 600, minHeight: 500)
        .onAppear {
            smc.refresh()
            for fan in smc.fans { fanPercentages[fan.id] = Double(fan.percentage) }
            timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in smc.refresh() }
        }
        .onDisappear { timer?.invalidate() }
        .sheet(isPresented: $showSettings) { SettingsView(smc: smc, settings: settings) }
    }
}

@main
struct FanControlApp: App {
    @StateObject private var menuBarController = MenuBarController()
    var body: some Scene { WindowGroup { ContentView() }.windowResizability(.contentSize) }
}
