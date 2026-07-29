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
        XCTAssertEqual(acc(def: "张三", tail: "7443", alias: nil).displayName, "火山引擎 · 张三 (…7443)")
        XCTAssertEqual(acc(def: "张三", tail: "7443", alias: "工作号").displayName, "火山引擎 · 工作号 (…7443)")
        XCTAssertEqual(acc(def: "", tail: "1074", alias: nil).displayName, "火山引擎 · 账号 (…1074)")
        XCTAssertEqual(acc(def: "张三", tail: nil, alias: nil).displayName, "火山引擎 · 张三")
        XCTAssertEqual(acc(def: "张三", tail: "7443", alias: "").displayName, "火山引擎 · 张三 (…7443)")
        XCTAssertEqual(acc(def: "张三", tail: "7443", alias: "工作号").accountDisplayName, "工作号 (…7443)")
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

    // MARK: - 配置持久化防丢失（旧 schema JSON 仍能解析）

    func testAccountConfigDecodesLegacyJSON() throws {
        // 模拟早期版本存的 JSON：没有 platform 字段
        let legacy = """
        {"id":"abc","alias":"主账号","enableAgentPlan":true,"speechApps":[]}
        """
        let config = try JSONDecoder().decode(AccountConfig.self, from: Data(legacy.utf8))
        XCTAssertEqual(config.id, "abc")
        XCTAssertEqual(config.alias, "主账号")
        XCTAssertTrue(config.enableAgentPlan)
        XCTAssertFalse(config.enableSpeech)
        XCTAssertEqual(config.platform, .volcengine)   // 缺失 platform 回落火山
    }

    func testLegacySpeechAppsRemainEnabledAfterMigration() throws {
        let legacy = """
        {"id":"speech","alias":"语音账号","enableAgentPlan":false,
         "speechApps":[{"id":"a","appID":"123","label":"A"}]}
        """
        let config = try JSONDecoder().decode(AccountConfig.self, from: Data(legacy.utf8))
        XCTAssertTrue(config.enableSpeech)
        XCTAssertEqual(config.speechApps.count, 1)
    }

    func testAccountConfigDecodesUnknownPlatform() throws {
        // 未来降级：原样保留本版本不认识的平台，绝不能污染成火山引擎。
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

    func testAccountConfigRoundTrip() throws {
        let apps = [SpeechApp(id: "s1", appID: "123", label: "应用A")]
        let orig = AccountConfig(id: "acc1", platform: .volcengine, alias: "测试",
                                 accountFullID: "2104007443", enableAgentPlan: true, speechApps: apps)
        let data = try JSONEncoder().encode(orig)
        let back = try JSONDecoder().decode(AccountConfig.self, from: data)
        XCTAssertEqual(orig, back)
        XCTAssertTrue(back.enableSpeech)
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