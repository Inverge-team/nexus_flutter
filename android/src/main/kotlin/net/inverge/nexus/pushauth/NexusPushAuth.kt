package net.inverge.nexus.pushauth

import android.app.Activity
import android.app.KeyguardManager
import android.content.Context
import android.content.pm.PackageManager
import android.hardware.biometrics.BiometricManager
import android.hardware.biometrics.BiometricPrompt
import android.os.Build
import android.os.CancellationSignal
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyInfo
import android.security.keystore.KeyPermanentlyInvalidatedException
import android.security.keystore.KeyProperties
import android.security.keystore.StrongBoxUnavailableException
import android.util.Base64
import java.math.BigInteger
import java.security.KeyFactory
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.PrivateKey
import java.security.Signature
import java.security.interfaces.ECPublicKey
import java.security.spec.ECGenParameterSpec
import java.util.concurrent.Executor

/**
 * Push Authentication — Android native side.
 *
 * Each enrolled device holds TWO EC P-256 keys generated INSIDE the Android
 * Keystore (StrongBox when available, else the TEE). Dart only ever sees the
 * public keys, their attestation chains and signatures.
 *
 *  - PRESENCE key (`<prefix>_presence`): the keystore itself refuses to sign
 *    unless the user authenticated for THIS operation (strong biometric or the
 *    device PIN/pattern/password; no time window), and it is destroyed when a
 *    new fingerprint/face is enrolled. Its attestation certificate carries those
 *    rules, so the server can prove an approval needed the user.
 *  - SILENT key (`<prefix>_silent`): no user authentication — answers silent
 *    approvals in the background and signs the device's request proofs.
 *
 * Both are created for one enrollment: the attestation challenge is derived
 * from that enrollment's token, so evidence can't be replayed into another.
 *
 * Requires Android 9 (API 28) for the framework BiometricPrompt + CryptoObject
 * — which works with any Activity (androidx's needs a FragmentActivity).
 */
class NexusPushAuth(private val context: Context) {

    class Unsupported(val reason: String, message: String) : Exception(message)

    private fun keyStore(): KeyStore = KeyStore.getInstance(KEYSTORE).apply { load(null) }

    /** Can this device hold a user-bound key? `null` = yes, else the reason. */
    fun unsupportedReason(): String? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.P) return "android_version"
        val km = context.getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager
        if (!km.isDeviceSecure) return "no_screen_lock"
        // API 28–29 can only bind a per-use key to a biometric.
        if (Build.VERSION.SDK_INT == Build.VERSION_CODES.P) {
            @Suppress("DEPRECATION")
            val fm = context.getSystemService(Context.FINGERPRINT_SERVICE) as? android.hardware.fingerprint.FingerprintManager
            @Suppress("DEPRECATION")
            if (fm == null || !fm.isHardwareDetected || !fm.hasEnrolledFingerprints()) return "biometric_not_enrolled"
        } else if (Build.VERSION.SDK_INT == Build.VERSION_CODES.Q) {
            val bm = context.getSystemService(BiometricManager::class.java)
            @Suppress("DEPRECATION")
            if (bm == null || bm.canAuthenticate() != BiometricManager.BIOMETRIC_SUCCESS) return "biometric_not_enrolled"
        }
        return null
    }

    /**
     * Create a FRESH key pair for an enrollment (any previous pair under [prefix]
     * is deleted). Returns `{presence:{x,y,chain,hardware}, silent:{…}}`.
     */
    fun createKeys(prefix: String, attestationChallenge: ByteArray): Map<String, Any?> {
        unsupportedReason()?.let { throw Unsupported(it, "Push Authentication is not available on this device: $it") }
        deleteKeys(prefix)
        val presence = generate("${prefix}_presence", attestationChallenge, userBound = true)
        val silent = generate("${prefix}_silent", attestationChallenge, userBound = false)
        return mapOf("presence" to presence, "silent" to silent)
    }

    /** The existing pair's public keys, or null when not enrolled / invalidated. */
    fun keyInfo(prefix: String): Map<String, Any?>? {
        val ks = keyStore()
        val p = "${prefix}_presence"
        val s = "${prefix}_silent"
        if (!ks.containsAlias(p) || !ks.containsAlias(s)) return null
        return mapOf("presence" to describe(ks, p, null), "silent" to describe(ks, s, null), "presenceValid" to presenceUsable(p))
    }

    fun deleteKeys(prefix: String) {
        val ks = keyStore()
        for (a in listOf("${prefix}_presence", "${prefix}_silent")) if (ks.containsAlias(a)) ks.deleteEntry(a)
    }

    /** False once a new biometric was enrolled (the keystore destroyed the key's usability). */
    private fun presenceUsable(alias: String): Boolean = try {
        Signature.getInstance("SHA256withECDSA").initSign(keyStore().getKey(alias, null) as PrivateKey)
        true
    } catch (_: KeyPermanentlyInvalidatedException) {
        false
    } catch (_: Exception) {
        true // UserNotAuthenticated etc. — usable, just needs the prompt
    }

    private fun generate(alias: String, challenge: ByteArray, userBound: Boolean): Map<String, Any?> {
        fun spec(strongBox: Boolean): KeyGenParameterSpec {
            val b = KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_SIGN)
                .setAlgorithmParameterSpec(ECGenParameterSpec("secp256r1"))
                .setDigests(KeyProperties.DIGEST_SHA256)
                .setAttestationChallenge(challenge)
            if (userBound) {
                b.setUserAuthenticationRequired(true)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                    // Timeout 0 = a fresh authentication for EVERY signature.
                    b.setUserAuthenticationParameters(0, KeyProperties.AUTH_BIOMETRIC_STRONG or KeyProperties.AUTH_DEVICE_CREDENTIAL)
                } else {
                    @Suppress("DEPRECATION")
                    b.setUserAuthenticationValidityDurationSeconds(-1)
                }
                b.setInvalidatedByBiometricEnrollment(true)
            }
            if (strongBox) b.setIsStrongBoxBacked(true)
            return b.build()
        }
        val gen = KeyPairGenerator.getInstance(KeyProperties.KEY_ALGORITHM_EC, KEYSTORE)
        var strongBox = false
        if (context.packageManager.hasSystemFeature(PackageManager.FEATURE_STRONGBOX_KEYSTORE)) {
            try {
                gen.initialize(spec(true))
                gen.generateKeyPair()
                strongBox = true
            } catch (_: StrongBoxUnavailableException) {
            } catch (_: Exception) {
                // Some StrongBox chips reject attestation / user-auth combos: use the TEE.
            }
        }
        if (!strongBox) {
            gen.initialize(spec(false))
            gen.generateKeyPair()
        }
        return describe(keyStore(), alias, if (strongBox) "strongbox" else null)
    }

    private fun describe(ks: KeyStore, alias: String, knownLevel: String?): Map<String, Any?> {
        val cert = ks.getCertificate(alias) ?: throw IllegalStateException("no certificate for $alias")
        val pub = cert.publicKey as ECPublicKey
        val chain = ks.getCertificateChain(alias)?.map { Base64.encodeToString(it.encoded, Base64.NO_WRAP) } ?: emptyList()
        return mapOf(
            "x" to b64url(unsigned32(pub.w.affineX)),
            "y" to b64url(unsigned32(pub.w.affineY)),
            "chain" to chain,
            "hardware" to (knownLevel ?: hardwareLevel(ks, alias)),
        )
    }

    private fun hardwareLevel(ks: KeyStore, alias: String): String = try {
        val key = ks.getKey(alias, null) as PrivateKey
        val info = KeyFactory.getInstance(key.algorithm, KEYSTORE).getKeySpec(key, KeyInfo::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            when (info.securityLevel) {
                KeyProperties.SECURITY_LEVEL_STRONGBOX -> "strongbox"
                KeyProperties.SECURITY_LEVEL_TRUSTED_ENVIRONMENT -> "tee"
                else -> "software"
            }
        } else {
            @Suppress("DEPRECATION")
            if (info.isInsideSecureHardware) "tee" else "software"
        }
    } catch (_: Exception) {
        "unknown"
    }

    /** Silent key: sign immediately (background-safe). DER-encoded. */
    fun signSilent(prefix: String, data: ByteArray): ByteArray {
        val key = keyStore().getKey("${prefix}_silent", null) as? PrivateKey ?: throw IllegalStateException("not enrolled")
        return Signature.getInstance("SHA256withECDSA").run {
            initSign(key)
            update(data)
            sign()
        }
    }

    /**
     * Presence key: shows the system biometric / device-credential prompt and
     * signs inside the keystore once the user authenticates. [done] gets the DER
     * signature, or an error code: `cancelled`, `invalidated` (re-enroll),
     * `no_activity`, `lockout`, `failed`.
     */
    fun signWithPresence(
        activity: Activity?,
        prefix: String,
        data: ByteArray,
        prompt: Map<String, String?>,
        executor: Executor,
        done: (ByteArray?, String?) -> Unit,
    ) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.P) return done(null, "android_version")
        if (activity == null) return done(null, "no_activity")
        val key = keyStore().getKey("${prefix}_presence", null) as? PrivateKey ?: return done(null, "not_enrolled")
        val sig = Signature.getInstance("SHA256withECDSA")
        try {
            sig.initSign(key)
        } catch (_: KeyPermanentlyInvalidatedException) {
            return done(null, "invalidated")
        }
        val builder = BiometricPrompt.Builder(activity)
            .setTitle(prompt["title"] ?: "Approve")
            .apply { prompt["subtitle"]?.let { setSubtitle(it) } }
            .apply { prompt["description"]?.let { setDescription(it) } }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            builder.setAllowedAuthenticators(BiometricManager.Authenticators.BIOMETRIC_STRONG or BiometricManager.Authenticators.DEVICE_CREDENTIAL)
        } else {
            builder.setNegativeButton(prompt["cancel"] ?: "Cancel", executor) { _, _ -> done(null, "cancelled") }
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) builder.setConfirmationRequired(false)
        builder.build().authenticate(
            BiometricPrompt.CryptoObject(sig),
            CancellationSignal(),
            executor,
            object : BiometricPrompt.AuthenticationCallback() {
                override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult) {
                    try {
                        val s = result.cryptoObject?.signature ?: return done(null, "failed")
                        s.update(data)
                        done(s.sign(), null)
                    } catch (_: Exception) {
                        done(null, "failed")
                    }
                }

                override fun onAuthenticationError(errorCode: Int, errString: CharSequence?) {
                    done(
                        null,
                        when (errorCode) {
                            // (API 28–29's negative button reports through its own listener.)
                            BiometricPrompt.BIOMETRIC_ERROR_USER_CANCELED, BiometricPrompt.BIOMETRIC_ERROR_CANCELED -> "cancelled"
                            BiometricPrompt.BIOMETRIC_ERROR_LOCKOUT, BiometricPrompt.BIOMETRIC_ERROR_LOCKOUT_PERMANENT -> "lockout"
                            else -> "failed"
                        },
                    )
                }
                // onAuthenticationFailed = one unrecognised finger; the prompt stays up.
            },
        )
    }

    companion object {
        private const val KEYSTORE = "AndroidKeyStore"

        private fun b64url(b: ByteArray): String =
            Base64.encodeToString(b, Base64.URL_SAFE or Base64.NO_PADDING or Base64.NO_WRAP)

        /** Big-endian unsigned, left-padded to 32 bytes (a P-256 coordinate). */
        private fun unsigned32(v: BigInteger): ByteArray {
            val raw = v.toByteArray()
            return when {
                raw.size == 32 -> raw
                raw.size > 32 -> raw.copyOfRange(raw.size - 32, raw.size)
                else -> ByteArray(32 - raw.size) + raw
            }
        }
    }
}
