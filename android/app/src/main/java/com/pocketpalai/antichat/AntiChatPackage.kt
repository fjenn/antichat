package com.pocketpal.antichat

import com.facebook.react.BaseReactPackage
import com.facebook.react.bridge.NativeModule
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.module.model.ReactModuleInfo
import com.facebook.react.module.model.ReactModuleInfoProvider

/** Registers AntiChat's own native modules (added in MainApplication.kt). */
class AntiChatPackage : BaseReactPackage() {
  override fun getModule(name: String, reactContext: ReactApplicationContext): NativeModule? =
      if (name == AntiChatNativeModule.NAME) AntiChatNativeModule(reactContext) else null

  override fun getReactModuleInfoProvider(): ReactModuleInfoProvider = ReactModuleInfoProvider {
    mapOf(
        AntiChatNativeModule.NAME to ReactModuleInfo(
            AntiChatNativeModule.NAME,
            AntiChatNativeModule.NAME,
            false, // canOverrideExistingModule
            false, // needsEagerInit
            false, // isCxxModule
            false, // isTurboModule
        )
    )
  }
}
