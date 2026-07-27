import XCTest
@testable import MyQuotaBar

/// 关键逻辑测试：不求多，只覆盖「数据正确性命脉 + 易错边界」。
/// 这些一旦出错，用户看到的数字/百分比/文案就是错的。
final class MyQuotaBarTests: XCTestCase {

    // MARK: - Formatting：用户看到的数字格式（原样、去尾零、限位）

    func testFormattingRaw() {
        // 保留至多 3 位小数，去掉末尾多余零；不做 k/w 压缩
        XCTAssertEqual(Formatting.raw(1793.747), "1793.747")
        XCTAssertEqual(Formatting.raw(10000), "10000")           // 整数不带 .0
        XCTAssertEqual(Formatting.raw(25873.6460), "25873.646")  // 去尾零
        XCTAssertEqual(Formatting.raw(0.5), "0.5")
        XCTAssertEqual(Formatting.raw(0), "0")
        XCTAssertEqual(Formatting.raw(8.790), "8.79")
        // 第 4 位小数被四舍五入到 3 位
        XCTAssertEqual(Formatting.raw(1.23449), "1.234")
    }

    func testFormattingPercent() {
        XCTAssertEqual(Formatting.percent(78), "78")       // 整数不带 .0
        XCTAssertEqual(Formatting.percent(78.5), "78.5")
        XCTAssertEqual(Formatting.percent(78.54), "78.5")  // 限 1 位
        XCTAssertEqual(Formatting.percent(0), "0")
        XCTAssertEqual(Formatting.percent(100), "100")
    }

    // MARK: - 百分比计算：除零保护 + 越界裁剪（进度条/剩余标签命脉）

    func testAgentPlanRemainingPercent() {
        let p = AgentPlanPeriod(label: "5h", used: 22, total: 100, percent: 22, resetAt: nil)
        XCTAssertEqual(p.remainingPercent, 78, accuracy: 0.001)
    }

    func testAgentPlanPercentClamp() {
        // 超用（percent > 100）时剩余不应为负
        let over = AgentPlanPeriod(label: "5h", used: 120, total: 100, percent: 120, resetAt: nil)
        XCTAssertEqual(over.remainingPercent, 0)
        // percent < 0 的异常输入，剩余不超过 100
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
        // 未购买（purchasedValue = 0）不能崩，也不能得 NaN
        let pack = SpeechPack(title: "x", purchased: "", used: "", unit: "",
                              purchasedValue: 0, usedValue: 0, expires: "", type: "")
        XCTAssertEqual(pack.remainingPercent, 0)
        XCTAssertEqual(pack.usedPercent, 0)
    }

    // MARK: - 语音数值抽取：从 "20,000 次" / "8.79 小时" 抽数（逗号/小数/单位）

    func testNumberFromLoose() {
        XCTAssertEqual(SpeechProvider.numberFromLoose("20,000 次"), 20000)   // 去千分位逗号
        XCTAssertEqual(SpeechProvider.numberFromLoose("8.79 小时"), 8.79)    // 带小数
        XCTAssertEqual(SpeechProvider.numberFromLoose("34 次"), 34)
        XCTAssertEqual(SpeechProvider.numberFromLoose("20.00 小时"), 20)
        XCTAssertEqual(SpeechProvider.numberFromLoose(""), 0)               // 空串
        XCTAssertEqual(SpeechProvider.numberFromLoose("无数字"), 0)          // 无数字
        XCTAssertEqual(SpeechProvider.numberFromLoose("1,234.5 万"), 1234.5) // 逗号+小数
    }

    // MARK: - Agent Plan 解析：字段抽取 + 窗口排序 + 缺字段处理

    func testParseAgentPlanBasic() throws {
        let json = """
        {
          "viewer": { "user_name": "张三", "account_id": "2104007443" },
          "items": [{
            "product": "agent-plan",
            "tier": "medium",
            "edition": "personal",
            "periods": [
              { "label": "monthly", "used": 100, "total": 1000, "percent": 10 },
              { "label": "5h", "used": 22, "total": 100, "percent": 22 },
              { "label": "weekly", "used": 50, "total": 500, "percent": 10 }
            ]
          }]
        }
        """
        let plan = try ArkPlanProvider.parse(json)
        XCTAssertEqual(plan.tier, "medium")
        XCTAssertEqual(plan.userName, "张三")
        XCTAssertEqual(plan.accountID, "2104007443")
        // 必须按 5h → weekly → monthly 排序（不受输入顺序影响）
        XCTAssertEqual(plan.periods.map(\.label), ["5h", "weekly", "monthly"])
        XCTAssertEqual(plan.periods[0].used, 22)
    }

    func testParseAgentPlanComputesPercentWhenMissing() throws {
        // percent 缺失时用 used/total 算
        let json = """
        { "items": [{ "product": "agent-plan",
          "periods": [{ "label": "5h", "used": 25, "total": 100 }] }] }
        """
        let plan = try ArkPlanProvider.parse(json)
        XCTAssertEqual(plan.periods[0].percent, 25, accuracy: 0.001)
        XCTAssertEqual(plan.periods[0].remainingPercent, 75, accuracy: 0.001)
    }

    func testParseAgentPlanEmptyThrows() {
        // 没有 periods 应抛错（不静默返回空卡）
        let json = """
        { "items": [{ "product": "agent-plan", "periods": [] }] }
        """
        XCTAssertThrowsError(try ArkPlanProvider.parse(json))
    }

    func testParseAgentPlanBadJSONThrows() {
        XCTAssertThrowsError(try ArkPlanProvider.parse("not json"))
        XCTAssertThrowsError(try ArkPlanProvider.parse("{}"))  // 缺 items
    }

    // MARK: - 重置倒计时文案（分/时/天边界 + 过去时间）

    func testRelativeReset() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        func at(_ secs: TimeInterval) -> String {
            RelativeReset.text(to: now.addingTimeInterval(secs), now: now)
        }
        XCTAssertEqual(at(-10), "即将重置")           // 已过期
        XCTAssertEqual(at(30 * 60), "30 分钟后重置")   // 30 分钟
        XCTAssertEqual(at(90 * 60), "1 小时 30 分后重置")
        XCTAssertEqual(at(120 * 60), "2 小时后重置")   // 整点无余分
        XCTAssertEqual(at(25 * 3600), "1 天 1 小时后重置")
        XCTAssertEqual(at(48 * 3600), "2 天后重置")    // 整天无余时
    }
}
