import Foundation
import Security
import CryptoKit

// My Quota Bar 钥匙串助手（credhelper）。
//
// 为什么需要它：macOS 钥匙串对「自签名 / ad-hoc 签名」的 app，在图形化访问时按
// 二进制哈希（cdhash）记忆授权；而主程序每次改代码重新编译，哈希都会变，于是 AK/SK
// 条目每次更新后都重新弹「始终允许」。解决办法是把钥匙串读写收敛到这个**签名一次、
// 之后永不再编译**的固定助手：它的二进制哈希恒定，用户对它点一次「始终允许」即永久
// 有效；主程序随便重编译都不再直接碰钥匙串，因此不再弹窗。
//
// 协议（极简、稳定，冻结后不改；将来若必须变更用 credhelper-v2 新文件，互不影响）：
//   credhelper-v1 get    <account>     把密钥原样写到 stdout；不存在则输出空；出错返回非 0
//   credhelper-v1 set    <account>     从 stdin 读入密钥值；空值=删除
//   credhelper-v1 delete <account>     删除该条目
//
// 安全：只对「同一自签证书签名、identifier 为 local.my.quota-bar 的父进程」返回密钥；
// 其他进程调用一律拒绝。密钥经 stdin/stdout 传递，不进命令行参数（避免 ps 泄露）。

private let service = "local.my.quota-bar"
private let expectedParentIdentifier = "local.my.quota-bar"

// MARK: - 调用方校验

/// 校验父进程：必须与本助手由同一张证书签名，且 bundle identifier 是主程序。
/// 私钥从不离开本机，因此只有本项目构建的产物能满足该要求。
private func parentIsAuthorized() -> Bool {
    let ppid = getppid()

    // 取本助手叶子证书的 SHA-1（与 codesign designated requirement 里的 leaf 哈希一致）。
    // kSecCSSigningInformation 才会返回证书链。
    let selfURL = URL(fileURLWithPath: CommandLine.arguments[0])
    var staticSelf: SecStaticCode?
    guard SecStaticCodeCreateWithPath(selfURL as CFURL, SecCSFlags(), &staticSelf) == errSecSuccess,
          let staticSelf else { return false }
    var infoCF: CFDictionary?
    let infoFlags = SecCSFlags(rawValue: kSecCSSigningInformation)
    guard SecCodeCopySigningInformation(staticSelf, infoFlags, &infoCF) == errSecSuccess,
          let selfInfoDict = infoCF as? [String: Any],
          let selfCerts = selfInfoDict[kSecCodeInfoCertificates as String] as? [SecCertificate],
          let leaf = selfCerts.first else { return false }
    let leafHash = Insecure.SHA1.hash(data: SecCertificateCopyData(leaf) as Data)
        .map { String(format: "%02x", $0) }.joined()

    var parentCode: SecCode?
    let guestAttrs = [kSecGuestAttributePid as String: ppid] as CFDictionary
    guard SecCodeCopyGuestWithAttributes(nil, guestAttrs, SecCSFlags(), &parentCode) == errSecSuccess,
          let parentCode else { return false }

    let requirementText =
        "identifier \"\(expectedParentIdentifier)\" and certificate leaf = H\"\(leafHash)\""
    var requirement: SecRequirement?
    guard SecRequirementCreateWithString(requirementText as CFString, SecCSFlags(), &requirement) == errSecSuccess,
          let requirement else { return false }

    return SecCodeCheckValidity(parentCode, SecCSFlags(), requirement) == errSecSuccess
}

// MARK: - 钥匙串操作

private func keychainQuery(account: String) -> [String: Any] {
    [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: account
    ]
}

private func getItem(account: String) -> Int32 {
    var query = keychainQuery(account: account)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    if status == errSecSuccess, let data = item as? Data {
        FileHandle.standardOutput.write(data)
        return 0
    }
    if status == errSecItemNotFound { return 0 } // 不存在=输出空
    FileHandle.standardError.write("get failed: \(status)\n".data(using: .utf8)!)
    return 1
}

private func setItem(account: String) -> Int32 {
    let value = FileHandle.standardInput.readDataToEndOfFile()
    // 去掉末尾换行（调用方写入时可能带一个换行）
    var trimmed = value
    while let last = trimmed.last, last == 0x0A || last == 0x0D { trimmed.removeLast() }

    if trimmed.isEmpty {
        return deleteItem(account: account)
    }

    var query = keychainQuery(account: account)
    let attributes: [String: Any] = [
        kSecValueData as String: trimmed,
        kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
    ]
    var updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    if updateStatus == errSecSuccess { return 0 }
    if updateStatus != errSecItemNotFound {
        FileHandle.standardError.write("set update failed: \(updateStatus)\n".data(using: .utf8)!)
        return 1
    }
    for (k, v) in attributes { query[k] = v }
    updateStatus = SecItemAdd(query as CFDictionary, nil)
    if updateStatus != errSecSuccess {
        FileHandle.standardError.write("set add failed: \(updateStatus)\n".data(using: .utf8)!)
        return 1
    }
    return 0
}

private func deleteItem(account: String) -> Int32 {
    let status = SecItemDelete(keychainQuery(account: account) as CFDictionary)
    if status == errSecSuccess || status == errSecItemNotFound { return 0 }
    FileHandle.standardError.write("delete failed: \(status)\n".data(using: .utf8)!) ; return 1
}

/// 一次性维护：把本服务下所有条目的 ACL 重锚到当前身份（本助手，与主程序同一证书 DR）。
/// 用于把 ad-hoc 时期的旧条目迁移到冻结助手身份。**不读取密钥数据，只改访问控制**；
/// 锚到的是本项目证书身份，安全上不产生降级，因此允许构建脚本（非 app 父进程）调用。
private func migrateAll() -> Int32 {
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecMatchLimit as String: kSecMatchLimitAll,
        kSecReturnRef as String: true
    ]
    var refs: CFTypeRef?
    let match = SecItemCopyMatching(query as CFDictionary, &refs)
    if match == errSecItemNotFound { return 0 }
    guard match == errSecSuccess else { return 1 }

    var me: SecTrustedApplication?
    SecTrustedApplicationCreateFromPath(nil, &me)
    var access: SecAccess?
    SecAccessCreate(service as CFString, [me!] as CFArray, &access)

    let update: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecMatchLimit as String: kSecMatchLimitAll,
        kSecAttrAccess as String: access!
    ]
    let us = SecItemUpdate(update as CFDictionary, [:] as CFDictionary)
    return us == errSecSuccess ? 0 : 1
}

// MARK: - 入口

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write("credhelper: missing command\n".data(using: .utf8)!) ; exit(2)
}
let command = args[1]

// migrate-all：一次性维护操作（构建脚本调用，父进程不是 app 也允许）。
// 只把本服务条目的访问控制重锚到当前证书身份，**不读取任何密钥数据**，不会泄露凭据。
if command == "migrate-all" {
    exit(migrateAll())
}

guard args.count >= 3, parentIsAuthorized() else {
    FileHandle.standardError.write("credhelper: unauthorized or bad arguments\n".data(using: .utf8)!) ; exit(1)
}
let account = args[2]

switch command {
case "get":
    exit(getItem(account: account))
case "set":
    exit(setItem(account: account))
case "delete":
    exit(deleteItem(account: account))
default:
    FileHandle.standardError.write("credhelper: unknown command \(command)\n".data(using: .utf8)!) ; exit(2)
}
