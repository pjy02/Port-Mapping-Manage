# 发布与签名

发布工作流只接受 `vX.Y.Z` 标签，并要求仓库 Secret `PMM_RELEASE_SIGNING_KEY`。工作流先验证私钥与仓库内公钥完全匹配，再对 `release-manifest.sha256` 签名；缺少密钥、密钥不匹配或签名自检失败时均停止发布。

当前发布公钥指纹（PKIX DER 的 SHA-256）：

```text
5e4c8fba36596ef61c3e0beaf4d44c5ce93dcf529e0b97cf645d9c4f8807f38c
```

首次配置时，在受信任的本地环境将私钥写入 GitHub Actions Secret：

```bash
gh secret set PMM_RELEASE_SIGNING_KEY < .release-keys/release-signing-private.pem
```

确认 Secret 已写入并做好离线加密备份后，删除工作目录中的私钥。`.release-keys/` 已被 Git 忽略，但忽略规则不能替代密钥保管。

```bash
rm -f .release-keys/release-signing-private.pem
```

创建发布：

```bash
git tag -a v6.0.0 -m 'Port Mapping Manager v6.0.0'
git push origin v6.0.0
```

不要复用或移动已有版本标签。若必须轮换密钥，应先提交新公钥到以下三个位置并通过一致性测试，再更新 Secret，最后发布新版本：

- `release-signing-public.pem`
- `install_pmm.sh` 中的内置公钥
- `internal/updater/release-signing-public.pem`

轮换公钥会使旧二进制无法直接验证新签名。正常轮换应提前一个版本发布同时信任新旧两把公钥的过渡版本，然后再停止使用旧私钥。
