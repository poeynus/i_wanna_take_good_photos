package com.example.i_wanna_take_good_photos

import android.hardware.camera2.CameraAccessException
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val cameras = getSystemService(CameraManager::class.java)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "camera/capabilities")
            .setMethodCallHandler { call, result ->
                if (call.method != "hasFlash") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                val id = call.arguments as? String
                if (id == null) {
                    result.success(false)
                    return@setMethodCallHandler
                }
                val hasFlash = try {
                    cameras.getCameraCharacteristics(id)
                        .get(CameraCharacteristics.FLASH_INFO_AVAILABLE) == true
                } catch (_: CameraAccessException) {
                    false
                } catch (_: IllegalArgumentException) {
                    false
                }
                result.success(hasFlash)
            }
    }
}
