# -*- coding: utf-8 -*-
"""HarmonyOS 签名材料体检（可复用）

用途：一眼看清本地签名材料的真实情况，避免"以为有发布证书，其实全是调试证书"这类误判。

覆盖四项检查：
  ① .cer 按【证书链】逐块解析 —— 找出叶子证书（真正的应用证书）并判定是
     调试证书（CN 含 Development）还是发布证书（CN 含 Release）
  ② .p7b 解析 type / bundle-name / 应用服务能力 / allowed-acls / 是否含 device-ids
  ③ .p12 口令与私钥探测（口令从命令行传入，脚本不回显口令）
  ④ .csr 公钥指纹 —— 与证书叶子比对，判断某个 p12 是否就是该证书的密钥库

用法：
  python signing_check.py                      # 只做 ①②④（不需口令）
  python signing_check.py <p12密码>            # 额外做 ③，并列出 p12 里的公钥指纹
  python signing_check.py <p12密码> <别名>

关键知识（踩过的坑）：
  · .cer 是**证书链**（根 CA → 中间 CA → 叶子证书），用 x509.load_pem_x509_certificate
    只读第一块会得到同一张根 CA，从而误判"所有证书都一样"。必须逐块解析。
  · .p12 的密码有两层：密钥库密码（打开库）与密钥密码（该别名下的私钥）。
    DevEco 新建密钥库时两者默认相同，通常填同一个即可。
  · cryptography 的 PKCS#12 绑定在遇到以 NUL 开头的口令字节时会抛
    pyo3_runtime.PanicException（不是 Exception 子类），必须捕获 BaseException。
    Java 的 keytool 惯用 UTF-16BE 口令，但该绑定会把字节当 C 字符串，
    因此只传 ASCII 口令。
"""
import hashlib
import os
import re
import sys
import glob

try:
    from cryptography import x509
    from cryptography.hazmat.primitives import serialization
    from cryptography.hazmat.primitives.serialization import pkcs12
except ImportError:
    print('缺少 cryptography：pip install cryptography')
    sys.exit(1)

PEM_RE = re.compile(rb'-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----', re.S)

# 常见搜索位置（可按项目调整）
SEARCH_ROOTS = [
    r'D:\download',
    r'C:\Users\10735\.ohos\config',
    r'C:\Users\10735',
]


def find_files(exts):
    hits = []
    for root in SEARCH_ROOTS:
        if not os.path.isdir(root):
            continue
        for dp, dn, fn in os.walk(root):
            if dp.count(os.sep) - root.count(os.sep) > 3:
                dn[:] = []
                continue
            for f in fn:
                if f.lower().endswith(exts):
                    hits.append(os.path.join(dp, f))
    return sorted(set(hits))


def pub_fp(pk):
    der = pk.public_bytes(encoding=serialization.Encoding.DER,
                          format=serialization.PublicFormat.SubjectPublicKeyInfo)
    return hashlib.sha256(der).hexdigest()


def cert_chain(path):
    """返回证书链列表（按文件内顺序：根 → 叶子）"""
    raw = open(path, 'rb').read()
    blocks = PEM_RE.findall(raw)
    certs = []
    if blocks:
        for b in blocks:
            try:
                certs.append(x509.load_pem_x509_certificate(b))
            except Exception:
                pass
    if not certs:
        for ld in (x509.load_der_x509_certificate, x509.load_pem_x509_certificate):
            try:
                certs = [ld(raw)]
                break
            except Exception:
                pass
    return certs


print('#' * 78)
print('# ① 证书（.cer）：按证书链解析，定位叶子证书')
print('#' * 78)
leaf_fps = {}
for p in find_files(('.cer',)):
    certs = cert_chain(p)
    print('\n%s' % p)
    if not certs:
        print('   [无法解析]')
        continue
    print('   链长 %d   整文件SHA256 %s' % (len(certs), hashlib.sha256(open(p, 'rb').read()).hexdigest()[:20]))
    leaf = certs[-1]
    cn = ''
    try:
        for attr in leaf.subject.get_attributes_for_oid(x509.NameOID.COMMON_NAME):
            cn = attr.value
    except Exception:
        pass
    kind = '调试证书' if 'Development' in cn else ('发布证书' if 'Release' in cn else '未知类型')
    try:
        val = '%s ~ %s' % (leaf.not_valid_before_utc.date(), leaf.not_valid_after_utc.date())
    except Exception:
        val = '?'
    fp = pub_fp(leaf.public_key())
    leaf_fps[p] = fp
    print('   叶子主体 CN : %s' % cn[:80])
    print('   类型判定    : 【%s】' % kind)
    print('   有效期      : %s' % val)
    print('   公钥指纹    : %s' % fp[:32])

print()
print('#' * 78)
print('# ② Profile（.p7b）：类型 / 包名 / 能力 / ACL / 是否调试')
print('#' * 78)
for p in find_files(('.p7b',)):
    txt = open(p, 'rb').read().decode('latin-1')
    print('\n%s' % p)
    m = re.search(r'"type"\s*:\s*"([^"]*)"', txt)
    b = re.search(r'"bundle-name"\s*:\s*"([^"]*)"', txt)
    caps = sorted(set(re.findall(r'"(com\.[a-z0-9_.\-]*service[a-z0-9_.\-]*)"', txt)))
    acls = re.search(r'"allowed-acls"\s*:\s*\[([^\]]*)\]', txt)
    print('   type=%s   bundle=%s' % (m.group(1) if m else '?', b.group(1) if b else '?'))
    print('   应用服务能力: %s' % (caps if caps else '（未解析到）'))
    print('   allowed-acls: %s' % (acls.group(1).strip() if acls else '（未解析到）'))
    print('   含 device-ids: %s' % ('是（调试 Profile）' if 'device-ids' in txt else '否'))
    print('   ← 代理提醒需在「应用服务能力」里出现；没有它 = 该 Profile 签出的包发不出提醒')

print()
print('#' * 78)
print('# ④ CSR 公钥指纹（用于判断某个 p12 是否就是该证书的密钥库）')
print('#' * 78)
csr_fps = {}
for p in find_files(('.csr',)):
    try:
        data = open(p, 'rb').read()
        csr = None
        for ld in (x509.load_der_x509_csr, x509.load_pem_x509_csr):
            try:
                csr = ld(data)
                break
            except Exception:
                pass
        if csr is None:
            print('   [无法解析] %s' % p)
            continue
        fp = pub_fp(csr.public_key())
        csr_fps[p] = fp
        print('   %-72s %s' % (os.path.basename(p), fp[:32]))
    except Exception as e:
        print('   [错误] %s %s' % (p, e))
for cp, cfp in leaf_fps.items():
    for sp, sfp in csr_fps.items():
        if cfp == sfp:
            print('   ★ 配对：%s  ←→  %s' % (os.path.basename(cp), os.path.basename(sp)))

print()
print('#' * 78)
print('# ③ p12 口令 / 私钥探测')
print('#' * 78)
pw = sys.argv[1] if len(sys.argv) > 1 else None
p12s = find_files(('.p12',))
if not pw:
    print('未提供口令，跳过。用法：python signing_check.py <p12密码> [别名]')
    print('（共发现 %d 个 .p12：%s）' % (len(p12s), [os.path.basename(x) for x in p12s]))
else:
    for p in p12s:
        print('\n%s' % p)
        try:
            key, cert, extra = pkcs12.load_key_and_certificates(open(p, 'rb').read(), pw.encode('ascii'))
        except BaseException as e:
            print('   ❌ 打不开：%s' % type(e).__name__)
            continue
        print('   ✅ 口令正确')
        print('   私钥: %s   额外证书 %d 张' % (type(key).__name__ if key else '无', len(extra or [])))
        if cert is not None:
            f = pub_fp(cert.public_key())
            print('   库内证书公钥指纹: %s' % f[:32])
            for cp, cfp in leaf_fps.items():
                if cfp == f:
                    print('   ★ 该 p12 与 %s 配套' % os.path.basename(cp))
