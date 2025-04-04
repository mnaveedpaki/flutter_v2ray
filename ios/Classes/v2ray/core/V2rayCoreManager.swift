import Flutter
import Foundation
import LibXray
import Network
import NetworkExtension
import os.log

let appLog = OSLog(subsystem: "com.group.sulian.app", category: "vpn_management")

/// 单例 V2rayCoreManager 实现（与 Java 类似）
public class V2rayCoreManager {
    private lazy var pligun = FlutterV2rayPlugin.shared()

    private static var sharedV2rayCoreManager: V2rayCoreManager = .init()

    public class func shared() -> V2rayCoreManager {
        return sharedV2rayCoreManager
    }

    private var manager = NETunnelProviderManager.shared()

    var isLibV2rayCoreInitialized = false
    var V2RAY_STATE: AppConfigs.V2RAY_STATES = .DISCONNECT

    private var trafficStatsTimer: Timer?
    private var startTime: Date?

    /// 设置监听器
    public func setUpListener() {
        stopTrafficStatsTimer()

        // 初始化配置项
        isLibV2rayCoreInitialized = true
        V2RAY_STATE = .DISCONNECT

        // Record the start time
        startTime = Date()
        // 调用 startTrafficStatsTimer 启动定时器
        startTrafficStatsTimer()
    }

    /// 加载并选择特定的 VPN 配置
    public func loadAndSelectVPNConfiguration(completion: @escaping (Error?) -> Void) {
        NETunnelProviderManager.loadAllFromPreferences { managers, error in
            guard let managers = managers, error == nil else {
                completion(error)
                return
            }

            // 查找特定的 VPN 配置
            if let targetManager = managers.first(where: { $0.localizedDescription == AppConfigs.APPLICATION_NAME }) {
                // 找到匹配的配置
                self.manager = targetManager
                completion(nil)
            } else {
                // 没有找到匹配的配置，创建新的配置
                self.createNewVPNConfiguration(completion: completion)
            }
        }
    }

    /// 创建新的 VPN 配置（支持自定义名称）
    private func createNewVPNConfiguration(completion: @escaping (Error?) -> Void) {
        let newManager = NETunnelProviderManager()
        newManager.protocolConfiguration = NETunnelProviderProtocol()
        newManager.protocolConfiguration?.serverAddress = AppConfigs.APPLICATION_NAME
        newManager.localizedDescription = AppConfigs.APPLICATION_NAME

        newManager.saveToPreferences { error in
            guard error == nil else {
                completion(error)
                return
            }

            newManager.loadFromPreferences { _ in
                self.manager = newManager
                completion(nil)
            }
        }
    }

    /// 启动VPN核心
    public func startCore() {
        guard isLibV2rayCoreInitialized else {
            print("Error: V2rayCoreManager must be initialized before starting.")
            return
        }

        V2RAY_STATE = .CONNECTED

        let v2rayConfig = V2rayConfig.shared // 创建 V2rayConfig 实例
        let vmess = AppConfigs.V2RAY_CONFIG?.V2RAY_FULL_JSON_CONFIG ?? ""
        let port = v2rayConfig.LOCAL_SOCKS5_PORT
        let tunnelProtocol = createVPNProtocol(vmess: vmess, port: port)

        loadVPNConfigurationAndStartTunnel(with: tunnelProtocol)
    }

    /// 创建VPN协议
    private func createVPNProtocol(vmess: String, port: Int) -> NETunnelProviderProtocol {
        let tunnelProtocol = NETunnelProviderProtocol()
        tunnelProtocol.serverAddress = AppConfigs.APPLICATION_NAME
        tunnelProtocol.providerConfiguration = ["vmess": vmess, "port": port]
        tunnelProtocol.providerBundleIdentifier = AppConfigs.BUNDLE_IDENTIFIER
        return tunnelProtocol
    }

    /// 加载现有VPN配置并启动VPN隧道
    private func loadVPNConfigurationAndStartTunnel(with tunnelProtocol: NETunnelProviderProtocol) {
        NETunnelProviderManager.loadAllFromPreferences { managers, error in
            guard let managers = managers, error == nil else {
                os_log("loadAllFromPreferences Failed to save VPN configuration:  %{public}@", log: appLog, type: .error, error!.localizedDescription)
                return
            }

            if managers.isEmpty {
                self.createNewVPNConfigurationAndStartTunnel(with: tunnelProtocol)
            } else {
                let targetDescription = AppConfigs.APPLICATION_NAME
                if let existingManager = managers.first(where: { $0.localizedDescription == targetDescription }) {
                    // 找到匹配的配置
                    existingManager.isEnabled = true
                    existingManager.saveToPreferences { _ in
                        existingManager.loadFromPreferences { _ in
                            self.manager = existingManager
                            self.startVPNTunnel()
                        }
                    }
                } else {
                    // 没有找到匹配的配置，创建新的配置
                    self.createNewVPNConfigurationAndStartTunnel(with: tunnelProtocol)
                }
            }
        }
    }

    /// 使用新的VPN协议配置并启动隧道（公共方法）
    private func saveAndStartTunnel(with tunnelProtocol: NETunnelProviderProtocol, manager: NETunnelProviderManager?) {
        let managerToUse = manager ?? NETunnelProviderManager()

        managerToUse.isEnabled = true
        managerToUse.protocolConfiguration = tunnelProtocol
        managerToUse.localizedDescription = AppConfigs.APPLICATION_NAME

        managerToUse.saveToPreferences { error in
            if let error = error {
                os_log("saveAndStartTunnel Failed to save VPN configuration:  %{public}@", log: appLog, type: .error, error.localizedDescription)
            } else {
                // 如果是新的管理器，则保存并启动隧道
                if manager == nil {
                    self.manager = managerToUse
                }
                managerToUse.loadFromPreferences { _ in
                    self.startVPNTunnel()
                }
            }
        }
    }

    /// 使用新的VPN协议配置并启动隧道（调用公共方法）
    private func createNewVPNConfigurationAndStartTunnel(with tunnelProtocol: NETunnelProviderProtocol) {
        let managerToUse = NETunnelProviderManager()

        managerToUse.isEnabled = true
        managerToUse.protocolConfiguration = tunnelProtocol
        managerToUse.localizedDescription = AppConfigs.APPLICATION_NAME

        managerToUse.saveToPreferences { error in
            if let error = error {
                os_log("saveAndStartTunnel Failed to save VPN configuration:  %{public}@", log: appLog, type: .error, error.localizedDescription)
            } else {
                self.manager = managerToUse
                managerToUse.loadFromPreferences { _ in
                    self.startVPNTunnel()
                }
            }
        }
    }

    /// 启动VPN隧道
    private func startVPNTunnel() {
        do {
            try manager.connection.startVPNTunnel()
            os_log("VPN 核心已启用", log: appLog, type: .info)
        } catch let vpnError as NSError {
            os_log("Failed to start VPN tunnel: %{public}@", log: appLog, type: .error, vpnError.localizedDescription)
            os_log("Error code: %{public}d", log: appLog, type: .error, vpnError.code)
        }
    }

    /// 启用VPN配置
    public func enableVPNManager(completion: @escaping (Error?) -> Void) {
        manager.isEnabled = true

        manager.saveToPreferences { error in
            guard error == nil else {
                completion(error)
                return
            }

            self.manager.loadFromPreferences { error in
                completion(error)
            }
        }
    }

    /// 停止核心逻辑
    public func stopCore() {
        NETunnelProviderManager.loadAllFromPreferences { managers, error in
            guard let managers = managers, error == nil else {
                return
            }

            // 查找特定的 VPN 配置
            if let targetManager = managers.first(where: { $0.localizedDescription == AppConfigs.APPLICATION_NAME }) {
                // 找到匹配的配置
                self.manager = targetManager
                self.manager.loadFromPreferences { [weak self] error in
                    guard let self = self else { return }
                    if let error = error {
                        os_log("加载配置失败: %@", log: appLog, type: .error, error.localizedDescription)
                        return
                    }

                    // 更新内部状态
                    V2RAY_STATE = .DISCONNECT

//                    self.manager.isEnabled = false
                    self.manager.saveToPreferences { error in
                        if let error = error {
                            os_log("保存配置失败: %@", log: appLog, type: .error, error.localizedDescription)
                            return
                        }

                        // 确认配置已保存后再停止隧道
                        self.manager.connection.stopVPNTunnel()
                        self.stopTrafficStatsTimer()
                        os_log("VPN 核心已停止", log: appLog, type: .info)
                    }
                }
            }
        }
    }

    // 封装获取流量统计和发送到 Flutter 的功能
    func getTrafficStatsAndSendToFlutter() {
        guard let vpnConnection = manager.connection as? NETunnelProviderSession else {
            print("Error: VPN connection is not available.")
            return
        }

        let message: [String: Any] = ["command": "getTrafficStats"]
        do {
            let messageData = try JSONSerialization.data(withJSONObject: message, options: [])

            try vpnConnection.sendProviderMessage(messageData) { response in
                guard let response = response else {
                    print("No response received")
                    return
                }

                do {
                    if let responseJSON = try JSONSerialization.jsonObject(with: response, options: []) as? [String: Any] {
                        // 定义要提取的键
                        let keys = ["totalUpload", "downloadSpeed", "totalDownload", "uploadSpeed"]

                        var totalUpload = 0
                        var downloadSpeed = 0
                        var totalDownload = 0
                        var uploadSpeed = 0

                        // 遍历键，获取对应的值
                        for key in keys {
                            if let value = responseJSON[key] as? Int {
                                // 根据键存储对应的值
                                switch key {
                                case "totalUpload":
                                    totalUpload = value
                                case "downloadSpeed":
                                    downloadSpeed = value
                                case "totalDownload":
                                    totalDownload = value
                                case "uploadSpeed":
                                    uploadSpeed = value
                                default:
                                    break
                                }
                            }
                        }

                        let connectStatus = AppConfigs.V2RAY_STATE.description
                        // Calculate duration
                        let duration = self.getDurationString()
                        // 将值传递到 Flutter
                        self.pligun.sendEventToFlutter([
                            duration, // 持续时间
                            "\(uploadSpeed)", // 上传速度
                            "\(downloadSpeed)", // 下载速度
                            "\(totalUpload)", // 总上传
                            "\(totalDownload)", // 总下载
                            connectStatus // 当前状态
                        ])
                    } else {
                        print("Failed to decode response as JSON")
                    }
                } catch {
                    print("Error decoding JSON: \(error.localizedDescription)")
                }
            }
        } catch {
            print("Error sending provider message: \(error.localizedDescription)")
        }
    }

    // 定时每1秒调用一次
    func startTrafficStatsTimer() {
        trafficStatsTimer?.invalidate()
        trafficStatsTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.getTrafficStatsAndSendToFlutter()
        }
    }

    private func stopTrafficStatsTimer() {
        trafficStatsTimer?.invalidate()
        trafficStatsTimer = nil
    }

    private func getDurationString() -> String {
        guard let startTime = startTime else {
            return "00:00:00"
        }

        let elapsedTime = Date().timeIntervalSince(startTime)
        let hours = Int(elapsedTime) / 3600
        let minutes = (Int(elapsedTime) % 3600) / 60
        let seconds = Int(elapsedTime) % 60

        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }
}
