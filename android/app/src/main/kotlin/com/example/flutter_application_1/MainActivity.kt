package com.example.flutter_application_1

import android.os.Build
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.security.KeyStore
import java.security.PrivateKey
import java.security.Signature

/**
 * AI-SAGA 主 Activity。
 *
 * 注册原生安全硬件通道（ai_saga/hardware_key）：
 *  - getPublicKey：从 Android Keystore 获取/生成 ECDSA P-256 密钥对，返回 Base64(SPKI) 公钥。
 *  - sign：用安全硬件内私钥对数据做 SHA256withECDSA 签名。
 *  - hasKey：查询本机是否已有密钥。
 *
 * 私钥始终保存在 Android Keystore（优先 StrongBox / TEE 安全硬件），
 * 永不导出到应用层，App 只能拿到公钥与签名结果。
 */
class MainActivity : FlutterActivity() {

    companion object {
        private const val CHANNEL = "ai_saga/hardware_key"
        private const val KEY_ALIAS = "ai_saga_device_key"
        private const val ANDROID_KEYSTORE = "AndroidKeyStore"
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getPublicKey" -> {
                        try {
                            result.success(getOrCreatePublicKey())
                        } catch (e: Exception) {
                            result.error("KEY_ERROR", e.message, null)
                        }
                    }
                    "sign" -> {
                        val dataB64 = call.argument<String>("data")
                        try {
                            result.success(sign(dataB64 ?: ""))
                        } catch (e: Exception) {
                            result.error("SIGN_ERROR", e.message, null)
                        }
                    }
                    "hasKey" -> {
                        result.success(hasKey())
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun keyStore(): KeyStore {
        val ks = KeyStore.getInstance(ANDROID_KEYSTORE)
        ks.load(null)
        return ks
    }

    private fun hasKey(): Boolean = keyStore().containsAlias(KEY_ALIAS)

    /**
     * 返回 Base64(SPKI) 公钥；不存在时先生成密钥对。
     */
    private fun getOrCreatePublicKey(): String {
        val ks = keyStore()
        if (!ks.containsAlias(KEY_ALIAS)) {
            generateKeyPair()
        }
        val cert = keyStore().getCertificate(KEY_ALIAS)
            ?: throw IllegalStateException("Keystore 中不存在设备证书")
        return Base64.encodeToString(cert.publicKey.encoded, Base64.NO_WRAP)
    }

    /**
     * 生成 ECDSA P-256 密钥对，优先 StrongBox，失败自动降级到 TEE/软件 Keystore。
     */
    private fun generateKeyPair() {
        val generator =
            java.security.KeyPairGenerator.getInstance(
                KeyProperties.KEY_ALGORITHM_EC,
                ANDROID_KEYSTORE,
            )

        // 1) 尝试 StrongBox 安全硬件（API 28+）
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            try {
                val strongBoxSpec = KeyGenParameterSpec.Builder(
                    KEY_ALIAS,
                    KeyProperties.PURPOSE_SIGN or KeyProperties.PURPOSE_VERIFY,
                )
                    .setKeySize(256) // P-256
                    .setDigests(KeyProperties.DIGEST_SHA256)
                    .setUserAuthenticationRequired(false) // 无感使用，不要求生物识别
                    .setIsStrongBoxBacked(true)
                    .build()
                generator.initialize(strongBoxSpec)
                generator.generateKeyPair()
                return
            } catch (e: Exception) {
                // StrongBox 不可用：降级到 TEE / 软件 Keystore
                removeKeyIfExists()
            }
        }

        // 2) 默认 Keystore（TEE / 软件）
        val defaultSpec = KeyGenParameterSpec.Builder(
            KEY_ALIAS,
            KeyProperties.PURPOSE_SIGN or KeyProperties.PURPOSE_VERIFY,
        )
            .setKeySize(256)
            .setDigests(KeyProperties.DIGEST_SHA256)
            .setUserAuthenticationRequired(false)
            .build()
        generator.initialize(defaultSpec)
        generator.generateKeyPair()
    }

    private fun removeKeyIfExists() {
        try {
            keyStore().deleteEntry(KEY_ALIAS)
        } catch (_: Exception) {
            // 忽略删除失败
        }
    }

    /**
     * 用安全硬件私钥对 Base64 数据签名，返回 Base64 签名（DER 格式）。
     */
    private fun sign(dataB64: String): String {
        val ks = keyStore()
        if (!ks.containsAlias(KEY_ALIAS)) {
            generateKeyPair()
        }
        val privateKey = ks.getKey(KEY_ALIAS, null) as? PrivateKey
            ?: throw IllegalStateException("无法读取安全硬件私钥")
        val signature = Signature.getInstance("SHA256withECDSA")
        signature.initSign(privateKey)
        signature.update(Base64.decode(dataB64, Base64.NO_WRAP))
        return Base64.encodeToString(signature.sign(), Base64.NO_WRAP)
    }
}
