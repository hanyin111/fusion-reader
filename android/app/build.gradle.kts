import java.security.KeyStore
import java.security.MessageDigest

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Keep the existing shared key, but explicitly select its file. AGP's default
// debug-key location is not a contract with the CI restore location.
val fusionKeystore = System.getenv("FUSION_ANDROID_KEYSTORE")
    ?: "${System.getProperty("user.home")}/.android/debug.keystore"

android {
    namespace = "app.fusionreader.fusion_reader"
    // file_picker's dependencies require at least 36; the Flutter default
    // still resolves to 34 here.
    compileSdk = 36
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "app.fusionreader.fusion_reader"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("fusionRelease") {
            storeFile = file(fusionKeystore)
            storePassword = "android"
            keyAlias = "androiddebugkey"
            keyPassword = "android"
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("fusionRelease")
        }
    }
}

// Fail before packaging instead of silently generating or using another key.
val verifyFusionReleaseSigning = tasks.register("verifyFusionReleaseSigning") {
    doLast {
        val config = android.signingConfigs.getByName("fusionRelease")
        val keyFile = requireNotNull(config.storeFile)
        check(keyFile.isFile) {
            "FusionReader release key is missing. Restore the existing shared key; do not generate a new one."
        }
        val keyStore = KeyStore.getInstance(keyFile, config.storePassword!!.toCharArray())
        check(keyStore.isKeyEntry(config.keyAlias)) { "Release signing private key is missing." }
        val certificate = requireNotNull(keyStore.getCertificate(config.keyAlias))
        val fingerprint = MessageDigest.getInstance("SHA-256")
            .digest(certificate.encoded)
            .joinToString("") { (it.toInt() and 0xff).toString(16).padStart(2, '0') }
        val expected = rootProject.file("signing-certificate.sha256").readText().trim()
        check(fingerprint == expected) {
            "Wrong release signing certificate: $fingerprint. Expected $expected."
        }
        logger.lifecycle("FusionReader release signing certificate SHA-256: $fingerprint")
    }
}
tasks.matching { it.name == "preReleaseBuild" || it.name == "validateSigningRelease" }.configureEach {
    dependsOn(verifyFusionReleaseSigning)
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
