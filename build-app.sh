#!/bin/zsh
set -euo pipefail

project_dir=${0:A:h}
output_dir="$project_dir/outputs"
app_dir="$output_dir/My Quota Bar.app"

cd "$project_dir"
# 编译 universal（arm64 + x86_64），使 Apple Silicon 与 Intel Mac 都能运行。
swift build -c release --arch arm64 --arch x86_64

# Recreate only this script's generated application bundle.
if [[ -d "$app_dir" ]]; then
    /bin/rm -rf "$app_dir"
fi
mkdir -p "$app_dir/Contents/MacOS"
# --arch 双架构产物在 apple/ 子目录（而非 release/）
bin_src="$project_dir/.build/apple/Products/Release/MyQuotaBar"
if [[ ! -f "$bin_src" ]]; then
    bin_src="$project_dir/.build/release/MyQuotaBar"
fi
cp "$bin_src" "$app_dir/Contents/MacOS/MyQuotaBar"
cp "$project_dir/Resources/Info.plist" "$app_dir/Contents/Info.plist"
chmod 755 "$app_dir/Contents/MacOS/MyQuotaBar"

xattr -cr "$app_dir"

# 签名身份：用固定的本地自签名证书（而非 ad-hoc "-"）。
# 原因：ad-hoc 签名的应用身份是二进制哈希，每次重新编译都变，钥匙串里的
# AK/SK 条目会把它当成另一个 App 而反复弹授权框（每账号 AK/SK 各一次）。
# 固定证书的 leaf hash 跨构建稳定，用户点一次「始终允许」后永久生效。
# 证书不存在时自动生成并导入登录钥匙串（-T 授权 codesign 使用私钥，签名不弹窗）。
sign_identity="My Quota Bar Signing"
# 注意：不加 -v —— 自签证书不受系统信任（CSSMERR_TP_NOT_TRUSTED），但 codesign
# 与钥匙串 ACL 只认证书指纹（designated requirement），不需要信任链。
if ! security find-identity -p codesigning | grep -qF "$sign_identity"; then
    echo "未找到签名证书，正在生成本地自签名证书：$sign_identity"
    cert_tmp=$(mktemp -d)
    # 自签证书必须带 codeSigning 扩展密钥用法，否则钥匙串不把它认作签名身份。
    cat > "$cert_tmp/openssl.cnf" <<'EOF'
[req]
distinguished_name = dn
x509_extensions = v3
[dn]
[v3]
basicConstraints = critical, CA:FALSE
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF
    openssl req -x509 -newkey rsa:2048 -nodes \
        -config "$cert_tmp/openssl.cnf" \
        -keyout "$cert_tmp/key.pem" -out "$cert_tmp/cert.pem" \
        -days 3650 -subj "/CN=$sign_identity" 2>/dev/null
    # PEM 证书与私钥分别导入，系统自动配对为签名身份；-T 授权 codesign 使用私钥。
    security import "$cert_tmp/cert.pem" \
        -k "$HOME/Library/Keychains/login.keychain-db" -T /usr/bin/codesign
    security import "$cert_tmp/key.pem" \
        -k "$HOME/Library/Keychains/login.keychain-db" -T /usr/bin/codesign
    /bin/rm -rf "$cert_tmp"
fi

codesign --force --deep --sign "$sign_identity" "$app_dir"
echo "$app_dir"
