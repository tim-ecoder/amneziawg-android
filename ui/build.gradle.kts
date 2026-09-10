@file:Suppress("UnstableApiUsage")

import org.jetbrains.kotlin.gradle.dsl.JvmTarget
import org.jetbrains.kotlin.gradle.tasks.KotlinCompile

val pkg: String = providers.gradleProperty("amneziawgPackageName").get()

plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.android)
    alias(libs.plugins.kotlin.kapt)
}

android {
    buildFeatures {
        buildConfig = true
        dataBinding = true
        viewBinding = true
    }
    namespace = pkg
    defaultConfig {
        applicationId = pkg
        targetSdk = 36
        // athena: к версии апстрима добавляется номер нашей сборки.
        //
        // Иначе PackageManager не перечитывает подменённый APK: у наших сборок
        // совпадают и versionCode, и размер файла, а `touch` разбор не
        // сбрасывает -- проверено 2026-09-10, система десять минут держала
        // манифест от вчерашней установки и отвечала "Unable to start service
        // ... not found" на KernelVpnService, которого в её разборе не было.
        // Лечилось только очисткой /data/system/package_cache и перезагрузкой.
        //
        // Номер берётся из athenaBuild в gradle.properties. Поднимайте его на
        // каждую сборку, которая уезжает на аппарат.
        // versionCode двигает athenaBuild, versionName несёт нашу версию сборки
        // (krabVersion) -- ту же, что у прошивки, чтобы по экрану «о программе»
        // было видно, какая сборка стоит.
        // Имя выходного файла: amneziawg-kernel-krab-vX.Ya. Так по одному файлу
        // видно и что это наша сборка, и какой версии, без заглядывания внутрь.
        base.archivesName.set("amneziawg-kernel-" + providers.gradleProperty("krabVersion").get())
        val athenaBuild = providers.gradleProperty("athenaBuild").get().toInt()
        versionCode = providers.gradleProperty("amneziawgVersionCode").get().toInt() * 1000 + athenaBuild
        versionName = providers.gradleProperty("amneziawgVersionName").get() + "-" +
                providers.gradleProperty("krabVersion").get()
        buildConfigField("int", "MIN_SDK_VERSION", minSdk.toString())
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        isCoreLibraryDesugaringEnabled = true
    }
    buildTypes {
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles("proguard-android-optimize.txt")
            packaging {
                resources {
                    excludes += "DebugProbesKt.bin"
                    excludes += "kotlin-tooling-metadata.json"
                    excludes += "META-INF/*.version"
                }
            }
        }
        debug {
            applicationIdSuffix = ".debug"
            versionNameSuffix = "-debug"
        }
        create("googleplay") {
            initWith(getByName("release"))
            matchingFallbacks += "release"
        }
    }
    androidResources {
        generateLocaleConfig = true
    }
    lint {
        disable += "LongLogTag"
        warning += "MissingTranslation"
        warning += "ImpliedQuantity"
    }
}

dependencies {
    implementation(project(":tunnel"))
    implementation(libs.androidx.activity.ktx)
    implementation(libs.androidx.annotation)
    implementation(libs.androidx.appcompat)
    implementation(libs.androidx.constraintlayout)
    implementation(libs.androidx.coordinatorlayout)
    implementation(libs.androidx.biometric)
    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.fragment.ktx)
    implementation(libs.androidx.preference.ktx)
    implementation(libs.androidx.lifecycle.runtime.ktx)
    implementation(libs.androidx.datastore.preferences)
    implementation(libs.google.material)
    implementation(libs.zxing.android.embedded)
    implementation(libs.kotlinx.coroutines.android)
    coreLibraryDesugaring(libs.desugarJdkLibs)
}

tasks.withType<JavaCompile>().configureEach {
    options.compilerArgs.add("-Xlint:unchecked")
    options.isDeprecation = true
}

tasks.withType<KotlinCompile>().configureEach {
    compilerOptions.jvmTarget.set(JvmTarget.JVM_17)
}
