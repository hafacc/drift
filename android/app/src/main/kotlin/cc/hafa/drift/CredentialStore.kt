package cc.hafa.drift

import android.content.Context
import android.content.SharedPreferences
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import io.hafa.mideakt.ACState
import io.hafa.mideakt.DeviceCredentials
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.update

/** Encrypted persistence for the set-up device (credentials + nickname). */
class CredentialStore(context: Context) {
    private val prefs: SharedPreferences = openPrefs(context)

    private fun openPrefs(context: Context): SharedPreferences {
        fun build(): SharedPreferences {
            val masterKey = MasterKey.Builder(context)
                .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
                .build()
            return EncryptedSharedPreferences.create(
                context,
                FILE,
                masterKey,
                EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
                EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM,
            )
        }
        return try {
            build()
        } catch (_: Exception) {
            // Keystore/prefs corrupted (e.g. after a device restore): drop & recreate.
            context.deleteSharedPreferences(FILE)
            build()
        }
    }

    fun load(): DeviceCredentials? {
        val token = prefs.getString("token", null) ?: return null
        return try {
            DeviceCredentials(
                name = prefs.getString("name", "") ?: "",
                id = prefs.getLong("id", 0),
                ip = prefs.getString("ip", "") ?: "",
                port = prefs.getInt("port", 6444),
                version = prefs.getInt("version", 3),
                token = token.hexToByteArray(),
                key = (prefs.getString("key", "") ?: "").hexToByteArray(),
                // Null for credentials saved before this field existed.
                serialNumber = prefs.getString("serial", null),
            )
        } catch (_: IllegalArgumentException) {
            // A token or key that isn't hex can't reach the AC, so it reads as not set up.
            null
        }
    }

    fun save(credentials: DeviceCredentials) = synchronized(deviceLock) {
        prefs.edit()
            .putString("name", credentials.name)
            .putLong("id", credentials.id)
            .putString("ip", credentials.ip)
            .putInt("port", credentials.port)
            .putInt("version", credentials.version)
            .putString("token", credentials.token.toHexString())
            .putString("key", credentials.key.toHexString())
            .putString("serial", credentials.serialNumber)
            .apply()
        revision.update { it + 1 }
    }

    /** Save [credentials] only if the stored device has the same id, returning whether it did. */
    fun replaceSameDevice(credentials: DeviceCredentials): Boolean = synchronized(deviceLock) {
        val holdsSameDevice = prefs.getString("token", null) != null && prefs.getLong("id", 0) == credentials.id
        if (holdsSameDevice) save(credentials)
        holdsSameDevice
    }

    /** Forget the set-up device, keeping app preferences like beep. */
    fun clear() = synchronized(deviceLock) {
        // Every persisted key except the retained prefs (beep) must be listed here; a new
        // pref added elsewhere won't be cleared unless it's also removed below.
        prefs.edit()
            .remove("name").remove("id").remove("ip").remove("port")
            .remove("version").remove("token").remove("key").remove("serial").remove("nickname")
            .remove("ls_has").remove("ls_power").remove("ls_target").remove("ls_mode").remove("ls_indoor")
            .apply()
        revision.update { it + 1 }
    }

    /** The last reading we saw, so the tile and widget can show a stable state
     *  immediately (and across process death) instead of flashing while reconnecting. */
    fun lastState(): LastState? {
        if (!prefs.getBoolean("ls_has", false)) return null
        return LastState(
            powerOn = prefs.getBoolean("ls_power", false),
            targetTemperature = prefs.getString("ls_target", null)?.toDoubleOrNull() ?: 0.0,
            modeName = prefs.getString("ls_mode", "") ?: "",
            indoorTemperature = prefs.getString("ls_indoor", null)?.toDoubleOrNull(),
            updatedAtMillis = prefs.getLong("ls_updated", 0L).takeIf { it > 0L },
        )
    }

    fun saveLastState(state: ACState) {
        prefs.edit()
            .putBoolean("ls_has", true)
            .putBoolean("ls_power", state.powerOn)
            .putString("ls_target", state.targetTemperature.toString())
            .putString("ls_mode", state.modeName)
            .putString("ls_indoor", state.indoorTemperature?.toString())
            .putLong("ls_updated", System.currentTimeMillis())
            .apply()
        revision.update { it + 1 }
    }

    fun nickname(): String = prefs.getString("nickname", "") ?: ""

    fun saveNickname(nickname: String) {
        prefs.edit().putString("nickname", nickname).apply()
        revision.update { it + 1 }
    }

    fun beepEnabled(): Boolean = prefs.getBoolean("beep", true)

    fun saveBeep(enabled: Boolean) {
        prefs.edit().putBoolean("beep", enabled).apply()
    }

    companion object {
        private const val FILE = "drift_secure"
        // Every store in the process shares one file, so a check-then-save locks across them.
        private val deviceLock = Any()

        private val revision = MutableStateFlow(0)

        /** Bumped on every write the widget shows (device, nickname, last reading), so its
         *  running session can recompose. A preference listener can't stand in:
         *  EncryptedSharedPreferences only notifies listeners on the instance that wrote,
         *  and each surface opens its own. */
        val revisions: StateFlow<Int> = revision
    }
}
