package app.fusionreader.fusion_reader

import android.content.Intent
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.security.MessageDigest

class MainActivity : FlutterActivity() {
    private var installResult: MethodChannel.Result? = null
    private var installFile: File? = null
    private val installPermissionRequest = 40281

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "app.fusionreader/updater")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "platformInfo" -> {
                        val nativeDir = File(applicationInfo.nativeLibraryDir).name
                        val abi = when (nativeDir) {
                            "arm64" -> "arm64-v8a"
                            "arm" -> "armeabi-v7a"
                            "x86_64" -> "x86_64"
                            else -> Build.SUPPORTED_ABIS.firstOrNull()
                        }
                        result.success(mapOf("abi" to abi, "cachePath" to File(cacheDir, "updates").absolutePath))
                    }
                    "installApk" -> {
                        if (installResult != null) {
                            result.error("install_busy", "请先完成系统安装授权。", null)
                            return@setMethodCallHandler
                        }
                        try {
                            val path = requireNotNull(call.argument<String>("path"))
                            val file = File(path).canonicalFile
                            val allowed = File(cacheDir, "updates").canonicalPath + File.separator
                            check(file.path.startsWith(allowed) && file.isFile && file.name == "package.apk") {
                                "安装包位置无效，请重新下载。"
                            }
                            verifyApk(file)
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && !packageManager.canRequestPackageInstalls()) {
                                installResult = result
                                installFile = file
                                startActivityForResult(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                                    Uri.parse("package:$packageName")), installPermissionRequest)
                            } else {
                                launchInstaller(file)
                                result.success(null)
                            }
                        } catch (error: Exception) {
                            installResult = null
                            installFile = null
                            result.error("install_failed", error.message ?: "无法启动系统安装。", null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    @Suppress("DEPRECATION")
    private fun signatures(info: PackageInfo): Set<String> {
        val signatures = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P)
            info.signingInfo?.apkContentsSigners else info.signatures
        return signatures?.map { signature ->
            MessageDigest.getInstance("SHA-256").digest(signature.toByteArray())
                .joinToString("") { "%02x".format(it.toInt() and 0xff) }
        }?.toSet() ?: emptySet()
    }

    @Suppress("DEPRECATION")
    private fun verifyApk(file: File) {
        val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P)
            PackageManager.GET_SIGNING_CERTIFICATES else PackageManager.GET_SIGNATURES
        val update = requireNotNull(packageManager.getPackageArchiveInfo(file.path, flags)) {
            "安装包无法读取，请重新下载。"
        }
        val current = packageManager.getPackageInfo(packageName, flags)
        check(update.packageName == packageName) { "安装包不是聚阅，请重新下载。" }
        val certificate = signatures(current)
        check(certificate.isNotEmpty() && signatures(update) == certificate) {
            "安装包签名与当前版本不一致，无法覆盖安装。请从官方发布页核对版本。"
        }
        val oldCode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) current.longVersionCode else current.versionCode.toLong()
        val newCode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) update.longVersionCode else update.versionCode.toLong()
        check(newCode > oldCode) { "安装包版本号不高于当前版本，无法更新。" }
    }

    private fun launchInstaller(file: File) {
        // Recheck after the permission screen rather than trusting a stale APK.
        verifyApk(file)
        val uri = FileProvider.getUriForFile(this, "$packageName.updates", file)
        startActivity(Intent(Intent.ACTION_VIEW).setDataAndType(uri, "application/vnd.android.package-archive")
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION))
    }

    @Deprecated("Android activity-result API", ReplaceWith("super.onActivityResult(requestCode, resultCode, data)"))
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != installPermissionRequest) return
        val result = installResult ?: return
        val file = installFile
        installResult = null
        installFile = null
        try {
            check(Build.VERSION.SDK_INT < Build.VERSION_CODES.O || packageManager.canRequestPackageInstalls()) {
                "未允许聚阅安装更新。允许后可继续安装，无需重新下载。"
            }
            launchInstaller(requireNotNull(file))
            result.success(null)
        } catch (error: Exception) {
            result.error("install_permission", error.message ?: "无法启动系统安装。", null)
        }
    }
}
