package com.nothix.gitmit

import android.content.Intent
import android.net.Uri

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
	private val channel = "gitmit/open_url"

	override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
		super.configureFlutterEngine(flutterEngine)

		MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channel)
			.setMethodCallHandler { call, result ->
				if (call.method != "open") {
					result.notImplemented()
					return@setMethodCallHandler
				}

				val url = call.argument<String>("url")?.trim().orEmpty()
				if (url.isEmpty()) {
					result.success(false)
					return@setMethodCallHandler
				}

				try {
					val intent = Intent(Intent.ACTION_VIEW, Uri.parse(url))
					intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
					startActivity(intent)
					result.success(true)
				} catch (_: Exception) {
					result.success(false)
				}
			}
	}
}
