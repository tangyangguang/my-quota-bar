import XCTest
@testable import MyQuotaBar

/// 关键逻辑测试：不求多，只覆盖「数据正确性命脉 + 易错边界」。
/// 这些一旦出错，用户看到的数字/百分比/文案就是错的。
final class MyQuotaBarTests: XCTestCase {

    // MARK: - Formatting：用户看到的数字格式（原样、去尾零、限位）

    func testFormattingRaw() {
        XCTAssertEqual(Formatting.raw(1793.747), "1793.747")
        XCTAssertEqual(Formatting.raw(10000), "10000")
        XCTAssertEqual(Formatting.raw(25873.6460), "25873.646")
        XCTAssertEqual(Formatting.raw(0.5), "0.5")
        XCTAssertEqual(Formatting.raw(0), "0")
        XCTAssertEqual(Formatting.raw(8.790), "8.79")
        XCTAssertEqual(Formatting.raw(1.23449), "1.234")
    }

    func testFormattingPercent() {
        XCTAssertEqual(Formatting.percent(78), "78")
        XCTAssertEqual(Formatting.percent(78.5), "78.5")
        XCTAssertEqual(Formatting.percent(78.54), "78.5")
        XCTAssertEqual(Formatting.percent(0), "0")
        XCTAssertEqual(Formatting.percent(100), "100")
    }

    // MARK: - 百分比计算：除零保护 + 越界裁剪

    func testAgentPlanRemainingPercent() {
        let p = AgentPlanPeriod(label: "5h", used: 22, total: 100, percent: 22, resetAt: nil)
        XCTAssertEqual(p.remainingPercent, 78, accuracy: 0.001)
    }

    func testAgentPlanPercentClamp() {
        let over = AgentPlanPeriod(label: "5h", used: 120, total: 100, percent: 120, resetAt: nil)
        XCTAssertEqual(over.remainingPercent, 0)
        let neg = AgentPlanPeriod(label: "5h", used: 0, total: 100, percent: -5, resetAt: nil)
        XCTAssertEqual(neg.remainingPercent, 100)
    }

    func testSpeechPackPercents() {
        let pack = SpeechPack(title: "语音识别 ASR", purchased: "20.00 小时", used: "8.79 小时",
                              unit: "小时", purchasedValue: 20, usedValue: 8.79,
                              expires: "", type: "试用包")
        XCTAssertEqual(pack.usedPercent, 43.95, accuracy: 0.001)
        XCTAssertEqual(pack.remainingPercent, 56.05, accuracy: 0.001)
    }

    func testSpeechPackDivideByZero() {
        let pack = SpeechPack(title: "x", purchased: "", used: "", unit: "",
                              purchasedValue: 0, usedValue: 0, expires: "", type: "")
        XCTAssertEqual(pack.remainingPercent, 0)
        XCTAssertEqual(pack.usedPercent, 0)
    }

    // MARK: - 语音数值抽取：从 "20,000 次" / "8.79 小时" 抽数

    func testNumberFromLoose() {
        XCTAssertEqual(SpeechProvider.numberFromLoose("20,000 次"), 20000)
        XCTAssertEqual(SpeechProvider.numberFromLoose("8.79 小时"), 8.79)
        XCTAssertEqual(SpeechProvider.numberFromLoose("34 次"), 34)
        XCTAssertEqual(SpeechProvider.numberFromLoose("20.00 小时"), 20)
        XCTAssertEqual(SpeechProvider.numberFromLoose(""), 0)
        XCTAssertEqual(SpeechProvider.numberFromLoose("无数字"), 0)
        XCTAssertEqual(SpeechProvider.numberFromLoose("1,234.5 万"), 1234.5)
    }

    func testSpeechProviderKeepsAllResourcePacks() {
        let list: [[String: Any]] = [
            ["instance_number": "pack-a", "purchased_amount": "20.00 小时",
             "current_usage": "3.00 小时", "expires": "2027-01-01", "type": "试用包"],
            ["instance_number": "pack-b", "purchased_amount": "10.00 小时",
             "current_usage": "1.00 小时", "expires": "2027-02-01", "type": "购买包"]
        ]
        let packs = SpeechProvider.parsePacks(title: "语音识别 ASR", list: list)
        XCTAssertEqual(packs.count, 2)
        XCTAssertEqual(packs.map(\.instanceID), ["pack-a", "pack-b"])
        XCTAssertEqual(packs.map(\.purchasedValue), [20, 10])
    }

    // MARK: - Agent Plan AFP API 解析（GetAFPUsage 响应格式）

    /// 模拟一次完整的 AFP 响应。
    private func afpJSON(tier: String = "medium",
                         fiveHour: [String: Any] = ["Quota": 10000, "Used": 660.94, "ResetTime": 1785236766000],
                         weekly: [String: Any] = ["Quota": 35000, "Used": 22289.18, "ResetTime": 1785686400000],
                         monthly: [String: Any] = ["Quota": 100000, "Used": 38528.53, "ResetTime": 1786809599000]) -> Data {
        let dict: [String: Any] = [
            "ResponseMetadata": ["Action": "GetAFPUsage", "Version": "2024-01-01", "Service": "ark", "Region": "cn-beijing"],
            "Result": [
                "PlanType": tier,
                "AFPFiveHour": fiveHour,
                "AFPWeekly": weekly,
                "AFPMonthly": monthly
            ]
        ]
        return try! JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])
    }

    func testParseAFPBasic() throws {
        let data = afpJSON()
        let plan = try AgentPlanProvider.parse(data)
        XCTAssertEqual(plan.tier, "medium")
        XCTAssertEqual(plan.edition, "personal")
        XCTAssertEqual(plan.unit, "AFP")
        XCTAssertEqual(plan.periods.map(\.label), ["5h", "weekly", "monthly"])
        // 5h: 660.94 / 10000 = 6.6094%
        XCTAssertEqual(plan.periods[0].used, 660.94, accuracy: 0.001)
        XCTAssertEqual(plan.periods[0].total, 10000)
        XCTAssertEqual(plan.periods[0].remainingPercent, 100 - 660.94 / 10000 * 100, accuracy: 0.001)
    }

    func testParseAFPEmptyPeriodThrows() {
        // 没有 Quota 的周期应跳过；全部跳过则抛错
        let data = afpJSON(fiveHour: [:], weekly: [:], monthly: [:])
        XCTAssertThrowsError(try AgentPlanProvider.parse(data))
    }

    func testParseAFPBadJSONThrows() {
        let bad = Data("not json".utf8)
        XCTAssertThrowsError(try AgentPlanProvider.parse(bad))
        // 缺 Result 顶层字段
        let noResult = try! JSONSerialization.data(withJSONObject: ["ResponseMetadata": [:]], options: [])
        XCTAssertThrowsError(try AgentPlanProvider.parse(noResult))
    }

    func testParseAFPErrorResponse() throws {
        // 错误响应没有 Result，也必须保留官方错误信息而非报“格式错误”。
        let err: [String: Any] = [
            "ResponseMetadata": [
                "Error": ["Code": "AuthFailure", "Message": "InvalidAccessKeyId"]
            ]
        ]
        let data = try! JSONSerialization.data(withJSONObject: err, options: [.sortedKeys])
        XCTAssertThrowsError(try AgentPlanProvider.parse(data)) { error in
            XCTAssertEqual(error.localizedDescription, "命令执行失败：InvalidAccessKeyId")
        }
    }

    // MARK: - 账号显示名（别名 > 默认名 > “账号”，拼尾号）

    func testAccountDisplayName() {
        func acc(def: String, tail: String?, alias: String?) -> Account {
            Account(id: "x", platform: "火山引擎", defaultName: def,
                    idTail: tail, fullID: nil, alias: alias, services: [])
        }
        XCTAssertEqual(acc(def: "张三", tail: "1234", alias: nil).displayName, "火山引擎 · 张三 (…1234)")
        XCTAssertEqual(acc(def: "张三", tail: "1234", alias: "工作号").displayName, "火山引擎 · 工作号 (…1234)")
        XCTAssertEqual(acc(def: "", tail: "5678", alias: nil).displayName, "火山引擎 · 账号 (…5678)")
        XCTAssertEqual(acc(def: "张三", tail: nil, alias: nil).displayName, "火山引擎 · 张三")
        XCTAssertEqual(acc(def: "张三", tail: "1234", alias: "").displayName, "火山引擎 · 张三 (…1234)")
        XCTAssertEqual(acc(def: "张三", tail: "1234", alias: "工作号").accountDisplayName, "工作号 (…1234)")
    }

    func testPlatformRegistry() {
        XCTAssertEqual(PlatformRegistry.supportedPlatforms, [.volcengine])
        let adapter = PlatformRegistry.adapter(for: .volcengine)
        XCTAssertEqual(adapter?.services.map(\.id), ["agent-plan", "speech"])
        XCTAssertEqual(adapter?.credentialFields.map(\.id), ["accessKeyID", "secretAccessKey"])
        XCTAssertNil(PlatformRegistry.adapter(for: Platform(rawValue: "future-platform")))
    }

    func testAccountEffectiveName() {
        let a = Account(id: "x", platform: "P", defaultName: "张三", idTail: nil,
                        fullID: nil, alias: "别名", services: [])
        XCTAssertEqual(a.effectiveName, "别名")
        let b = Account(id: "x", platform: "P", defaultName: "张三", idTail: nil,
                        fullID: nil, alias: nil, services: [])
        XCTAssertEqual(b.effectiveName, "张三")
    }

    // MARK: - 配置持久化（当前 schema 往返 / 未知字段忽略 / 未知平台保留）

    func testAccountConfigDecodesUnknownPlatform() throws {
        // 不认识的平台原样保留，绝不能污染成火山引擎。
        let future = """
        {"id":"x","platform":"unknown_platform","alias":"","enableAgentPlan":false,"speechApps":[]}
        """
        let config = try JSONDecoder().decode(AccountConfig.self, from: Data(future.utf8))
        XCTAssertEqual(config.platform.rawValue, "unknown_platform")
        XCTAssertFalse(config.platform.isSupported)
        let roundTrip = try JSONDecoder().decode(AccountConfig.self,
                                                  from: JSONEncoder().encode(config))
        XCTAssertEqual(roundTrip.platform.rawValue, "unknown_platform")
    }

    func testAccountConfigIgnoresLegacyExtraKeys() throws {
        // 已移除的历史字段（如 enableSpeech）是未知键，合成解码直接忽略，不报错、不丢账号。
        let old = """
        {"id":"abc","platform":"volcengine","alias":"主账号","accountFullID":"1234567890",
         "enableAgentPlan":true,"enableSpeech":true,
         "speechApps":[{"id":"a","appID":"123","label":"A","enableASR":true,"enableTTS":true}]}
        """
        let config = try JSONDecoder().decode(AccountConfig.self, from: Data(old.utf8))
        XCTAssertEqual(config.id, "abc")
        XCTAssertTrue(config.enableAgentPlan)
        XCTAssertTrue(config.hasActiveSpeech)
        XCTAssertTrue(config.hasAnyService)
    }

    func testAccountConfigRoundTrip() throws {
        let apps = [SpeechApp(id: "s1", appID: "123", label: "应用A")]
        let orig = AccountConfig(id: "acc1", platform: .volcengine, alias: "测试",
                                 accountFullID: "1234567890", enableAgentPlan: true, speechApps: apps)
        let data = try JSONEncoder().encode(orig)
        let back = try JSONDecoder().decode(AccountConfig.self, from: data)
        XCTAssertEqual(orig, back)
        XCTAssertTrue(back.hasActiveSpeech)
    }

    // MARK: - 语音应用启用态派生（isActive）与 ASR / TTS 开关

    func testSpeechAppActiveRequiresValidAppIDAndASubService() {
        XCTAssertTrue(SpeechApp(id: "s1", appID: "123", label: "A").isActive)   // 有效 AppID + 默认全开
        XCTAssertFalse(SpeechApp(id: "s2", appID: "", label: "A").isActive)      // 空 AppID
        XCTAssertFalse(SpeechApp(id: "s3", appID: "abc", label: "A").isActive)   // 非数字
        XCTAssertFalse(SpeechApp(id: "s4", appID: "0", label: "A").isActive)     // 0
        XCTAssertFalse(SpeechApp(id: "s5", appID: "456", enableASR: false, enableTTS: false).isActive) // 全关
        XCTAssertTrue(SpeechApp(id: "s6", appID: "456", enableASR: false, enableTTS: true).isActive)   // 只开 TTS
    }

    func testSpeechAppRoundTripsASRTTSToggles() throws {
        let app = SpeechApp(id: "s1", appID: "123", label: "A", enableASR: false, enableTTS: true)
        let back = try JSONDecoder().decode(SpeechApp.self, from: JSONEncoder().encode(app))
        XCTAssertEqual(app, back)
        XCTAssertFalse(back.enableASR)
        XCTAssertTrue(back.enableTTS)
        XCTAssertTrue(back.isActive)
    }

    // MARK: - 身份标记（主账号 / 子用户）

    func testIdentityKindCodeAndBadge() {
        let root = VolcSigner.Identity(accountID: "1234567890", userName: nil, isRoot: true)
        XCTAssertEqual(root.kindCode, "root")
        let user = VolcSigner.Identity(accountID: "2345678901", userName: "小明", isRoot: false)
        XCTAssertEqual(user.kindCode, "user:小明")

        XCTAssertNil(AccountConfig(id: "a").identityBadge)
        XCTAssertEqual(AccountConfig(id: "b", iamIdentity: "root").identityBadge, "主账号")
        XCTAssertEqual(AccountConfig(id: "c", iamIdentity: "user:小明").identityBadge, "子用户 · 小明")
    }

    func testAccountConfigDerivesSpeechActivity() {
        let inactiveApp = SpeechApp(id: "a", appID: "123", enableASR: false, enableTTS: false)
        let noIDApp = SpeechApp(id: "b", appID: "", enableASR: true, enableTTS: true)
        let activeApp = SpeechApp(id: "c", appID: "456", enableASR: false, enableTTS: true)

        let none = AccountConfig(id: "x", speechApps: [inactiveApp, noIDApp])
        XCTAssertFalse(none.hasActiveSpeech)
        XCTAssertFalse(none.hasAnyService)

        let some = AccountConfig(id: "y", enableAgentPlan: true, speechApps: [inactiveApp, activeApp])
        XCTAssertTrue(some.hasActiveSpeech)
        XCTAssertTrue(some.hasAnyService)
    }

    // MARK: - 面板多账号内容高度

    func testPanelContentHeightUsesNaturalHeightUntilItNeedsScrolling() {
        XCTAssertEqual(PanelContentLayout.scrollHeight(for: 40), 90)
        XCTAssertEqual(PanelContentLayout.scrollHeight(for: 420), 420)
        XCTAssertEqual(PanelContentLayout.scrollHeight(for: 900), 640)
    }

    // MARK: - 重置倒计时文案（分/时/天边界 + 过去时间）

    func testRelativeReset() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        func at(_ secs: TimeInterval) -> String {
            RelativeReset.text(to: now.addingTimeInterval(secs), now: now)
        }
        XCTAssertEqual(at(-10), "即将重置")
        XCTAssertEqual(at(30 * 60), "30 分钟后重置")
        XCTAssertEqual(at(90 * 60), "1 小时 30 分后重置")
        XCTAssertEqual(at(120 * 60), "2 小时后重置")
        XCTAssertEqual(at(25 * 3600), "1 天 1 小时后重置")
        XCTAssertEqual(at(48 * 3600), "2 天后重置")
    }
}