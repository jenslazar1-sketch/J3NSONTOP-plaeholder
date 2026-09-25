import java.io.File
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// -----------------------------------------------------------------------------
// Release signing (see docs/SIGNING.md)
//
// Where the release key comes from, in this order:
//   1. android/key.properties  (keys: storeFile, storePassword, keyAlias,
//      keyPassword; git-ignored). When this file exists it is the only source.
//   2. Environment variables    J3_KEYSTORE_PATH, J3_KEYSTORE_PASSWORD,
//      J3_KEY_ALIAS, J3_KEY_PASSWORD  (used by .github/workflows/release.yml).
// Relative keystore paths are resolved against the android/ directory.
//
// Modes:
//   -Pj3RequireReleaseSigning=true (or env J3_REQUIRE_RELEASE_SIGNING=true)
//       A missing or incomplete configuration FAILS the build and lists what
//       is missing. Used for every build that is meant to be distributed.
//   -Pj3ForceDebugSigning=true
//       Always sign release builds with the Android debug key (TEST build),
//       even if a release key is configured. Used for CI test APKs.
//   neither
//       Use the release key when it is fully configured, otherwise fall back
//       to the debug key. Such an APK is a TEST build: it cannot be updated
//       by a properly signed build and must never be distributed.
// -----------------------------------------------------------------------------
fun isTrue(value: String?): Boolean = value?.trim()?.equals("true", ignoreCase = true) == true

val requireReleaseSigning: Boolean =
    isTrue(providers.gradleProperty("j3RequireReleaseSigning").orNull) ||
        isTrue(providers.environmentVariable("J3_REQUIRE_RELEASE_SIGNING").orNull)
val forceDebugSigning: Boolean = isTrue(providers.gradleProperty("j3ForceDebugSigning").orNull)

if (requireReleaseSigning && forceDebugSigning) {
    throw GradleException(
        "j3RequireReleaseSigning and j3ForceDebugSigning were both requested; choose one.",
    )
}

val keyPropertiesFile: File = rootProject.file("key.properties")
val signingFromKeyProperties: Boolean = keyPropertiesFile.isFile
val keyProperties =
    Properties().apply {
        if (signingFromKeyProperties) {
            keyPropertiesFile.inputStream().use { load(it) }
        }
    }
val signingSource: String =
    if (signingFromKeyProperties) "android/key.properties" else "environment variables"

fun signingValue(propertyKey: String, environmentKey: String): String? {
    val raw =
        if (signingFromKeyProperties) {
            keyProperties.getProperty(propertyKey)
        } else {
            System.getenv(environmentKey)
        }
    return raw?.trim()?.takeIf { it.isNotEmpty() }
}

val keystorePathValue: String? = signingValue("storeFile", "J3_KEYSTORE_PATH")
val keystorePasswordValue: String? = signingValue("storePassword", "J3_KEYSTORE_PASSWORD")
val keyAliasValue: String? = signingValue("keyAlias", "J3_KEY_ALIAS")
val keyPasswordValue: String? = signingValue("keyPassword", "J3_KEY_PASSWORD")

val keystoreFile: File? =
    keystorePathValue?.let { path ->
        val candidate = File(path)
        if (candidate.isAbsolute) candidate else rootProject.file(path)
    }

val missingSigningItems: List<String> =
    buildList {
        val names =
            if (signingFromKeyProperties) {
                listOf("storeFile", "storePassword", "keyAlias", "keyPassword")
            } else {
                listOf("J3_KEYSTORE_PATH", "J3_KEYSTORE_PASSWORD", "J3_KEY_ALIAS", "J3_KEY_PASSWORD")
            }
        when {
            keystorePathValue == null -> add("${names[0]} (not set)")
            keystoreFile?.isFile != true -> add("${names[0]} (keystore file not found: $keystoreFile)")
        }
        if (keystorePasswordValue == null) add(names[1])
        if (keyAliasValue == null) add(names[2])
        if (keyPasswordValue == null) add(names[3])
    }

val releaseSigningConfigured: Boolean = missingSigningItems.isEmpty()
val useReleaseKey: Boolean = releaseSigningConfigured && !forceDebugSigning

if (requireReleaseSigning && !releaseSigningConfigured) {
    throw GradleException(
        "Release signing is required (j3RequireReleaseSigning / J3_REQUIRE_RELEASE_SIGNING) but the " +
            "configuration from $signingSource is incomplete. Missing: " +
            missingSigningItems.joinToString(", ") +
            ". Provide android/key.properties or the J3_KEYSTORE_PATH, J3_KEYSTORE_PASSWORD, " +
            "J3_KEY_ALIAS and J3_KEY_PASSWORD environment variables. See docs/SIGNING.md.",
    )
}

if (useReleaseKey) {
    logger.lifecycle("[J3NSONTOP] Release builds are signed with the release key from $signingSource.")
} else {
    val reason =
        if (forceDebugSigning) "j3ForceDebugSigning=true" else "release signing not configured"
    logger.warn(
        "[J3NSONTOP] Release builds are signed with the Android DEBUG key ($reason). " +
            "The result is a TEST build that must not be distributed.",
    )
}

android {
    namespace = "com.j3nsontop.multitool"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.j3nsontop.multitool"
        // minSdk 24 (Flutter default); every plugin in use needs 21 or lower.
        // See docs/TOOLCHAIN.md for the full table.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // versionCode/versionName come from `version:` in pubspec.yaml.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        // ABIs are left at Flutter's defaults: arm64-v8a, armeabi-v7a, x86_64.
    }

    signingConfigs {
        if (useReleaseKey) {
            create("release") {
                storeFile = keystoreFile
                storePassword = keystorePasswordValue
                keyAlias = keyAliasValue
                keyPassword = keyPasswordValue
            }
        }
    }

    buildTypes {
        release {
            signingConfig =
                if (useReleaseKey) {
                    signingConfigs.getByName("release")
                } else {
                    signingConfigs.getByName("debug")
                }
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
