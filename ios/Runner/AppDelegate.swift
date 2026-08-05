import Flutter
import UIKit
import Security

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    registerHardwareKeyChannel(engineBridge)
  }

  // MARK: - 安全硬件密钥通道（Secure Enclave）

  /// 注册与 Android 端一致的通道：ai_saga/hardware_key
  ///  - getPublicKey：从 Keychain（Secure Enclave）获取/生成 ECDSA P-256 公钥（Base64，DER SubjectPublicKeyInfo）
  ///  - sign：用 Secure Enclave 私钥对 Base64 数据做 ECDSA SHA256 签名（X9.62 DER）
  ///  - hasKey：查询本机是否已有密钥
  private func registerHardwareKeyChannel(_ engineBridge: FlutterImplicitEngineBridge) {
    let channel = FlutterMethodChannel(
      name: "ai_saga/hardware_key",
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(FlutterError(code: "NO_APP", message: "AppDelegate 不可用", details: nil))
        return
      }
      switch call.method {
      case "getPublicKey":
        do {
          result(try self.getOrCreatePublicKey())
        } catch {
          result(FlutterError(code: "KEY_ERROR", message: error.localizedDescription, details: nil))
        }
      case "sign":
        guard let args = call.arguments as? [String: Any],
              let dataB64 = args["data"] as? String else {
          result(FlutterError(code: "BAD_ARGS", message: "缺少 data 参数", details: nil))
          return
        }
        do {
          result(try self.sign(dataB64: dataB64))
        } catch {
          result(FlutterError(code: "SIGN_ERROR", message: error.localizedDescription, details: nil))
        }
      case "hasKey":
        result(self.hasKey())
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private static let keyAlias = "ai_saga_device_key"
  private static let keyTag = "com.example.ai_saga.devicekey".data(using: .utf8)!

  private var keyQuery: [String: Any] {
    [
      kSecClass as String: kSecClassKey,
      kSecAttrApplicationTag as String: AppDelegate.keyTag,
      kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
      kSecAttrTokenID as String: kSecAttrTokenIDSecureEnclave,
    ]
  }

  private func hasKey() -> Bool {
    var item: CFTypeRef?
    let status = SecItemCopyMatching(keyQuery as CFDictionary, &item)
    return status == errSecSuccess
  }

  private func getOrCreatePublicKey() throws -> String {
    if !hasKey() {
      try generateKeyPair()
    }
    guard let pubKey = try? loadPublicKey() else {
      throw NSError(domain: "hardware_key", code: -1, userInfo: [NSLocalizedDescriptionKey: "无法读取 Secure Enclave 公钥"])
    }
    let derData = try publicKeyDER(pubKey)
    return derData.base64EncodedString()
  }

  private func generateKeyPair() throws {
    let access = SecAccessControlCreateWithFlags(
      nil,
      kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
      [.privateKeyUsage],
      nil
    )!

    let attributes: [String: Any] = [
      kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
      kSecAttrKeySizeInBits as String: 256,
      kSecAttrTokenID as String: kSecAttrTokenIDSecureEnclave,
      kSecAttrLabel as String: AppDelegate.keyAlias,
      kSecAttrApplicationTag as String: AppDelegate.keyTag,
      kSecAttrAccessControl as String: access,
      kSecPrivateKeyAttrs as String: [
        kSecAttrIsPermanent as String: true,
      ],
      kSecPublicKeyAttrs as String: [
        kSecAttrIsPermanent as String: false,
      ],
    ]

    var error: Unmanaged<CFError>?
    guard SecKeyCreateRandomKey(attributes as CFDictionary, &error) != nil else {
      let message = error?.takeRetainedValue().localizedDescription ?? "生成 Secure Enclave 密钥失败"
      throw NSError(domain: "hardware_key", code: -2, userInfo: [NSLocalizedDescriptionKey: message])
    }
  }

  /// 加载 Secure Enclave 公钥。
  private func loadPublicKey() throws -> SecKey {
    var item: CFTypeRef?
    let status = SecItemCopyMatching(keyQuery as CFDictionary, &item)
    guard status == errSecSuccess, let key = item as? SecKey else {
      throw NSError(domain: "hardware_key", code: -3, userInfo: [NSLocalizedDescriptionKey: "未找到 Secure Enclave 公钥"])
    }
    return key
  }

  /// 将 SecKey 公钥导出为 DER SubjectPublicKeyInfo。
  private func publicKeyDER(_ pubKey: SecKey) throws -> Data {
    var error: Unmanaged<CFError>?
    guard let data = SecKeyCopyExternalRepresentation(pubKey, &error) as Data? else {
      let message = error?.takeRetainedValue().localizedDescription ?? "导出公钥失败"
      throw NSError(domain: "hardware_key", code: -4, userInfo: [NSLocalizedDescriptionKey: message])
    }
    // Secure Enclave EC 公钥的 external representation 是 X9.63 格式：
    // 0x04 || X(32) || Y(32)，需要包装成 SubjectPublicKeyInfo 以便与其他端互操作。
    return wrapX963ToSubjectPublicKeyInfo(data)
  }

  /// 将 X9.63 格式（0x04||X||Y）包装为 SPKI（包含 P-256 OID）。
  private func wrapX963ToSubjectPublicKeyInfo(_ x963: Data) -> Data {
    // SEC1 OID: 1.2.840.10045.2.1 (id-ecPublicKey)
    // P-256 OID: 1.2.840.10045.3.1.7
    // AlgorithmIdentifier: 30 13 06 07 2A 86 48 CE 3D 02 01 06 08 2A 86 48 CE 3D 03 01 07
    let algorithmIdentifier: [UInt8] = [
      0x30, 0x13, 0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01,
      0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07,
    ]
    var spki = Data()
    spki.append(0x30) // SEQUENCE
    spki.append(0x59) // length (0x59 = 89)
    spki.append(contentsOf: algorithmIdentifier)
    spki.append(0x03) // BIT STRING
    spki.append(0x42) // length (66)
    spki.append(0x00) // unused bits
    spki.append(x963)
    return spki
  }

  /// 用 Secure Enclave 私钥对 Base64 数据做 ECDSA SHA256 签名，返回 Base64（DER X9.62）。
  private func sign(dataB64: String) throws -> String {
    if !hasKey() {
      try generateKeyPair()
    }
    guard let data = Data(base64Encoded: dataB64) else {
      throw NSError(domain: "hardware_key", code: -5, userInfo: [NSLocalizedDescriptionKey: "data 不是合法 Base64"])
    }

    var query = keyQuery
    query[kSecReturnRef as String] = true
    query[kSecClass as String] = kSecClassKey
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    guard status == errSecSuccess, let privateKey = item as! SecKey? else {
      throw NSError(domain: "hardware_key", code: -6, userInfo: [NSLocalizedDescriptionKey: "无法读取 Secure Enclave 私钥"])
    }

    var error: Unmanaged<CFError>?
    guard let sig = SecKeyCreateSignature(
      privateKey,
      .ecdsaSignatureMessageX962SHA256,
      data as CFData,
      &error
    ) as Data? else {
      let message = error?.takeRetainedValue().localizedDescription ?? "Secure Enclave 签名失败"
      throw NSError(domain: "hardware_key", code: -7, userInfo: [NSLocalizedDescriptionKey: message])
    }
    return sig.base64EncodedString()
  }
}
