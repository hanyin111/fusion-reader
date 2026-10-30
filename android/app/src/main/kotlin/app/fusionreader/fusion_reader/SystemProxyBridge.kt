package app.fusionreader.fusion_reader

import android.content.Context
import android.net.ConnectivityManager
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/** Read the current Wi-Fi/VPN HTTP proxy without binding the app to a network. */
object SystemProxyBridge {
    fun register(engine: FlutterEngine, context: Context) {
        val connectivity = context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        MethodChannel(engine.dartExecutor.binaryMessenger, "fusion_reader/system_proxy")
            .setMethodCallHandler { call, result ->
                if (call.method != "settings") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                try {
                    // getDefaultProxy includes a proxy advertised by the active
                    // VPN. Do not read the underlying Wi-Fi network instead.
                    val proxy = connectivity.defaultProxy
                    val address = endpoint(proxy?.host, proxy?.port ?: -1)
                    val http = address.ifEmpty { propertyEndpoint("http") }
                    val https = address.ifEmpty { propertyEndpoint("https").ifEmpty { http } }
                    val bypass = proxy?.exclusionList?.toList()
                        ?: System.getProperty("http.nonProxyHosts", "").split('|')
                    result.success(mapOf("http" to http, "https" to https, "bypass" to bypass))
                } catch (error: Exception) {
                    result.error("proxy_settings", "Unable to read system proxy settings", null)
                }
            }
    }

    private fun propertyEndpoint(scheme: String): String = endpoint(
        System.getProperty("$scheme.proxyHost"),
        System.getProperty("$scheme.proxyPort")?.toIntOrNull() ?: -1,
    )

    private fun endpoint(host: String?, port: Int): String {
        if (host.isNullOrBlank() || port !in 1..65535) return ""
        val formatted = if (host.contains(':') && !host.startsWith('[')) "[$host]" else host
        return "$formatted:$port"
    }
}
