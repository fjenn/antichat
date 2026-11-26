package com.pocketpal.antichat

import android.app.ActivityManager
import android.content.ComponentCallbacks2
import android.content.Context
import android.content.res.Configuration
import com.facebook.react.bridge.Arguments
import com.facebook.react.bridge.Promise
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.bridge.ReactContextBaseJavaModule
import com.facebook.react.bridge.ReactMethod
import com.facebook.react.module.annotations.ReactModule
import com.facebook.react.modules.core.DeviceEventManagerModule
import java.io.File
import java.io.FileInputStream
import java.security.MessageDigest
import kotlin.concurrent.thread

/**
 * Android face of the AntiChat model engine: memory-pressure events, a memory
 * reading and a streamed SHA-256 with progress. Downloads use upstream's
 * resumable `DownloadModule`. JS side: `src/antichat/engine/downloads/native.ts`.
 */
@ReactModule(name = AntiChatNativeModule.NAME)
class AntiChatNativeModule(reactContext: ReactApplicationContext) :
    ReactContextBaseJavaModule(reactContext), ComponentCallbacks2 {

  init {
    reactContext.applicationContext.registerComponentCallbacks(this)
  }

  override fun getName(): String = NAME

  override fun invalidate() {
    reactApplicationContext.applicationContext.unregisterComponentCallbacks(this)
    super.invalidate()
  }

  @ReactMethod fun addListener(eventName: String) = Unit

  @ReactMethod fun removeListeners(count: Double) = Unit

  private fun emit(name: String, build: com.facebook.react.bridge.WritableMap.() -> Unit) {
    if (!reactApplicationContext.hasActiveReactInstance()) return
    reactApplicationContext
        .getJSModule(DeviceEventManagerModule.RCTDeviceEventEmitter::class.java)
        .emit(name, Arguments.createMap().apply(build))
  }

  // ---- memory -------------------------------------------------------------

  @Suppress("DEPRECATION")
  override fun onTrimMemory(level: Int) {
    // Only the levels that mean "the system is short of memory now". UI_HIDDEN and
    // BACKGROUND are routine and say nothing about pressure.
    val pressure = when (level) {
      ComponentCallbacks2.TRIM_MEMORY_RUNNING_CRITICAL,
      ComponentCallbacks2.TRIM_MEMORY_COMPLETE -> "critical"
      ComponentCallbacks2.TRIM_MEMORY_RUNNING_LOW,
      ComponentCallbacks2.TRIM_MEMORY_RUNNING_MODERATE,
      ComponentCallbacks2.TRIM_MEMORY_MODERATE -> "warning"
      else -> return
    }
    emit("onMemoryPressure") {
      putString("level", pressure)
      putInt("trimLevel", level)
    }
  }

  @Deprecated("Deprecated in Java")
  override fun onLowMemory() {
    emit("onMemoryPressure") {
      putString("level", "critical")
      putInt("trimLevel", -1)
    }
  }

  override fun onConfigurationChanged(newConfig: Configuration) = Unit

  @ReactMethod
  fun memoryInfo(promise: Promise) {
    try {
      val manager = reactApplicationContext.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
      val info = ActivityManager.MemoryInfo()
      manager.getMemoryInfo(info)
      promise.resolve(Arguments.createMap().apply {
        putDouble("availableBytes", info.availMem.toDouble())
        putDouble("totalBytes", info.totalMem.toDouble())
        putDouble("thresholdBytes", info.threshold.toDouble())
        putBoolean("lowMemory", info.lowMemory)
      })
    } catch (e: Exception) {
      promise.reject("MEMORY_INFO_FAILED", e.message, e)
    }
  }

  // ---- hashing ------------------------------------------------------------

  /** SHA-256 read in 1 MB pieces on its own thread; never holds the file in memory. */
  @ReactMethod
  fun hashFile(path: String, token: String, promise: Promise) {
    thread(name = "antichat-hash") {
      try {
        val file = File(path)
        val size = file.length()
        val digest = MessageDigest.getInstance("SHA-256")
        val buffer = ByteArray(1024 * 1024)
        var done = 0L
        var lastReport = 0L
        FileInputStream(file).use { input ->
          while (true) {
            val read = input.read(buffer)
            if (read < 0) break
            digest.update(buffer, 0, read)
            done += read
            val now = System.currentTimeMillis()
            if (size > 0 && now - lastReport > 250) {
              lastReport = now
              val fraction = done.toDouble() / size.toDouble()
              emit("onHashProgress") {
                putString("token", token)
                putDouble("fraction", fraction)
              }
            }
          }
        }
        promise.resolve(digest.digest().joinToString("") { "%02x".format(it) })
      } catch (e: Exception) {
        promise.reject("HASH_FAILED", e.message, e)
      }
    }
  }

  companion object {
    const val NAME = "AntiChatNative"
  }
}
