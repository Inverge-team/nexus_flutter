package net.inverge.nexus.shield

import android.content.Context
import android.os.Build
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyInfo
import android.security.keystore.KeyProperties
import android.security.keystore.StrongBoxUnavailableException
import android.util.Base64
import com.google.android.play.core.integrity.IntegrityManagerFactory
import com.google.android.play.core.integrity.StandardIntegrityManager.PrepareIntegrityTokenRequest
import com.google.android.play.core.integrity.StandardIntegrityManager.StandardIntegrityTokenProvider
import com.google.android.play.core.integrity.StandardIntegrityManager.StandardIntegrityTokenRequest
import java.math.BigInteger
import java.security.KeyFactory
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.PrivateKey
import java.security.Signature
import java.security.interfaces.ECPublicKey
import java.security.spec.ECGenParameterSpec
import java.util.concurrent.ConcurrentHashMap

/**
 * Nexus Shield — Android native side.
 *
 * The device key is an EC P-256 key generated INSIDE the Android Keystore
 * (StrongBox when the device has one, else the TEE). It never leaves the
 * hardware: Dart only ever sees the public key, the attestation certificate
 * chain, and signatures. That key is both what Google's hardware attestation
 * certifies and what signs every DPoP proof — so a Shield token can't be used
 * from anywhere but this device.
 *
 * Play Integrity uses the STANDARD API (prepare once, then cheap requests),
 * with the request hash Shield computes binding the verdict to the exchange.
 */
class NexusShield(private val context: Context) {
    private val providers = ConcurrentHashMap<Long, StandardIntegrityTokenProvider>()

    private fun keyStore(): KeyStore = KeyStore.getInstance(KEYSTORE).apply { load(null) }

    /**
     * Return the key for [alias], creating it when absent. A NEW key is
     * generated with [attestationChallenge] baked into its certificate; an
     * existing key returns its original chain (the challenge it was made for).
     */
    fun ensureKey(alias: String, attestationChallenge: ByteArray?): Map<String, Any?> {
        val ks = keyStore()
        var created = false
        var strongBox = false
        if (!ks.containsAlias(alias)) {
            strongBox = generate(alias, attestationChallenge, preferStrongBox = true)
            created = true
        }
        val cert = ks.getCertificate(alias) ?: throw IllegalStateException("no certificate for $alias")
        val pub = cert.publicKey as ECPublicKey
        val chain = ks.getCertificateChain(alias)?.map { Base64.encodeToString(it.encoded, Base64.NO_WRAP) } ?: emptyList()
        return mapOf(
            "x" to b64url(unsigned32(pub.w.affineX)),
            "y" to b64url(unsigned32(pub.w.affineY)),
            "chain" to chain,
            "hardware" to hardwareLevel(ks, alias, strongBox),
            "created" to created,
        )
    }

    /** Returns true when the key landed in StrongBox. */
    private fun generate(alias: String, challenge: ByteArray?, preferStrongBox: Boolean): Boolean {
        fun spec(strongBox: Boolean): KeyGenParameterSpec {
            val b = KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_SIGN)
                .setAlgorithmParameterSpec(ECGenParameterSpec("secp256r1"))
                .setDigests(KeyProperties.DIGEST_SHA256)
            if (challenge != null) b.setAttestationChallenge(challenge)
            if (strongBox && Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) b.setIsStrongBoxBacked(true)
            return b.build()
        }
        val gen = KeyPairGenerator.getInstance(KeyProperties.KEY_ALGORITHM_EC, KEYSTORE)
        if (preferStrongBox && Build.VERSION.SDK_INT >= Build.VERSION_CODES.P &&
            context.packageManager.hasSystemFeature("android.hardware.strongbox_keystore")
        ) {
            try {
                gen.initialize(spec(true))
                gen.generateKeyPair()
                return true
            } catch (_: StrongBoxUnavailableException) {
                // fall through to the TEE
            } catch (_: Exception) {
                // Some StrongBox implementations reject attestation or EC: use the TEE.
            }
        }
        gen.initialize(spec(false))
        gen.generateKeyPair()
        return false
    }

    private fun hardwareLevel(ks: KeyStore, alias: String, strongBox: Boolean): String {
        if (strongBox) return "strongbox"
        return try {
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
    }

    /** ECDSA-SHA256 over [data]; DER-encoded (Dart converts to JOSE r||s). */
    fun sign(alias: String, data: ByteArray): ByteArray {
        val key = keyStore().getKey(alias, null) as? PrivateKey ?: throw IllegalStateException("no key $alias")
        return Signature.getInstance("SHA256withECDSA").run {
            initSign(key)
            update(data)
            sign()
        }
    }

    fun deleteKey(alias: String) {
        val ks = keyStore()
        if (ks.containsAlias(alias)) ks.deleteEntry(alias)
    }

    /**
     * Standard Play Integrity request. The provider is prepared once per cloud
     * project (that call warms Google Play services and is the slow part);
     * [requestHash] is base64url(bindingHash) from Dart.
     */
    fun playIntegrity(cloudProjectNumber: Long, requestHash: String, done: (String?, String?) -> Unit) {
        val request: (StandardIntegrityTokenProvider) -> Unit = { provider ->
            provider.request(StandardIntegrityTokenRequest.builder().setRequestHash(requestHash).build())
                .addOnSuccessListener { done(it.token(), null) }
                .addOnFailureListener {
                    // A provider can go stale (Play services updated); prepare again next time.
                    providers.remove(cloudProjectNumber)
                    done(null, it.message ?: it.javaClass.simpleName)
                }
        }
        val cached = providers[cloudProjectNumber]
        if (cached != null) return request(cached)
        IntegrityManagerFactory.createStandard(context.applicationContext)
            .prepareIntegrityToken(PrepareIntegrityTokenRequest.builder().setCloudProjectNumber(cloudProjectNumber).build())
            .addOnSuccessListener { provider ->
                providers[cloudProjectNumber] = provider
                request(provider)
            }
            .addOnFailureListener { done(null, it.message ?: it.javaClass.simpleName) }
    }

    companion object {
        private const val KEYSTORE = "AndroidKeyStore"

        private fun b64url(b: ByteArray): String =
            Base64.encodeToString(b, Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING)

        /** Big-endian, unsigned, left-padded to exactly 32 bytes (JWK coordinate). */
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
