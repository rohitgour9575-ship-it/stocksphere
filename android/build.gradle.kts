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
subprojects {
    project.evaluationDependsOn(":app")
}

// facebook_app_events uses version range [18.0,19.0) which requires Maven
// metadata listing; pin an exact SDK version to avoid flaky network/DNS failures.
subprojects {
    configurations.configureEach {
        resolutionStrategy.eachDependency {
            if (requested.group == "com.facebook.android" &&
                requested.name == "facebook-android-sdk"
            ) {
                useVersion("18.1.3")
                because("Pin exact Facebook SDK to avoid Maven metadata range lookup")
            }
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
