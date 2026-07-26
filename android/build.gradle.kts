allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
// Some plugins (flutter_js, package_info_plus, wakelock_plus) still pin their
// Kotlin tasks to JVM target 1.8 while their Java tasks compile to 11, and
// Gradle refuses to build a module whose two compilers disagree. Align every
// module on 11. These are lazy task configurations on purpose: the block below
// forces subproject evaluation, so an afterEvaluate hook would arrive too late.
// Plugins disagree about their JVM target — some compile Java to 11 and Kotlin
// to 1.8, others the reverse — and Gradle refuses to build a module whose two
// compilers disagree. Pin every module to 11.
//
// This has to run at afterEvaluate: the Android plugin derives its Java compile
// settings from the extension during evaluation, so changing the extension any
// later has no effect, and changing the tasks directly gets overwritten. The
// state guard exists because the block further down forces `:app` to evaluate
// early, and registering afterEvaluate on an evaluated project throws.
fun Project.alignJvmTarget() {
    extensions.findByName("android")?.let { ext ->
        (ext as? com.android.build.gradle.BaseExtension)?.let { android ->
            android.compileOptions {
                sourceCompatibility = JavaVersion.VERSION_11
                targetCompatibility = JavaVersion.VERSION_11
            }
            // Plugin modules pin their own compileSdk (file_picker still ships
            // 34) while their transitive dependencies demand 36.
            val current = android.compileSdkVersion
                ?.removePrefix("android-")
                ?.toIntOrNull() ?: 0
            if (current < 36) android.compileSdkVersion(36)
        }
    }
    tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinCompile>().configureEach {
        compilerOptions {
            jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_11)
        }
    }
}

subprojects {
    if (state.executed) alignJvmTarget() else afterEvaluate { alignJvmTarget() }
}

subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
