# Zhaiwo-NativeScan

旧版 DCloud / HBuilderX 本地原生插件包，用于 iOS 扫码测试。

前端插件名保持：

```js
const scan = uni.requireNativePlugin('Zhaiwo-NativeScan')
scan.mpaasScan(options, callback)
```

## 目录

```text
package.json                         HBuilderX 本地原生插件配置
ios/                                 HBuilderX 打包读取的 iOS 插件目录
ios/Classes/                         iOS 源码备份，便于查看
ios-project/ZhaiwoNativeScan/        Xcode 静态 framework 工程
scripts/build-ios-framework.sh       macOS 构建脚本
```

## 生成 iOS framework

当前 Windows 环境不能编译 iOS `.framework`，需要在 macOS + Xcode 上执行：

```bash
cd /path/to/Scan-Module
HBUILDER_IOS_SDK=/path/to/IOS-SDK/SDK ./scripts/build-ios-framework.sh
```

`HBUILDER_IOS_SDK` 要指向解压后的 HBuilder iOS SDK 根目录，也就是里面包含：

```text
SDK/inc/DCUni/DCUniModule.h
```

构建成功后会生成：

```text
ios/ZhaiwoNativeScan.framework
```

然后在 HBuilderX 里选择这个 `Scan-Module` 文件夹作为本地原生插件即可。

## 识别能力

相机实时扫码支持二维码和常见条形码，并同时开启 PDF417、DataMatrix、Aztec 等系统支持的码型，不需要业务层切换类型。

相册识别使用 iOS 系统 `CIDetectorTypeQRCode`，主要稳定识别二维码；相册条形码如需更强识别，需要后续接入第三方解码库。
